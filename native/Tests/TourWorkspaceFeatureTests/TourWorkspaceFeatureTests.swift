import Foundation
import RTCContracts
import RTCDiagram
import RTCModelAdapters
import RTCStore
import RTCSyntax
import RTCTour
import RTCTourIntegration
import TourWorkspace

@main
struct TourWorkspaceFeatureTests {
    static func main() async throws {
        let fixture = try Fixture()
        try contextPackPreservesMetadataAndIsDeterministic(fixture)
        try await diffSlicesResolveThroughExactArtifacts(fixture)
        try await hostileStructuredContentIsRejected(fixture)
        try strictDecoderRejectsUnknownFields(fixture)
        try await suppliedAndLocalToursShareValidationAndPersistence(fixture)
        try await materialSignalsRequireGroundedDiagrams(fixture)
        try await cancellationIsExplicitAndDurable(fixture)
        try await deterministicFallbackIsStable(fixture)
        print("RTC Tour workspace feature checks passed")
    }

    private static func contextPackPreservesMetadataAndIsDeterministic(_ fixture: Fixture) throws {
        let largeText = String(repeating: "private-token-shaped-context ", count: 220)
        let largeLine = DiffLine(
            kind: .addition, oldLine: nil, newLine: 40, text: largeText,
            contextHash: SHA256Digest(data: Data(largeText.utf8)))
        let largeHunk = DiffHunk(
            header: "@@ -0,0 +40,1 @@", oldStart: 0, oldLines: 0,
            newStart: 40, newLines: 1, lines: [largeLine])
        let second = DiffArtifact(
            path: "Sources/Large.swift", oldPath: "Sources/OldLarge.swift",
            status: .renamed, additions: 1, deletions: 2,
            binary: false, truncated: true, oldLineCount: 80,
            newLineCount: 79, hunks: [largeHunk])
        let manifest = fixture.manifest(files: [fixture.file, second])
        let builder = ContextPackBuilder(inputBudget: 2_500)
        let first = try builder.build(manifest: manifest)
        let secondBuild = try builder.build(manifest: manifest)
        try expect(first == secondBuild, "context pack is not deterministic")
        try expect(
            first.files.map(\.path) == [fixture.file.path, second.path],
            "metadata for an omitted changed file was lost")
        try expect(
            first.files[1].oldPath == "Sources/OldLarge.swift" && first.files[1].truncated,
            "complete changed-file metadata was not preserved")
        try expect(
            first.omissions.contains(where: { $0.path == second.path && $0.omittedBytes > 0 }),
            "omitted hunks were not recorded")
        try expect(first.byteCount <= builder.inputBudget, "context pack exceeded its byte budget")
        try expect(first.digest == secondBuild.digest, "context digest changed for identical evidence")
    }

    private static func diffSlicesResolveThroughExactArtifacts(_ fixture: Fixture) async throws {
        let source = ManifestTourArtifactSource(manifest: fixture.manifest())
        let valid = DiffSliceReference(path: fixture.file.path, hunkIndex: 0, startLine: 10, endLine: 10)
        let invalid = DiffSliceReference(path: fixture.file.path, hunkIndex: 9, startLine: 10, endLine: 10)
        let validTour = try fixture.tour(
            producer: .workerSupplied, digest: fixture.contextDigest,
            blocks: [.diffSlice(valid)])
        let invalidTour = try fixture.tour(
            producer: .workerSupplied, digest: fixture.contextDigest,
            blocks: [.diffSlice(invalid)])
        try expectSuccess(
            await TourValidator().validate(
                validTour, against: fixture.revision,
                expectedInputDigest: fixture.contextDigest,
                anchors: source))
        let rejected = await TourValidator().validate(
            invalidTour, against: fixture.revision,
            expectedInputDigest: fixture.contextDigest,
            anchors: source)
        try expectFailure(rejected, code: .unresolvedAnchor)
    }

