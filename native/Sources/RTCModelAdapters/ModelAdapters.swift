import Foundation
import RTCContracts

public enum ModelAdapterKind: String, Codable, Sendable { case ollama, openAICompatible }

public enum ModelAdapterError: Error, Equatable, Sendable {
    case invalidEndpoint(String), unsupportedEndpoint, unavailable, unauthorized
    case malformedResponse, unsupportedSchema, responseTooLarge, timedOut, cancelled, concurrencyLimit
}

public struct ModelLimits: Sendable, Equatable {
    public var timeout: Duration = .seconds(90)
    public var maxResponseBytes = 1_048_576
    public var maxRequestBytes = 128_000
    public var maxConcurrentRequests = 1
    public init(timeout: Duration = .seconds(90), maxResponseBytes: Int = 1_048_576,
                maxRequestBytes: Int = 128_000, maxConcurrentRequests: Int = 1) {
        self.timeout = timeout; self.maxResponseBytes = maxResponseBytes
        self.maxRequestBytes = maxRequestBytes; self.maxConcurrentRequests = maxConcurrentRequests
    }
}

public struct LoopbackEndpoint: Codable, Hashable, Sendable {
    public let url: URL
    public init(_ url: URL) throws {
        guard url.scheme == "http", url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, let host = url.host,
              !host.isEmpty, url.port != nil, (1...65_535).contains(url.port!) else {
            throw ModelAdapterError.invalidEndpoint("endpoint must be an http IP literal with a port")
        }
        guard Self.isLoopback(host) else { throw ModelAdapterError.invalidEndpoint("endpoint is not loopback") }
        self.url = url
    }
    fileprivate static func isLoopback(_ host: String) -> Bool {
        if host == "127.0.0.1" || host == "::1" { return true }
        let pieces = host.split(separator: ".").compactMap { Int($0) }
        return pieces.count == 4 && pieces[0] == 127 && host == pieces.map(String.init).joined(separator: ".")
    }
}

public protocol ModelCredentialLookup: Sendable { func credential(for key: String) async throws -> String? }
public struct NoCredentials: ModelCredentialLookup {
    public init() {}
    public func credential(for key: String) async throws -> String? { nil }
}

public struct ModelHealthSnapshot: Codable, Sendable, Equatable {
    public let kind: ModelAdapterKind, endpoint: String, healthy: Bool, models: [BoundedString], schemaSupported: Bool
    public init(kind: ModelAdapterKind, endpoint: String, healthy: Bool, models: [BoundedString], schemaSupported: Bool) {
        self.kind = kind; self.endpoint = endpoint; self.healthy = healthy; self.models = models; self.schemaSupported = schemaSupported
    }
}

public protocol ModelHTTPTransport: Sendable {
    func send(_ request: URLRequest, limits: ModelLimits) async throws -> AsyncThrowingStream<Data, Error>
}

private final class RedirectDenyingDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

public struct URLSessionModelTransport: ModelHTTPTransport {
    public init() {}
    public func send(_ request: URLRequest, limits: ModelLimits) async throws -> AsyncThrowingStream<Data, Error> {
        guard let url = request.url, let host = url.host, LoopbackEndpoint.isAllowed(host) else { throw ModelAdapterError.invalidEndpoint("destination changed") }
        var request = request
        let components = limits.timeout.components
        request.timeoutInterval = Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
        request.allHTTPHeaderFields = (request.allHTTPHeaderFields ?? [:]).merging(["Accept": "application/json", "Cache-Control": "no-store"]) { _, new in new }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration, delegate: RedirectDenyingDelegate(), delegateQueue: nil)
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw ModelAdapterError.unavailable }
        return AsyncThrowingStream { continuation in
            Task {
                var total = 0
                do {
                    for try await byte in bytes {
                        total += 1; if total > limits.maxResponseBytes { throw ModelAdapterError.responseTooLarge }
                        continuation.yield(Data([byte]))
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
        }
    }
}

extension LoopbackEndpoint {
    fileprivate static func isAllowed(_ host: String) -> Bool {
        if host == "127.0.0.1" || host == "::1" { return true }
        let pieces = host.split(separator: ".").compactMap { Int($0) }
        return pieces.count == 4 && pieces[0] == 127 && host == pieces.map(String.init).joined(separator: ".")
    }
}

public final actor ModelConcurrencyGate {
    private var active = 0; private let limit: Int
    public init(limit: Int = 1) { self.limit = max(1, limit) }
    public func enter() throws { guard active < limit else { throw ModelAdapterError.concurrencyLimit }; active += 1 }
    public func leave() { active = max(0, active - 1) }
}

public enum ModelJSON {
    public static func object(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ModelAdapterError.malformedResponse }
        return object
    }
    public static func bounded(_ data: Data, _ limits: ModelLimits) throws { guard data.count <= limits.maxRequestBytes else { throw ModelAdapterError.responseTooLarge } }
}

public final class ModelAdapterRegistry: @unchecked Sendable {
    private let adapters: [ModelAdapterKind: any ModelAdapter]
    public init(adapters: [ModelAdapterKind: any ModelAdapter]) { self.adapters = adapters }
    public func adapter(for kind: ModelAdapterKind) -> (any ModelAdapter)? { adapters[kind] }
}
