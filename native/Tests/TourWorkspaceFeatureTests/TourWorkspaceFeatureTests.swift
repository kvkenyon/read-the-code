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
        try await sideSpecificDiffSlicesAreExact(fixture)
        try await hostileStructuredContentIsRejected(fixture)
        try strictDecoderRejectsUnknownFields(fixture)
        try await strictDecoderRejectsBypassedBoundsAndDuplicateKeys(fixture)
        try await suppliedAndLocalToursShareValidationAndPersistence(fixture)
        try await corruptReplayFailsClosed(fixture)
        try await durableJobsResumeAndRemainIdempotent(fixture)
        try await modelStreamingIsBoundedByWorkAndDeadline(fixture)
        try await reviewStateIsAuthoritative(fixture)
        try await materialSignalsRequireGroundedDiagrams(fixture)
        try await cancellationIsExplicitAndDurable(fixture)
        try await deterministicFallbackIsStable(fixture)
        try await noChangesIsTruthful(fixture)
        try diagramLayoutDigestIncludesSemantics(fixture)
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
        let hash = fixture.file.hunks[0].lines[0].contextHash
        let valid = DiffSliceReference(
            path: fixture.file.path, hunkIndex: 0, startLine: 10, endLine: 10,
            startContextHash: hash, endContextHash: hash)
        let invalid = DiffSliceReference(
            path: fixture.file.path, hunkIndex: 9, startLine: 10, endLine: 10,
            startContextHash: hash, endContextHash: hash)
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

    private static func sideSpecificDiffSlicesAreExact(_ fixture: Fixture) async throws {
        func line(_ kind: DiffLineKind, old: Int?, new: Int?, _ text: String) -> DiffLine {
            DiffLine(
                kind: kind, oldLine: old, newLine: new, text: text,
                contextHash: SHA256Digest(data: Data(text.utf8)))
        }
        let replacement = DiffHunk(
            header: "@@ -10,3 +10,3 @@", oldStart: 10, oldLines: 3, newStart: 10, newLines: 3,
            lines: [
                line(.deletion, old: 10, new: nil, "old value"),
                line(.addition, old: nil, new: 10, "new value"),
                line(.context, old: 11, new: 11, "shared"),
                line(.deletion, old: 12, new: nil, "removed"),
                line(.addition, old: nil, new: 12, "added"),
            ])
        let renamed = DiffArtifact(
            path: "Sources/New.swift", oldPath: "Sources/Old.swift", status: .renamed,
            additions: 2, deletions: 2, binary: false, truncated: false,
            oldLineCount: 12, newLineCount: 12, hunks: [replacement])
        let manifest = fixture.manifest(files: [renamed])
        let resolver = ExactTourArtifactResolver(git: FakeGit(manifest: manifest))
        let oldHash = replacement.lines[0].contextHash
        let newHash = replacement.lines[1].contextHash
        let old = DiffSliceReference(
            path: "Sources/Old.swift", hunkIndex: 0, side: .old, startLine: 10, endLine: 10,
            startContextHash: oldHash, endContextHash: oldHash)
        let new = DiffSliceReference(
            path: "Sources/New.swift", hunkIndex: 0, side: .new, startLine: 10, endLine: 10,
            startContextHash: newHash, endContextHash: newHash)
        let oldSlice = try await resolver.resolve(old, revision: fixture.revision)
        let newSlice = try await resolver.resolve(new, revision: fixture.revision)
        try expect(oldSlice.lines.map(\.text) == ["old value"], "old-side replacement included new content")
        try expect(newSlice.lines.map(\.text) == ["new value"], "new-side replacement included deleted content")

        let deletionOnly = DiffHunk(
            header: "@@ -20,1 +20,0 @@", oldStart: 20, oldLines: 1, newStart: 20, newLines: 0,
            lines: [line(.deletion, old: 20, new: nil, "gone")])
        let deleted = DiffArtifact(
            path: "Sources/Gone.swift", status: .deleted, additions: 0, deletions: 1,
            binary: false, truncated: false, hunks: [deletionOnly])
        let deletionResolver = ExactTourArtifactResolver(git: FakeGit(manifest: fixture.manifest(files: [deleted])))
        let deletedHash = deletionOnly.lines[0].contextHash
        _ = try await deletionResolver.resolve(
            DiffSliceReference(
                path: deleted.path, hunkIndex: 0, side: .old, startLine: 20, endLine: 20,
                startContextHash: deletedHash, endContextHash: deletedHash),
            revision: fixture.revision)
        do {
            _ = try await deletionResolver.resolve(
                DiffSliceReference(
                    path: deleted.path, hunkIndex: 0, side: .new, startLine: 20, endLine: 20,
                    startContextHash: deletedHash, endContextHash: deletedHash),
                revision: fixture.revision)
            throw TestFailure("zero-count new side resolved")
        } catch TourIntegrationError.invalidPayload {}

        let truncated = DiffArtifact(
            path: renamed.path, oldPath: renamed.oldPath, status: .renamed,
            additions: renamed.additions, deletions: renamed.deletions,
            binary: false, truncated: true, hunks: [replacement])
        let truncatedResolver = ExactTourArtifactResolver(git: FakeGit(manifest: fixture.manifest(files: [truncated])))
        do {
            _ = try await truncatedResolver.resolve(
                DiffSliceReference(
                    path: truncated.path, hunkIndex: 0, side: .new, startLine: 10, endLine: 13,
                    startContextHash: newHash, endContextHash: newHash),
                revision: fixture.revision)
            throw TestFailure("noncontiguous truncated slice resolved")
        } catch TourIntegrationError.invalidPayload {}
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
        do {
            _ = try fixture.tour(
                producer: .workerSupplied, digest: fixture.contextDigest,
                title: String(repeating: "x", count: RTCConstants.maxLabelCharacters + 1))
            throw TestFailure("bounded constructor accepted an oversized title")
        } catch RTCContractError.invalid {}

        let nodes = (0...RTCConstants.maxNodes).map { index in
            ["id": "n\(index)", "label": "node \(index)", "role": "action", "anchors": [fixture.anchorObject]]
                as [String: Any]
        }
        let diagramObject: [String: Any] = [
            "id": "bomb", "kind": "controlFlow", "title": "Bounded graph",
            "summary": ["runs": [["kind": "plain", "text": "Graph summary"]]],
            "nodes": nodes, "edges": [], "groups": [], "anchors": [fixture.anchorObject],
        ]
        do {
            _ = try JSONDecoder().decode(
                DiagramDocument.self,
                from: JSONSerialization.data(withJSONObject: diagramObject))
            throw TestFailure("bounded decoder accepted an oversized graph")
        } catch RTCContractError.invalid {}
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

    private static func strictDecoderRejectsBypassedBoundsAndDuplicateKeys(_ fixture: Fixture) async throws {
        let tour = try fixture.tour(producer: .workerSupplied, digest: fixture.contextDigest)
        let canonical = try RTCCanonicalJSON.encode(tour)
        var object = try JSONSerialization.jsonObject(with: canonical) as! [String: Any]
        var overview = object["overview"] as! [[String: Any]]
        var paragraph = overview[0]["paragraph"] as! [String: Any]
        paragraph["_0"] = ["runs": Array(repeating: ["kind": "plain", "text": "x"], count: 257)]
        overview[0]["paragraph"] = paragraph; object["overview"] = overview
        do {
            _ = try StrictTourDecoder.decode(JSONSerialization.data(withJSONObject: object))
            throw TestFailure("257 rich-text runs bypassed strict decoding")
        } catch TourIntegrationError.invalidPayload {}

        let duplicate = String(decoding: canonical, as: UTF8.self).replacingOccurrences(
            of: "\"title\":\"Validated tour\"",
            with: "\"title\":\"Validated tour\",\"title\":\"duplicate\"")
        do {
            _ = try StrictTourDecoder.decode(Data(duplicate.utf8))
            throw TestFailure("duplicate JSON key was accepted")
        } catch TourIntegrationError.invalidPayload {}

        object = try JSONSerialization.jsonObject(with: canonical) as! [String: Any]
        object["risks"] = [
            [
                "title": "Risk", "body": ["runs": [["kind": "plain", "text": "Ground this risk"]]],
                "anchors": [],
            ]
        ]
        let ungrounded = try StrictTourDecoder.decode(JSONSerialization.data(withJSONObject: object))
        try expectFailure(
            await TourValidator().validate(
                ungrounded, against: fixture.revision,
                expectedInputDigest: fixture.contextDigest,
                anchors: ManifestTourArtifactSource(manifest: fixture.manifest())),
            code: .insufficientGrounding)

        object = try JSONSerialization.jsonObject(with: canonical) as! [String: Any]
        var chapters = object["chapters"] as! [[String: Any]]; chapters[0]["id"] = "overview"
        object["chapters"] = chapters
        let reserved = try StrictTourDecoder.decode(JSONSerialization.data(withJSONObject: object))
        try expectFailure(
            await TourValidator().validate(
                reserved, against: fixture.revision,
                expectedInputDigest: fixture.contextDigest,
                anchors: ManifestTourArtifactSource(manifest: fixture.manifest())),
            code: .duplicateID)

        let envelope = WorkerTourEnvelope(
            document: tour,
            attribution: WorkerTourAttribution(
                identityLabel: "worker-1", generatorName: "generator", generatorVersion: "2"))
        let envelopeData = try RTCCanonicalJSON.encode(envelope)
        let decoded = try StrictTourDecoder.decodeWorkerEnvelope(envelopeData)
        try expect(decoded.attribution.identityLabel.value == "worker-1", "worker attribution was lost")
        var envelopeObject = try JSONSerialization.jsonObject(with: envelopeData) as! [String: Any]
        var attribution = envelopeObject["attribution"] as! [String: Any]; attribution["secret"] = "no"
        envelopeObject["attribution"] = attribution
        do {
            _ = try StrictTourDecoder.decodeWorkerEnvelope(JSONSerialization.data(withJSONObject: envelopeObject))
            throw TestFailure("unknown worker envelope attribution was accepted")
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
        let localRun = try await jobs.generate(
            reviewID: fixture.revision.reviewID,
            revision: fixture.revision, configuration: configuration)
        try expect(localRun.state == .succeeded, "valid local tour did not succeed")

        let supplied = try fixture.tour(producer: .workerSupplied, digest: pack.digest)
        let attribution = WorkerTourAttribution(
            identityLabel: "firstmate-worker",
            generatorName: "fixture-generator",
            generatorVersion: "2.1")
        let suppliedRun = try await jobs.attach(
            supplied,
            reviewID: fixture.revision.reviewID,
            attribution: attribution
        )
        try expect(suppliedRun.state == .succeeded, "valid supplied tour did not succeed")
        let history = try await jobs.history(reviewID: fixture.revision.reviewID)
        try expect(
            history.tours.count == 2 && history.attachments.first?.state == .accepted,
            "tour history or attachment state was not persisted")
        _ = try await jobs.attach(supplied, reviewID: fixture.revision.reviewID, attribution: attribution)
        let afterDuplicate = try await jobs.history(reviewID: fixture.revision.reviewID)
        try expect(
            afterDuplicate.attachments.count == 1,
            "identical worker attachment was not idempotent")

        let conflicting = try fixture.tour(
            id: supplied.id, producer: .workerSupplied,
            digest: pack.digest, title: "Different valid content")
        let conflict = try await jobs.attach(conflicting, reviewID: fixture.revision.reviewID)
        try expect(
            conflict.failureCode == .tourIDConflict,
            "same tour ID with different content did not preserve error taxonomy")
        try await jobs.rate(
            reviewID: fixture.revision.reviewID, revision: fixture.revision, tourID: supplied.id, rating: .helpful)
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
        let rejected = try await jobs.attach(malicious, reviewID: fixture.revision.reviewID)
        try expect(rejected.state == .rejected, "hostile supplied tour was accepted")
        let afterReject = try await jobs.history(reviewID: fixture.revision.reviewID)
        try expect(
            afterReject.tours.count == 2 && afterReject.attachments.contains(where: { $0.state == .rejected }),
            "rejected attachment was rendered or not recorded")
    }

    private static func corruptReplayFailsClosed(_ fixture: Fixture) async throws {
        for corruptAttachments in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "rtc-tour-corrupt-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let store = try SQLiteStore(rootURL: root)
            let jobs = TourGenerationJobHandler(
                persistence: SQLiteTourPersistence(store: store), jobs: JobQueue(store: store),
                artifacts: ExactTourArtifactResolver(git: FakeGit(manifest: fixture.manifest())))
            let tour = try fixture.tour(producer: .workerSupplied, digest: fixture.contextDigest)
            _ = try await jobs.attach(tour, reviewID: fixture.revision.reviewID)
            if corruptAttachments {
                try await store.write { db in
                    try db.execute(
                        sql: "UPDATE settings SET value = ? WHERE key LIKE ?",
                        arguments: [Data("corrupt".utf8), "tour.attachment.\(fixture.revision.reviewID.value).%"])
                }
            } else {
                try await store.write { db in
                    try db.execute(
                        sql: "UPDATE tour_documents SET payload = ? WHERE review_id = ?",
                        arguments: [
                            Data("{\"title\":\"<script>owned</script>\"}".utf8), fixture.revision.reviewID.value,
                        ])
                }
            }
            var rejected = false
            do { _ = try await jobs.history(reviewID: fixture.revision.reviewID, revision: fixture.revision) } catch {
                rejected = true
            }
            try expect(rejected, "corrupt persisted tour state was replayed")
        }
    }

    private static func durableJobsResumeAndRemainIdempotent(_ fixture: Fixture) async throws {
        let configuration = try LocalTourConfiguration(
            kind: .ollama, endpoint: try LoopbackEndpoint(URL(string: "http://127.0.0.1:11434")!),
            model: "durable-model")
        let localTour = try fixture.tour(producer: .localModel, digest: fixture.contextDigest)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rtc-tour-resume-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteStore(rootURL: root), queue = JobQueue(store: store)
        let persistence = SQLiteTourPersistence(store: store)
        let artifacts = ExactTourArtifactResolver(git: FakeGit(manifest: fixture.manifest()))
        let transport = CountingOllamaTransport(document: localTour)
        let first = TourGenerationJobHandler(
            persistence: persistence, jobs: queue, artifacts: artifacts, transport: transport)
        let request = try await first.enqueueGeneration(
            reviewID: fixture.revision.reviewID, revision: fixture.revision, configuration: configuration)
        let restarted = TourGenerationJobHandler(
            persistence: persistence, jobs: queue, artifacts: artifacts, transport: transport)
        let resumed = try await restarted.resumePending()
        try expect(resumed.first?.state == .succeeded, "queued generation did not resume after restart")
        let repeated = try await restarted.generate(
            reviewID: fixture.revision.reviewID, revision: fixture.revision, configuration: configuration)
        try expect(repeated.id == request.runID, "deterministic request key created a second run")
        try expect(transport.requestCount == 1, "idempotent retry repeated model work")

        for checkpoint in [
            TourGenerationCheckpoint.enqueued, .leased, .modelResponse, .validated, .published, .completed,
        ] {
            let crashRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
                "rtc-tour-crash-\(checkpoint.rawValue)-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: crashRoot) }
            let crashStore = try SQLiteStore(rootURL: crashRoot), crashQueue = JobQueue(store: crashStore)
            let crashPersistence = SQLiteTourPersistence(store: crashStore)
            let crashTransport = CountingOllamaTransport(document: localTour)
            let crashing = TourGenerationJobHandler(
                persistence: crashPersistence, jobs: crashQueue, artifacts: artifacts,
                transport: crashTransport,
                checkpoint: { point in
                    if point == checkpoint { throw TourGenerationInjectedCrash.at(point) }
                })
            do {
                _ = try await crashing.generate(
                    reviewID: fixture.revision.reviewID, revision: fixture.revision,
                    configuration: configuration)
                throw TestFailure("injected crash did not interrupt \(checkpoint.rawValue)")
            } catch is TourGenerationInjectedCrash {}
            let future = Date().addingTimeInterval(61)
            let recovery = TourGenerationJobHandler(
                persistence: crashPersistence, jobs: crashQueue, artifacts: artifacts,
                transport: crashTransport)
            let recovered = try await recovery.resumePending(now: future)
            let durable = try await crashPersistence.run(id: request.runID)
            if checkpoint == .published || checkpoint == .completed {
                try expect(durable?.state == .succeeded, "atomic publish/completion was not durable")
            } else {
                try expect(recovered.first?.state == .succeeded, "restart did not recover \(checkpoint.rawValue)")
                try expect((durable?.attempt ?? 0) >= 1, "lease attempt was not persisted")
            }
        }
    }

    private static func modelStreamingIsBoundedByWorkAndDeadline(_ fixture: Fixture) async throws {
        let endpoint = try LoopbackEndpoint(URL(string: "http://127.0.0.1:11434")!)
        let terminal = try JSONSerialization.data(withJSONObject: ["response": "{}", "done": true]) + Data("\n".utf8)
        let slow = OllamaAdapter(
            endpoint: endpoint, model: "slow",
            limits: ModelLimits(timeout: .milliseconds(10)),
            transport: ScriptedTransport(chunks: [terminal], delay: .milliseconds(120)))
        try await expectModelError(.timedOut) {
            try await slow.generateStructured(request: Data("{}".utf8), schema: Data("{}".utf8))
        }

        let endless = OllamaAdapter(
            endpoint: endpoint, model: "endless",
            limits: ModelLimits(maxEvents: 4),
            transport: ScriptedTransport(chunks: [Data(String(repeating: "\n", count: 8).utf8)]))
        try await expectModelError(.responseTooLarge) {
            try await endless.generateStructured(request: Data("{}".utf8), schema: Data("{}".utf8))
        }

        let huge = OllamaAdapter(
            endpoint: endpoint, model: "huge",
            limits: ModelLimits(maxLineBytes: 32),
            transport: ScriptedTransport(chunks: [Data(String(repeating: "x", count: 33).utf8)]))
        try await expectModelError(.responseTooLarge) {
            try await huge.generateStructured(request: Data("{}".utf8), schema: Data("{}".utf8))
        }

        let deepObject = String(repeating: "{\"x\":", count: 8) + "0" + String(repeating: "}", count: 8)
        let deepEvent = Data((deepObject + "\n").utf8)
        let deep = OllamaAdapter(
            endpoint: endpoint, model: "deep", limits: ModelLimits(maxJSONDepth: 4),
            transport: ScriptedTransport(chunks: [deepEvent]))
        try await expectModelError(.malformedResponse) {
            try await deep.generateStructured(request: Data("{}".utf8), schema: Data("{}".utf8))
        }

        let partialEvent = try JSONSerialization.data(withJSONObject: ["response": "{}", "done": false])
        let partial = OllamaAdapter(
            endpoint: endpoint, model: "partial",
            transport: ScriptedTransport(chunks: [partialEvent]))
        try await expectModelError(.malformedResponse) {
            try await partial.generateStructured(request: Data("{}".utf8), schema: Data("{}".utf8))
        }

        let terminalThenBomb = terminal + Data(String(repeating: "x", count: 300_000).utf8)
        let stopped = OllamaAdapter(
            endpoint: endpoint, model: "terminal",
            limits: ModelLimits(maxLineBytes: 400_000),
            transport: ScriptedTransport(chunks: [terminalThenBomb]))
        let stoppedOutput = try await stopped.generateStructured(
            request: Data("{}".utf8), schema: Data("{}".utf8))
        try expect(stoppedOutput == Data("{}".utf8), "adapter processed bytes after terminal event")

        let bodyBounded = OllamaAdapter(
            endpoint: endpoint, model: "request-cap",
            limits: ModelLimits(maxRequestBytes: 20),
            transport: ScriptedTransport(chunks: [terminal]))
        try await expectModelError(.responseTooLarge) {
            try await bodyBounded.generateStructured(request: Data("{}".utf8), schema: Data("{}".utf8))
        }
        let invalidLimits = OllamaAdapter(
            endpoint: endpoint, model: "invalid", limits: ModelLimits(maxEvents: 0),
            transport: ScriptedTransport(chunks: [terminal]))
        try await expectModelError(.unsupportedSchema) {
            try await invalidLimits.generateStructured(request: Data("{}".utf8), schema: Data("{}".utf8))
        }
    }

    private static func reviewStateIsAuthoritative(_ fixture: Fixture) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rtc-tour-stale-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteStore(rootURL: root)
        let persistence = SQLiteTourPersistence(store: store)
        let artifacts = ExactTourArtifactResolver(git: FakeGit(manifest: fixture.manifest()))
        let writable = TourGenerationJobHandler(
            persistence: persistence, jobs: JobQueue(store: store), artifacts: artifacts)
        let tour = try fixture.tour(producer: .workerSupplied, digest: fixture.contextDigest)
        _ = try await writable.attach(tour, reviewID: fixture.revision.reviewID)

        let staleManifest = fixture.manifest(stale: true)
        let stale = TourGenerationJobHandler(
            persistence: persistence, jobs: JobQueue(store: store), artifacts: artifacts,
            reviewStateSource: StaticReviewStateSource(
                state: TourReviewState(manifest: staleManifest, objectExists: true, symbolicHeadMatches: false)))
        let history = try await stale.history(reviewID: fixture.revision.reviewID, revision: fixture.revision)
        try expect(history.selectedTour?.id == tour.id, "stale exact artifacts could not be replayed read-only")
        try expect(!history.reviewState.isWritable, "symbolic-head movement remained writable")
        do {
            _ = try await stale.attach(tour, reviewID: fixture.revision.reviewID)
            throw TestFailure("stale review accepted attachment mutation")
        } catch TourIntegrationError.readOnlyReview {}
        do {
            try await stale.rate(
                reviewID: fixture.revision.reviewID, revision: fixture.revision,
                tourID: tour.id, rating: .helpful)
            throw TestFailure("stale review accepted rating mutation")
        } catch TourIntegrationError.readOnlyReview {}
        try await stale.validateNavigation(fixture.fileAnchor)

        let missing = TourGenerationJobHandler(
            persistence: persistence, jobs: JobQueue(store: store), artifacts: artifacts,
            reviewStateSource: StaticReviewStateSource(
                state: TourReviewState(manifest: staleManifest, objectExists: false, symbolicHeadMatches: false)))
        do {
            try await missing.validateNavigation(fixture.fileAnchor)
            throw TestFailure("navigation dispatched after exact object disappeared")
        } catch TourIntegrationError.invalidPayload {}
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
        let run = try await jobs.generate(
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
        try expect(first.producer == .deterministicFallback, "fallback producer attribution was not truthful")
    }

    private static func noChangesIsTruthful(_ fixture: Fixture) async throws {
        let manifest = fixture.manifest(files: [])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rtc-tour-empty-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteStore(rootURL: root)
        let jobs = TourGenerationJobHandler(
            persistence: SQLiteTourPersistence(store: store), jobs: JobQueue(store: store),
            artifacts: ExactTourArtifactResolver(git: FakeGit(manifest: manifest)))
        let run = try await jobs.deterministicFallback(
            reviewID: fixture.revision.reviewID, revision: fixture.revision)
        try expect(run.state == .noChanges && run.tourID == nil, "empty review fabricated a fallback tour")
        let history = try await jobs.history(reviewID: fixture.revision.reviewID, revision: fixture.revision)
        try expect(history.tours.isEmpty && history.selectedTour == nil, "empty review exposed a renderable tour")
    }

    private static func diagramLayoutDigestIncludesSemantics(_ fixture: Fixture) throws {
        func document(edgeLabel: String) throws -> DiagramDocument {
            let object: [String: Any] = [
                "id": "flow-diagram", "kind": "controlFlow", "title": "Control flow",
                "summary": ["runs": [["kind": "plain", "text": "Bounded flow"]]],
                "nodes": [
                    ["id": "entry-node", "label": "Start", "role": "entry", "anchors": [fixture.anchorObject]],
                    ["id": "exit-node", "label": "Finish", "role": "exit", "anchors": [fixture.anchorObject]],
                ],
                "edges": [
                    [
                        "from": "entry-node", "to": "exit-node", "label": edgeLabel,
                        "role": "next", "anchors": [fixture.anchorObject],
                    ]
                ],
                "groups": [["id": "flow-group", "label": "Main path", "nodeIDs": ["entry-node", "exit-node"]]],
                "anchors": [fixture.anchorObject],
            ]
            return try JSONDecoder().decode(
                DiagramDocument.self, from: JSONSerialization.data(withJSONObject: object))
        }
        let first = try DiagramLayoutEngine.layout(DiagramValidator.validate(document(edgeLabel: "continues")))
        let second = try DiagramLayoutEngine.layout(DiagramValidator.validate(document(edgeLabel: "returns")))
        try expect(first.digest != second.digest, "diagram digest ignored relationship semantics")
        try expect(first.nodes.first?.label.isEmpty == false, "diagram layout discarded node labels")
        try expect(
            first.textualFallback?.contains("Relationships") == true, "diagram textual fallback lacks relationships")
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
            try await jobs.generate(
                reviewID: fixture.revision.reviewID,
                revision: fixture.revision, configuration: configuration)
        }
        try await Task.sleep(for: .milliseconds(30))
        generation.cancel()
        try await jobs.cancel(reviewID: fixture.revision.reviewID)
        let run = try await generation.value
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

    func manifest(files: [DiffArtifact]? = nil, stale: Bool = false, status: ReviewStatus = .ready) -> ReviewManifest {
        let values = files ?? [file]
        return ReviewManifest(
            id: revision.reviewID, revision: revision,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1), status: status, stale: stale,
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
                "response": String(decoding: documentData, as: UTF8.self), "done": true,
            ]) + Data("\n".utf8)
    }
    func send(_ request: URLRequest, limits: ModelLimits) async throws -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(response); continuation.finish()
        }
    }
}

