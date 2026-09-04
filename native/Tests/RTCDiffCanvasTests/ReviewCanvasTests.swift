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
        let file=CanvasFile(artifact: artifact), controller=ReviewCanvasController()
        controller.loadView(); controller.apply(CanvasSnapshot(revision: revision, files: [file], contentVersion: 1))
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        precondition(controller.fullSnapshotApplicationCount == 1 && controller.enumeratedLineCount == 100_000)

        let anchor=CanvasSelection(path: artifact.path, side: .new, startLine: 50_000, endLine: 50_000)
        controller.apply(CanvasSnapshot(revision: revision, files: [file], selected: anchor, contentVersion: 1))
        controller.apply(CanvasSnapshot(revision: revision, files: [file], selected: anchor, composer: anchor, contentVersion: 1))
        let thread=CanvasInlineThread(id: UUID(), selection: anchor, state: "draft", body: "Bounded inline feedback")
        controller.apply(CanvasSnapshot(revision: revision, files: [file], selected: anchor, threads: [thread], contentVersion: 1))
        precondition(controller.fullSnapshotApplicationCount == 1 && controller.enumeratedLineCount == 100_000, "selection, composer typing/insertion, and thread insertion must not rebuild the 100k-row snapshot")
        precondition(controller.saveScrollPosition() == anchor, "selection restoration remains exact")
        print("RTC diff canvas 100k-row checks passed")
    }
}
