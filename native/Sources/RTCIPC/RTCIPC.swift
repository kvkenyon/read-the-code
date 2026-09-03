import Foundation
import RTCContracts

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum IPCConstants {
    public static let maxFrameBytes = 4 * 1024 * 1024
    public static let maxTourBytes = 1 * 1024 * 1024
    public static let protocolMajor = 2
    public static let protocolMinor = 0
}

public struct IPCProtocolVersion: Codable, Equatable, Sendable {
    public let major: Int
    public let minor: Int
    public init(major: Int = IPCConstants.protocolMajor, minor: Int = IPCConstants.protocolMinor) {
        self.major = major; self.minor = minor
    }
}

public struct IPCEnvelope: Codable, Sendable {
    public let protocolVersion: IPCProtocolVersion
    public let requestID: UUID
    public let operation: String
    public let capability: String
    public let body: Data
    public init(requestID: UUID = UUID(), operation: String, capability: String, body: Data = Data(), version: IPCProtocolVersion = .init()) {
        self.protocolVersion = version; self.requestID = requestID; self.operation = operation; self.capability = capability; self.body = body
    }
}

public struct IPCEnvelopeResponse: Codable, Sendable {
    public let protocolVersion: IPCProtocolVersion
    public let requestID: UUID
    public let ok: Bool
    public let body: Data?
    public let error: IPCWireError?
    public init(requestID: UUID, body: Data) { self.protocolVersion = .init(); self.requestID = requestID; self.ok = true; self.body = body; self.error = nil }
    public init(requestID: UUID, error: IPCWireError) { self.protocolVersion = .init(); self.requestID = requestID; self.ok = false; self.body = nil; self.error = error }
}

public struct IPCWireError: Codable, Error, Equatable, Sendable {
    public let code: String
    public let message: String
    public let retryable: Bool
    public init(code: String, message: String, retryable: Bool = false) { self.code = code; self.message = message; self.retryable = retryable }
}

public enum IPCFrameError: Error, Equatable, Sendable { case truncated, oversize(Int), invalidUTF8, invalidJSON, unsupportedProtocol, invalidEnvelope }
public enum IPCTransportError: Error, Equatable, Sendable { case unavailable, socketPathTooLong, socketCreationFailed, bindFailed, writeFailed }

public enum IPCFrameCodec {
    public static func encode<T: Encodable>(_ value: T, limit: Int = IPCConstants.maxFrameBytes) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let payload = try encoder.encode(value)
        guard payload.count <= limit else { throw IPCFrameError.oversize(payload.count) }
        var result = Data([UInt8((payload.count >> 24) & 255), UInt8((payload.count >> 16) & 255), UInt8((payload.count >> 8) & 255), UInt8(payload.count & 255)])
        result.append(payload); return result
    }
    public static func decode(_ frame: Data, limit: Int = IPCConstants.maxFrameBytes) throws -> Data {
        guard frame.count >= 4 else { throw IPCFrameError.truncated }
        let n = Int(frame[0]) << 24 | Int(frame[1]) << 16 | Int(frame[2]) << 8 | Int(frame[3])
        guard n <= limit else { throw IPCFrameError.oversize(n) }
        guard frame.count == n + 4 else { throw IPCFrameError.truncated }
        return frame.subdata(in: 4..<frame.count)
    }
    public static func decodeJSON<T: Decodable>(_ type: T.Type, from payload: Data) throws -> T {
        guard String(data: payload, encoding: .utf8) != nil else { throw IPCFrameError.invalidUTF8 }
        do { return try JSONDecoder().decode(type, from: payload) } catch { throw IPCFrameError.invalidJSON }
    }
}

public struct IPCFrameDecoder: Sendable {
    private var buffer = Data()
    public init() {}
    public mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data); var output = [Data]()
        while buffer.count >= 4 {
            let n = Int(buffer[0]) << 24 | Int(buffer[1]) << 16 | Int(buffer[2]) << 8 | Int(buffer[3])
            guard n <= IPCConstants.maxFrameBytes else { throw IPCFrameError.oversize(n) }
            guard buffer.count >= n + 4 else { break }
            output.append(buffer.subdata(in: 4..<(n + 4))); buffer.removeSubrange(0..<(n + 4))
        }
        return output
    }
}

