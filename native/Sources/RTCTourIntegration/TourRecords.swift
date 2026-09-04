import Foundation
import RTCContracts
import RTCModelAdapters
import RTCTour

public enum TourRunState: String, Codable, Equatable, Sendable {
    case queued, running, succeeded, fallback, noChanges, failed, cancelled, rejected
}

public enum TourProviderKind: String, Codable, Equatable, Sendable {
    case workerSupplied, ollama, openAICompatible, deterministicFallback
}

public struct TourProviderMetadata: Codable, Equatable, Sendable {
    public let kind: TourProviderKind
    public let displayName: String
    public let endpoint: String?
    public let model: String?
    public let workerIdentity: String?
    public let generatorVersion: String?

    public init(
        kind: TourProviderKind, displayName: String, endpoint: String? = nil,
        model: String? = nil, workerIdentity: String? = nil,
        generatorVersion: String? = nil
    ) {
        self.kind = kind
        self.displayName = displayName
        self.endpoint = endpoint
        self.model = model
        self.workerIdentity = workerIdentity
        self.generatorVersion = generatorVersion
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(TourProviderKind.self, forKey: .kind)
        let displayName = try c.decode(String.self, forKey: .displayName)
        let endpoint = try c.decodeIfPresent(String.self, forKey: .endpoint)
        let model = try c.decodeIfPresent(String.self, forKey: .model)
        let workerIdentity = try c.decodeIfPresent(String.self, forKey: .workerIdentity)
        let generatorVersion = try c.decodeIfPresent(String.self, forKey: .generatorVersion)
        guard !displayName.isEmpty, displayName.count <= 160,
            (endpoint?.count ?? 0) <= 256, (model?.count ?? 0) <= RTCConstants.maxLabelCharacters,
            (workerIdentity?.count ?? 0) <= 160, (generatorVersion?.count ?? 0) <= 80
        else {
            throw TourIntegrationError.invalidPayload
        }
        self.init(
            kind: kind, displayName: displayName, endpoint: endpoint, model: model,
            workerIdentity: workerIdentity, generatorVersion: generatorVersion)
    }

    public static let fallback = TourProviderMetadata(
        kind: .deterministicFallback,
        displayName: "Generated outline unavailable"
    )
}

public struct TourProviderAttempt: Codable, Equatable, Sendable {
    public let provider: TourProviderMetadata
    public let startedAt: Date
    public let completedAt: Date?
    public let failureReason: String?
    public init(
        provider: TourProviderMetadata, startedAt: Date, completedAt: Date? = nil,
        failureReason: String? = nil
    ) {
        self.provider = provider; self.startedAt = startedAt; self.completedAt = completedAt
        self.failureReason = failureReason.map { String($0.prefix(240)) }
    }
}

public struct TourDocumentProvenance: Codable, Equatable, Sendable {
    public let provider: TourProviderMetadata
    public init(provider: TourProviderMetadata) { self.provider = provider }
}

public struct PersistedTourRecord: Codable, Equatable, Sendable {
    public let rawPayload: Data
    public let payloadDigest: SHA256Digest
    public let integrityDigest: SHA256Digest
    public let revision: RevisionIdentity
    public let contextDigest: SHA256Digest
    public let provenance: TourDocumentProvenance

    init(
        rawPayload: Data, revision: RevisionIdentity, contextDigest: SHA256Digest,
        provenance: TourDocumentProvenance
    ) throws {
        self.rawPayload = rawPayload
        payloadDigest = SHA256Digest(data: rawPayload)
        self.revision = revision
        self.contextDigest = contextDigest
        self.provenance = provenance
        integrityDigest = SHA256Digest(
            data: rawPayload + (try RTCCanonicalJSON.encode(revision))
                + Data(contextDigest.hex.utf8) + (try RTCCanonicalJSON.encode(provenance)))
    }

    public func verifyIntegrity() throws {
        let rebuilt = try PersistedTourRecord(
            rawPayload: rawPayload, revision: revision, contextDigest: contextDigest,
            provenance: provenance)
        guard rebuilt.payloadDigest == payloadDigest, rebuilt.integrityDigest == integrityDigest else {
            throw TourIntegrationError.invalidPayload
        }
    }
}

/// The only renderable/persistable tour value. Its initializer is module-private and
/// is reached only through `TourValidationBoundary`.
public struct ValidatedTourDocument: Sendable {
    let document: TourDocument
    public let rawPayload: Data
    public let payloadDigest: SHA256Digest
    public let provenance: TourDocumentProvenance

    init(document: TourDocument, rawPayload: Data, provenance: TourDocumentProvenance) {
        self.document = document; self.rawPayload = rawPayload
        payloadDigest = SHA256Digest(data: rawPayload); self.provenance = provenance
    }

