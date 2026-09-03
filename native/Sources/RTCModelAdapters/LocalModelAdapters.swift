import Foundation
import RTCContracts

private func dataFromLines(_ stream: AsyncThrowingStream<Data, Error>, limits: ModelLimits,
                           decode: @escaping ([String: Any]) throws -> Data) async throws -> Data {
    var buffer = Data(), output = Data()
    for try await chunk in stream {
        buffer.append(chunk); if buffer.count > limits.maxResponseBytes { throw ModelAdapterError.responseTooLarge }
        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer[..<newline]; buffer.removeSubrange(...newline)
            if line.isEmpty { continue }
            var payload = Data(line)
            if payload.starts(with: Data("data:".utf8)) { payload.removeFirst(5); while payload.first == 32 { payload.removeFirst() }; if payload == Data("[DONE]".utf8) { continue } }
            output.append(try decode(ModelJSON.object(payload)))
            if output.count > limits.maxResponseBytes { throw ModelAdapterError.responseTooLarge }
        }
    }
    if !buffer.isEmpty {
        var payload = buffer
        if payload.starts(with: Data("data:".utf8)) { payload.removeFirst(5); while payload.first == 32 { payload.removeFirst() } }
        if payload != Data("[DONE]".utf8) { output.append(try decode(ModelJSON.object(payload))) }
    }
    return output
}

public final class OllamaAdapter: ModelAdapter, @unchecked Sendable {
    public let endpoint: LoopbackEndpoint; public let model: String; public let limits: ModelLimits
    private let transport: any ModelHTTPTransport; private let credentials: any ModelCredentialLookup; private let gate: ModelConcurrencyGate
    private var currentTask: Task<Void, Never>?
    public init(endpoint: LoopbackEndpoint, model: String, limits: ModelLimits = .init(),
                transport: any ModelHTTPTransport = URLSessionModelTransport(), credentials: any ModelCredentialLookup = NoCredentials()) {
        self.endpoint = endpoint; self.model = model; self.limits = limits; self.transport = transport; self.credentials = credentials; self.gate = ModelConcurrencyGate(limit: limits.maxConcurrentRequests)
    }
    public func discoverModels() async throws -> [BoundedString] {
        let request = makeRequest(path: "/api/tags", method: "GET")
        let stream = try await transport.send(request, limits: limits); var data = Data()
        for try await chunk in stream { data.append(chunk); guard data.count <= limits.maxResponseBytes else { throw ModelAdapterError.responseTooLarge } }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let values = root["models"] as? [[String: Any]] else { throw ModelAdapterError.malformedResponse }
        return try values.compactMap { try BoundedString($0["name"] as? String ?? "") }
    }
    public func health() async throws -> Bool { _ = try await discoverModels(); return true }
    public func generateStructured(request: Data, schema: Data) async throws -> Data {
        try ModelJSON.bounded(request, limits); try ModelJSON.bounded(schema, limits); try await gate.enter(); defer { Task { await gate.leave() } }
        var body: [String: Any] = ["model": model, "prompt": String(data: request, encoding: .utf8) ?? "", "stream": true]
        if let schemaObject = try? JSONSerialization.jsonObject(with: schema) { body["format"] = schemaObject }
        let data = try JSONSerialization.data(withJSONObject: body); var req = makeRequest(path: "/api/generate", method: "POST"); req.httpBody = data
        return try await dataFromLines(try await transport.send(req, limits: limits), limits: limits) { item in
            if let response = item["response"] as? String { return Data(response.utf8) }
            if item["done"] as? Bool == true { return Data() }
            throw ModelAdapterError.malformedResponse
        }
    }
    public func cancel() async { currentTask?.cancel(); currentTask = nil }
    private func makeRequest(path: String, method: String) -> URLRequest { var r = URLRequest(url: endpoint.url.appendingPathComponent(String(path.dropFirst()))); r.httpMethod = method; return r }
}

public final class OpenAICompatibleAdapter: ModelAdapter, @unchecked Sendable {
    public let endpoint: LoopbackEndpoint; public let model: String; public let limits: ModelLimits
    private let transport: any ModelHTTPTransport; private let credentials: any ModelCredentialLookup; private let credentialKey: String; private let gate: ModelConcurrencyGate
    public init(endpoint: LoopbackEndpoint, model: String, credentialKey: String = "openai-compatible", limits: ModelLimits = .init(), transport: any ModelHTTPTransport = URLSessionModelTransport(), credentials: any ModelCredentialLookup = NoCredentials()) {
        self.endpoint = endpoint; self.model = model; self.credentialKey = credentialKey; self.limits = limits; self.transport = transport; self.credentials = credentials; self.gate = ModelConcurrencyGate(limit: limits.maxConcurrentRequests)
    }
    public func discoverModels() async throws -> [BoundedString] {
        let response = try await send(path: "/v1/models", method: "GET", body: nil)
        guard let values = try? JSONSerialization.jsonObject(with: response) as? [String: Any], let models = values["data"] as? [[String: Any]] else { throw ModelAdapterError.malformedResponse }
        return try models.compactMap { try BoundedString($0["id"] as? String ?? "") }
    }
    public func health() async throws -> Bool { _ = try await discoverModels(); return true }
    public func generateStructured(request: Data, schema: Data) async throws -> Data {
        try ModelJSON.bounded(request, limits); try ModelJSON.bounded(schema, limits); try await gate.enter(); defer { Task { await gate.leave() } }
        guard JSONSerialization.isValidJSONObject((try? JSONSerialization.jsonObject(with: request)) as Any) else { throw ModelAdapterError.malformedResponse }
        let messages: Any = (try? JSONSerialization.jsonObject(with: request)) ?? [["role": "user", "content": String(data: request, encoding: .utf8) ?? ""]]
        var body: [String: Any] = ["model": model, "messages": messages, "stream": true, "response_format": ["type": "json_schema", "json_schema": ["name": "tour", "schema": (try? JSONSerialization.jsonObject(with: schema)) ?? [:]]]]
        return try await dataFromLines(try await stream(path: "/v1/chat/completions", method: "POST", body: try JSONSerialization.data(withJSONObject: body)), limits: limits) { item in
            guard let choices = item["choices"] as? [[String: Any]], let delta = choices.first?["delta"] as? [String: Any], let content = delta["content"] as? String else { return Data() }; return Data(content.utf8)
        }
    }
    public func cancel() async {}
    private func send(path: String, method: String, body: Data?) async throws -> Data {
        let stream = try await stream(path: path, method: method, body: body); var result = Data()
        for try await chunk in stream { result.append(chunk); guard result.count <= limits.maxResponseBytes else { throw ModelAdapterError.responseTooLarge } }
        return result
    }
    private func stream(path: String, method: String, body: Data?) async throws -> AsyncThrowingStream<Data, Error> {
        var r = URLRequest(url: endpoint.url.appendingPathComponent(String(path.dropFirst()))); r.httpMethod = method; r.httpBody = body
        if let token = try await credentials.credential(for: credentialKey), !token.isEmpty { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return try await transport.send(r, limits: limits)
    }
}