    private static func hostileStructuredContentIsRejected(_ fixture: Fixture) async throws {
        let source = ManifestTourArtifactSource(manifest: fixture.manifest())
        for payload in [
            "<script>alert(1)</script>", "<svg onload=alert(1)>",
            "mermaid flowchart TD", "javascript:alert(1)", "https://example.invalid/run",
        ] {
            let tour = try fixture.tour(
                producer: .workerSupplied, digest: fixture.contextDigest,
                title: payload)
            let result = await TourValidator().validate(
                tour, against: fixture.revision,
                expectedInputDigest: fixture.contextDigest,
                anchors: source)
            try expectFailure(result, code: .prohibitedContent)
        }
        let oversizedLabel = try fixture.tour(
            producer: .workerSupplied, digest: fixture.contextDigest,
            title: String(repeating: "x", count: RTCConstants.maxLabelCharacters + 1))
        try expectFailure(
            await TourValidator().validate(
                oversizedLabel, against: fixture.revision,
                expectedInputDigest: fixture.contextDigest, anchors: source),
            code: .limitExceeded)

        let nodes = (0...RTCConstants.maxNodes).map { index in
            ["id": "n\(index)", "label": "node \(index)", "role": "action", "anchors": [fixture.anchorObject]]
                as [String: Any]
        }
        let diagramObject: [String: Any] = [
            "id": "bomb", "kind": "controlFlow", "title": "Bounded graph",
            "summary": ["runs": [["kind": "plain", "text": "Graph summary"]]],
            "nodes": nodes, "edges": [], "groups": [], "anchors": [fixture.anchorObject],
        ]
        let diagram = try JSONDecoder().decode(
            DiagramDocument.self,
            from: JSONSerialization.data(withJSONObject: diagramObject)
        )
        let graphBomb = try fixture.tour(
            producer: .workerSupplied, digest: fixture.contextDigest,
            blocks: [.diagram(diagram)])
        let graphResult = await TourValidator().validate(
            graphBomb, against: fixture.revision,
            expectedInputDigest: fixture.contextDigest,
            anchors: source)
        try expectFailure(graphResult, code: .invalidDiagram)
    }

    private static func strictDecoderRejectsUnknownFields(_ fixture: Fixture) throws {
        let tour = try fixture.tour(producer: .workerSupplied, digest: fixture.contextDigest)
        let canonical = try RTCCanonicalJSON.encode(tour)
        let decoded = try StrictTourDecoder.decode(canonical)
        try expect(
            decoded == tour,
            "strict decoder rejected a canonical TourDocument")
        var object = try JSONSerialization.jsonObject(with: canonical) as! [String: Any]
        object["rawHTML"] = "<b>not allowed</b>"
        let payload = try JSONSerialization.data(withJSONObject: object)
        do {
            _ = try StrictTourDecoder.decode(payload)
            throw TestFailure("strict decoder accepted an unknown field")
        } catch TourIntegrationError.invalidPayload {}
    }

    private static func suppliedAndLocalToursShareValidationAndPersistence(_ fixture: Fixture) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rtc-tour-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteStore(rootURL: root)
        let persistence = SQLiteTourPersistence(store: store)
        let manifest = fixture.manifest()
        let artifacts = ExactTourArtifactResolver(git: FakeGit(manifest: manifest), syntax: RTCSyntaxHighlighter())
        let pack = try ContextPackBuilder(inputBudget: 96 * 1024).build(manifest: manifest)
        let localTour = try fixture.tour(producer: .localModel, digest: pack.digest)
        let transport = OllamaTourTransport(document: localTour)
        let jobs = TourGenerationJobHandler(
            persistence: persistence, jobs: JobQueue(store: store),
            artifacts: artifacts, transport: transport,
            credentials: SecretCredentials())
        let configuration = try LocalTourConfiguration(
            kind: .ollama,
            endpoint: try LoopbackEndpoint(URL(string: "http://127.0.0.1:11434")!),
            model: "fixture-model",
            credentialKey: "credential-key-that-must-not-be-persisted"
        )
        let localRun = await jobs.generate(
            reviewID: fixture.revision.reviewID,
            revision: fixture.revision, configuration: configuration)
        try expect(localRun.state == .succeeded, "valid local tour did not succeed")

        let supplied = try fixture.tour(producer: .workerSupplied, digest: pack.digest)
        let suppliedRun = await jobs.attach(
            supplied,
            reviewID: fixture.revision.reviewID,
            attribution: WorkerTourAttribution(
                identityLabel: "firstmate-worker",
                generatorName: "fixture-generator",
                generatorVersion: "2.1")
        )
        try expect(suppliedRun.state == .succeeded, "valid supplied tour did not succeed")
        let history = try await jobs.history(reviewID: fixture.revision.reviewID)
        try expect(
            history.tours.count == 2 && history.attachments.first?.state == .accepted,
            "tour history or attachment state was not persisted")
        _ = await jobs.attach(supplied, reviewID: fixture.revision.reviewID)
        let afterDuplicate = try await jobs.history(reviewID: fixture.revision.reviewID)
        try expect(
            afterDuplicate.attachments.count == 1,
            "identical worker attachment was not idempotent")

        let conflicting = try fixture.tour(
            id: supplied.id, producer: .workerSupplied,
            digest: pack.digest, title: "Different valid content")
        let conflict = await jobs.attach(conflicting, reviewID: fixture.revision.reviewID)
        try expect(
            conflict.failureCode == .tourIDConflict,
            "same tour ID with different content did not preserve error taxonomy")
        try await jobs.rate(reviewID: fixture.revision.reviewID, tourID: supplied.id, rating: .helpful)
        let rated = try await jobs.history(reviewID: fixture.revision.reviewID)
        try expect(rated.rating?.rating == .helpful, "local rating was not persisted")

