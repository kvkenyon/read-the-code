import Foundation
import RTCContracts
import RTCIPC

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
        let server = IPCServer(
            socketPath: socketPath,
            dispatcher: dispatcher,
            maximumInFlightClients: 2,
            timeout: 0.2
        )
        try server.start()
        defer { server.stop() }
        let body = Data("round trip".utf8)
        let response = try IPCClient(socketPath: socketPath).send(
            IPCEnvelope(operation: "echo", capability: "test-capability", body: body)
        )
        check(response.ok && response.body == body, "server round trip")

        let idleClient = try connectRawSocket(to: socketPath)
        defer { close(idleClient) }
        let partialClient = try connectRawSocket(to: socketPath)
        defer { close(partialClient) }
        let partialPrefix = Data([0, 0])
        let partialWrite = partialPrefix.withUnsafeBytes {
            RawSocketWrite(partialClient, $0.baseAddress!, $0.count)
        }
        check(partialWrite == partialPrefix.count, "partial frame setup")
        Thread.sleep(forTimeInterval: 0.05)

        let recovered = try IPCClient(socketPath: socketPath).send(
            IPCEnvelope(operation: "echo", capability: "test-capability", body: body),
            timeout: 2
        )
        check(recovered.ok && recovered.body == body, "valid request after stalled-client saturation")

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
    return fd
}

#if canImport(Darwin)
private func RawSocketWrite(_ fd: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int {
    Darwin.write(fd, buffer, count)
}
#else
private func RawSocketWrite(_ fd: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int {
    Glibc.write(fd, buffer, count)
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