    public var id: UUID { document.id }
    public var revision: RevisionIdentity { document.revision }
    public var producer: TourProducer { document.producer }
    public var inputDigest: SHA256Digest { document.inputDigest }
    public var title: BoundedString { document.title }
    public var overview: [TourBlock] { document.overview }
    public var reviewFocuses: [ReviewFocus] { document.reviewFocuses }
    public var chapters: [TourChapter] { document.chapters }
    public var risks: [ReviewFocus] { document.risks }
}

public struct WorkerTourAttribution: Codable, Equatable, Sendable {
    public let identityLabel: BoundedString
    public let generatorName: BoundedString?
    public let generatorVersion: BoundedString?
    public init(
        identityLabel: BoundedString = "Worker", generatorName: BoundedString? = nil,
        generatorVersion: BoundedString? = nil
    ) {
        self.identityLabel = identityLabel; self.generatorName = generatorName
        self.generatorVersion = generatorVersion
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let identity = try c.decode(BoundedString.self, forKey: .identityLabel)
        let name = try c.decodeIfPresent(BoundedString.self, forKey: .generatorName)
        let version = try c.decodeIfPresent(BoundedString.self, forKey: .generatorVersion)
        guard !identity.value.isEmpty, identity.value.count <= 160,
            (name?.value.count ?? 0) <= 160, (version?.value.count ?? 0) <= 80
        else {
            throw TourIntegrationError.invalidPayload
        }
        self.init(identityLabel: identity, generatorName: name, generatorVersion: version)
    }

    var metadata: TourProviderMetadata {
        let identity =
            (try? BoundedString(identityLabel.value, maxCharacters: 160))?.value ?? "Worker"
        let name = generatorName.flatMap {
            try? BoundedString($0.value, maxCharacters: 160)
        }?.value
        let version = generatorVersion.flatMap {
            try? BoundedString($0.value, maxCharacters: 80)
        }?.value
        return TourProviderMetadata(
            kind: .workerSupplied,
            displayName: name ?? "Worker-supplied tour",
            workerIdentity: identity,
            generatorVersion: version)
    }
}

public struct WorkerTourEnvelope: Codable, Sendable {
    public let schemaVersion: Int
    public let document: TourDocument
    public let attribution: WorkerTourAttribution
    public init(document: TourDocument, attribution: WorkerTourAttribution) {
        schemaVersion = RTCConstants.schemaVersion; self.document = document; self.attribution = attribution
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard try c.decode(Int.self, forKey: .schemaVersion) == RTCConstants.schemaVersion else {
            throw TourIntegrationError.invalidPayload
        }
        schemaVersion = RTCConstants.schemaVersion
        document = try c.decode(TourDocument.self, forKey: .document)
        attribution = try c.decode(WorkerTourAttribution.self, forKey: .attribution)
    }
}

public struct LocalTourConfiguration: Sendable {
    public let kind: ModelAdapterKind
    public let endpoint: LoopbackEndpoint
    public let model: BoundedString
    public let credentialKey: String
    public let limits: ModelLimits

    public init(
        kind: ModelAdapterKind, endpoint: LoopbackEndpoint, model: BoundedString,
        credentialKey: String = "openai-compatible", limits: ModelLimits = .init()
    ) throws {
        guard
            !model.value.isEmpty,
            (try? BoundedString(model.value, maxCharacters: RTCConstants.maxLabelCharacters)) != nil,
            !credentialKey.isEmpty, credentialKey.utf8.count <= 256,
            (try? BoundedString(credentialKey, maxCharacters: 256)) != nil
        else { throw ModelAdapterError.unsupportedSchema }
        self.kind = kind
        self.endpoint = endpoint
        self.model = model
        self.credentialKey = credentialKey
        self.limits = limits
    }

    public var metadata: TourProviderMetadata {
        let host = endpoint.url.host == "::1" ? "[::1]" : (endpoint.url.host ?? "127.0.0.1")
        let origin = "http://\(host):\(endpoint.url.port ?? 0)"
        return TourProviderMetadata(
            kind: kind == .ollama ? .ollama : .openAICompatible,
            displayName: kind == .ollama ? "Ollama" : "OpenAI-compatible local model",
            endpoint: origin,
            model: model.value
        )
    }
}

public struct StoredModelLimits: Codable, Equatable, Sendable {
    public let timeoutSeconds: Double
    public let maxResponseBytes: Int
    public let maxRequestBytes: Int
    public let maxConcurrentRequests: Int
    public let maxChunks: Int
    public let maxLineBytes: Int
    public let maxEvents: Int
    public let maxJSONDepth: Int
    public let maxJSONItems: Int

