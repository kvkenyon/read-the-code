import RTCDiffCanvas
import RTCContracts

@main
struct ReviewCanvasTests {
    static func main() throws {
        let selection = CanvasSelection(path: "Sources/App.swift", side: .new, startLine: 19, endLine: 7)
        precondition(selection.startLine == 7 && selection.endLine == 19)

        let revision = try RevisionIdentity(repositoryPath: "/tmp/repo", baseSHA: String(repeating: "a", count: 40), headSHA: String(repeating: "b", count: 40))
        let canvas = CanvasSnapshot(revision: revision, files: [])
        precondition(canvas.revision == revision && canvas.files.isEmpty)
    }
}
