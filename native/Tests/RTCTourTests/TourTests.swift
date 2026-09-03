import Foundation
import RTCContracts
import RTCTour

struct FakeAnchors: AnchorArtifactSource {
    let result: Bool
    func validate(_ anchor: ReviewAnchor) async throws -> Bool { result }
}

struct FakeArtifacts: ExactArtifactSource {
    let manifest: ReviewManifest
    func manifest(for revision: RevisionIdentity) async throws -> ReviewManifest { manifest }
}

@main struct TourTests {
    static func main() async throws {
        let fixture = try Data(contentsOf: URL(fileURLWithPath: "native/Fixtures/Tours/valid-tour.json"))
        let tour = try JSONDecoder().decode(TourDocument.self, from: fixture)
        let revision = tour.revision
        let valid = await TourValidator().validate(tour, against: revision, anchors: FakeAnchors(result: true))
        guard case .success = valid else { throw TestFailure("valid tour rejected") }
        let rejected = await TourValidator().validate(tour, against: revision, anchors: FakeAnchors(result: false))
        guard case .failure(let failure) = rejected, failure.issues.contains(where: { $0.code == .unresolvedAnchor }) else { throw TestFailure("unresolved anchor accepted") }
        let pack = ContextPack(revision: revision, files: [], omissions: [ContextOmission(path: "Secret.swift", reason: "input budget", omittedBytes: 10)], byteCount: 0)
        guard pack.digest.hex.count == 64 else { throw TestFailure("context digest") }
        let signals = SignalAnalyzer().analyze(pack)
        guard SignalAnalyzer().intents(signals).count == 4 else { throw TestFailure("diagram intents") }
        let request = TourGenerationRequest(revision: revision, contextDigest: tour.inputDigest)
        let supplied = SuppliedTourProvider(tour: tour)
        let result = await TourCoordinator().run(request: request, provider: supplied, anchors: FakeAnchors(result: true), fallback: supplied) { _ in }
        guard case .success(let generated) = result, generated == tour else { throw TestFailure("provider orchestration") }
        print("RTC tour checks passed")
    }
}
enum TestFailure: Error { case message(String); init(_ message: String) { self = .message(message) } }