    public init(_ limits: ModelLimits) {
        let components = limits.timeout.components
        timeoutSeconds =
            Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
        maxResponseBytes = limits.maxResponseBytes; maxRequestBytes = limits.maxRequestBytes
        maxConcurrentRequests = limits.maxConcurrentRequests; maxChunks = limits.maxChunks
        maxLineBytes = limits.maxLineBytes; maxEvents = limits.maxEvents
        maxJSONDepth = limits.maxJSONDepth; maxJSONItems = limits.maxJSONItems
    }

    public func modelLimits() -> ModelLimits {
        ModelLimits(
            timeout: .seconds(timeoutSeconds), maxResponseBytes: maxResponseBytes,
            maxRequestBytes: maxRequestBytes, maxConcurrentRequests: maxConcurrentRequests,
            maxChunks: maxChunks, maxLineBytes: maxLineBytes, maxEvents: maxEvents,
            maxJSONDepth: maxJSONDepth, maxJSONItems: maxJSONItems)
    }
}

public struct TourGenerationRequestRecord: Codable, Equatable, Sendable {
    public let requestKey: SHA256Digest
    public let jobID: UUID
    public let runID: UUID
    public let revision: RevisionIdentity
    public let contextDigest: SHA256Digest
    public let provider: TourProviderMetadata
    public let modelKind: ModelAdapterKind
    public let endpoint: String
    public let model: String
    public let limits: StoredModelLimits
    public let createdAt: Date

    public func configuration() throws -> LocalTourConfiguration {
        guard let url = URL(string: endpoint) else { throw TourIntegrationError.invalidPayload }
        return try LocalTourConfiguration(
            kind: modelKind, endpoint: LoopbackEndpoint(url),
            model: BoundedString(model, maxCharacters: RTCConstants.maxLabelCharacters),
            limits: limits.modelLimits())
    }
}

public struct TourReviewState: Sendable {
    public let manifest: ReviewManifest
    public let objectExists: Bool
    public let symbolicHeadMatches: Bool
    public init(manifest: ReviewManifest, objectExists: Bool = true, symbolicHeadMatches: Bool? = nil) {
        self.manifest = manifest; self.objectExists = objectExists
        self.symbolicHeadMatches = symbolicHeadMatches ?? !manifest.stale
    }
    public var readOnlyReason: String? {
        guard objectExists else { return "The exact committed revision is unavailable." }
        guard symbolicHeadMatches, !manifest.stale else {
            return "The review branch moved; this exact revision is read-only."
        }
        guard ![.approved, .closed, .failed, .superseded].contains(manifest.status) else {
            return "This review is terminal and read-only."
        }
        return nil
    }
    public var isWritable: Bool { readOnlyReason == nil }
}

public protocol TourReviewStateSource: Sendable {
    func state(for revision: RevisionIdentity) async throws -> TourReviewState
}

public struct TourRunRecord: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let jobID: UUID?
    public let reviewID: ReviewID
    public let revision: RevisionIdentity
    public let provider: TourProviderMetadata
    public let contextDigest: SHA256Digest
    public let contextOmissions: [ContextOmission]
    public let diagramIntents: [DiagramIntent]
    public let state: TourRunState
    public let progress: TourProgressSnapshot
    public let createdAt: Date
    public let completedAt: Date?
    public let tourID: UUID?
    public let fallbackReason: String?
    public let failureCode: RTCErrorCode?
    public let validationIssues: [TourValidationIssue]
    public let requestKey: SHA256Digest?
    public let attempt: Int
    public let providerAttempts: [TourProviderAttempt]

    public init(
        id: UUID, jobID: UUID?, reviewID: ReviewID, revision: RevisionIdentity,
        provider: TourProviderMetadata, contextDigest: SHA256Digest,
        contextOmissions: [ContextOmission] = [], diagramIntents: [DiagramIntent] = [],
        state: TourRunState, progress: TourProgressSnapshot,
        createdAt: Date, completedAt: Date? = nil, tourID: UUID? = nil,
        fallbackReason: String? = nil, failureCode: RTCErrorCode? = nil,
        validationIssues: [TourValidationIssue] = [], requestKey: SHA256Digest? = nil,
        attempt: Int = 0, providerAttempts: [TourProviderAttempt] = []
    ) {
        self.id = id; self.jobID = jobID; self.reviewID = reviewID; self.revision = revision
        self.provider = provider; self.contextDigest = contextDigest; self.state = state
        self.contextOmissions = contextOmissions; self.diagramIntents = diagramIntents
        self.progress = progress; self.createdAt = createdAt; self.completedAt = completedAt
        self.tourID = tourID; self.fallbackReason = fallbackReason
        self.failureCode = failureCode; self.validationIssues = validationIssues
        self.requestKey = requestKey; self.attempt = attempt
        self.providerAttempts = Array(providerAttempts.prefix(8))
    }

    public func updating(
        state: TourRunState, progress: TourProgressSnapshot? = nil,
        completedAt: Date? = nil, tourID: UUID? = nil,
        fallbackReason: String? = nil, failureCode: RTCErrorCode? = nil,
        validationIssues: [TourValidationIssue]? = nil,
        provider: TourProviderMetadata? = nil,
        providerAttempts: [TourProviderAttempt]? = nil,
        attempt: Int? = nil
    ) -> TourRunRecord {
        TourRunRecord(
            id: id, jobID: jobID, reviewID: reviewID, revision: revision,
            provider: provider ?? self.provider, contextDigest: contextDigest,
            contextOmissions: contextOmissions, diagramIntents: diagramIntents,
            state: state, progress: progress ?? self.progress, createdAt: createdAt,
            completedAt: completedAt ?? self.completedAt, tourID: tourID ?? self.tourID,
            fallbackReason: fallbackReason ?? self.fallbackReason,
            failureCode: failureCode ?? self.failureCode,
            validationIssues: validationIssues ?? self.validationIssues,
            requestKey: requestKey, attempt: attempt ?? self.attempt,
            providerAttempts: providerAttempts ?? self.providerAttempts)
    }
}

