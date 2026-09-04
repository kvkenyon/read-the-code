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

public func syncIPCDirectory(_ directory: URL) throws {
    let fd = open(directory.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw IPCTransportError.writeFailed }
    defer { close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
          fsync(fd) == 0 else { throw IPCTransportError.writeFailed }
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

/// A capability names both the principal and the only operations it may invoke.
/// This prevents a chat worker capability from being reused for review mutation.
public struct IPCScopedCapabilityStore: IPCCapabilityStore, Sendable {
    private let grants: [String: Set<String>]
    public init(_ grants: [String: Set<String>]) { self.grants = grants }
    public func isAuthorized(_ capability: String, operation: String) -> Bool {
        guard !capability.isEmpty, !operation.isEmpty else { return false }
        // Compare every token to avoid leaking which prefix matched.
        var allowed = false
        for (token, operations) in grants {
            let lhs = Array(token.utf8), rhs = Array(capability.utf8)
            var difference = UInt8(lhs.count == rhs.count ? 0 : 1)
            for index in 0..<max(lhs.count, rhs.count) {
                difference |= (index < lhs.count ? lhs[index] : 0) ^ (index < rhs.count ? rhs[index] : 0)
            }
            allowed = allowed || (difference == 0 && operations.contains(operation))
        }
        return allowed
    }
}

public typealias IPCOperationAllowList = IPCScopedCapabilityStore

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
            let code: String
            if case .oversize = error { code = "LIMIT_EXCEEDED" } else { code = "INVALID_ARGUMENT" }
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
        let deadline = IPCDeadline(timeout: timeout)
        #if canImport(Darwin)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        #else
        let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        guard fd >= 0 else { throw IPCTransportError.socketCreationFailed }
        defer { close(fd) }
        try prepareSocket(fd)
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8) + [UInt8(0)]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw IPCTransportError.socketPathTooLong }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in raw.copyBytes(from: bytes) }
        let length = socklen_t(MemoryLayout<sa_family_t>.size + bytes.count)
        let connectResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, length) }
        }
        try finishConnect(fd, result: connectResult, deadline: deadline)
        let frame = try IPCFrameCodec.encode(request)
        try writeSocket(fd, frame, deadline: deadline)
        var prefix = Data(count: 4); try readSocket(fd, into: &prefix, deadline: deadline)
        let n = Int(prefix[0]) << 24 | Int(prefix[1]) << 16 | Int(prefix[2]) << 8 | Int(prefix[3])
        guard n <= IPCConstants.maxFrameBytes else { throw IPCFrameError.oversize(n) }
        var payload = Data(count: n); try readSocket(fd, into: &payload, deadline: deadline)
        return try IPCFrameCodec.decodeJSON(IPCEnvelopeResponse.self, from: payload)
    }
}

public final class IPCServer: @unchecked Sendable {
    private static let hardClientLimit = 16
    private let path: String; private let dispatcher: IPCDispatcher; private var listener: Int32 = -1
    private let timeout: TimeInterval
    private let maximumInFlightClients: Int
    private let inFlightSlots: DispatchSemaphore
    private let clientDidAcquireSlot: (@Sendable () -> Void)?
    private let acceptQueue = DispatchQueue(label: "com.readthecode.ipc.accept", qos: .userInitiated)
    private let clientQueue = DispatchQueue(label: "com.readthecode.ipc.client", qos: .userInitiated, attributes: .concurrent)

    public convenience init(socketPath: String, dispatcher: IPCDispatcher, maximumInFlightClients: Int = 16, timeout: TimeInterval = 8) {
        self.init(socketPath: socketPath, dispatcher: dispatcher, maximumInFlightClients: maximumInFlightClients, timeout: timeout, testingClientDidAcquireSlot: nil)
    }

    @_spi(Testing)
    public convenience init(socketPath: String, dispatcher: IPCDispatcher, maximumInFlightClients: Int, timeout: TimeInterval, clientDidAcquireSlot: @escaping @Sendable () -> Void) {
        self.init(socketPath: socketPath, dispatcher: dispatcher, maximumInFlightClients: maximumInFlightClients, timeout: timeout, testingClientDidAcquireSlot: clientDidAcquireSlot)
    }

