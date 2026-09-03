import Foundation
import Darwin
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
        guard Self.isAllowed(url) else {
            throw ModelAdapterError.invalidEndpoint("endpoint must be an http IP literal with a port")
        }
        self.url = url
    }
    /// The sole address-authority parser for user input and the transport boundary.
    /// `inet_pton` rejects hostnames and non-standard/signed/out-of-range numeric forms.
    public static func isAllowed(_ url: URL) -> Bool {
        guard url.scheme == "http", url.user == nil, url.password == nil, url.query == nil,
              url.fragment == nil, let host = url.host, !host.isEmpty, let port = url.port,
              (1...65_535).contains(port) else { return false }
        var ipv4 = in_addr()
        if inet_pton(AF_INET, host, &ipv4) == 1 {
            return withUnsafeBytes(of: &ipv4) { $0.first == 127 }
        }
        var ipv6 = in6_addr()
        if inet_pton(AF_INET6, host, &ipv6) == 1 {
            let bytes = withUnsafeBytes(of: &ipv6) { Array($0) }
            return bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1
        }
        return false
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
        guard let url = request.url, LoopbackEndpoint.isAllowed(url) else { throw ModelAdapterError.invalidEndpoint("destination changed") }
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
            let producer = Task {
                var total = 0
                do {
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        total += 1; if total > limits.maxResponseBytes { throw ModelAdapterError.responseTooLarge }
                        continuation.yield(Data([byte]))
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in producer.cancel() }
        }
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