public struct TourProgressSnapshot: Codable, Equatable, Sendable {
    public let phase: String
    public let fraction: Double
    public init(phase: String, fraction: Double) {
        self.phase = phase
        self.fraction = min(1, max(0, fraction.isFinite ? fraction : 0))
    }
}

public enum TourAttachmentState: String, Codable, Equatable, Sendable {
    case accepted, rejected
}

public struct TourAttachmentRecord: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let reviewID: ReviewID
    public let receivedAt: Date
    public let provider: TourProviderMetadata
    public let candidateDigest: SHA256Digest
    public let state: TourAttachmentState
    public let tourID: UUID?
    public let validationIssues: [TourValidationIssue]
    public let runID: UUID
    public let failureCode: RTCErrorCode?
    public let contextDigest: SHA256Digest
    public let contextOmissions: [ContextOmission]
    public let diagramIntents: [DiagramIntent]

    public init(
        id: UUID, reviewID: ReviewID, receivedAt: Date,
        provider: TourProviderMetadata, candidateDigest: SHA256Digest,
        state: TourAttachmentState, tourID: UUID?,
        validationIssues: [TourValidationIssue], runID: UUID? = nil,
        failureCode: RTCErrorCode? = nil,
        contextDigest: SHA256Digest? = nil,
        contextOmissions: [ContextOmission] = [], diagramIntents: [DiagramIntent] = []
    ) {
        self.id = id; self.reviewID = reviewID; self.receivedAt = receivedAt
        self.provider = provider; self.candidateDigest = candidateDigest; self.state = state
        self.tourID = tourID; self.validationIssues = validationIssues
        self.runID = runID ?? id; self.failureCode = failureCode
        self.contextDigest = contextDigest ?? SHA256Digest(data: Data())
        self.contextOmissions = contextOmissions; self.diagramIntents = diagramIntents
    }
}

public enum TourRating: String, Codable, Equatable, Sendable { case helpful, notHelpful }

public struct TourRatingRecord: Codable, Equatable, Sendable {
    public let reviewID: ReviewID
    public let tourID: UUID
    public let rating: TourRating
    public let ratedAt: Date
    public init(reviewID: ReviewID, tourID: UUID, rating: TourRating, ratedAt: Date) {
        self.reviewID = reviewID; self.tourID = tourID; self.rating = rating; self.ratedAt = ratedAt
    }
}

public struct TourHistorySnapshot: Sendable {
    public let selectedTour: ValidatedTourDocument?
    public let tours: [ValidatedTourDocument]
    public let runs: [TourRunRecord]
    public let attachments: [TourAttachmentRecord]
    public let rating: TourRatingRecord?
    public let reviewState: TourReviewState
    public init(
        selectedTour: ValidatedTourDocument?, tours: [ValidatedTourDocument], runs: [TourRunRecord],
        attachments: [TourAttachmentRecord], rating: TourRatingRecord?, reviewState: TourReviewState
    ) {
        self.selectedTour = selectedTour; self.tours = tours; self.runs = runs
        self.attachments = attachments; self.rating = rating; self.reviewState = reviewState
    }
}

public enum TourIntegrationError: Error, Equatable, Sendable {
    case revisionMismatch
    case invalidJob
    case tourIDConflict
    case noSelectedTour
    case invalidPayload
    case readOnlyReview
    case persistenceFailed
}
