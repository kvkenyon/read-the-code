import Foundation
import RTCContracts

private struct DecodedModelEvent { let data: Data; let terminal: Bool }

private func dataFromLines(
    _ stream: AsyncThrowingStream<Data, Error>, limits: ModelLimits,
    decode: @escaping ([String: Any]) throws -> DecodedModelEvent
) async throws -> Data {
    let limits = try limits.validated()
    var buffer = Data(), output = Data(), chunks = 0, events = 0
    func decodedLine(_ raw: Data) throws -> DecodedModelEvent? {
        events += 1
        guard events <= limits.maxEvents, raw.count <= limits.maxLineBytes else {
            throw ModelAdapterError.responseTooLarge
        }
        if raw.isEmpty { return nil }
        var payload = raw
        if payload.starts(with: Data("data:".utf8)) {
            payload.removeFirst(5); while payload.first == 32 { payload.removeFirst() }
            if payload == Data("[DONE]".utf8) { return DecodedModelEvent(data: Data(), terminal: true) }
        }
        return try decode(ModelJSON.object(payload, limits: limits))
    }
    for try await chunk in stream {
        try Task.checkCancellation()
        chunks += 1
        guard chunks <= limits.maxChunks, chunk.count <= limits.maxLineBytes else {
            throw ModelAdapterError.responseTooLarge
        }
        buffer.append(chunk)
        if buffer.count > limits.maxResponseBytes { throw ModelAdapterError.responseTooLarge }
        while let newline = buffer.firstIndex(of: 10) {
            var line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
            if line.last == 13 { line.removeLast() }
            guard let decoded = try decodedLine(line) else { continue }
            output.append(decoded.data)
            if output.count > limits.maxResponseBytes { throw ModelAdapterError.responseTooLarge }
            if decoded.terminal { return output }
        }
        if buffer.count > limits.maxLineBytes { throw ModelAdapterError.responseTooLarge }
    }
    if !buffer.isEmpty {
        guard let decoded = try decodedLine(buffer) else { throw ModelAdapterError.malformedResponse }
        output.append(decoded.data)
        guard decoded.terminal else { throw ModelAdapterError.malformedResponse }
        guard output.count <= limits.maxResponseBytes else { throw ModelAdapterError.responseTooLarge }
        return output
    }
    throw ModelAdapterError.malformedResponse
}

public final class OllamaAdapter: ModelAdapter, @unchecked Sendable {
    public let endpoint: LoopbackEndpoint; public let model: String; public let limits: ModelLimits
    private let transport: any ModelHTTPTransport; private let credentials: any ModelCredentialLookup;
    private let gate: ModelConcurrencyGate
    private let taskLock = NSLock()
    private var activeTasks: [UUID: Task<Data, Error>] = [:]
    public init(
        endpoint: LoopbackEndpoint, model: String, limits: ModelLimits = .init(),
        transport: any ModelHTTPTransport = URLSessionModelTransport(),
        credentials: any ModelCredentialLookup = NoCredentials()
    ) {
        self.endpoint = endpoint; self.model = model; self.limits = limits; self.transport = transport;
        self.credentials = credentials; self.gate = ModelConcurrencyGate(limit: limits.maxConcurrentRequests)
    }
    public func discoverModels() async throws -> [BoundedString] {
        try await withModelDeadline(limits: limits) {
            let request = self.makeRequest(path: "/api/tags", method: "GET")
            let data = try await collect(
                try await self.transport.send(request, limits: self.limits), limits: self.limits)
            let root = try ModelJSON.object(data, limits: self.limits)
            guard let values = root["models"] as? [[String: Any]], values.count <= self.limits.maxJSONItems else {
                throw ModelAdapterError.malformedResponse
            }
            return try values.map { try BoundedString($0["name"] as? String ?? "") }.filter { !$0.value.isEmpty }
        }
    }
    public func health() async throws -> Bool { _ = try await discoverModels(); return true }
    public func generateStructured(request: Data, schema: Data) async throws -> Data {
        let taskID = UUID()
        let task = Task {
            try await withModelDeadline(limits: self.limits) {
                try await self.performGenerate(request: request, schema: schema)
            }
        }
        taskLock.withLock { activeTasks[taskID] = task }
        defer { taskLock.withLock { activeTasks[taskID] = nil } }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }
    public func cancel() async {
        let tasks = taskLock.withLock {
            let tasks = Array(activeTasks.values); activeTasks.removeAll(); return tasks
        }
        tasks.forEach { $0.cancel() }
    }
    private func performGenerate(request: Data, schema: Data) async throws -> Data {
        try ModelJSON.bounded(request, limits); try ModelJSON.bounded(schema, limits)
        do {
            try RTCJSONPreflight.validate(request, maxDepth: limits.maxJSONDepth, maxItems: limits.maxJSONItems)
            try RTCJSONPreflight.validate(schema, maxDepth: limits.maxJSONDepth, maxItems: limits.maxJSONItems)
        } catch { throw ModelAdapterError.malformedResponse }
        try await gate.enter(); defer { Task { await gate.leave() } }
        var body: [String: Any] = [
            "model": model, "prompt": String(data: request, encoding: .utf8) ?? "", "stream": true,
        ]
        if let schemaObject = try? JSONSerialization.jsonObject(with: schema) { body["format"] = schemaObject }
        let data = try JSONSerialization.data(withJSONObject: body)
        try ModelJSON.bounded(data, limits)
        var req = makeRequest(path: "/api/generate", method: "POST"); req.httpBody = data
        return try await dataFromLines(try await transport.send(req, limits: limits), limits: limits) { item in
            let terminal = item["done"] as? Bool == true
            if let response = item["response"] as? String {
                return DecodedModelEvent(data: Data(response.utf8), terminal: terminal)
            }
            if terminal { return DecodedModelEvent(data: Data(), terminal: true) }
            throw ModelAdapterError.malformedResponse
        }
    }
    private func makeRequest(path: String, method: String) -> URLRequest {
        var r = URLRequest(url: endpoint.url.appendingPathComponent(String(path.dropFirst()))); r.httpMethod = method;
        return r
    }
}

