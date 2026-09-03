import Foundation
import RTCContracts
import RTCDomain

public enum ThreadState: String, Codable, Sendable { case draft, open, resolved }
public enum ReviewAuthorRole: String, Codable, Sendable { case captain, worker, system }

public struct ThreadMessage: Codable, Hashable, Sendable {
    public let id: UUID, sequence: Int, author: ReviewAuthorRole, body: RichText, createdAt: Date
    public init(id: UUID = UUID(), sequence: Int, author: ReviewAuthorRole, body: RichText, createdAt: Date = Date()) {
        self.id=id; self.sequence=sequence; self.author=author; self.body=body; self.createdAt=createdAt
    }
}

public struct ReviewThread: Codable, Hashable, Sendable {
    public let id: UUID, reviewID: ReviewID, revision: RevisionIdentity, anchor: ReviewAnchor
    public private(set) var state: ThreadState
    public private(set) var messages: [ThreadMessage]
    public let promotedConversationID: UUID?, promotedMessageID: UUID?
    public init(id: UUID = UUID(), reviewID: ReviewID, revision: RevisionIdentity, anchor: ReviewAnchor, state: ThreadState = .draft, messages: [ThreadMessage] = [], promotedConversationID: UUID? = nil, promotedMessageID: UUID? = nil) {
        self.id=id; self.reviewID=reviewID; self.revision=revision; self.anchor=anchor; self.state=state; self.messages=messages; self.promotedConversationID=promotedConversationID; self.promotedMessageID=promotedMessageID
    }
    public var latestMessage: ThreadMessage? { messages.last }
    public mutating func append(_ message: ThreadMessage) throws {
        guard state != .resolved else { throw RTCDomainError.invalidTransition }
        guard message.sequence == messages.count + 1 else { throw RTCDomainError.invalidTransition }
        messages.append(message)
    }
    public mutating func markOpen() throws { guard state == .draft, !messages.isEmpty else { throw RTCDomainError.invalidTransition }; state = .open }
    public mutating func resolve() throws { guard state == .open else { throw RTCDomainError.invalidTransition }; state = .resolved }
    public mutating func reopen() throws { guard state == .resolved else { throw RTCDomainError.invalidTransition }; state = .open }
}

public struct FileProgress: Codable, Hashable, Sendable {
    public let path: String
    public private(set) var viewed: Bool
    public let version: Int
    public init(path: String, viewed: Bool = false, version: Int = 0) { self.path=path; self.viewed=viewed; self.version=version }
    public func updating(viewed: Bool, expectedVersion: Int? = nil) throws -> FileProgress {
        if let expectedVersion, expectedVersion != version { throw RTCDomainError.invalidTransition }
        return FileProgress(path: path, viewed: viewed, version: version + 1)
    }
}

public struct ReviewFeedback: Codable, Hashable, Sendable {
    public let threadIDs: [UUID], revision: RevisionIdentity, summary: RichText?, createdAt: Date
    public init(threadIDs: [UUID], revision: RevisionIdentity, summary: RichText? = nil, createdAt: Date = Date()) { self.threadIDs=threadIDs; self.revision=revision; self.summary=summary; self.createdAt=createdAt }
}

public struct ReviewDecision: Codable, Hashable, Sendable {
    public let kind: ReviewEventKind, revision: RevisionIdentity, headSHA: String, warnings: [String]
    public init(kind: ReviewEventKind, revision: RevisionIdentity, warnings: [String] = []) { self.kind=kind; self.revision=revision; self.headSHA=revision.headSHA; self.warnings=warnings }
}

/// Domain event emitted by the reducer. The persistence layer can translate this
/// value to the frozen `ReviewEvent` envelope without giving the reducer storage
/// knowledge.
public struct ReviewDomainEvent: Codable, Hashable, Sendable {
    public let kind: ReviewEventKind, reviewID: ReviewID, revision: RevisionIdentity, sequence: Int, payload: [String: String]
    public init(kind: ReviewEventKind, reviewID: ReviewID, revision: RevisionIdentity, sequence: Int, payload: [String: String]) {
        self.kind=kind; self.reviewID=reviewID; self.revision=revision; self.sequence=sequence; self.payload=payload
    }
}

