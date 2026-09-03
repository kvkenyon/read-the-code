import Foundation
import RTCContracts
import RTCGit

@objc public protocol GitWorkerXPCProtocol {
    func materialize(_ request: Data, withReply reply: @escaping (Data?, Error?) -> Void)
    func context(_ request: Data, withReply reply: @escaping (Data?, Error?) -> Void)
    func verifyCurrentHead(_ request: Data, withReply reply: @escaping (Data?, Error?) -> Void)
}

public final class GitWorkerService: NSObject, GitWorkerXPCProtocol {
    private let engine = ExactGitEngine()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    public override init() { super.init() }
    public func materialize(_ request: Data, withReply reply: @escaping (Data?, Error?) -> Void) { Task { do { let revision=try decoder.decode(RevisionIdentity.self,from:request); let value=try await engine.materialize(revision); reply(try encoder.encode(value),nil) } catch { reply(nil,error) } } }
    public func context(_ request: Data, withReply reply: @escaping (Data?, Error?) -> Void) { Task { do { let input=try decoder.decode(GitContextRequest.self,from:request); let value=try await engine.context(input); reply(try encoder.encode(value),nil) } catch { reply(nil,error) } } }
    public func verifyCurrentHead(_ request: Data, withReply reply: @escaping (Data?, Error?) -> Void) { Task { do { let input=try decoder.decode(RevisionIdentity.self,from:request); reply(try encoder.encode(await engine.verifyCurrentHead(input)),nil) } catch { reply(nil,error) } } }
}
