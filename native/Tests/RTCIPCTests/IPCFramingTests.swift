import Foundation
import RTCContracts
@_spi(Testing) import RTCIPC

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

@main struct IPCFramingTests {
    static func check(_ condition: Bool, _ message: String) { precondition(condition, message) }
    static func main() throws {
        let first = try IPCFrameCodec.encode(["one": 1])
        let second = try IPCFrameCodec.encode(["two": 2])
        var decoder = IPCFrameDecoder()
        check(try decoder.append(first.prefix(2)).isEmpty, "fragment")
        let frames = try decoder.append(first.dropFirst(2) + second)
        check(frames.count == 2, "coalesced")
        check(try IPCFrameCodec.decodeJSON([String: Int].self, from: frames[1])["two"] == 2, "json")
        var oversizeDecoder = IPCFrameDecoder()
        check((try? oversizeDecoder.append(Data([0xff, 0xff, 0xff, 0xff]))) == nil, "oversize")
        check((try? IPCFrameCodec.decodeJSON([String: Int].self, from: Data([0xff]))) == nil, "utf8")
        check((try? IPCFrameCodec.decode(Data([0, 0, 0]))) == nil, "truncated")

        let socketPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("rtc-ipc-\(UUID().uuidString.prefix(8)).sock")
        let dispatcher = IPCDispatcher(
            handler: EchoHandler(),
            peer: AcceptingPeer(),
            capabilities: IPCAllowList(["test-capability"])
        )
        let acceptedClient = DispatchSemaphore(value: 0)
        let server = IPCServer(
            socketPath: socketPath,
            dispatcher: dispatcher,
            maximumInFlightClients: 2,
            timeout: 0.6,
            clientDidAcquireSlot: { acceptedClient.signal() }
        )
        try server.start()
        defer { server.stop() }
        let body = Data("round trip".utf8)

        let hostileClients = [
            try connectRawSocket(to: socketPath),
            try connectRawSocket(to: socketPath),
        ]
        defer { hostileClients.forEach { close($0) } }
        for _ in hostileClients {
            check(acceptedClient.wait(timeout: .now() + .seconds(1)) == .success, "hostile client accepted")
        }
        check(
            hostileClients.count == server.maximumInFlightClientsForTesting,
            "hostile clients own every bounded slot"
        )

        let tricklers = DispatchGroup()
        for client in hostileClients {
            tricklers.enter()
            DispatchQueue.global().async {
                defer { tricklers.leave() }
                tricklePartialFrame(to: client)
            }
        }

        let validClient = try connectRawSocket(to: socketPath)
        defer { close(validClient) }
        let validRequest = IPCEnvelope(operation: "echo", capability: "test-capability", body: body)
        try writeRawSocket(validClient, try IPCFrameCodec.encode(validRequest))
        check(
            acceptedClient.wait(timeout: .now() + .milliseconds(200)) == .timedOut,
            "valid request initially blocked by saturated slots"
        )
        check(
            acceptedClient.wait(timeout: .now() + .seconds(2)) == .success,
            "absolute frame deadline reclaims a saturated slot"
        )
        let recovered = try readRawResponse(from: validClient, timeout: 2)
        check(
            recovered.requestID == validRequest.requestID && recovered.ok && recovered.body == body,
            "authorized request succeeds after absolute-deadline reclamation"
        )
        check(tricklers.wait(timeout: .now() + .seconds(1)) == .success, "trickling clients released")

        do {
            _ = try IPCClient(socketPath: socketPath).send(
                IPCEnvelope(operation: "slow", capability: "test-capability"),
                timeout: 0.05
            )
            preconditionFailure("client receive timeout")
        } catch let error as IPCFrameError {
            check(error == .truncated, "client receive timeout error")
        }
    }
}

private func connectRawSocket(to path: String) throws -> Int32 {
    #if canImport(Darwin)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    #else
    let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
    #endif
    guard fd >= 0 else { throw IPCTransportError.socketCreationFailed }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8) + [UInt8(0)]
    guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
        close(fd)
        throw IPCTransportError.socketPathTooLong
    }
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
    let length = socklen_t(MemoryLayout<sa_family_t>.size + bytes.count)
    guard withUnsafePointer(to: &address, {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, length) }
    }) == 0 else {
        close(fd)
        throw IPCTransportError.unavailable
    }
    #if canImport(Darwin)
    var noSignal: Int32 = 1
    guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
        close(fd)
        throw IPCTransportError.unavailable
    }
    #endif
    return fd
}

