import Foundation
import RTCContracts
import RTCDiffCanvas
import RTCDomain
import RTCReview
import RTCReviewWorkspace

private struct Source: AnchorArtifactSource { func validate(_ anchor: ReviewAnchor) async throws -> Bool { true } }

@main enum RTCReviewWorkspaceFeatureTests {
    @MainActor static func main() async throws {
        let revision = try RevisionIdentity(repositoryPath: "/tmp/repo", baseSHA: String(repeating: "a", count: 40), headSHA: String(repeating: "b", count: 40))
        let hash = SHA256Digest(data: Data("let value = 1".utf8))
        let line = DiffLine(kind: .addition, oldLine: nil, newLine: 8, text: "let value = 1", contextHash: hash)
        let endHash = SHA256Digest(data: Data("return value".utf8))
        let end = DiffLine(kind: .addition, oldLine: nil, newLine: 9, text: "return value", contextHash: endHash)
        let hunk = DiffHunk(header: BoundedString("@@ -0,0 +8,2 @@"), oldStart: 0, oldLines: 0, newStart: 8, newLines: 2, lines: [line, end])
        let artifact = DiffArtifact(path: "Sources/App.swift", status: .added, additions: 2, deletions: 0, binary: false, truncated: false, hunks: [hunk])
        let handler = ReviewCommandHandler(reviewID: revision.reviewID, revision: revision, source: Source(), files: [artifact.path])
        let model = ReviewWorkspaceModel(revision: revision, files: [CanvasFile(artifact: artifact)], handler: handler)
        let selection = CanvasSelection(path: artifact.path, side: .new, startLine: 9, endLine: 8)
        model.select(selection)
        let anchor = try model.anchor(for: selection)
        precondition(selection.startLine == 8 && selection.endLine == 9, "line selection normalizes ranges")
        precondition(anchor.startContextHash == hash && anchor.endContextHash == endHash, "anchor uses committed diff hashes")
        model.openComposer(); model.updateComposer("Please explain this value.")
        let draft = try await model.saveComposer()
        await model.refresh()
        precondition(model.threads.count == 1 && model.threads.first?.state == .draft, "inline composer creates durable draft")
        try await model.markViewed(artifact.path)
        precondition(model.viewedCount == 1, "file progress updates through handler")
        let feedback = try await model.sendDrafts()
        precondition(feedback.kind == .feedback && model.threads.first?.id == draft && model.threads.first?.state == .open, "send moves draft once")
        let decision = try await model.approve()
        precondition(decision.kind == .approval, "approval is distinct")
        await model.markHead(String(repeating: "c", count: 40))
        precondition(model.isReadOnly, "moved symbolic head makes evidence read-only")
        do { try await model.markViewed(artifact.path, viewed: false); preconditionFailure("stale mutation succeeded") } catch let error as RTCDomainError { precondition(error == .readOnly || error == .staleRevision) }
        print("RTC review workspace feature checks passed")
    }
}