public protocol IPCPeerAuthenticator: Sendable { func isAuthorized(fileDescriptor: Int32) -> Bool }
public protocol IPCCapabilityStore: Sendable { func isAuthorized(_ capability: String, operation: String) -> Bool }
public struct IPCAllowList: IPCCapabilityStore, Sendable {
    private let values: Set<String>
    public init(_ values: Set<String>) { self.values = values }
    public func isAuthorized(_ capability: String, operation: String) -> Bool { !capability.isEmpty && values.contains(capability) }
}

public struct IPCDispatcher: Sendable {
    public let handler: any IPCOperationHandler
    public let peer: any IPCPeerAuthenticator
    public let capabilities: any IPCCapabilityStore
    public init(handler: any IPCOperationHandler, peer: any IPCPeerAuthenticator, capabilities: any IPCCapabilityStore) { self.handler = handler; self.peer = peer; self.capabilities = capabilities }
    public func dispatch(frame: Data, fileDescriptor: Int32) async -> Data {
        do {
            guard peer.isAuthorized(fileDescriptor: fileDescriptor) else { throw IPCWireError(code: "UNAUTHORIZED", message: "IPC peer is not authorized") }
            let payload = try IPCFrameCodec.decode(frame)
            let request = try IPCFrameCodec.decodeJSON(IPCEnvelope.self, from: payload)
            guard request.protocolVersion.major == IPCConstants.protocolMajor else { throw IPCWireError(code: "UNSUPPORTED_PROTOCOL", message: "Unsupported protocol version") }
            guard capabilities.isAuthorized(request.capability, operation: request.operation) else { throw IPCWireError(code: "UNAUTHORIZED", message: "Capability is not authorized") }
            let contract = IPCRequest(schemaVersion: RTCConstants.schemaVersion, id: request.requestID, operation: try BoundedString(request.operation), reviewID: nil, payload: request.body)
            let response = await handler.handle(contract)
            if response.ok { return (try? IPCFrameCodec.encode(IPCEnvelopeResponse(requestID: request.requestID, body: response.payload ?? Data()))) ?? Data() }
            let error = response.error.map { IPCWireError(code: $0.code.rawValue, message: $0.message.value, retryable: $0.retryable) } ?? IPCWireError(code: "INTERNAL", message: "The operation failed")
            return (try? IPCFrameCodec.encode(IPCEnvelopeResponse(requestID: request.requestID, error: error))) ?? Data()
        } catch let error as IPCWireError {
            return (try? IPCFrameCodec.encode(IPCEnvelopeResponse(requestID: UUID(), error: error))) ?? Data()
        } catch let error as IPCFrameError {
            let code = error == .oversize(0) ? "LIMIT_EXCEEDED" : "INVALID_ARGUMENT"
            return (try? IPCFrameCodec.encode(IPCEnvelopeResponse(requestID: UUID(), error: .init(code: code, message: "Malformed IPC request")))) ?? Data()
        } catch { return (try? IPCFrameCodec.encode(IPCEnvelopeResponse(requestID: UUID(), error: .init(code: "INVALID_ARGUMENT", message: "Malformed IPC request")))) ?? Data() }
    }
}

public struct SameUIDPeerAuthenticator: IPCPeerAuthenticator, Sendable {
    public init() {}
    public func isAuthorized(fileDescriptor: Int32) -> Bool {
        #if canImport(Darwin)
        var uid: uid_t = 0; var gid: gid_t = 0
        return getpeereid(fileDescriptor, &uid, &gid) == 0 && uid == geteuid()
        #else
        return true // peer credentials are enforced by the Darwin app target
        #endif
    }
}