private func tricklePartialFrame(to fd: Int32) {
    let incompleteFrame = Data([0, 0, 16, 0]) + Data(repeating: 0x20, count: 128)
    for byte in incompleteFrame {
        var byte = byte
        let written = withUnsafeBytes(of: &byte) { RawSocketWrite(fd, $0.baseAddress!, 1) }
        guard written == 1 else { return }
        Thread.sleep(forTimeInterval: 0.04)
    }
}

private func writeRawSocket(_ fd: Int32, _ data: Data) throws {
    try data.withUnsafeBytes { raw in
        var offset = 0
        while offset < data.count {
            let written = RawSocketWrite(fd, raw.baseAddress!.advanced(by: offset), data.count - offset)
            guard written > 0 else { throw IPCTransportError.writeFailed }
            offset += written
        }
    }
}

private func readRawResponse(from fd: Int32, timeout: TimeInterval) throws -> IPCEnvelopeResponse {
    let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeout * 1_000_000_000)
    var prefix = Data(count: 4)
    try readRawSocket(fd, into: &prefix, deadline: deadline)
    let count = Int(prefix[0]) << 24 | Int(prefix[1]) << 16 | Int(prefix[2]) << 8 | Int(prefix[3])
    guard count <= IPCConstants.maxFrameBytes else { throw IPCFrameError.oversize(count) }
    var payload = Data(count: count)
    try readRawSocket(fd, into: &payload, deadline: deadline)
    return try IPCFrameCodec.decodeJSON(IPCEnvelopeResponse.self, from: payload)
}

private func readRawSocket(_ fd: Int32, into data: inout Data, deadline: UInt64) throws {
    let count = data.count
    try data.withUnsafeMutableBytes { raw in
        var offset = 0
        while offset < count {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { throw IPCFrameError.truncated }
            let remaining = deadline - now
            let roundedMilliseconds = remaining / 1_000_000 + (remaining % 1_000_000 == 0 ? 0 : 1)
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard RawSocketPoll(&descriptor, Int32(min(roundedMilliseconds, UInt64(Int32.max)))) > 0 else {
                throw IPCFrameError.truncated
            }
            let readCount = RawSocketRead(fd, raw.baseAddress!.advanced(by: offset), count - offset)
            guard readCount > 0 else { throw IPCFrameError.truncated }
            offset += readCount
        }
    }
}

#if canImport(Darwin)
private func RawSocketRead(_ fd: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int) -> Int {
    Darwin.read(fd, buffer, count)
}
private func RawSocketWrite(_ fd: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int {
    Darwin.write(fd, buffer, count)
}
private func RawSocketPoll(_ descriptor: inout pollfd, _ timeout: Int32) -> Int32 {
    Darwin.poll(&descriptor, 1, timeout)
}
#else
private func RawSocketRead(_ fd: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int) -> Int {
    Glibc.read(fd, buffer, count)
}
private func RawSocketWrite(_ fd: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int {
    Glibc.send(fd, buffer, count, Int32(MSG_NOSIGNAL))
}
private func RawSocketPoll(_ descriptor: inout pollfd, _ timeout: Int32) -> Int32 {
    Glibc.poll(&descriptor, 1, timeout)
}
#endif

private struct AcceptingPeer: IPCPeerAuthenticator {
    func isAuthorized(fileDescriptor: Int32) -> Bool { true }
}

private struct EchoHandler: IPCOperationHandler {
    func handle(_ request: IPCRequest) async -> IPCResponse {
        if request.operation == "slow" {
            try? await Task.sleep(for: .milliseconds(500))
        }
        return IPCResponse(
            schemaVersion: RTCConstants.schemaVersion,
            requestID: request.id,
            ok: true,
            error: nil,
            payload: request.payload
        )
    }
}
