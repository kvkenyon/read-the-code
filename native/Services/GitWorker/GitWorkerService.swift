import Foundation
import RTCContracts
import RTCGit

@objc public protocol GitWorkerXPCProtocol {
    func materialize(_ request: Data, withReply reply: @escaping @Sendable (Data?, Error?) -> Void)
    func context(_ request: Data, withReply reply: @escaping @Sendable (Data?, Error?) -> Void)
    func verifyCurrentHead(_ request: Data, withReply reply: @escaping @Sendable (Data?, Error?) -> Void)
}

public final class GitWorkerService: NSObject, GitWorkerXPCProtocol, @unchecked Sendable {
    private let engine = ExactGitEngine()
    public override init() { super.init() }

    public func materialize(_ request: Data, withReply reply: @escaping @Sendable (Data?, Error?) -> Void) {
        Task {
            do {
                let revision = try JSONDecoder().decode(RevisionIdentity.self, from: request)
                let value = try await engine.materialize(revision)
                reply(try JSONEncoder().encode(value), nil)
            } catch {
                reply(nil, error)
            }
        }
    }

    public func context(_ request: Data, withReply reply: @escaping @Sendable (Data?, Error?) -> Void) {
        Task {
            do {
                let input = try JSONDecoder().decode(GitContextRequest.self, from: request)
                let value = try await engine.context(input)
                reply(try JSONEncoder().encode(value), nil)
            } catch {
                reply(nil, error)
            }
        }
    }

    public func verifyCurrentHead(_ request: Data, withReply reply: @escaping @Sendable (Data?, Error?) -> Void) {
        Task {
            do {
                let input = try JSONDecoder().decode(RevisionIdentity.self, from: request)
                reply(try JSONEncoder().encode(await engine.verifyCurrentHead(input)), nil)
            } catch {
                reply(nil, error)
            }
        }
    }
}