public protocol AppActivator: Sendable { func activate() async -> Bool }
public struct NoopAppActivator: AppActivator, Sendable { public init() {}; public func activate() async -> Bool { false } }

public struct IPCClient: Sendable {
    public let socketPath: String
    public init(socketPath: String) { self.socketPath = socketPath }
    public func send(_ request: IPCEnvelope, timeout: TimeInterval = 8) throws -> IPCEnvelopeResponse {
        #if canImport(Darwin)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        #else
        let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        guard fd >= 0 else { throw IPCTransportError.socketCreationFailed }
        defer { close(fd) }
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8) + [UInt8(0)]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw IPCTransportError.socketPathTooLong }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in raw.copyBytes(from: bytes) }
        let length = socklen_t(MemoryLayout<sa_family_t>.size + bytes.count)
        guard withUnsafePointer(to: &address, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, length) } }) == 0 else { throw IPCTransportError.unavailable }
        try configureSocket(fd, timeout: timeout)
        let frame = try IPCFrameCodec.encode(request)
        try writeAll(fd, frame)
        var prefix = Data(count: 4); try readAll(fd, into: &prefix)
        let n = Int(prefix[0]) << 24 | Int(prefix[1]) << 16 | Int(prefix[2]) << 8 | Int(prefix[3])
        guard n <= IPCConstants.maxFrameBytes else { throw IPCFrameError.oversize(n) }
        var payload = Data(count: n); try readAll(fd, into: &payload)
        return try IPCFrameCodec.decodeJSON(IPCEnvelopeResponse.self, from: payload)
    }
    private func writeAll(_ fd: Int32, _ data: Data) throws { try data.withUnsafeBytes { raw in var offset = 0; while offset < data.count { let n = SocketWrite(fd, raw.baseAddress!.advanced(by: offset), data.count - offset); guard n > 0 else { throw IPCTransportError.writeFailed }; offset += n } } }
    private func readAll(_ fd: Int32, into data: inout Data) throws { let count = data.count; try data.withUnsafeMutableBytes { raw in var offset = 0; while offset < count { let n = DarwinOrGlibc(fd, raw.baseAddress!.advanced(by: offset), count - offset); guard n > 0 else { throw IPCFrameError.truncated }; offset += n } } }
}