    private init(socketPath: String, dispatcher: IPCDispatcher, maximumInFlightClients: Int, timeout: TimeInterval, testingClientDidAcquireSlot: (@Sendable () -> Void)?) {
        let boundedClientLimit = min(max(1, maximumInFlightClients), Self.hardClientLimit)
        self.path = socketPath
        self.dispatcher = dispatcher
        self.timeout = timeout
        self.maximumInFlightClients = boundedClientLimit
        self.inFlightSlots = DispatchSemaphore(value: boundedClientLimit)
        self.clientDidAcquireSlot = testingClientDidAcquireSlot
    }

    @_spi(Testing) public var maximumInFlightClientsForTesting: Int { maximumInFlightClients }

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
            let deadline = IPCDeadline(timeout: timeout)
            clientDidAcquireSlot?()
            clientQueue.async {
                defer { self.inFlightSlots.signal() }
                self.serve(client, deadline: deadline)
            }
        }
    }
    private func serve(_ fd: Int32, deadline: IPCDeadline) {
        defer { close(fd) }
        var prefix = Data(count: 4)
        do {
            try prepareSocket(fd)
            try readSocket(fd, into: &prefix, deadline: deadline)
            let n = Int(prefix[0]) << 24 | Int(prefix[1]) << 16 | Int(prefix[2]) << 8 | Int(prefix[3])
            guard n <= IPCConstants.maxFrameBytes else { return }
            var payload = Data(count: n)
            try readSocket(fd, into: &payload, deadline: deadline)
            var frame = prefix
            frame.append(payload)
            let dispatcher = self.dispatcher
            let response = Task { await dispatcher.dispatch(frame: frame, fileDescriptor: fd) }
            try writeSocket(fd, try awaitResult(response, deadline: deadline), deadline: deadline)
        } catch {}
    }
    private func awaitResult(_ task: Task<Data, Never>, deadline: IPCDeadline) throws -> Data {
        let semaphore = DispatchSemaphore(value: 0)
        let result = LockedIPCData()
        Task {
            result.store(await task.value)
            semaphore.signal()
        }
        guard semaphore.wait(timeout: deadline.dispatchTime) == .success else {
            task.cancel()
            throw IPCTransportError.unavailable
        }
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

private struct IPCDeadline: Sendable {
    private let uptimeNanoseconds: UInt64

    init(timeout: TimeInterval) {
        let seconds = timeout.isFinite ? min(max(timeout, 0.001), TimeInterval(Int32.max)) : 8
        let interval = UInt64(seconds * 1_000_000_000)
        let now = DispatchTime.now().uptimeNanoseconds
        let (deadline, overflow) = now.addingReportingOverflow(interval)
        self.uptimeNanoseconds = overflow ? UInt64.max : deadline
    }

    var dispatchTime: DispatchTime { DispatchTime(uptimeNanoseconds: uptimeNanoseconds) }

    func waitForIO(fileDescriptor: Int32, events: Int16) -> Bool {
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < uptimeNanoseconds else { return false }
            let remaining = uptimeNanoseconds - now
            let milliseconds = remaining / 1_000_000 + (remaining % 1_000_000 == 0 ? 0 : 1)
            var descriptor = pollfd(fd: fileDescriptor, events: events, revents: 0)
            let result = SocketPoll(&descriptor, Int32(min(milliseconds, UInt64(Int32.max))))
            if result > 0 { return true }
            if result == 0 || errno != EINTR { return false }
        }
    }
}

private func prepareSocket(_ fd: Int32) throws {
    let flags = fcntl(fd, F_GETFL, 0)
    guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { throw IPCTransportError.unavailable }
    #if canImport(Darwin)
    var noSignal: Int32 = 1
    guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
        throw IPCTransportError.unavailable
    }
    #endif
}

