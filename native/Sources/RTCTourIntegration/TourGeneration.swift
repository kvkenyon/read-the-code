import Foundation
import RTCContracts
import RTCModelAdapters
import RTCStore
import RTCTour

public final class LoopbackTourProvider: TourProvider, @unchecked Sendable {
    public let descriptor: BoundedString
    public let metadata: TourProviderMetadata
    private let adapter: any ModelAdapter
    private let context: ContextPack
    private let intents: [DiagramIntent]

    public init(
        configuration: LocalTourConfiguration, context: ContextPack,
        intents: [DiagramIntent], transport: any ModelHTTPTransport = URLSessionModelTransport(),
        credentials: any ModelCredentialLookup = NoCredentials()
    ) {
        descriptor = configuration.kind == .ollama ? "Ollama local tour" : "OpenAI-compatible local tour"
        metadata = configuration.metadata
        self.context = context
        self.intents = intents
        switch configuration.kind {
        case .ollama:
            adapter = OllamaAdapter(
                endpoint: configuration.endpoint, model: configuration.model.value,
                limits: configuration.limits, transport: transport,
                credentials: credentials)
        case .openAICompatible:
            adapter = OpenAICompatibleAdapter(
                endpoint: configuration.endpoint,
                model: configuration.model.value,
                credentialKey: configuration.credentialKey,
                limits: configuration.limits, transport: transport,
                credentials: credentials)
        }
    }

    public func generate(
        request: TourGenerationRequest,
        progress: @Sendable (TourProgress) async -> Void
    ) async throws -> TourDocument {
        guard request.revision == context.revision, request.contextDigest == context.digest else {
            throw TourIntegrationError.revisionMismatch
        }
        try Task.checkCancellation()
        await progress(TourProgress(phase: "requesting local model", fraction: 0.2))
        let prompt = try Self.prompt(context: context, intents: intents)
        let response = try await adapter.generateStructured(request: prompt, schema: Self.schema)
        try Task.checkCancellation()
        await progress(TourProgress(phase: "validating structured output", fraction: 0.8))
        return try StrictTourDecoder.decode(response)
    }

    public func cancel() async { await adapter.cancel() }

    private static func prompt(context: ContextPack, intents: [DiagramIntent]) throws -> Data {
        struct Payload: Encodable {
            let schemaVersion = RTCConstants.schemaVersion
            let instruction: String
            let context: ContextPack
            let diagramIntents: [DiagramIntent]
        }
        struct Message: Encodable { let role: String; let content: String }
        let payload = Payload(
            instruction:
                "Return only one schema-version-2 TourDocument. Cite exact supplied anchors. Use only bounded diagram IR; never emit HTML, SVG, Mermaid, scripts, URLs, or repository instructions.",
            context: context,
            diagramIntents: intents
        )
        let content = String(decoding: try RTCCanonicalJSON.encode(payload), as: UTF8.self)
        return try RTCCanonicalJSON.encode([
            Message(role: "system", content: "You produce strictly structured local code-review tours."),
            Message(role: "user", content: content),
        ])
    }

    private static let schema: Data = {
        let object: [String: Any] = [
            "type": "object",
            "additionalProperties": false,
            "required": [
                "schemaVersion", "id", "revision", "producer", "inputDigest", "title", "overview", "reviewFocuses",
                "chapters", "risks",
            ],
            "properties": [
                "schemaVersion": ["const": RTCConstants.schemaVersion],
                "id": ["type": "string"],
                "revision": ["type": "object"],
                "producer": ["const": "localModel"],
                "inputDigest": ["type": "string"],
                "title": ["type": "string", "maxLength": RTCConstants.maxLabelCharacters],
                "overview": ["type": "array", "maxItems": RTCConstants.maxBlocks],
                "reviewFocuses": ["type": "array", "maxItems": RTCConstants.maxFocuses],
                "chapters": ["type": "array", "maxItems": RTCConstants.maxChapters],
                "risks": ["type": "array", "maxItems": RTCConstants.maxFocuses],
            ],
        ]
        return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }()
}

