import Foundation
import RTCContracts
import RTCDomain
import RTCReview

private struct TestSource: AnchorArtifactSource {
    let valid: Bool
    func validate(_ anchor: ReviewAnchor) async throws -> Bool { valid }
}

@main enum RTCReviewTests {
    static func main() async throws {
        let revision = try RevisionIdentity(repositoryPath: "/tmp/repo", baseSHA: String(repeating: "a", count: 40), headSHA: String(repeating: "b", count: 40))
        let anchor = try ReviewAnchor(revision: revision, path: "Sources/A.swift", scope: .line, side: .new, startLine: 2, endLine: 2)
        let handler = ReviewCommandHandler(reviewID: revision.reviewID, revision: revision, source: TestSource(valid: true), files: ["Sources/A.swift", "README.md"])
        let body = try RichText(runs: [RichTextRun(kind: .plain, text: "Please handle this case." )])
        let threadID = try await handler.createDraft(anchor: anchor, body: body)
        let draftThreads = await handler.snapshotThreads()
        precondition(draftThreads.first?.state == .draft)
        do { _ = try await handler.sendReview(threadIDs: [threadID]) } catch { preconditionFailure("valid draft failed: \(error)") }
        let openThreads = await handler.snapshotThreads()
        precondition(openThreads.first?.state == .open)
        try await handler.markViewed(path: "Sources/A.swift")
        let approval = try await handler.approveExactRevision()
        precondition(approval.kind == .approval && approval.headSHA == revision.headSHA && approval.warnings.contains("unviewedFiles:1"))
        let failed = ReviewCommandHandler(reviewID: revision.reviewID, revision: revision, source: TestSource(valid: false))
        let promoted = try await failed.createDraft(anchor: anchor, body: body, promotedFrom: UUID(), messageID: UUID())
        do { _ = try await failed.sendReview(threadIDs: [promoted]); preconditionFailure("false anchor sent") } catch { }
        let preserved = await failed.snapshotThreads().first
        precondition(preserved?.state == .draft && preserved?.promotedConversationID != nil && preserved?.promotedMessageID != nil)
        let summary = try RichText(runs: [RichTextRun(kind: .plain, text: "Needs changes." )])
        let decisionHandler = ReviewCommandHandler(reviewID: revision.reviewID, revision: revision, source: TestSource(valid: true))
        let changes = try await decisionHandler.requestChanges(threadIDs: [], summary: summary)
        precondition(changes.kind == .changesRequested)
        let approvalHandler = ReviewCommandHandler(reviewID: revision.reviewID, revision: revision, source: TestSource(valid: true))
        let separateApproval = try await approvalHandler.approveExactRevision()
        precondition(separateApproval.kind == .approval)
        let stale = String(repeating: "c", count: 40)
        await handler.markHead(stale)
        do { _ = try await handler.closeReview(); preconditionFailure("stale close succeeded") } catch { precondition(error as? RTCDomainError == .staleRevision) }
        print("RTC review checks passed")
    }
}