public actor ReviewCommandHandler {
    public private(set) var revisionState: ReviewRevisionState
    public let reviewID: ReviewID
    private let resolver: ReviewAnchorResolver
    private var threads: [UUID: ReviewThread] = [:]
    private var progress: [String: FileProgress] = [:]
    private var sequence = 0

    public init(reviewID: ReviewID, revision: RevisionIdentity, source: any AnchorArtifactSource, files: [String] = []) {
        self.reviewID=reviewID; self.revisionState=ReviewRevisionState(revision: revision); self.resolver=ReviewAnchorResolver(source: source)
        for file in files { progress[file] = FileProgress(path: file) }
    }
    public func snapshotThreads() -> [ReviewThread] { threads.values.sorted { $0.id.uuidString < $1.id.uuidString } }
    public func snapshotProgress() -> [FileProgress] { progress.values.sorted { $0.path < $1.path } }
    public func viewedCount() -> Int { progress.values.filter(\.viewed).count }

    public func markHead(_ headSHA: String) { revisionState.markHead(headSHA) }
    private func guardMutable() throws {
        guard !revisionState.stale else { throw RTCDomainError.staleRevision }
        guard ![.closed, .superseded, .approved, .changesRequested].contains(revisionState.status) else { throw RTCDomainError.readOnly }
    }
    private func validate(_ anchor: ReviewAnchor) async throws { let result = try await resolver.resolve(anchor, for: revisionState.revision); guard result.resolved else { throw result.reason ?? .invalidAnchor } }

    @discardableResult public func createDraft(anchor: ReviewAnchor, body: RichText, promotedFrom conversationID: UUID? = nil, messageID: UUID? = nil) async throws -> UUID {
        try guardMutable(); guard anchor.revision == revisionState.revision, anchor.revision.reviewID == reviewID else { throw RTCDomainError.staleRevision }
        guard ReviewAnchorResolver.isStructurallyValid(anchor) else { throw RTCDomainError.invalidAnchor }
        let id = UUID(); var thread = ReviewThread(id: id, reviewID: reviewID, revision: revisionState.revision, anchor: anchor, promotedConversationID: conversationID, promotedMessageID: messageID)
        try thread.append(ThreadMessage(sequence: 1, author: .captain, body: body)); threads[id] = thread; return id
    }
    public func reply(threadID: UUID, body: RichText) throws { try guardMutable(); guard var thread=threads[threadID] else { throw RTCDomainError.invalidTransition }; try thread.append(ThreadMessage(sequence: thread.messages.count + 1, author: .captain, body: body)); threads[threadID]=thread }
    public func resolve(threadID: UUID) throws -> ReviewDomainEvent { try guardMutable(); guard var thread=threads[threadID] else { throw RTCDomainError.invalidTransition }; try thread.resolve(); threads[threadID]=thread; return event(kind: .threadResolved, payload: ["threadID": threadID.uuidString]) }
    public func reopen(threadID: UUID) throws -> ReviewDomainEvent { try guardMutable(); guard var thread=threads[threadID] else { throw RTCDomainError.invalidTransition }; try thread.reopen(); threads[threadID]=thread; return event(kind: .threadReopened, payload: ["threadID": threadID.uuidString]) }

    public func markViewed(path: String, viewed: Bool = true, expectedVersion: Int? = nil) throws { try guardMutable(); guard let current=progress[path] else { throw RTCDomainError.invalidTransition }; progress[path]=try current.updating(viewed: viewed, expectedVersion: expectedVersion) }
    public func sendReview(threadIDs: [UUID]) async throws -> ReviewDomainEvent { try guardMutable(); let ids = Array(Set(threadIDs)); guard !ids.isEmpty else { throw RTCDomainError.invalidTransition }; for id in ids { guard var t=threads[id], t.state == .draft else { throw RTCDomainError.invalidTransition }; try await validate(t.anchor); try t.markOpen(); threads[id]=t }; if revisionState.status == .ready { try revisionState.transition(to: .inReview) }; return event(kind: .feedback, payload: ["threadIDs": ids.map(\.uuidString).joined(separator: ",")]) }
    public func requestChanges(threadIDs: [UUID], summary: RichText? = nil) async throws -> ReviewDomainEvent { try guardMutable(); guard !threadIDs.isEmpty || summary != nil else { throw RTCDomainError.invalidTransition }; let feedback = threadIDs.isEmpty ? nil : try await sendReview(threadIDs: threadIDs); if revisionState.status == .ready { try revisionState.transition(to: .inReview) }; try revisionState.transition(to: .changesRequested); return event(kind: .changesRequested, payload: (feedback?.payload ?? [:]).merging(["summary": summary == nil ? "" : "present"], uniquingKeysWith: { $1 })) }
    public func approveExactRevision() throws -> ReviewDecision { try guardMutable(); var warnings = threads.values.filter { $0.state == .draft || $0.state == .open }.map { $0.state.rawValue }; let unviewed = progress.values.filter { !$0.viewed }.count; if unviewed > 0 { warnings.append("unviewedFiles:\(unviewed)") }; if revisionState.status == .ready { try revisionState.transition(to: .inReview) }; try revisionState.transition(to: .approved); return ReviewDecision(kind: .approval, revision: revisionState.revision, warnings: warnings) }
    public func closeReview() throws -> ReviewDecision { try guardMutable(); try revisionState.transition(to: .closed); return ReviewDecision(kind: .close, revision: revisionState.revision) }
    private func event(kind: ReviewEventKind, payload: [String: String]) -> ReviewDomainEvent { sequence += 1; return ReviewDomainEvent(kind: kind, reviewID: reviewID, revision: revisionState.revision, sequence: sequence, payload: payload) }
}