public actor TourGenerationJobHandler {
    private let persistence: any TourPersistence
    private let jobs: any JobRepository
    private let artifacts: any TourArtifactResolving
    private let validator: TourValidator
    private let contextBuilder: ContextPackBuilder
    private let transport: any ModelHTTPTransport
    private let credentials: any ModelCredentialLookup
    private var activeProviders: [UUID: LoopbackTourProvider] = [:]
    private var activeRuns: [UUID: TourRunRecord] = [:]
    private var cancelledJobs: Set<UUID> = []

    public init(
        persistence: any TourPersistence, jobs: any JobRepository,
        artifacts: any TourArtifactResolving,
        validator: TourValidator = TourValidator(),
        contextBuilder: ContextPackBuilder = ContextPackBuilder(inputBudget: 96 * 1024),
        transport: any ModelHTTPTransport = URLSessionModelTransport(),
        credentials: any ModelCredentialLookup = NoCredentials()
    ) {
        self.persistence = persistence; self.jobs = jobs; self.artifacts = artifacts
        self.validator = validator; self.contextBuilder = contextBuilder
        self.transport = transport; self.credentials = credentials
    }

    public func generate(
        reviewID: ReviewID, revision: RevisionIdentity,
        configuration: LocalTourConfiguration,
        progress progressSink: @escaping @Sendable (TourProgressSnapshot) async -> Void = { _ in }
    ) async -> TourRunRecord {
        let jobID = UUID(), runID = UUID(), now = Date()
        let emptyDigest = SHA256Digest(data: Data())
        guard reviewID == revision.reviewID else {
            return TourRunRecord(
                id: runID, jobID: jobID, reviewID: reviewID, revision: revision,
                provider: configuration.metadata, contextDigest: emptyDigest,
                state: .failed, progress: .init(phase: "failed", fraction: 0),
                createdAt: now, completedAt: now, failureCode: .invalidRevision)
        }
        do {
            try await jobs.enqueue(
                JobRecord(
                    id: jobID, kind: .tourGeneration, reviewID: reviewID,
                    state: .queued, attempt: 0, availableAt: now))
            let manifest = try await artifacts.manifest(for: revision)
            let pack = try contextBuilder.build(manifest: manifest)
            let source = ManifestTourArtifactSource(manifest: manifest)
            let intents = SignalAnalyzer().intents(SignalAnalyzer().analyze(pack))
            let provider = LoopbackTourProvider(
                configuration: configuration, context: pack,
                intents: intents,
                transport: transport, credentials: credentials)
            var run = TourRunRecord(
                id: runID, jobID: jobID, reviewID: reviewID, revision: revision,
                provider: configuration.metadata, contextDigest: pack.digest,
                contextOmissions: pack.omissions, diagramIntents: intents,
                state: .running, progress: .init(phase: "building context", fraction: 0.1),
                createdAt: now)
            activeProviders[jobID] = provider; activeRuns[jobID] = run
            try await persistence.saveRun(run)
            await progressSink(run.progress)
            do {
                let candidate = try await provider.generate(
                    request: TourGenerationRequest(revision: revision, contextDigest: pack.digest)
                ) { progress in
                    await self.recordProgress(jobID: jobID, progress: progress)
                    await progressSink(.init(phase: progress.phase.value, fraction: progress.fraction))
                }
                if cancelledJobs.contains(jobID) { return await cancelled(run, jobID: jobID) }
                guard candidate.producer == .localModel else {
                    return await fallback(
                        run: run, jobID: jobID, pack: pack, source: source,
                        reason: "provider returned the wrong producer kind", issues: [])
                }
                switch await validator.validate(
                    candidate, against: revision,
                    expectedInputDigest: pack.digest, anchors: source)
                {
                case .success(let tour):
                    let qualityIssues = logicIssues(document: tour, intents: intents)
                    if !qualityIssues.isEmpty {
                        return await fallback(
                            run: run, jobID: jobID, pack: pack, source: source,
                            reason: "provider output omitted a material diagram decision",
                            issues: qualityIssues)
                    }
                    try await persistence.publishValidatedTour(ValidatedTourDocument(tour))
                    run = run.updating(
                        state: .succeeded, progress: .init(phase: "ready", fraction: 1),
                        completedAt: Date(), tourID: tour.id)
                    return await finish(run, jobID: jobID, jobState: .succeeded)
                case .failure(let failure):
                    let codes = Set(failure.issues.map { $0.code.rawValue }).sorted().joined(separator: ",")
                    return await fallback(
                        run: run, jobID: jobID, pack: pack, source: source,
                        reason: "provider output rejected: \(codes)", issues: failure.issues)
                }
            } catch is CancellationError {
                return await cancelled(run, jobID: jobID)
            } catch {
                if cancelledJobs.contains(jobID) { return await cancelled(run, jobID: jobID) }
                return await fallback(
                    run: run, jobID: jobID, pack: pack, source: source,
                    reason: safeProviderFailure(error), issues: [])
            }
        } catch {
            let run = TourRunRecord(
                id: runID, jobID: jobID, reviewID: reviewID, revision: revision,
                provider: configuration.metadata, contextDigest: emptyDigest,
                state: .failed, progress: .init(phase: "failed", fraction: 0),
                createdAt: now, completedAt: Date(), failureCode: .tourRejected)
            try? await persistence.saveRun(run); try? await jobs.complete(jobID, state: .failed)
            return run
        }
    }

    public func attach(
        _ tour: TourDocument, reviewID: ReviewID,
        attribution: WorkerTourAttribution = WorkerTourAttribution()
    ) async -> TourRunRecord {
        let now = Date(), runID = UUID()
        let candidateData = (try? RTCCanonicalJSON.encode(tour)) ?? Data()
        let candidateDigest = SHA256Digest(data: candidateData)
        let provider = attribution.metadata
        var contextDigest = tour.inputDigest
        var contextOmissions: [ContextOmission] = []
        var diagramIntents: [DiagramIntent] = []
        var issues: [TourValidationIssue] = []
        var rejectionCode: RTCErrorCode = .tourRejected
        do {
            guard reviewID == tour.revision.reviewID, tour.producer == .workerSupplied else {
                throw TourIntegrationError.revisionMismatch
            }
            if let existing = try await persistence.attachments(reviewID: reviewID)
                .first(where: { $0.candidateDigest == candidateDigest })
            {
                return TourRunRecord(
                    id: existing.id, jobID: nil, reviewID: reviewID,
                    revision: tour.revision, provider: existing.provider,
                    contextDigest: tour.inputDigest,
                    state: existing.state == .accepted ? .succeeded : .rejected,
                    progress: .init(phase: existing.state.rawValue, fraction: 1),
                    createdAt: existing.receivedAt, completedAt: existing.receivedAt,
                    tourID: existing.tourID,
                    failureCode: existing.state == .accepted ? nil : .tourRejected,
                    validationIssues: existing.validationIssues)
            }
            if let existingTour = try await persistence.tour(reviewID: reviewID, id: tour.id),
                SHA256Digest(data: try RTCCanonicalJSON.encode(existingTour)) != candidateDigest
            {
                throw TourIntegrationError.tourIDConflict
            }
            let manifest = try await artifacts.manifest(for: tour.revision)
            let pack = try contextBuilder.build(manifest: manifest); contextDigest = pack.digest
            let intents = SignalAnalyzer().intents(SignalAnalyzer().analyze(pack))
            contextOmissions = pack.omissions; diagramIntents = intents
            let source = ManifestTourArtifactSource(manifest: manifest)
            switch await validator.validate(
                tour, against: manifest.revision,
                expectedInputDigest: pack.digest, anchors: source)
            {
            case .success(let validated):
                let qualityIssues = logicIssues(document: validated, intents: intents)
                guard qualityIssues.isEmpty else { issues = qualityIssues; break }
                let attachment = TourAttachmentRecord(
                    id: UUID(), reviewID: reviewID, receivedAt: now,
                    provider: provider, candidateDigest: candidateDigest,
                    state: .accepted, tourID: validated.id, validationIssues: [])
                try await persistence.publishValidatedTour(
                    ValidatedTourDocument(validated), attachment: attachment)
                let run = TourRunRecord(
                    id: runID, jobID: nil, reviewID: reviewID,
                    revision: tour.revision, provider: provider,
                    contextDigest: pack.digest, contextOmissions: pack.omissions,
                    diagramIntents: intents, state: .succeeded,
                    progress: .init(phase: "attached", fraction: 1),
                    createdAt: now, completedAt: now, tourID: validated.id)
                try await persistence.saveRun(run)
                return run
            case .failure(let failure):
                issues = failure.issues
            }
        } catch TourIntegrationError.tourIDConflict {
            rejectionCode = .tourIDConflict
            issues = [
                .init(
                    code: .duplicateID, location: "id",
                    message: "tour ID is already attached to different content")
            ]
        } catch {
            if issues.isEmpty {
                issues = [
                    .init(
                        code: .revisionMismatch, location: "revision",
                        message: "supplied tour does not match exact review evidence")
                ]
            }
        }
        let attachment = TourAttachmentRecord(
            id: UUID(), reviewID: reviewID, receivedAt: now,
            provider: provider, candidateDigest: candidateDigest,
            state: .rejected, tourID: nil, validationIssues: issues)
        try? await persistence.saveAttachment(attachment)
        let run = TourRunRecord(
            id: runID, jobID: nil, reviewID: reviewID, revision: tour.revision,
            provider: provider, contextDigest: contextDigest,
            contextOmissions: contextOmissions, diagramIntents: diagramIntents,
            state: .rejected,
            progress: .init(phase: "rejected", fraction: 1), createdAt: now,
            completedAt: now, failureCode: rejectionCode, validationIssues: issues)
        try? await persistence.saveRun(run)
        return run
    }

    public func deterministicFallback(
        reviewID: ReviewID, revision: RevisionIdentity,
        reason: String = "No tour provider is configured"
    ) async -> TourRunRecord {
        let now = Date(), runID = UUID(), emptyDigest = SHA256Digest(data: Data())
        guard reviewID == revision.reviewID else {
            return TourRunRecord(
                id: runID, jobID: nil, reviewID: reviewID, revision: revision,
                provider: .fallback, contextDigest: emptyDigest, state: .failed,
                progress: .init(phase: "failed", fraction: 1), createdAt: now,
                completedAt: now, failureCode: .invalidRevision)
        }
        do {
            let manifest = try await artifacts.manifest(for: revision)
            let pack = try contextBuilder.build(manifest: manifest)
            let intents = SignalAnalyzer().intents(SignalAnalyzer().analyze(pack))
            let source = ManifestTourArtifactSource(manifest: manifest)
            let document = try await FallbackTourProvider(source: source).generate(
                request: TourGenerationRequest(revision: revision, contextDigest: pack.digest)
            ) { _ in }
            guard
                case .success(let validated) = await validator.validate(
                    document, against: revision, expectedInputDigest: pack.digest, anchors: source
                )
            else { throw TourIntegrationError.invalidPayload }
            try await persistence.publishValidatedTour(ValidatedTourDocument(validated))
            let run = TourRunRecord(
                id: runID, jobID: nil, reviewID: reviewID, revision: revision,
                provider: .fallback, contextDigest: pack.digest,
                contextOmissions: pack.omissions, diagramIntents: intents,
                state: .fallback,
                progress: .init(phase: "fallback ready", fraction: 1),
                createdAt: now, completedAt: now, tourID: validated.id,
                fallbackReason: String(reason.prefix(240)))
            try await persistence.saveRun(run)
            return run
        } catch {
            let run = TourRunRecord(
                id: runID, jobID: nil, reviewID: reviewID, revision: revision,
                provider: .fallback, contextDigest: emptyDigest, state: .failed,
                progress: .init(phase: "failed", fraction: 1), createdAt: now,
                completedAt: now, fallbackReason: String(reason.prefix(240)),
                failureCode: .tourRejected)
            try? await persistence.saveRun(run)
            return run
        }
    }

    public func cancel(jobID: UUID) async {
        cancelledJobs.insert(jobID)
        await activeProviders[jobID]?.cancel()
        if let run = activeRuns[jobID] {
            let cancelled = run.updating(
                state: .cancelled,
                progress: .init(phase: "cancelled", fraction: run.progress.fraction),
                completedAt: Date(), failureCode: .internalError)
            try? await persistence.saveRun(cancelled)
        }
        try? await jobs.complete(jobID, state: .cancelled)
    }

    public func cancel(reviewID: ReviewID) async {
        let jobIDs = activeRuns.compactMap { $0.value.reviewID == reviewID ? $0.key : nil }
        for jobID in jobIDs { await cancel(jobID: jobID) }
    }

    public func history(reviewID: ReviewID) async throws -> TourHistorySnapshot {
        let tours = try await persistence.tours(reviewID: reviewID)
        let selectedID = try await persistence.selectedTourID(reviewID: reviewID)
        let selected = selectedID.flatMap { id in tours.first { $0.id == id } }
        let rating: TourRatingRecord?
        if let selected {
            rating = try await persistence.rating(reviewID: reviewID, tourID: selected.id)
        } else {
            rating = nil
        }
        return TourHistorySnapshot(
            selectedTour: selected, tours: tours,
            runs: try await persistence.runs(reviewID: reviewID),
            attachments: try await persistence.attachments(reviewID: reviewID),
            rating: rating)
    }

    public func select(reviewID: ReviewID, tourID: UUID) async throws {
        try await persistence.select(reviewID: reviewID, tourID: tourID)
    }

    public func rate(reviewID: ReviewID, tourID: UUID, rating: TourRating) async throws {
        try await persistence.saveRating(
            .init(
                reviewID: reviewID, tourID: tourID,
                rating: rating, ratedAt: Date()))
    }

    private func recordProgress(jobID: UUID, progress: TourProgress) async {
        guard let current = activeRuns[jobID], !cancelledJobs.contains(jobID) else { return }
        let updated = current.updating(
            state: .running,
            progress: .init(
                phase: progress.phase.value,
                fraction: progress.fraction))
        activeRuns[jobID] = updated
        try? await persistence.saveRun(updated)
    }

    private func fallback(
        run: TourRunRecord, jobID: UUID, pack: ContextPack,
        source: ManifestTourArtifactSource, reason: String,
        issues: [TourValidationIssue]
    ) async -> TourRunRecord {
        if cancelledJobs.contains(jobID) { return await cancelled(run, jobID: jobID) }
        do {
            let fallback = try await FallbackTourProvider(source: source).generate(
                request: TourGenerationRequest(revision: run.revision, contextDigest: pack.digest)
            ) { progress in await self.recordProgress(jobID: jobID, progress: progress) }
            switch await validator.validate(
                fallback, against: run.revision,
                expectedInputDigest: pack.digest, anchors: source)
            {
            case .success(let validated):
                try await persistence.publishValidatedTour(ValidatedTourDocument(validated))
                let completed = run.updating(
                    state: .fallback,
                    progress: .init(phase: "fallback ready", fraction: 1),
                    completedAt: Date(), tourID: validated.id,
                    fallbackReason: reason, validationIssues: issues)
                return await finish(completed, jobID: jobID, jobState: .succeeded)
            case .failure(let failure):
                let failed = run.updating(
                    state: .failed, progress: .init(phase: "failed", fraction: 1),
                    completedAt: Date(), fallbackReason: reason,
                    failureCode: .insufficientGrounding,
                    validationIssues: issues + failure.issues)
                return await finish(failed, jobID: jobID, jobState: .failed)
            }
        } catch {
            let failed = run.updating(
                state: .failed, progress: .init(phase: "failed", fraction: 1),
                completedAt: Date(), fallbackReason: reason,
                failureCode: .tourRejected, validationIssues: issues)
            return await finish(failed, jobID: jobID, jobState: .failed)
        }
    }

    private func cancelled(_ run: TourRunRecord, jobID: UUID) async -> TourRunRecord {
        let result = run.updating(
            state: .cancelled,
            progress: .init(phase: "cancelled", fraction: run.progress.fraction),
            completedAt: Date(), failureCode: .internalError)
        return await finish(result, jobID: jobID, jobState: .cancelled)
    }

    private func finish(_ run: TourRunRecord, jobID: UUID, jobState: JobState) async -> TourRunRecord {
        try? await persistence.saveRun(run); try? await jobs.complete(jobID, state: jobState)
        activeProviders[jobID] = nil; activeRuns[jobID] = nil; cancelledJobs.remove(jobID)
        return run
    }

    private func safeProviderFailure(_ error: Error) -> String {
        switch error {
        case ModelAdapterError.timedOut: "local model timed out"
        case ModelAdapterError.cancelled: "local model cancelled"
        case is ModelAdapterError: "local model unavailable or returned malformed structured output"
        case is TourIntegrationError: "local model returned invalid structured output"
        default: "local model generation failed"
        }
    }

    private func logicIssues(document: TourDocument, intents: [DiagramIntent]) -> [TourValidationIssue] {
        let blocks = document.overview + document.chapters.flatMap(\.blocks)
        let diagramKinds = Set(
            blocks.compactMap { block -> DiagramKind? in
                if case .diagram(let diagram) = block { return diagram.kind }
                return nil
            })
        return intents.filter { $0.material && !diagramKinds.contains($0.kind) }.map {
            TourValidationIssue(
                code: .insufficientGrounding,
                location: "diagramIntent.\($0.kind.rawValue)",
                message: "material change signal has no grounded diagram")
        }
    }
}