public final class OpenAICompatibleAdapter: ModelAdapter, @unchecked Sendable {
    public let endpoint: LoopbackEndpoint; public let model: String; public let limits: ModelLimits
    private let transport: any ModelHTTPTransport; private let credentials: any ModelCredentialLookup;
    private let credentialKey: String; private let gate: ModelConcurrencyGate
    private let taskLock = NSLock(); private var activeTasks: [UUID: Task<Data, Error>] = [:]
    public init(
        endpoint: LoopbackEndpoint, model: String, credentialKey: String = "openai-compatible",
        limits: ModelLimits = .init(), transport: any ModelHTTPTransport = URLSessionModelTransport(),
        credentials: any ModelCredentialLookup = NoCredentials()
    ) {
        self.endpoint = endpoint; self.model = model; self.credentialKey = credentialKey; self.limits = limits;
        self.transport = transport; self.credentials = credentials;
        self.gate = ModelConcurrencyGate(limit: limits.maxConcurrentRequests)
    }
    public func discoverModels() async throws -> [BoundedString] {
        try await withModelDeadline(limits: limits) {
            let response = try await self.send(path: "/v1/models", method: "GET", body: nil)
            let values = try ModelJSON.object(response, limits: self.limits)
            guard let models = values["data"] as? [[String: Any]], models.count <= self.limits.maxJSONItems else {
                throw ModelAdapterError.malformedResponse
            }
            return try models.map { try BoundedString($0["id"] as? String ?? "") }.filter { !$0.value.isEmpty }
        }
    }
    public func health() async throws -> Bool { _ = try await discoverModels(); return true }
    public func generateStructured(request: Data, schema: Data) async throws -> Data {
        let taskID = UUID()
        let task = Task {
            try await withModelDeadline(limits: self.limits) {
                try await self.performGenerate(request: request, schema: schema)
            }
        }
        taskLock.withLock { activeTasks[taskID] = task }
        defer { taskLock.withLock { activeTasks[taskID] = nil } }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }
    private func performGenerate(request: Data, schema: Data) async throws -> Data {
        try ModelJSON.bounded(request, limits); try ModelJSON.bounded(schema, limits)
        do {
            try RTCJSONPreflight.validate(request, maxDepth: limits.maxJSONDepth, maxItems: limits.maxJSONItems)
            try RTCJSONPreflight.validate(schema, maxDepth: limits.maxJSONDepth, maxItems: limits.maxJSONItems)
        } catch { throw ModelAdapterError.malformedResponse }
        try await gate.enter(); defer { Task { await gate.leave() } }
        guard JSONSerialization.isValidJSONObject((try? JSONSerialization.jsonObject(with: request)) as Any) else {
            throw ModelAdapterError.malformedResponse
        }
        let messages: Any =
            (try? JSONSerialization.jsonObject(with: request)) ?? [
                ["role": "user", "content": String(data: request, encoding: .utf8) ?? ""]
            ]
        let body: [String: Any] = [
            "model": model, "messages": messages, "stream": true,
            "response_format": [
                "type": "json_schema",
                "json_schema": ["name": "tour", "schema": (try? JSONSerialization.jsonObject(with: schema)) ?? [:]],
            ],
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        try ModelJSON.bounded(bodyData, limits)
        return try await dataFromLines(
            try await stream(path: "/v1/chat/completions", method: "POST", body: bodyData), limits: limits
        ) { item in
            guard let choices = item["choices"] as? [[String: Any]], choices.count <= self.limits.maxJSONItems,
                let choice = choices.first
            else { throw ModelAdapterError.malformedResponse }
            let terminal = choice["finish_reason"] is String
            let content = (choice["delta"] as? [String: Any])?["content"] as? String ?? ""
            return DecodedModelEvent(data: Data(content.utf8), terminal: terminal)
        }
    }
    public func cancel() async {
        let tasks = taskLock.withLock {
            let tasks = Array(activeTasks.values); activeTasks.removeAll(); return tasks
        }
        tasks.forEach { $0.cancel() }
    }
    private func send(path: String, method: String, body: Data?) async throws -> Data {
        try await collect(try await stream(path: path, method: method, body: body), limits: limits)
    }
    private func stream(path: String, method: String, body: Data?) async throws -> AsyncThrowingStream<Data, Error> {
        var r = URLRequest(url: endpoint.url.appendingPathComponent(String(path.dropFirst()))); r.httpMethod = method;
        r.httpBody = body
        if let token = try await credentials.credential(for: credentialKey), !token.isEmpty {
            r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return try await transport.send(r, limits: limits)
    }
}

private func collect(_ stream: AsyncThrowingStream<Data, Error>, limits: ModelLimits) async throws -> Data {
    let limits = try limits.validated()
    var result = Data(), chunks = 0
    for try await chunk in stream {
        try Task.checkCancellation(); chunks += 1
        guard chunks <= limits.maxChunks, chunk.count <= limits.maxLineBytes else {
            throw ModelAdapterError.responseTooLarge
        }
        result.append(chunk)
        guard result.count <= limits.maxResponseBytes else { throw ModelAdapterError.responseTooLarge }
    }
    return result
}
