import AppKit
import Foundation
import RTCContracts
import RTCDiffCanvas
import RTCDomain
import RTCReview
import RTCReviewWorkspace
import SwiftUI

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
        try mountedCanvasRetainsControllerAndEnablesComment(model: model, artifact: artifact)
        let tourSelection = CanvasSelection(path: artifact.path, side: .new, startLine: 8, endLine: 8)
        model.navigate(to: tourSelection)
        precondition(model.selection == tourSelection && model.navigationRequest?.selection == tourSelection)
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

    @MainActor private static func mountedCanvasRetainsControllerAndEnablesComment(model: ReviewWorkspaceModel, artifact: DiffArtifact) throws {
        let mountedAt = ContinuousClock.now
        let host = NSHostingView(rootView: RTCReviewWorkspaceView(model: model))
        host.frame = NSRect(x: 0, y: 0, width: 1_200, height: 900)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()

        guard let canvas = descendant(of: host, as: NSCollectionView.self) else {
            throw FeatureFailure.failed("mounted workspace did not create a collection view")
        }
        let diffReady = mountedAt.duration(to: .now)
        precondition(canvas.numberOfSections > 0 && canvas.numberOfItems(inSection: 0) > 0, "mounted workspace bridge must retain nonzero diff canvas items")
        guard let controller = canvas.delegate as? ReviewCanvasController else {
            throw FeatureFailure.failed("mounted workspace lost its canvas controller")
        }

        let interactionAt = ContinuousClock.now
        controller.collectionView(canvas, didSelectItemsAt: [IndexPath(item: 1, section: 0)])
        let firstInteraction = interactionAt.duration(to: .now)
        precondition(model.selection?.path == artifact.path, "mounted canvas line navigation must select exact diff evidence")
        model.openComposer()
        precondition(model.composer?.selection == model.selection, "Comment must enable after mounted canvas line selection")
        precondition(diffReady < .seconds(2), "mounted diff-ready timing exceeded twice the captured 0.746-second baseline: \(diffReady)")
        precondition(firstInteraction < .seconds(1), "mounted first-interaction timing exceeded budget: \(firstInteraction)")
        print("RTC mounted canvas diff-ready \(diffReady); first-interaction \(firstInteraction)")
    }

    @MainActor private static func descendant<T: NSView>(of root: NSView, as type: T.Type) -> T? {
        if let match = root as? T { return match }
        for child in root.subviews {
            if let match = descendant(of: child, as: type) { return match }
        }
        return nil
    }
}

private enum FeatureFailure: Error { case failed(String) }
