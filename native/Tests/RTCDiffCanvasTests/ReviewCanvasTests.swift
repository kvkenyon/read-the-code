import AppKit
import Foundation
import RTCContracts
import RTCDiffCanvas

@main
struct ReviewCanvasTests {
    @MainActor static func main() throws {
        let selection=CanvasSelection(path: "Sources/App.swift", side: .new, startLine: 19, endLine: 7)
        precondition(selection.startLine == 7 && selection.endLine == 19)
        let revision=try RevisionIdentity(repositoryPath: "/tmp/repo", baseSHA: String(repeating: "a", count: 40), headSHA: String(repeating: "b", count: 40))

        let lines=(1...100_000).map { (number: Int) in DiffLine(kind: .addition, oldLine: nil, newLine: number, text: "let value\(number) = \(number)", contextHash: SHA256Digest(data: Data(String(number).utf8))) }
        let hunk=DiffHunk(header: "@@ -0,0 +1,100000 @@", oldStart: 0, oldLines: 0, newStart: 1, newLines: lines.count, lines: lines)
        let artifact=DiffArtifact(path: "Sources/App.swift", status: .added, additions: lines.count, deletions: 0, binary: false, truncated: false, hunks: [hunk])
        let threads=(1...10_000).map { index in
            let id=UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", index))!
            let anchor=CanvasSelection(path: artifact.path, side: .new, startLine: index * 10, endLine: index * 10)
            return CanvasInlineThread(id: id, selection: anchor, state: "open", body: "Thread \(index)")
        }
        let file=CanvasFile(artifact: artifact), controller=ReviewCanvasController()
        controller.loadView(); controller.view.frame=NSRect(x: 0, y: 0, width: 1_200, height: 900)
        let clock=ContinuousClock(), coldStart=clock.now
        controller.apply(CanvasSnapshot(revision: revision, files: [file], threads: threads, contentVersion: 1))
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        controller.view.layoutSubtreeIfNeeded()
        let coldDuration=coldStart.duration(to: clock.now)
        precondition(controller.fullSnapshotApplicationCount == 1 && controller.enumeratedLineCount == 100_000 && controller.indexedThreadCount == 10_000, "cold restoration must enumerate lines once and pre-index every thread")
        precondition(coldDuration < .seconds(10), "populated cold restoration exceeded the 10-second CLT characterization budget: \(coldDuration)")
        precondition(controller.collectionView.visibleItems().count < 1_000, "the canvas must materialize only a bounded visible-cell window")

        let anchor=CanvasSelection(path: artifact.path, side: .new, startLine: 50_000, endLine: 50_000)
        controller.apply(CanvasSnapshot(revision: revision, files: [file], selected: anchor, threads: threads, contentVersion: 1))
        controller.apply(CanvasSnapshot(revision: revision, files: [file], selected: anchor, threads: threads, composer: anchor, contentVersion: 1))
        let thread=CanvasInlineThread(id: UUID(uuidString: "ffffffff-ffff-4fff-8fff-ffffffffffff")!, selection: anchor, state: "draft", body: "Bounded inline feedback")
        controller.apply(CanvasSnapshot(revision: revision, files: [file], selected: anchor, threads: threads + [thread], contentVersion: 1))
        precondition(controller.fullSnapshotApplicationCount == 1 && controller.enumeratedLineCount == 100_000, "selection, composer typing/insertion, and thread insertion must not rebuild the 100k-row snapshot")
        let inserted = controller.incrementalInsertedItemCount, deleted = controller.incrementalDeletedItemCount, reloaded = controller.incrementalReloadedItemCount
        let editedThread=CanvasInlineThread(id: thread.id, selection: anchor, state: "open", body: "Edited in place")
        controller.apply(CanvasSnapshot(revision: revision, files: [file], selected: anchor, threads: threads + [editedThread], contentVersion: 1))
        precondition(controller.incrementalInsertedItemCount == inserted && controller.incrementalDeletedItemCount == deleted && controller.incrementalReloadedItemCount == reloaded + 1, "editing one thread must reload one inline item")
        controller.apply(CanvasSnapshot(revision: revision, files: [file], selected: anchor, threads: threads, contentVersion: 1))
        precondition(controller.incrementalDeletedItemCount == deleted + 1 && controller.fullSnapshotApplicationCount == 1, "removing one thread must delete one inline item without rebuilding rows")
        precondition(controller.saveScrollPosition() == anchor, "selection restoration remains exact")
        print("RTC diff canvas 100k-row / 10k-thread checks passed")
    }
}
