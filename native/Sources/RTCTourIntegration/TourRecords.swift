import Foundation
import RTCContracts
import RTCModelAdapters
import RTCTour

public enum TourRunState: String, Codable, Equatable, Sendable {
    case queued, running, succeeded, fallback, failed, cancelled, rejected
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

    public static let fallback = TourProviderMetadata(
        kind: .deterministicFallback,
        displayName: "Generated outline unavailable"
    )
}

public struct ValidatedTourDocument: Sendable {
    public let document: TourDocument
    init(_ document: TourDocument) { self.document = document }
}

public struct WorkerTourAttribution: Sendable {
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

    public init(
        id: UUID, jobID: UUID?, reviewID: ReviewID, revision: RevisionIdentity,
        provider: TourProviderMetadata, contextDigest: SHA256Digest,
        contextOmissions: [ContextOmission] = [], diagramIntents: [DiagramIntent] = [],
        state: TourRunState, progress: TourProgressSnapshot,
        createdAt: Date, completedAt: Date? = nil, tourID: UUID? = nil,
        fallbackReason: String? = nil, failureCode: RTCErrorCode? = nil,
        validationIssues: [TourValidationIssue] = []
    ) {
        self.id = id; self.jobID = jobID; self.reviewID = reviewID; self.revision = revision
        self.provider = provider; self.contextDigest = contextDigest; self.state = state
        self.contextOmissions = contextOmissions; self.diagramIntents = diagramIntents
        self.progress = progress; self.createdAt = createdAt; self.completedAt = completedAt
        self.tourID = tourID; self.fallbackReason = fallbackReason
        self.failureCode = failureCode; self.validationIssues = validationIssues
    }

    public func updating(
        state: TourRunState, progress: TourProgressSnapshot? = nil,
        completedAt: Date? = nil, tourID: UUID? = nil,
        fallbackReason: String? = nil, failureCode: RTCErrorCode? = nil,
        validationIssues: [TourValidationIssue]? = nil,
        provider: TourProviderMetadata? = nil
    ) -> TourRunRecord {
        TourRunRecord(
            id: id, jobID: jobID, reviewID: reviewID, revision: revision,
            provider: provider ?? self.provider, contextDigest: contextDigest,
            contextOmissions: contextOmissions, diagramIntents: diagramIntents,
            state: state, progress: progress ?? self.progress, createdAt: createdAt,
            completedAt: completedAt ?? self.completedAt, tourID: tourID ?? self.tourID,
            fallbackReason: fallbackReason ?? self.fallbackReason,
            failureCode: failureCode ?? self.failureCode,
            validationIssues: validationIssues ?? self.validationIssues)
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

    public init(
        id: UUID, reviewID: ReviewID, receivedAt: Date,
        provider: TourProviderMetadata, candidateDigest: SHA256Digest,
        state: TourAttachmentState, tourID: UUID?,
        validationIssues: [TourValidationIssue]
    ) {
        self.id = id; self.reviewID = reviewID; self.receivedAt = receivedAt
        self.provider = provider; self.candidateDigest = candidateDigest; self.state = state
        self.tourID = tourID; self.validationIssues = validationIssues
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
    public let selectedTour: TourDocument?
    public let tours: [TourDocument]
    public let runs: [TourRunRecord]
    public let attachments: [TourAttachmentRecord]
    public let rating: TourRatingRecord?
    public init(
        selectedTour: TourDocument?, tours: [TourDocument], runs: [TourRunRecord],
        attachments: [TourAttachmentRecord], rating: TourRatingRecord?
    ) {
        self.selectedTour = selectedTour; self.tours = tours; self.runs = runs
        self.attachments = attachments; self.rating = rating
    }
}

public enum TourIntegrationError: Error, Equatable, Sendable {
    case revisionMismatch
    case invalidJob
    case tourIDConflict
    case noSelectedTour
    case invalidPayload
}
