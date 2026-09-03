import Foundation
import RTCContracts
import RTCDomain

private struct ValidatingSource: AnchorArtifactSource {
    let accepted: Bool
    func validate(_ anchor: ReviewAnchor) async throws -> Bool { accepted }
}

@main enum RTCDomainTests {
    static func main() async throws {
        let revision = try RevisionIdentity(repositoryPath: "/tmp/repo", baseSHA: String(repeating: "a", count: 40), headSHA: String(repeating: "b", count: 40))
        let line = try ReviewAnchor(revision: revision, path: "Sources/A.swift", scope: .line, side: .new, startLine: 4, endLine: 7)
        precondition(ReviewAnchorResolver.isStructurallyValid(line))
        let invalidFile = try ReviewAnchor(revision: revision, path: "Sources/A.swift", scope: .file, startLine: 4, endLine: 7)
        precondition(!ReviewAnchorResolver.isStructurallyValid(invalidFile))
        let resolver = ReviewAnchorResolver(source: ValidatingSource(accepted: true))
        let resolved = try await resolver.resolve(line, for: revision)
        precondition(resolved.resolved)
        let other = try RevisionIdentity(repositoryPath: "/tmp/repo", baseSHA: String(repeating: "a", count: 40), headSHA: String(repeating: "c", count: 40))
        let stale = try await resolver.resolve(line, for: other)
        precondition(stale.reason == .staleRevision)
        print("RTC domain checks passed")
    }
}
