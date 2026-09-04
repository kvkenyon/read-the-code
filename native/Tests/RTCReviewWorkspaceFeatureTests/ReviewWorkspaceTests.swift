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
        let manifest = ReviewManifest(id: revision.reviewID, revision: revision, createdAt: Date(), updatedAt: Date(), status: .ready, stale: false, summary: ReviewSummary(files: 1, additions: 2, deletions: 0), files: [artifact])
        let repository = MemoryReviewEventRepository()
        let handler = try await ReviewCommandHandler.open(manifest: manifest, repository: repository, anchors: Source(), mutationPreflight: FixedReviewMutationPreflight(headSHA: revision.headSHA))
        let model = ReviewWorkspaceModel(revision: revision, files: [CanvasFile(artifact: artifact)], handler: handler)
        await model.refresh()
        precondition(!model.isReadOnly, "workspace control enablement comes from reducer snapshot")
        let menu = ReviewWorkspaceCommandRouter(model: model).reviewMenu()
        precondition(menu.items.map(\.title).contains("Send Review") && menu.items.map(\.title).contains("Request Changes") && menu.items.map(\.title).contains("Close Review"), "all review actions remain discoverable as menu commands")
        let selection = CanvasSelection(path: artifact.path, side: .new, startLine: 9, endLine: 8)
        model.select(selection)
        let anchor = try model.anchor(for: selection)
        precondition(selection.startLine == 8 && selection.endLine == 9, "line selection normalizes ranges")
        precondition(anchor.startContextHash == hash && anchor.endContextHash == endHash, "anchor uses committed diff hashes")
        let restoration = model.restorationData()
        let restoredModel = ReviewWorkspaceModel(revision: revision, files: [CanvasFile(artifact: artifact)], handler: handler, restorationData: restoration)
        precondition(restoredModel.selection == selection && restoredModel.selectedFile == artifact.path, "selection and file navigation restore")
        model.openComposer(); model.updateComposer("Please explain this value.")
        let draft = try await model.saveComposer()
        await model.refresh()
        precondition(model.threads.count == 1 && model.threads.first?.state == .draft, "inline composer creates durable draft")
        precondition(model.canvas.threads.first?.selection == selection, "canvas and comments rail project the same anchored thread")
        try await model.markViewed(artifact.path)
        precondition(model.viewedCount == 1, "file progress updates through handler")
        let feedback = try await model.sendDrafts()
        precondition(feedback.kind == .feedback && model.threads.first?.id == draft && model.threads.first?.state == .open, "send moves draft once")
        let decision = try await model.approve()
        precondition(decision.kind == ReviewEventKind.approval, "approval is distinct")
        precondition(model.isReadOnly, "approval makes the review read-only")
        do { try await model.markViewed(artifact.path, viewed: false); preconditionFailure("stale mutation succeeded") } catch let error as RTCDomainError { precondition(error == .readOnly || error == .staleRevision) }
        let restored = try await ReviewCommandHandler.open(manifest: manifest, repository: repository, anchors: Source(), mutationPreflight: FixedReviewMutationPreflight(headSHA: revision.headSHA))
        let snapshot = await restored.snapshot()
        precondition(snapshot.status == .approved && snapshot.threads.first?.anchor == anchor && snapshot.progress.first?.viewed == true, "workspace state survives restart")
        print("RTC review workspace feature checks passed")
    }
}
