import Foundation
import RTCContracts
import RTCTestSupport

@main struct ContractTests {
    static func check(_ condition: Bool, _ message: String) { precondition(condition, message) }
    static func main() throws {
        let r = try RTCFixture.revision(); check(r.reviewID.value.count == 24, "review id"); let a = try RTCCanonicalJSON.encode(r); let b = try RTCCanonicalJSON.encode(r); check(a == b, "canonical json"); let digest = try RTCCanonicalJSON.digest(r); let digest2 = try RTCCanonicalJSON.digest(r); check(digest == digest2, "digest"); _ = try JSONDecoder().decode(RevisionIdentity.self, from: a)
        check((try? ReviewAnchor(revision: r, path: "../../etc/passwd", scope: .file)) == nil, "hostile path"); _ = try BoundedString("<script>not executable</script>")
        check((try? RichText(runs: Array(repeating: RichTextRun(kind: .plain, text: "x"), count: 257))) == nil, "rich text limit")
        check((try? JSONDecoder().decode(ReviewManifest.self, from: Data("{\"schemaVersion\":99}".utf8))) == nil, "unknown major")
        let t = try TourDocument(id: UUID(), revision: r, producer: .localModel, inputDigest: SHA256Digest(data: Data()), title: "T", overview: [.paragraph(try RichText(runs: [RichTextRun(kind: .plain, text: "safe")]))], reviewFocuses: [], chapters: [], risks: []); let td = try RTCCanonicalJSON.encode(t); let decoded = try JSONDecoder().decode(TourDocument.self, from: td); check(t == decoded, "tour round trip")
        let e = RTCError(code: .staleRevision, message: "stale", retryable: true); check(e.code.rawValue == "STALE_REVISION", "stable error"); check(IPCRequest(schemaVersion: 2, id: UUID(), operation: "status", reviewID: nil, payload: nil).schemaVersion == 2, "ipc")
        print("RTC contract checks passed")
    }
}