private func finishConnect(_ fd: Int32, result: Int32, deadline: IPCDeadline) throws {
    if result == 0 { return }
    guard errno == EINPROGRESS || errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK,
          deadline.waitForIO(fileDescriptor: fd, events: Int16(POLLOUT))
    else { throw IPCTransportError.unavailable }
    var socketError: Int32 = 0
    var size = socklen_t(MemoryLayout<Int32>.size)
    guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &size) == 0, socketError == 0 else {
        throw IPCTransportError.unavailable
    }
}

private func readSocket(_ fd: Int32, into data: inout Data, deadline: IPCDeadline) throws {
    let count = data.count
    try data.withUnsafeMutableBytes { raw in
        var offset = 0
        while offset < count {
            guard deadline.waitForIO(fileDescriptor: fd, events: Int16(POLLIN)) else { throw IPCFrameError.truncated }
            let readCount = SocketRead(fd, raw.baseAddress!.advanced(by: offset), count - offset)
            if readCount > 0 { offset += readCount; continue }
            if readCount < 0, errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
            throw IPCFrameError.truncated
        }
    }
}

private func writeSocket(_ fd: Int32, _ data: Data, deadline: IPCDeadline) throws {
    try data.withUnsafeBytes { raw in
        var offset = 0
        while offset < data.count {
            guard deadline.waitForIO(fileDescriptor: fd, events: Int16(POLLOUT)) else { throw IPCTransportError.writeFailed }
            let written = SocketWrite(fd, raw.baseAddress!.advanced(by: offset), data.count - offset)
            if written > 0 { offset += written; continue }
            if written < 0, errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
            throw IPCTransportError.writeFailed
        }
    }
}

#if canImport(Darwin)
private func SocketRead(_ fd: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int) -> Int { Darwin.read(fd, buffer, count) }
private func SocketWrite(_ fd: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int { Darwin.write(fd, buffer, count) }
private func SocketPoll(_ descriptor: inout pollfd, _ timeout: Int32) -> Int32 { Darwin.poll(&descriptor, 1, timeout) }
#else
private func SocketRead(_ fd: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int) -> Int { Glibc.read(fd, buffer, count) }
private func SocketWrite(_ fd: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int { Glibc.send(fd, buffer, count, Int32(MSG_NOSIGNAL)) }
private func SocketPoll(_ descriptor: inout pollfd, _ timeout: Int32) -> Int32 { Glibc.poll(&descriptor, 1, timeout) }
#endif

public struct SpoolTransport: Sendable {
    public let directory: URL
    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var info = stat()
        guard lstat(directory.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == geteuid(), chmod(directory.path, 0o700) == 0 else { throw IPCTransportError.unavailable }
    }
    public func write(_ envelope: Data, id: UUID = UUID()) throws -> URL {
        guard envelope.count <= IPCConstants.maxFrameBytes + 4 else { throw IPCFrameError.oversize(envelope.count) }
        let tmp = directory.appendingPathComponent(".\(id.uuidString).\(UUID().uuidString).tmp")
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw IPCTransportError.writeFailed }
        var isOpen = true
        defer { if isOpen { close(fd) } }
        do {
            try envelope.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let count = SocketWrite(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                    if count > 0 { offset += count; continue }
                    if count < 0, errno == EINTR { continue }
                    throw IPCTransportError.writeFailed
                }
            }
            guard fsync(fd) == 0 else { throw IPCTransportError.writeFailed }
            close(fd); isOpen = false
            var destination = directory.appendingPathComponent("\(id.uuidString).spool")
            if FileManager.default.fileExists(atPath: destination.path) { destination = directory.appendingPathComponent("\(id.uuidString)-\(UUID().uuidString).spool") }
            try FileManager.default.moveItem(at: tmp, to: destination)
            try syncIPCDirectory(directory)
            return destination
        } catch {
            try? FileManager.default.removeItem(at: tmp); throw error
        }
    }
    public func replay(_ consume: (Data) throws -> Void) throws {
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter({ $0.pathExtension == "spool" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            try consume(Data(contentsOf: url))
            try FileManager.default.removeItem(at: url)
            try syncIPCDirectory(directory)
        }
    }
}