public final class IPCServer: @unchecked Sendable {
    private static let hardClientLimit = 16
    private let path: String; private let dispatcher: IPCDispatcher; private var listener: Int32 = -1
    private let timeout: TimeInterval
    private let inFlightSlots: DispatchSemaphore
    private let acceptQueue = DispatchQueue(label: "com.readthecode.ipc.accept", qos: .userInitiated)
    private let clientQueue = DispatchQueue(label: "com.readthecode.ipc.client", qos: .userInitiated, attributes: .concurrent)
    public init(socketPath: String, dispatcher: IPCDispatcher, maximumInFlightClients: Int = 16, timeout: TimeInterval = 8) {
        self.path = socketPath
        self.dispatcher = dispatcher
        self.timeout = timeout
        self.inFlightSlots = DispatchSemaphore(value: min(max(1, maximumInFlightClients), Self.hardClientLimit))
    }
    public func start() throws {
        #if canImport(Darwin)
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        #else
        listener = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        guard listener >= 0 else { throw IPCTransportError.socketCreationFailed }
        unlink(path)
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX); let bytes = Array(path.utf8) + [UInt8(0)]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw IPCTransportError.socketPathTooLong }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let length = socklen_t(MemoryLayout<sa_family_t>.size + bytes.count)
        guard withUnsafePointer(to: &address, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, length) } }) == 0, listen(listener, 16) == 0 else { throw IPCTransportError.bindFailed }
        chmod(path, 0o600)
        acceptQueue.async { [weak self] in self?.acceptLoop() }
    }
    public func stop() { if listener >= 0 { shutdown(listener, Int32(SHUT_RDWR)); close(listener); listener = -1; unlink(path) } }
    private func acceptLoop() {
        while listener >= 0 {
            inFlightSlots.wait()
            guard listener >= 0 else { inFlightSlots.signal(); return }
            let client = accept(listener, nil, nil)
            guard client >= 0 else { inFlightSlots.signal(); continue }
            clientQueue.async {
                defer { self.inFlightSlots.signal() }
                self.serve(client)
            }
        }
    }
    private func serve(_ fd: Int32) {
        defer { close(fd) }
        var prefix = Data(count: 4)
        do {
            try configureSocket(fd, timeout: timeout)
            try read(fd, &prefix)
            let n = Int(prefix[0]) << 24 | Int(prefix[1]) << 16 | Int(prefix[2]) << 8 | Int(prefix[3])
            guard n <= IPCConstants.maxFrameBytes else { return }
            var payload = Data(count: n)
            try read(fd, &payload)
            var frame = prefix
            frame.append(payload)
            let response = Task { await dispatcher.dispatch(frame: frame, fileDescriptor: fd) }
            try write(fd, try awaitResult(response))
        } catch {}
    }
    private func read(_ fd: Int32, _ data: inout Data) throws { let count = data.count; try data.withUnsafeMutableBytes { raw in var i = 0; while i < count { let n = DarwinOrGlibc(fd, raw.baseAddress!.advanced(by: i), count - i); guard n > 0 else { throw IPCFrameError.truncated }; i += n } } }
    private func write(_ fd: Int32, _ data: Data) throws { try data.withUnsafeBytes { raw in var offset = 0; while offset < data.count { let n = SocketWrite(fd, raw.baseAddress!.advanced(by: offset), data.count - offset); guard n > 0 else { throw IPCTransportError.writeFailed }; offset += n } } }
    private func awaitResult(_ task: Task<Data, Never>) throws -> Data {
        let semaphore = DispatchSemaphore(value: 0)
        let result = LockedIPCData()
        Task {
            result.store(await task.value)
            semaphore.signal()
        }
        semaphore.wait()
        return result.load()
    }
}

private final class LockedIPCData: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Data()

    func store(_ value: Data) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    func load() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

#if canImport(Darwin)
private func DarwinOrGlibc(_ fd: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int) -> Int { Darwin.read(fd, buffer, count) }
private func SocketWrite(_ fd: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int { Darwin.write(fd, buffer, count) }
#else
private func DarwinOrGlibc(_ fd: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int) -> Int { Glibc.read(fd, buffer, count) }
private func SocketWrite(_ fd: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int { Glibc.write(fd, buffer, count) }
#endif

private func configureSocket(_ fd: Int32, timeout: TimeInterval) throws {
    let seconds = timeout.isFinite ? min(max(timeout, 0.001), TimeInterval(Int32.max)) : 8
    var value = timeval()
    value.tv_sec = Int(seconds)
    value.tv_usec = Int32((seconds - floor(seconds)) * 1_000_000)
    let size = socklen_t(MemoryLayout<timeval>.size)
    guard setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &value, size) == 0,
          setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &value, size) == 0
    else { throw IPCTransportError.unavailable }
    #if canImport(Darwin)
    var noSignal: Int32 = 1
    guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
        throw IPCTransportError.unavailable
    }
    #endif
}

public struct SpoolTransport: Sendable {
    public let directory: URL
    public init(directory: URL) throws { self.directory = directory; try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true); try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
    public func write(_ envelope: Data, id: UUID = UUID()) throws -> URL {
        guard envelope.count <= IPCConstants.maxFrameBytes else { throw IPCFrameError.oversize(envelope.count) }
        let tmp = directory.appendingPathComponent(".\(id.uuidString).tmp"), destination = directory.appendingPathComponent("\(id.uuidString).spool")
        try envelope.write(to: tmp, options: [.atomic]); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path); try FileManager.default.moveItem(at: tmp, to: destination); return destination
    }
    public func replay(_ consume: (Data) throws -> Void) throws {
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter({ $0.pathExtension == "spool" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) { try consume(Data(contentsOf: url)); try FileManager.default.removeItem(at: url) }
    }
}