        let database = try Data(contentsOf: root.appendingPathComponent("ReviewStore.sqlite"))
        let databaseText = String(decoding: database, as: UTF8.self)
        try expect(
            !databaseText.contains("credential-key-that-must-not-be-persisted"),
            "model credential metadata leaked into persistent state")

        let malicious = try fixture.tour(
            producer: .workerSupplied, digest: pack.digest,
            title: "data:text/html,owned")
        let rejected = await jobs.attach(malicious, reviewID: fixture.revision.reviewID)
        try expect(rejected.state == .rejected, "hostile supplied tour was accepted")
        let afterReject = try await jobs.history(reviewID: fixture.revision.reviewID)
        try expect(
            afterReject.tours.count == 2 && afterReject.attachments.contains(where: { $0.state == .rejected }),
            "rejected attachment was rendered or not recorded")
    }

    private static func materialSignalsRequireGroundedDiagrams(_ fixture: Fixture) async throws {
        let lines = (10..<14).map { number -> DiffLine in
            let text = "if branch\(number) { return }"
            return DiffLine(
                kind: .addition, oldLine: nil, newLine: number, text: text,
                contextHash: SHA256Digest(data: Data(text.utf8)))
        }
        let hunk = DiffHunk(
            header: "@@ -9,0 +10,4 @@", oldStart: 9, oldLines: 0,
            newStart: 10, newLines: 4, lines: lines)
        let file = DiffArtifact(
            path: fixture.file.path, status: .modified, additions: 4,
            deletions: 0, binary: false, truncated: false,
            oldLineCount: 9, newLineCount: 13, hunks: [hunk])
        let manifest = fixture.manifest(files: [file])
        let pack = try ContextPackBuilder(inputBudget: 96 * 1024).build(manifest: manifest)
        let document = try fixture.tour(producer: .localModel, digest: pack.digest)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "rtc-tour-intents-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteStore(rootURL: root)
        let jobs = TourGenerationJobHandler(
            persistence: SQLiteTourPersistence(store: store), jobs: JobQueue(store: store),
            artifacts: ExactTourArtifactResolver(git: FakeGit(manifest: manifest)),
            transport: OllamaTourTransport(document: document)
        )
        let configuration = try LocalTourConfiguration(
            kind: .ollama,
            endpoint: try LoopbackEndpoint(URL(string: "http://127.0.0.1:11434")!),
            model: "fixture-model"
        )
        let run = await jobs.generate(
            reviewID: fixture.revision.reviewID,
            revision: fixture.revision, configuration: configuration)
        try expect(run.state == .fallback, "material change without a grounded diagram was accepted")
        try expect(
            run.diagramIntents.contains(where: { $0.kind == .controlFlow && $0.material }),
            "material diagram intent was not recorded")
    }

    private static func deterministicFallbackIsStable(_ fixture: Fixture) async throws {
        let source = ManifestTourArtifactSource(manifest: fixture.manifest())
        let request = TourGenerationRequest(revision: fixture.revision, contextDigest: fixture.contextDigest)
        let provider = FallbackTourProvider(source: source)
        let first = try await provider.generate(request: request) { _ in }
        let second = try await provider.generate(request: request) { _ in }
        try expect(first == second, "fallback tour was not deterministic")
        try expect(first.title.value == "Generated outline unavailable", "fallback is not explicitly labelled")
    }

    private static func cancellationIsExplicitAndDurable(_ fixture: Fixture) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rtc-tour-cancel-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteStore(rootURL: root)
        let persistence = SQLiteTourPersistence(store: store)
        let artifacts = ExactTourArtifactResolver(git: FakeGit(manifest: fixture.manifest()))
        let jobs = TourGenerationJobHandler(
            persistence: persistence, jobs: JobQueue(store: store),
            artifacts: artifacts, transport: SlowTransport())
        let configuration = try LocalTourConfiguration(
            kind: .ollama,
            endpoint: try LoopbackEndpoint(URL(string: "http://127.0.0.1:11434")!),
            model: "slow-model"
        )
        let generation = Task {
            await jobs.generate(
                reviewID: fixture.revision.reviewID,
                revision: fixture.revision, configuration: configuration)
        }
        try await Task.sleep(for: .milliseconds(30))
        generation.cancel()
        await jobs.cancel(reviewID: fixture.revision.reviewID)
        let run = await generation.value
        try expect(run.state == .cancelled, "cancellation fell through to fallback or failure")
        let history = try await jobs.history(reviewID: fixture.revision.reviewID)
        try expect(history.runs.first?.state == .cancelled, "cancelled run was not persisted explicitly")
    }
}