private final class CountingOllamaTransport: ModelHTTPTransport, @unchecked Sendable {
    private let response: Data
    private let lock = NSLock()
    private var count = 0
    init(document: TourDocument) {
        let documentData = try! RTCCanonicalJSON.encode(document)
        response =
            try! JSONSerialization.data(withJSONObject: [
                "response": String(decoding: documentData, as: UTF8.self), "done": true,
            ]) + Data("\n".utf8)
    }
    var requestCount: Int { lock.withLock { count } }
    func send(_ request: URLRequest, limits: ModelLimits) async throws -> AsyncThrowingStream<Data, Error> {
        lock.withLock { count += 1 }
        return AsyncThrowingStream { continuation in
            continuation.yield(response); continuation.finish()
        }
    }
}

private struct ScriptedTransport: ModelHTTPTransport {
    let chunks: [Data]
    let delay: Duration
    init(chunks: [Data], delay: Duration = .zero) { self.chunks = chunks; self.delay = delay }
    func send(_ request: URLRequest, limits: ModelLimits) async throws -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if delay > .zero { try await Task.sleep(for: delay) }
                    for chunk in chunks { try Task.checkCancellation(); continuation.yield(chunk) }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private struct StaticReviewStateSource: TourReviewStateSource {
    let state: TourReviewState
    func state(for revision: RevisionIdentity) async throws -> TourReviewState {
        guard revision == state.manifest.revision else { throw TourIntegrationError.revisionMismatch }
        return state
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

private func expectModelError(
    _ expected: ModelAdapterError,
    operation: @escaping @Sendable () async throws -> Data
) async throws {
    do { _ = try await operation() } catch let error as ModelAdapterError {
        try expect(error == expected, "expected model error \(expected), got \(error)")
        return
    }
    throw TestFailure("expected model error \(expected)")
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
