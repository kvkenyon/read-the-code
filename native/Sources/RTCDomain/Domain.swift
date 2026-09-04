import Foundation
import RTCContracts

public enum RTCDomainError: Error, Equatable, Sendable {
    case staleRevision
    case staleAnchor
    case invalidAnchor
    case invalidTransition
    case readOnly
}

public struct ReviewRevisionState: Equatable, Sendable {
    public let revision: RevisionIdentity
    public private(set) var status: ReviewStatus
    public private(set) var stale: Bool

    public init(revision: RevisionIdentity, status: ReviewStatus = .ready, stale: Bool = false) {
        self.revision = revision; self.status = status; self.stale = stale
    }

    public mutating func markHead(_ headSHA: String) {
        stale = stale || headSHA.lowercased() != revision.headSHA
    }

    public mutating func transition(to next: ReviewStatus) throws {
        guard !stale || next == .superseded else { throw RTCDomainError.staleRevision }
        let legal: [ReviewStatus: Set<ReviewStatus>] = [
            .accepted: [.materializing, .failed], .materializing: [.ready, .failed],
            .ready: [.inReview, .closed], .inReview: [.waitingOnWorker, .approved, .changesRequested, .closed],
            .waitingOnWorker: [.inReview, .closed], .approved: [.superseded],
            .changesRequested: [.superseded], .failed: [.materializing], .closed: [], .superseded: []
        ]
        guard legal[status, default: []].contains(next) else { throw RTCDomainError.invalidTransition }
        status = next
    }
}

public struct AnchorValidation: Equatable, Sendable {
    public let anchor: ReviewAnchor
    public let resolved: Bool
    public let reason: RTCDomainError?
    public init(anchor: ReviewAnchor, resolved: Bool, reason: RTCDomainError? = nil) {
        self.anchor = anchor; self.resolved = resolved; self.reason = reason
    }
}

public struct ReviewAnchorResolver: Sendable {
    private let source: any AnchorArtifactSource
    public init(source: any AnchorArtifactSource) { self.source = source }

    public func resolve(_ anchor: ReviewAnchor, for revision: RevisionIdentity) async throws -> AnchorValidation {
        guard anchor.revision == revision else { return AnchorValidation(anchor: anchor, resolved: false, reason: .staleRevision) }
        guard Self.isStructurallyValid(anchor) else { return AnchorValidation(anchor: anchor, resolved: false, reason: .invalidAnchor) }
        let valid = try await source.validate(anchor)
        return AnchorValidation(anchor: anchor, resolved: valid, reason: valid ? nil : .staleAnchor)
    }

    public static func isStructurallyValid(_ anchor: ReviewAnchor) -> Bool {
        if anchor.path.isEmpty || anchor.path.hasPrefix("/") || anchor.path.split(separator: "/").contains("..") { return false }
        if anchor.scope == .line && anchor.side == nil { return false }
        if let start = anchor.startLine, start < 1 { return false }
        if let end = anchor.endLine, end < 1 || (anchor.startLine != nil && end < anchor.startLine!) { return false }
        if anchor.scope == .general || anchor.scope == .file { return anchor.startLine == nil && anchor.endLine == nil }
        return anchor.startLine != nil && anchor.endLine != nil
    }
}

public struct ReviewMutationGuard: Sendable {
    public let revision: RevisionIdentity
    public init(revision: RevisionIdentity) { self.revision = revision }
    public func check(_ candidate: RevisionIdentity) throws {
        guard candidate == revision else { throw RTCDomainError.staleRevision }
    }
}
