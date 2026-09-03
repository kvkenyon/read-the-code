import Foundation
import RTCIPC

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
    }
}
