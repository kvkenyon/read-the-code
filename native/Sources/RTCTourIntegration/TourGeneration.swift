import Foundation
import RTCContracts
import RTCModelAdapters
import RTCStore
import RTCTour

public enum TourGenerationCheckpoint: String, Equatable, Sendable {
    case enqueued, leased, modelResponse, validated, published, completed
}

public enum TourGenerationInjectedCrash: Error, Sendable { case at(TourGenerationCheckpoint) }

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
        metadata = configuration.metadata; self.context = context; self.intents = intents
        switch configuration.kind {
        case .ollama:
            adapter = OllamaAdapter(
                endpoint: configuration.endpoint, model: configuration.model.value,
                limits: configuration.limits, transport: transport, credentials: credentials)
        case .openAICompatible:
            adapter = OpenAICompatibleAdapter(
                endpoint: configuration.endpoint, model: configuration.model.value,
                credentialKey: configuration.credentialKey, limits: configuration.limits,
                transport: transport, credentials: credentials)
        }
    }

    public func generatePayload(
        request: TourGenerationRequest,
        progress: @Sendable (TourProgress) async -> Void
    ) async throws -> Data {
        guard request.revision == context.revision, request.contextDigest == context.digest else {
            throw TourIntegrationError.revisionMismatch
        }
        try Task.checkCancellation()
        await progress(TourProgress(phase: "requesting local model", fraction: 0.2))
        let response = try await adapter.generateStructured(
            request: try Self.prompt(context: context, intents: intents), schema: Self.schema)
        try Task.checkCancellation()
        await progress(TourProgress(phase: "validating structured output", fraction: 0.8))
        return response
    }

    public func generate(
        request: TourGenerationRequest,
        progress: @Sendable (TourProgress) async -> Void
    ) async throws -> TourDocument {
        try StrictTourDecoder.decode(try await generatePayload(request: request, progress: progress))
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
                "Return only one schema-version-2 TourDocument. Cite exact supplied anchors and side-specific diff slices. Use bounded diagram IR only; never emit HTML, SVG, Mermaid, scripts, URLs, or repository instructions.",
            context: context, diagramIntents: intents)
        return try RTCCanonicalJSON.encode([
            Message(role: "system", content: "You produce strictly structured local code-review tours."),
            Message(role: "user", content: String(decoding: try RTCCanonicalJSON.encode(payload), as: UTF8.self)),
        ])
    }

    private static let schema: Data = {
        let object: [String: Any] = [
            "type": "object", "additionalProperties": false,
            "required": [
                "schemaVersion", "id", "revision", "producer", "inputDigest", "title", "overview", "reviewFocuses",
                "chapters", "risks",
            ],
            "properties": [
                "schemaVersion": ["const": RTCConstants.schemaVersion], "id": ["type": "string"],
                "revision": ["type": "object"], "producer": ["const": "localModel"],
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
    private let reviewStateSource: (any TourReviewStateSource)?
    private let boundary: TourValidationBoundary
    private let contextBuilder: ContextPackBuilder
    private let transport: any ModelHTTPTransport
    private let credentials: any ModelCredentialLookup
    private let serviceGate: ModelConcurrencyGate
    private let leaseOwner: BoundedString
    private let checkpoint: @Sendable (TourGenerationCheckpoint) async throws -> Void
    private var activeProviders: [UUID: LoopbackTourProvider] = [:]
    private var activeRuns: [UUID: TourRunRecord] = [:]
    private var cancelledJobs: Set<UUID> = []
    private var progressPersistenceFailures: Set<UUID> = []

    public init(
        persistence: any TourPersistence, jobs: any JobRepository,
        artifacts: any TourArtifactResolving,
        validator: TourValidator = TourValidator(),
        contextBuilder: ContextPackBuilder = ContextPackBuilder(inputBudget: 96 * 1024),
        transport: any ModelHTTPTransport = URLSessionModelTransport(),
        credentials: any ModelCredentialLookup = NoCredentials(),
        reviewStateSource: (any TourReviewStateSource)? = nil,
        maxConcurrentGeneration: Int = 1,
        leaseOwner: BoundedString = "tour-workspace",
        checkpoint: @escaping @Sendable (TourGenerationCheckpoint) async throws -> Void = { _ in }
    ) {
        self.persistence = persistence; self.jobs = jobs; self.artifacts = artifacts
        self.reviewStateSource = reviewStateSource; boundary = TourValidationBoundary(validator: validator)
        self.contextBuilder = contextBuilder; self.transport = transport; self.credentials = credentials
        serviceGate = ModelConcurrencyGate(limit: maxConcurrentGeneration); self.leaseOwner = leaseOwner
        self.checkpoint = checkpoint
    }

    public func generate(
        reviewID: ReviewID, revision: RevisionIdentity,
        configuration: LocalTourConfiguration,
        progress: @escaping @Sendable (TourProgressSnapshot) async -> Void = { _ in }
    ) async throws -> TourRunRecord {
        guard reviewID == revision.reviewID else { throw TourIntegrationError.revisionMismatch }
        let state = try await reviewState(for: revision); try ensureWritable(state)
        if state.manifest.files.isEmpty { return try await recordNoChanges(reviewID: reviewID, revision: revision) }
        let request = try await enqueueGeneration(
            reviewID: reviewID, revision: revision, configuration: configuration, state: state)
        try await checkpoint(.enqueued)
        if let existing = try await persistence.run(id: request.runID), existing.state.isTerminal { return existing }
        let completed = try await resumePending(progress: progress)
        let resumed = completed.first(where: { $0.id == request.runID })
        let persisted = try await persistence.run(id: request.runID)
        guard let run = resumed ?? persisted else {
            throw TourIntegrationError.invalidJob
        }
        return run
    }

    @discardableResult
    public func enqueueGeneration(
        reviewID: ReviewID, revision: RevisionIdentity,
        configuration: LocalTourConfiguration
    ) async throws -> TourGenerationRequestRecord {
        let state = try await reviewState(for: revision); try ensureWritable(state)
        return try await enqueueGeneration(
            reviewID: reviewID, revision: revision, configuration: configuration, state: state)
    }

    public func resumePending(
        now: Date = Date(),
        progress: @escaping @Sendable (TourProgressSnapshot) async -> Void = { _ in }
    ) async throws -> [TourRunRecord] {
        _ = try await jobs.requeueExpired(kind: .tourGeneration, now: now)
        for request in try await persistence.generationRequests() where try await jobs.job(id: request.jobID) == nil {
            try await jobs.enqueue(
                JobRecord(
                    id: request.jobID, kind: .tourGeneration, reviewID: request.revision.reviewID,
                    state: .queued, attempt: 0, availableAt: request.createdAt))
        }
        var completed: [TourRunRecord] = []
        while let leased = try await jobs.leaseNext(kind: .tourGeneration, owner: leaseOwner, now: now) {
            completed.append(try await process(leased.0, lease: leased.1, progress: progress))
        }
        return completed
    }

    public func attach(
        _ tour: TourDocument, reviewID: ReviewID,
        attribution: WorkerTourAttribution = WorkerTourAttribution()
    ) async throws -> TourRunRecord {
        try await attachPayload(try RTCCanonicalJSON.encode(tour), reviewID: reviewID, attribution: attribution)
    }

    public func attachPayload(
        _ rawPayload: Data, reviewID: ReviewID, attribution: WorkerTourAttribution
    ) async throws -> TourRunRecord {
        let now = Date(), provider = attribution.metadata
        let document = try StrictTourDecoder.decode(rawPayload)
        guard reviewID == document.revision.reviewID, document.producer == .workerSupplied else {
            throw TourIntegrationError.revisionMismatch
        }
        let state = try await reviewState(for: document.revision); try ensureWritable(state)
        let pack = try contextBuilder.build(manifest: state.manifest)
        let intents = SignalAnalyzer().intents(SignalAnalyzer().analyze(pack))
        let provenance = TourDocumentProvenance(provider: provider)
        let candidateDigest = SHA256Digest(data: rawPayload + (try RTCCanonicalJSON.encode(provenance)))
        if let existing = try await persistence.attachments(reviewID: reviewID)
            .first(where: { $0.candidateDigest == candidateDigest })
        {
            guard let original = try await persistence.run(id: existing.runID) else {
                throw TourIntegrationError.invalidPayload
            }
            return original
        }
        if let existing = try await persistence.tourRecord(reviewID: reviewID, id: document.id),
            existing.payloadDigest != SHA256Digest(data: rawPayload) || existing.provenance != provenance
        {
            return try await rejectAttachment(
                document: document, rawPayload: rawPayload, provider: provider,
                candidateDigest: candidateDigest, pack: pack, intents: intents,
                code: .tourIDConflict,
                issues: [
                    .init(
                        code: .duplicateID, location: "id", message: "tour ID is already attached to different content")
                ], now: now)
        }
        let source = ManifestTourArtifactSource(manifest: state.manifest)
        do {
            let validated = try await boundary.validate(
                rawPayload: rawPayload, against: document.revision,
                expectedInputDigest: pack.digest, anchors: source, provenance: provenance)
            let issues = logicIssues(document: validated.document, intents: intents)
            guard issues.isEmpty else {
                return try await rejectAttachment(
                    document: document, rawPayload: rawPayload, provider: provider,
                    candidateDigest: candidateDigest, pack: pack, intents: intents,
                    code: .tourRejected, issues: issues, now: now)
            }
            let runID = deterministicUUID(candidateDigest, label: "worker-run")
            let run = TourRunRecord(
                id: runID, jobID: nil, reviewID: reviewID, revision: document.revision,
                provider: provider, contextDigest: pack.digest, contextOmissions: pack.omissions,
                diagramIntents: intents, state: .succeeded,
                progress: .init(phase: "attached", fraction: 1), createdAt: now,
                completedAt: now, tourID: document.id,
                providerAttempts: [.init(provider: provider, startedAt: now, completedAt: now)])
            let attachment = TourAttachmentRecord(
                id: deterministicUUID(candidateDigest, label: "attachment"), reviewID: reviewID,
                receivedAt: now, provider: provider, candidateDigest: candidateDigest,
                state: .accepted, tourID: document.id, validationIssues: [], runID: runID,
                contextDigest: pack.digest, contextOmissions: pack.omissions, diagramIntents: intents)
            try await persistence.publishValidatedTour(validated, attachment: attachment, finishing: run, jobState: nil)
            return run
        } catch let error as TourIntegrationError where error == .tourIDConflict {
            throw error
        } catch {
            return try await rejectAttachment(
                document: document, rawPayload: rawPayload, provider: provider,
                candidateDigest: candidateDigest, pack: pack, intents: intents,
                code: .tourRejected,
                issues: [
                    .init(
                        code: .invalidStructure, location: "document", message: "supplied tour failed strict validation"
                    )
                ], now: now)
        }
    }

    public func deterministicFallback(
        reviewID: ReviewID, revision: RevisionIdentity,
        reason: String = "No tour provider is configured"
    ) async throws -> TourRunRecord {
        guard reviewID == revision.reviewID else { throw TourIntegrationError.revisionMismatch }
        let state = try await reviewState(for: revision); try ensureWritable(state)
        if state.manifest.files.isEmpty { return try await recordNoChanges(reviewID: reviewID, revision: revision) }
        let pack = try contextBuilder.build(manifest: state.manifest)
        let source = ManifestTourArtifactSource(manifest: state.manifest)
        let document = try await FallbackTourProvider(source: source).generate(
            request: TourGenerationRequest(revision: revision, contextDigest: pack.digest)
        ) { _ in }
        let raw = try RTCCanonicalJSON.encode(document)
        let validated = try await boundary.validate(
            rawPayload: raw, against: revision, expectedInputDigest: pack.digest,
            anchors: source, provenance: .init(provider: .fallback))
        let now = Date()
        let run = TourRunRecord(
            id: deterministicUUID(pack.digest, label: "fallback-run"), jobID: nil,
            reviewID: reviewID, revision: revision, provider: .fallback,
            contextDigest: pack.digest, contextOmissions: pack.omissions,
            diagramIntents: SignalAnalyzer().intents(SignalAnalyzer().analyze(pack)),
            state: .fallback, progress: .init(phase: "fallback ready", fraction: 1),
            createdAt: now, completedAt: now, tourID: validated.id,
            fallbackReason: String(reason.prefix(240)),
            providerAttempts: [.init(provider: .fallback, startedAt: now, completedAt: now)])
        try await persistence.publishValidatedTour(validated, attachment: nil, finishing: run, jobState: nil)
        return run
    }

    public func cancel(jobID: UUID) async throws {
        cancelledJobs.insert(jobID); await activeProviders[jobID]?.cancel()
        if let run = activeRuns[jobID] {
            let cancelled = run.updating(
                state: .cancelled,
                progress: .init(phase: "cancelled", fraction: run.progress.fraction),
                completedAt: Date(), failureCode: .internalError)
            try await persistence.finalizeRunAndJob(cancelled, jobState: .cancelled)
            activeRuns[jobID] = nil; activeProviders[jobID] = nil
        } else if let job = try await jobs.job(id: jobID), !job.state.isTerminal {
            try await jobs.complete(jobID, state: .cancelled)
        }
    }

    public func cancel(reviewID: ReviewID) async throws {
        for jobID in activeRuns.compactMap({ $0.value.reviewID == reviewID ? $0.key : nil }) {
            try await cancel(jobID: jobID)
        }
    }

    public func history(reviewID: ReviewID) async throws -> TourHistorySnapshot {
        let runs = try await persistence.runs(reviewID: reviewID)
        if let revision = runs.first?.revision {
            return try await history(reviewID: reviewID, revision: revision)
        }
        let records = try await persistence.tourRecords(reviewID: reviewID)
        guard let revision = records.first?.revision else { throw TourIntegrationError.noSelectedTour }
        return try await history(reviewID: reviewID, revision: revision)
    }

    public func history(reviewID: ReviewID, revision: RevisionIdentity) async throws -> TourHistorySnapshot {
        let state = try await reviewState(for: revision)
        let pack = try contextBuilder.build(manifest: state.manifest)
        let source = ManifestTourArtifactSource(manifest: state.manifest)
        var tours: [ValidatedTourDocument] = []
        for record in try await persistence.tourRecords(reviewID: reviewID) {
            tours.append(
                try await boundary.replay(record, against: revision, expectedInputDigest: pack.digest, anchors: source))
        }
        let selectedID = try await persistence.selectedTourID(reviewID: reviewID)
        let selected = selectedID.flatMap { id in tours.first { $0.id == id } }
        let rating: TourRatingRecord? =
            if let selected {
                try await persistence.rating(reviewID: reviewID, tourID: selected.id)
            } else { nil }
        return TourHistorySnapshot(
            selectedTour: selected, tours: tours, runs: try await persistence.runs(reviewID: reviewID),
            attachments: try await persistence.attachments(reviewID: reviewID), rating: rating,
            reviewState: state)
    }

    public func select(reviewID: ReviewID, revision: RevisionIdentity, tourID: UUID) async throws {
        try ensureWritable(try await reviewState(for: revision))
        _ = try await history(reviewID: reviewID, revision: revision)
        try await persistence.select(reviewID: reviewID, tourID: tourID)
    }

    public func rate(reviewID: ReviewID, revision: RevisionIdentity, tourID: UUID, rating: TourRating) async throws {
        try ensureWritable(try await reviewState(for: revision))
        _ = try await history(reviewID: reviewID, revision: revision)
        try await persistence.saveRating(.init(reviewID: reviewID, tourID: tourID, rating: rating, ratedAt: Date()))
    }

    public func validateNavigation(_ anchor: ReviewAnchor) async throws {
        let state = try await reviewState(for: anchor.revision)
        guard state.objectExists,
            try await ManifestTourArtifactSource(manifest: state.manifest).validate(anchor)
        else {
            throw TourIntegrationError.invalidPayload
        }
    }

    private func enqueueGeneration(
        reviewID: ReviewID, revision: RevisionIdentity,
        configuration: LocalTourConfiguration, state: TourReviewState
    ) async throws -> TourGenerationRequestRecord {
        guard reviewID == revision.reviewID, state.manifest.revision == revision else {
            throw TourIntegrationError.revisionMismatch
        }
        _ = try configuration.limits.validated()
        let pack = try contextBuilder.build(manifest: state.manifest)
        struct Identity: Encodable {
            let revision: RevisionIdentity; let contextDigest: SHA256Digest
            let kind: ModelAdapterKind; let endpoint: String; let model: String
            let limits: StoredModelLimits
        }
        let endpoint = configuration.endpoint.url.absoluteString
        let key = try RTCCanonicalJSON.digest(
            Identity(
                revision: revision, contextDigest: pack.digest, kind: configuration.kind,
                endpoint: endpoint, model: configuration.model.value,
                limits: StoredModelLimits(configuration.limits)))
        let request = TourGenerationRequestRecord(
            requestKey: key, jobID: deterministicUUID(key, label: "job"),
            runID: deterministicUUID(key, label: "run"), revision: revision,
            contextDigest: pack.digest, provider: configuration.metadata,
            modelKind: configuration.kind, endpoint: endpoint, model: configuration.model.value,
            limits: StoredModelLimits(configuration.limits), createdAt: Date())
        try await persistence.saveGenerationRequest(request)
        try await jobs.enqueue(
            JobRecord(
                id: request.jobID, kind: .tourGeneration, reviewID: reviewID,
                state: .queued, attempt: 0, availableAt: request.createdAt))
        if try await persistence.run(id: request.runID) == nil {
            try await persistence.saveRun(
                TourRunRecord(
                    id: request.runID, jobID: request.jobID, reviewID: reviewID, revision: revision,
                    provider: request.provider, contextDigest: pack.digest,
                    contextOmissions: pack.omissions,
                    diagramIntents: SignalAnalyzer().intents(SignalAnalyzer().analyze(pack)),
                    state: .queued, progress: .init(phase: "queued", fraction: 0),
                    createdAt: request.createdAt, requestKey: key))
        }
        return request
    }

    private func process(
        _ job: JobRecord, lease: JobLease,
        progress: @escaping @Sendable (TourProgressSnapshot) async -> Void
    ) async throws -> TourRunRecord {
        guard job.kind == .tourGeneration,
            let request = try await persistence.generationRequest(jobID: job.id),
            request.jobID == job.id, request.revision.reviewID == job.reviewID
        else {
            try await jobs.complete(job.id, state: .failed); throw TourIntegrationError.invalidJob
        }
        try await checkpoint(.leased)
        let state = try await reviewState(for: request.revision)
        do { try ensureWritable(state) } catch {
            let existing = try await persistence.run(id: request.runID)
            let failed = (existing ?? baseRun(request, pack: nil, attempt: job.attempt)).updating(
                state: .failed, progress: .init(phase: "read-only", fraction: 1),
                completedAt: Date(), failureCode: .staleRevision, attempt: job.attempt)
            try await persistence.finalizeRunAndJob(failed, jobState: .failed); return failed
        }
        let pack = try contextBuilder.build(manifest: state.manifest)
        guard pack.digest == request.contextDigest else { throw TourIntegrationError.revisionMismatch }
        if state.manifest.files.isEmpty {
            let run = baseRun(request, pack: pack, attempt: job.attempt).updating(
                state: .noChanges, progress: .init(phase: "no changes", fraction: 1), completedAt: Date())
            try await persistence.finalizeRunAndJob(run, jobState: .succeeded); return run
        }
        let source = ManifestTourArtifactSource(manifest: state.manifest)
        let intents = SignalAnalyzer().intents(SignalAnalyzer().analyze(pack))
        let configuration = try request.configuration()
        let provider = LoopbackTourProvider(
            configuration: configuration, context: pack, intents: intents,
            transport: transport, credentials: credentials)
        let started = Date()
        var run = TourRunRecord(
            id: request.runID, jobID: job.id, reviewID: job.reviewID, revision: request.revision,
            provider: request.provider, contextDigest: pack.digest, contextOmissions: pack.omissions,
            diagramIntents: intents, state: .running,
            progress: .init(phase: "building context", fraction: 0.1),
            createdAt: (try await persistence.run(id: request.runID))?.createdAt ?? started,
            requestKey: request.requestKey, attempt: job.attempt,
            providerAttempts: [.init(provider: request.provider, startedAt: started)])
        activeProviders[job.id] = provider; activeRuns[job.id] = run
        try await persistence.saveRun(run); await progress(run.progress)
        try await serviceGate.enter()
        let renewal = Task { [jobs] in
            while !Task.isCancelled {
                try await Task.sleep(for: .seconds(10))
                _ = try await jobs.renew(lease, now: Date())
            }
        }
        defer { renewal.cancel(); Task { await self.serviceGate.leave() } }
        do {
            let raw = try await provider.generatePayload(
                request: TourGenerationRequest(revision: request.revision, contextDigest: pack.digest)
            ) { value in
                await self.recordProgress(jobID: job.id, progress: value, sink: progress)
            }
            try await checkpoint(.modelResponse)
            guard !cancellationWasRequested(for: job.id) else { throw CancellationError() }
            if progressPersistenceFailures.contains(job.id) { throw TourIntegrationError.persistenceFailed }
            let validated = try await boundary.validate(
                rawPayload: raw, against: request.revision, expectedInputDigest: pack.digest,
                anchors: source, provenance: .init(provider: request.provider))
            try await checkpoint(.validated)
            guard !cancellationWasRequested(for: job.id) else { throw CancellationError() }
            let issues = logicIssues(document: validated.document, intents: intents)
            guard issues.isEmpty else {
                return try await fallback(
                    run: run, job: job, pack: pack, source: source,
                    reason: "provider output omitted a material diagram decision", issues: issues)
            }
            let attempts = [TourProviderAttempt(provider: request.provider, startedAt: started, completedAt: Date())]
            run = run.updating(
                state: .succeeded, progress: .init(phase: "ready", fraction: 1),
                completedAt: Date(), tourID: validated.id, providerAttempts: attempts)
            try await persistence.publishValidatedTour(validated, attachment: nil, finishing: run, jobState: .succeeded)
            try await checkpoint(.published)
            try await checkpoint(.completed)
            cleanup(job.id); return run
        } catch is CancellationError {
            return try await cancelled(run, jobID: job.id)
        } catch let crash as TourGenerationInjectedCrash {
            cleanup(job.id); throw crash
        } catch let error as TourIntegrationError where error == .persistenceFailed {
            cleanup(job.id); throw error
        } catch {
            if cancellationWasRequested(for: job.id) { return try await cancelled(run, jobID: job.id) }
            return try await fallback(
                run: run, job: job, pack: pack, source: source,
                reason: safeProviderFailure(error), issues: [])
        }
    }

    private func fallback(
        run: TourRunRecord, job: JobRecord, pack: ContextPack,
        source: ManifestTourArtifactSource, reason: String,
        issues: [TourValidationIssue]
    ) async throws -> TourRunRecord {
        if cancellationWasRequested(for: job.id) { return try await cancelled(run, jobID: job.id) }
        let failedAttempt = TourProviderAttempt(
            provider: run.provider, startedAt: run.providerAttempts.first?.startedAt ?? run.createdAt,
            completedAt: Date(), failureReason: reason)
        do {
            let fallbackDocument = try await FallbackTourProvider(source: source).generate(
                request: TourGenerationRequest(revision: run.revision, contextDigest: pack.digest)
            ) { value in
                await self.recordProgress(jobID: job.id, progress: value) { _ in }
            }
            let raw = try RTCCanonicalJSON.encode(fallbackDocument)
            let validated = try await boundary.validate(
                rawPayload: raw, against: run.revision, expectedInputDigest: pack.digest,
                anchors: source, provenance: .init(provider: .fallback))
            if cancellationWasRequested(for: job.id) { return try await cancelled(run, jobID: job.id) }
            let fallbackAttempt = TourProviderAttempt(
                provider: .fallback, startedAt: Date(), completedAt: Date())
            let completed = run.updating(
                state: .fallback, progress: .init(phase: "fallback ready", fraction: 1),
                completedAt: Date(), tourID: validated.id, fallbackReason: reason,
                validationIssues: issues, provider: .fallback,
                providerAttempts: [failedAttempt, fallbackAttempt])
            try await persistence.publishValidatedTour(
                validated, attachment: nil, finishing: completed, jobState: .succeeded)
            cleanup(job.id); return completed
        } catch {
            if cancellationWasRequested(for: job.id) { return try await cancelled(run, jobID: job.id) }
            let failed = run.updating(
                state: .failed, progress: .init(phase: "failed", fraction: 1),
                completedAt: Date(), fallbackReason: reason, failureCode: .tourRejected,
                validationIssues: issues, providerAttempts: [failedAttempt])
            try await persistence.finalizeRunAndJob(failed, jobState: .failed)
            cleanup(job.id); return failed
        }
    }

    private func rejectAttachment(
        document: TourDocument, rawPayload: Data, provider: TourProviderMetadata,
        candidateDigest: SHA256Digest, pack: ContextPack, intents: [DiagramIntent],
        code: RTCErrorCode, issues: [TourValidationIssue], now: Date
    ) async throws -> TourRunRecord {
        let runID = deterministicUUID(candidateDigest, label: "worker-run")
        let run = TourRunRecord(
            id: runID, jobID: nil, reviewID: document.revision.reviewID,
            revision: document.revision, provider: provider, contextDigest: pack.digest,
            contextOmissions: pack.omissions, diagramIntents: intents, state: .rejected,
            progress: .init(phase: "rejected", fraction: 1), createdAt: now,
            completedAt: now, failureCode: code, validationIssues: issues,
            providerAttempts: [
                .init(
                    provider: provider, startedAt: now, completedAt: now,
                    failureReason: "structured tour rejected")
            ])
        let attachment = TourAttachmentRecord(
            id: deterministicUUID(candidateDigest, label: "attachment"),
            reviewID: document.revision.reviewID, receivedAt: now, provider: provider,
            candidateDigest: candidateDigest, state: .rejected, tourID: nil,
            validationIssues: issues, runID: runID, failureCode: code,
            contextDigest: pack.digest, contextOmissions: pack.omissions, diagramIntents: intents)
        try await persistence.saveAttachment(attachment, run: run)
        return run
    }

    private func cancelled(_ run: TourRunRecord, jobID: UUID) async throws -> TourRunRecord {
        let result = run.updating(
            state: .cancelled,
            progress: .init(phase: "cancelled", fraction: run.progress.fraction),
            completedAt: Date(), failureCode: .internalError)
        try await persistence.finalizeRunAndJob(result, jobState: .cancelled)
        cleanup(jobID); return result
    }

    private func recordProgress(
        jobID: UUID, progress: TourProgress,
        sink: @escaping @Sendable (TourProgressSnapshot) async -> Void
    ) async {
        guard let current = activeRuns[jobID], !cancelledJobs.contains(jobID) else { return }
        let updated = current.updating(
            state: .running,
            progress: .init(phase: progress.phase.value, fraction: progress.fraction))
        activeRuns[jobID] = updated
        do { try await persistence.saveRun(updated); await sink(updated.progress) } catch {
            progressPersistenceFailures.insert(jobID)
            await activeProviders[jobID]?.cancel()
        }
    }

    private func recordNoChanges(reviewID: ReviewID, revision: RevisionIdentity) async throws -> TourRunRecord {
        let digest = SHA256Digest(data: Data("no-changes\0\(reviewID.value)".utf8)), now = Date()
        let run = TourRunRecord(
            id: deterministicUUID(digest, label: "no-changes"), jobID: nil,
            reviewID: reviewID, revision: revision, provider: .fallback,
            contextDigest: digest, state: .noChanges,
            progress: .init(phase: "no changes", fraction: 1), createdAt: now, completedAt: now)
        try await persistence.saveRun(run); return run
    }

    private func baseRun(
        _ request: TourGenerationRequestRecord, pack: ContextPack?, attempt: Int
    ) -> TourRunRecord {
        TourRunRecord(
            id: request.runID, jobID: request.jobID, reviewID: request.revision.reviewID,
            revision: request.revision, provider: request.provider,
            contextDigest: pack?.digest ?? request.contextDigest,
            contextOmissions: pack?.omissions ?? [], state: .running,
            progress: .init(phase: "resuming", fraction: 0), createdAt: request.createdAt,
            requestKey: request.requestKey, attempt: attempt)
    }

    private func reviewState(for revision: RevisionIdentity) async throws -> TourReviewState {
        let state: TourReviewState
        if let reviewStateSource {
            state = try await reviewStateSource.state(for: revision)
        } else {
            state = TourReviewState(manifest: try await artifacts.manifest(for: revision))
        }
        guard state.manifest.revision == revision, state.manifest.id == revision.reviewID else {
            throw TourIntegrationError.revisionMismatch
        }
        return state
    }

    private func ensureWritable(_ state: TourReviewState) throws {
        guard state.isWritable else { throw TourIntegrationError.readOnlyReview }
    }

    private func cleanup(_ jobID: UUID) {
        activeProviders[jobID] = nil; activeRuns[jobID] = nil
        cancelledJobs.remove(jobID); progressPersistenceFailures.remove(jobID)
    }

    private func cancellationWasRequested(for jobID: UUID) -> Bool {
        Task.isCancelled || cancelledJobs.contains(jobID)
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
                if case .diagram(let diagram) = block { return diagram.kind }; return nil
            })
        return intents.filter { $0.material && !diagramKinds.contains($0.kind) }.map {
            TourValidationIssue(
                code: .insufficientGrounding, location: "diagramIntent.\($0.kind.rawValue)",
                message: "material change signal has no grounded diagram")
        }
    }
}

private extension TourRunState {
    var isTerminal: Bool {
        [.succeeded, .fallback, .noChanges, .failed, .cancelled, .rejected].contains(self)
    }
}

private extension JobState {
    var isTerminal: Bool { [.succeeded, .failed, .cancelled].contains(self) }
}

private func deterministicUUID(_ digest: SHA256Digest, label: String) -> UUID {
    let hex = SHA256Digest(data: Data((digest.hex + "\0" + label).utf8)).hex
    let value =
        "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-4\(hex.dropFirst(13).prefix(3))-a\(hex.dropFirst(17).prefix(3))-\(hex.dropFirst(20).prefix(12))"
    return UUID(uuidString: value)!
}