private struct Fixture {
    let revision: RevisionIdentity
    let file: DiffArtifact
    let fileAnchor: ReviewAnchor

    init() throws {
        revision = try RevisionIdentity(
            repositoryPath: "/tmp/rtc-tour-fixture",
            baseSHA: String(repeating: "a", count: 40),
            headSHA: String(repeating: "b", count: 40))
        let text = "guard input.isValid else { return }"
        let hash = SHA256Digest(data: Data(text.utf8))
        let line = DiffLine(kind: .addition, oldLine: nil, newLine: 10, text: text, contextHash: hash)
        let hunk = DiffHunk(
            header: "@@ -9,0 +10,1 @@", oldStart: 9, oldLines: 0,
            newStart: 10, newLines: 1, lines: [line])
        file = DiffArtifact(
            path: "Sources/Feature.swift", status: .modified,
            additions: 1, deletions: 0, binary: false, truncated: false,
            oldLineCount: 9, newLineCount: 10, hunks: [hunk])
        fileAnchor = try ReviewAnchor(revision: revision, path: file.path, scope: .file)
    }

    var contextDigest: SHA256Digest {
        try! ContextPackBuilder(inputBudget: 96 * 1024).build(manifest: manifest()).digest
    }

    var anchorObject: [String: Any] {
        try! JSONSerialization.jsonObject(with: RTCCanonicalJSON.encode(fileAnchor)) as! [String: Any]
    }

    func manifest(files: [DiffArtifact]? = nil) -> ReviewManifest {
        let values = files ?? [file]
        return ReviewManifest(
            id: revision.reviewID, revision: revision,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1), status: .ready, stale: false,
            summary: ReviewSummary(
                files: values.count,
                additions: values.reduce(0) { $0 + $1.additions },
                deletions: values.reduce(0) { $0 + $1.deletions }),
            files: values)
    }

    func tour(
        id: UUID = UUID(), producer: TourProducer, digest: SHA256Digest, title: String = "Validated tour",
        blocks: [TourBlock] = []
    ) throws -> TourDocument {
        let summary = try RichText(runs: [RichTextRun(kind: .plain, text: "Behavior changes are grounded here.")])
        let chapter = TourChapter(
            id: "behavior", title: "Behavior", summary: summary,
            anchors: [fileAnchor], blocks: blocks)
        return try TourDocument(
            id: id, revision: revision, producer: producer,
            inputDigest: digest, title: try BoundedString(title),
            overview: [.paragraph(summary)], reviewFocuses: [],
            chapters: [chapter], risks: [])
    }
}

private struct FakeGit: ExactGitService {
    let manifest: ReviewManifest
    func materialize(_ revision: RevisionIdentity) async throws -> ReviewManifest {
        guard revision == manifest.revision else { throw TestFailure("revision mismatch") }
        return manifest
    }
    func context(_ request: GitContextRequest) async throws -> GitContext { throw TestFailure("unused") }
    func verifyCurrentHead(_ revision: RevisionIdentity) async throws -> Bool { revision == manifest.revision }
    func cancel(_ cancellation: GitCancellation) async {}
}

private struct SecretCredentials: ModelCredentialLookup {
    func credential(for key: String) async throws -> String? { "secret-value-that-must-not-be-persisted" }
}

private final class OllamaTourTransport: ModelHTTPTransport, @unchecked Sendable {
    private let response: Data
    init(document: TourDocument) {
        let documentData = try! RTCCanonicalJSON.encode(document)
        response =
            try! JSONSerialization.data(withJSONObject: [
                "response": String(decoding: documentData, as: UTF8.self), "done": false,
            ]) + Data("\n".utf8)
    }
    func send(_ request: URLRequest, limits: ModelLimits) async throws -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(response); continuation.finish()
        }
    }
}

private struct SlowTransport: ModelHTTPTransport {
    func send(_ request: URLRequest, limits: ModelLimits) async throws -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                try? await Task.sleep(for: .seconds(1))
                if !Task.isCancelled { continuation.finish(throwing: ModelAdapterError.timedOut) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw TestFailure(message) }
}

private func expectSuccess(_ result: Result<TourDocument, TourValidationFailure>) throws {
    guard case .success = result else { throw TestFailure("expected tour validation success") }
}

private func expectFailure(
    _ result: Result<TourDocument, TourValidationFailure>,
    code: TourValidationCode
) throws {
    guard case .failure(let failure) = result, failure.issues.contains(where: { $0.code == code }) else {
        throw TestFailure("expected validation failure \(code.rawValue)")
    }
}

private struct TestFailure: Error { let message: String; init(_ message: String) { self.message = message } }
