import CoreFoundation
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
        guard state != .resolved, message.sequence == messages.count + 1 else { throw RTCDomainError.invalidTransition }
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

public struct ReviewDecision: Codable, Hashable, Sendable {
    public let kind: ReviewEventKind, revision: RevisionIdentity, headSHA: String, warnings: [String]
    public init(kind: ReviewEventKind, revision: RevisionIdentity, warnings: [String] = []) { self.kind=kind; self.revision=revision; self.headSHA=revision.headSHA; self.warnings=warnings }
}

public enum ReviewStateError: Error, Equatable, Sendable { case corrupt(String), concurrentModification }

public struct ReviewSnapshot: Equatable, Sendable {
    public let revision: RevisionIdentity
    public let threads: [ReviewThread]
    public let progress: [FileProgress]
    public let status: ReviewStatus
    public let stale: Bool
    public let verificationAvailable: Bool
    public let cursor: Int
    public let requestChangesSummary: RichText?
    public var isMutable: Bool { verificationAvailable && !stale && [.ready, .inReview].contains(status) }
    public var viewedCount: Int { progress.filter(\.viewed).count }
}

private protocol StrictReviewPayload: Codable {
    static func validateJSON(_ value: Any) throws
}

private struct ThreadCreatedPayload: StrictReviewPayload {
    let thread: ReviewThread
    static func validateJSON(_ value: Any) throws {
        let object = try ReviewJSONShape.object(value, required: ["thread"])
        try ReviewJSONShape.thread(object["thread"])
    }
}
private struct ThreadMessageAddedPayload: StrictReviewPayload {
    let threadID: UUID, message: ThreadMessage
    static func validateJSON(_ value: Any) throws {
        let object = try ReviewJSONShape.object(value, required: ["message", "threadID"])
        try ReviewJSONShape.uuid(object["threadID"])
        try ReviewJSONShape.message(object["message"])
    }
}
private struct FileProgressPayload: StrictReviewPayload {
    let progress: FileProgress
    static func validateJSON(_ value: Any) throws {
        let object = try ReviewJSONShape.object(value, required: ["progress"])
        try ReviewJSONShape.progress(object["progress"])
    }
}
private struct ThreadIDsPayload: StrictReviewPayload {
    let threadIDs: [UUID]
    static func validateJSON(_ value: Any) throws {
        let object = try ReviewJSONShape.object(value, required: ["threadIDs"])
        _ = try ReviewJSONShape.threadIDs(object["threadIDs"])
    }
}
private struct RequestChangesPayload: StrictReviewPayload {
    let threadIDs: [UUID], summary: RichText?
    static func validateJSON(_ value: Any) throws {
        let object = try ReviewJSONShape.object(value, required: ["threadIDs"], optional: ["summary"])
        _ = try ReviewJSONShape.threadIDs(object["threadIDs"])
        if let summary = object["summary"] { try ReviewJSONShape.body(summary) }
    }
}
private struct ApprovalPayload: StrictReviewPayload {
    let warnings: [String]
    static func validateJSON(_ value: Any) throws {
        let object = try ReviewJSONShape.object(value, required: ["warnings"])
        let warnings = try ReviewJSONShape.stringArray(object["warnings"], maximum: RTCConstants.maxFiles + 1)
        guard warnings == warnings.sorted(), Set(warnings).count == warnings.count,
              warnings.allSatisfy(ReviewJSONShape.isApprovalWarning) else { throw ReviewJSONShape.invalid }
    }
}
private struct ThreadIDPayload: StrictReviewPayload {
    let threadID: UUID
    static func validateJSON(_ value: Any) throws {
        let object = try ReviewJSONShape.object(value, required: ["threadID"])
        try ReviewJSONShape.uuid(object["threadID"])
    }
}
private struct EmptyPayload: StrictReviewPayload {
    static func validateJSON(_ value: Any) throws { _ = try ReviewJSONShape.object(value, required: []) }
}

private enum ReviewJSONShape {
    static let invalid = ReviewStateError.corrupt("invalid payload schema")

    static func object(_ value: Any?, required: Set<String>, optional: Set<String> = []) throws -> [String: Any] {
        guard let object = value as? [String: Any] else { throw invalid }
        let keys = Set(object.keys)
        guard required.isSubset(of: keys), keys.isSubset(of: required.union(optional)) else { throw invalid }
        return object
    }

    static func string(_ value: Any?, maximumBytes: Int? = nil) throws -> String {
        guard let value = value as? String, maximumBytes.map({ value.utf8.count <= $0 }) ?? true else { throw invalid }
        return value
    }

    static func integer(_ value: Any?) throws -> Int {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
              number.doubleValue >= Double(Int.min), number.doubleValue <= Double(Int.max) else { throw invalid }
        return number.intValue
    }

    static func boolean(_ value: Any?) throws -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw invalid }
        return number.boolValue
    }

    static func uuid(_ value: Any?) throws {
        guard UUID(uuidString: try string(value)) != nil else { throw invalid }
    }

    static func revision(_ value: Any?) throws {
        let object = try object(value, required: ["baseSHA", "headSHA", "repositoryPath"])
        let base = try string(object["baseSHA"]), head = try string(object["headSHA"])
        let path = try string(object["repositoryPath"], maximumBytes: RTCConstants.maxPathBytes)
        guard !path.isEmpty, path.hasPrefix("/"), [base, head].allSatisfy({ $0.count == 40 && $0.allSatisfy(\.isHexDigit) }) else { throw invalid }
    }

    static func reviewID(_ value: Any?) throws {
        let object = try object(value, required: ["value"])
        let id = try string(object["value"])
        guard id.count == 24, id.allSatisfy(\.isHexDigit) else { throw invalid }
    }

    static func relativePath(_ value: Any?) throws -> String {
        let path = try string(value, maximumBytes: RTCConstants.maxPathBytes)
        guard !path.isEmpty, !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { throw invalid }
        return path
    }

    static func anchor(_ value: Any?) throws {
        let object = try object(
            value,
            required: ["path", "revision", "scope"],
            optional: ["oldPath", "side", "startLine", "endLine", "startContextHash", "endContextHash", "hunkIndex", "symbol"]
        )
        try revision(object["revision"])
        _ = try relativePath(object["path"])
        if let oldPath = object["oldPath"] { _ = try relativePath(oldPath) }
        let scope = try string(object["scope"])
        guard AnchorScope(rawValue: scope) != nil else { throw invalid }
        let side = try object["side"].map { try string($0) }
        guard side.map({ AnchorSide(rawValue: $0) != nil }) ?? true else { throw invalid }
        let start = try object["startLine"].map { try integer($0) }
        let end = try object["endLine"].map { try integer($0) }
        if let hash = object["startContextHash"] { try digest(hash) }
        if let hash = object["endContextHash"] { try digest(hash) }
        if let hunk = object["hunkIndex"] { guard try integer(hunk) >= 0 else { throw invalid } }
        if let symbol = object["symbol"] { _ = try boundedString(symbol) }
        guard scope == AnchorScope.line.rawValue, side != nil, let start, let end, start > 0, end >= start,
              object["startContextHash"] != nil, object["endContextHash"] != nil,
              object["hunkIndex"] == nil, object["symbol"] == nil else { throw invalid }
    }

    static func digest(_ value: Any?) throws {
        let value = try string(value)
        guard value.count == 64, value.allSatisfy(\.isHexDigit) else { throw invalid }
    }

    static func boundedString(_ value: Any?) throws -> String {
        let value = try string(value)
        guard value.count <= 4_096,
              value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && $0.value != 0 }) else { throw invalid }
        return value
    }

    static func body(_ value: Any?) throws {
        let object = try object(value, required: ["runs"])
        guard let runs = object["runs"] as? [Any], runs.count <= 256 else { throw invalid }
        var bytes = 0
        for value in runs {
            let run = try Self.object(value, required: ["kind", "text"])
            guard RichTextRunKind(rawValue: try string(run["kind"])) != nil else { throw invalid }
            bytes += try boundedString(run["text"]).utf8.count
            guard bytes <= RTCConstants.maxCommentBytes else { throw invalid }
        }
    }

    static func message(_ value: Any?) throws {
        let object = try object(value, required: ["author", "body", "createdAt", "id", "sequence"])
        guard ReviewAuthorRole(rawValue: try string(object["author"])) != nil, try integer(object["sequence"]) > 0 else { throw invalid }
        try body(object["body"]); try uuid(object["id"])
        guard ISO8601DateFormatter().date(from: try string(object["createdAt"])) != nil else { throw invalid }
    }

    static func thread(_ value: Any?) throws {
        let object = try object(
            value,
            required: ["anchor", "id", "messages", "reviewID", "revision", "state"],
            optional: ["promotedConversationID", "promotedMessageID"]
        )
        try anchor(object["anchor"]); try uuid(object["id"]); try reviewID(object["reviewID"]); try revision(object["revision"])
        guard ThreadState(rawValue: try string(object["state"])) != nil,
              let messages = object["messages"] as? [Any], messages.count <= 256 else { throw invalid }
        var messageIDs = Set<String>()
        for (index, messageValue) in messages.enumerated() {
            try message(messageValue)
            let message = try Self.object(messageValue, required: ["author", "body", "createdAt", "id", "sequence"])
            let id = try string(message["id"])
            guard try integer(message["sequence"]) == index + 1, messageIDs.insert(id.lowercased()).inserted else { throw invalid }
        }
        if let id = object["promotedConversationID"] { try uuid(id) }
        if let id = object["promotedMessageID"] { try uuid(id) }
    }

    static func progress(_ value: Any?) throws {
        let object = try object(value, required: ["path", "version", "viewed"])
        _ = try relativePath(object["path"])
        guard try integer(object["version"]) > 0 else { throw invalid }
        _ = try boolean(object["viewed"])
    }

    static func threadIDs(_ value: Any?) throws -> [String] {
        let ids = try stringArray(value, maximum: RTCConstants.maxAnchors)
        guard ids.allSatisfy({ UUID(uuidString: $0) != nil }), ids == ids.sorted(), Set(ids.map { $0.lowercased() }).count == ids.count else { throw invalid }
        return ids
    }

    static func stringArray(_ value: Any?, maximum: Int) throws -> [String] {
        guard let values = value as? [Any], values.count <= maximum else { throw invalid }
        return try values.map { try string($0, maximumBytes: RTCConstants.maxPathBytes) }
    }

    static func isApprovalWarning(_ warning: String) -> Bool {
        if warning == ThreadState.draft.rawValue || warning == ThreadState.open.rawValue { return true }
        guard warning.hasPrefix("unviewedFiles:"), let count = Int(warning.dropFirst("unviewedFiles:".count)) else { return false }
        return count > 0 && count <= RTCConstants.maxFiles
    }
}

private enum ReviewPayloadCodec {
    static func encode<T: Encodable>(_ value: T) throws -> [String: String] {
        let data = try RTCCanonicalJSON.encode(value)
        guard data.count <= RTCConstants.maxRequestBytes, let string = String(data: data, encoding: .utf8) else { throw RTCContractError.invalid("review event payload") }
        return ["version": "1", "data": string]
    }

    static func decode<T: StrictReviewPayload>(_ type: T.Type, from payload: [String: String]) throws -> T {
        guard payload.count == 2, payload["version"] == "1", let string = payload["data"],
              let data = string.data(using: .utf8), data.count <= RTCConstants.maxRequestBytes else { throw ReviewStateError.corrupt("invalid payload envelope") }
        do {
            let object = try JSONSerialization.jsonObject(with: data, options: [])
            let canonical = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
            guard canonical == data else { throw ReviewJSONShape.invalid }
            try T.validateJSON(object)
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(type, from: data)
        } catch let error as ReviewStateError { throw error }
        catch { throw ReviewStateError.corrupt("invalid payload") }
    }
}

/// Pure replay projection over one immutable manifest. It never reads source
/// files; anchors are checked against committed diff artifacts in the manifest.
public struct ReviewReducer: Sendable {
    private let manifest: ReviewManifest
    private let artifacts: [String: DiffArtifact]
    fileprivate(set) var revisionState: ReviewRevisionState
    fileprivate(set) var threads: [UUID: ReviewThread] = [:]
    fileprivate(set) var progress: [String: FileProgress]
    fileprivate(set) var cursor = 0
    fileprivate(set) var eventIDs: Set<UUID> = []
    private(set) var requestChangesSummary: RichText?

    public init(manifest: ReviewManifest) throws {
        guard manifest.schemaVersion == RTCConstants.schemaVersion, manifest.id == manifest.revision.reviewID else { throw ReviewStateError.corrupt("manifest identity") }
        let grouped = Dictionary(grouping: manifest.files, by: \.path)
        guard grouped.values.allSatisfy({ $0.count == 1 }), manifest.files.count <= RTCConstants.maxFiles else { throw ReviewStateError.corrupt("duplicate or excessive files") }
        self.manifest = manifest
        artifacts = Dictionary(uniqueKeysWithValues: manifest.files.map { ($0.path, $0) })
        revisionState = ReviewRevisionState(revision: manifest.revision, status: manifest.status, stale: manifest.stale)
        progress = Dictionary(uniqueKeysWithValues: manifest.files.map { ($0.path, FileProgress(path: $0.path)) })
    }

    public var snapshot: ReviewSnapshot { snapshot(verificationAvailable: true) }
    public func snapshot(verificationAvailable: Bool) -> ReviewSnapshot {
        ReviewSnapshot(revision: manifest.revision, threads: threads.values.sorted { $0.id.uuidString < $1.id.uuidString }, progress: progress.values.sorted { $0.path < $1.path }, status: revisionState.status, stale: revisionState.stale, verificationAvailable: verificationAvailable, cursor: cursor, requestChangesSummary: requestChangesSummary)
    }
    public mutating func markHead(_ headSHA: String) { revisionState.markHead(headSHA) }
    public mutating func replay(_ events: [ReviewEvent]) throws { for event in events { try apply(event) } }

    public mutating func apply(_ event: ReviewEvent) throws {
        guard event.reviewID == manifest.id, event.revision == manifest.revision else { throw ReviewStateError.corrupt("event scope") }
        guard event.sequence == cursor + 1, !eventIDs.contains(event.id) else { throw ReviewStateError.corrupt("event sequence") }
        var candidate = self
        try candidate.reduce(event)
        candidate.cursor = event.sequence
        candidate.eventIDs.insert(event.id)
        self = candidate
    }

    public func validateAnchor(_ anchor: ReviewAnchor) throws {
        guard anchor.revision == manifest.revision, ReviewAnchorResolver.isStructurallyValid(anchor), anchor.scope == .line,
              anchor.path.utf8.count <= RTCConstants.maxPathBytes, let artifact = artifacts[anchor.path], anchor.oldPath == artifact.oldPath,
              let start = anchor.startLine, let end = anchor.endLine, let side = anchor.side else { throw ReviewStateError.corrupt("anchor identity") }
        let lines = artifact.hunks.flatMap(\.lines).filter { line in
            let number = side == .new ? line.newLine : line.oldLine
            return number.map { start...end ~= $0 } ?? false
        }
        guard let first = lines.first, let last = lines.last, anchor.startContextHash == first.contextHash, anchor.endContextHash == last.contextHash else { throw ReviewStateError.corrupt("anchor evidence") }
    }

    private mutating func reduce(_ event: ReviewEvent) throws {
        switch event.kind {
        case .threadCreated:
            let payload = try ReviewPayloadCodec.decode(ThreadCreatedPayload.self, from: event.payload)
            let thread = payload.thread
            guard thread.id == event.id, thread.reviewID == manifest.id, thread.revision == manifest.revision,
                  thread.state == .draft, thread.messages.count == 1, thread.messages[0].id == event.id,
                  thread.messages[0].sequence == 1, thread.messages[0].author == .captain,
                  (thread.promotedConversationID == nil) == (thread.promotedMessageID == nil),
                  threads[thread.id] == nil else { throw ReviewStateError.corrupt("thread creation") }
            try validateBody(thread.messages[0].body); try validateAnchor(thread.anchor); threads[thread.id] = thread
        case .threadMessageAdded:
            let payload = try ReviewPayloadCodec.decode(ThreadMessageAddedPayload.self, from: event.payload)
            guard var thread = threads[payload.threadID], thread.state == .open, payload.message.id == event.id,
                  payload.message.sequence == thread.messages.count + 1, payload.message.author == .captain,
                  !threads.values.flatMap(\.messages).contains(where: { $0.id == payload.message.id }) else { throw ReviewStateError.corrupt("thread message") }
            try validateBody(payload.message.body); try thread.append(payload.message); threads[thread.id] = thread
        case .fileProgressChanged:
            let payload = try ReviewPayloadCodec.decode(FileProgressPayload.self, from: event.payload)
            guard let current = progress[payload.progress.path], payload.progress.version == current.version + 1 else { throw ReviewStateError.corrupt("file progress") }
            progress[payload.progress.path] = payload.progress
        case .feedback:
            let payload = try ReviewPayloadCodec.decode(ThreadIDsPayload.self, from: event.payload)
            try openDrafts(payload.threadIDs, allowEmpty: false)
            if revisionState.status == .ready { try revisionState.transition(to: .inReview) }
            guard revisionState.status == .inReview else { throw ReviewStateError.corrupt("feedback status") }
        case .changesRequested:
            let payload = try ReviewPayloadCodec.decode(RequestChangesPayload.self, from: event.payload)
            guard !payload.threadIDs.isEmpty || payload.summary != nil else { throw ReviewStateError.corrupt("empty request changes") }
            if let summary = payload.summary { try validateBody(summary) }
            try openDrafts(payload.threadIDs, allowEmpty: true)
            if revisionState.status == .ready { try revisionState.transition(to: .inReview) }
            try revisionState.transition(to: .changesRequested); requestChangesSummary = payload.summary
        case .approval:
            let payload = try ReviewPayloadCodec.decode(ApprovalPayload.self, from: event.payload)
            var expectedWarnings = Set(threads.values.filter { $0.state == .draft || $0.state == .open }.map { $0.state.rawValue })
            let unviewed = progress.values.filter { !$0.viewed }.count
            if unviewed > 0 { expectedWarnings.insert("unviewedFiles:\(unviewed)") }
            guard payload.warnings == expectedWarnings.sorted() else { throw ReviewStateError.corrupt("approval warnings") }
            if revisionState.status == .ready { try revisionState.transition(to: .inReview) }
            try revisionState.transition(to: .approved)
        case .close:
            _ = try ReviewPayloadCodec.decode(EmptyPayload.self, from: event.payload)
            try revisionState.transition(to: .closed)
        case .threadResolved:
            let payload = try ReviewPayloadCodec.decode(ThreadIDPayload.self, from: event.payload)
            guard var thread = threads[payload.threadID] else { throw ReviewStateError.corrupt("unknown thread") }
            try thread.resolve(); threads[thread.id] = thread
        case .threadReopened:
            let payload = try ReviewPayloadCodec.decode(ThreadIDPayload.self, from: event.payload)
            guard var thread = threads[payload.threadID] else { throw ReviewStateError.corrupt("unknown thread") }
            try thread.reopen(); threads[thread.id] = thread
        }
    }

    private mutating func openDrafts(_ ids: [UUID], allowEmpty: Bool) throws {
        let sorted = ids.sorted { $0.uuidString < $1.uuidString }
        guard ids == sorted, Set(ids).count == ids.count, allowEmpty || !ids.isEmpty else { throw ReviewStateError.corrupt("thread id ordering") }
        for id in ids {
            guard var thread = threads[id], thread.state == .draft else { throw ReviewStateError.corrupt("thread submission") }
            try thread.markOpen(); threads[id] = thread
        }
    }

    private func validateBody(_ body: RichText) throws {
        guard body.runs.count <= 256,
              body.runs.allSatisfy({ $0.text.value.count <= 4_096 && $0.text.value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) && $0.value != 0 } }),
              body.runs.reduce(0, { $0 + $1.text.value.utf8.count }) <= RTCConstants.maxCommentBytes else { throw ReviewStateError.corrupt("comment bounds") }
    }
}

public protocol ReviewMutationPreflight: Sendable { func currentHead(for revision: RevisionIdentity) async throws -> String }
public struct FixedReviewMutationPreflight: ReviewMutationPreflight {
    private let headSHA: String
    public init(headSHA: String) { self.headSHA = headSHA }
    public func currentHead(for revision: RevisionIdentity) async throws -> String { headSHA }
}

public actor MemoryReviewEventRepository: EventRepository {
    private var eventsByReview: [ReviewID: [ReviewEvent]] = [:]
    public init() {}
    public func append(_ proposal: PendingReviewEvent, after expectedSequence: Int) async throws -> ReviewEvent {
        if let stored = eventsByReview.values.flatMap({ $0 }).first(where: { $0.id == proposal.id }) {
            guard stored.reviewID == proposal.reviewID, stored.revision == proposal.revision, stored.kind == proposal.kind, stored.payload == proposal.payload, stored.createdAt == proposal.createdAt else { throw EventRepositoryError.idempotencyConflict }
            return stored
        }
        let current = eventsByReview[proposal.reviewID, default: []].count
        guard current == expectedSequence else { throw EventRepositoryError.concurrentModification }
        let event = ReviewEvent(id: proposal.id, reviewID: proposal.reviewID, revision: proposal.revision, sequence: current + 1, kind: proposal.kind, payload: proposal.payload, createdAt: proposal.createdAt)
        eventsByReview[proposal.reviewID, default: []].append(event)
        return event
    }
    public func events(after sequence: Int, reviewID: ReviewID) async throws -> [ReviewEvent] { eventsByReview[reviewID, default: []].filter { $0.sequence > sequence } }
}

public enum ReviewDeliveryPolicy {
    public static func isWorkerVisible(_ event: ReviewEvent) -> Bool {
        switch event.kind {
        case .feedback, .changesRequested, .approval, .close, .threadMessageAdded, .threadResolved, .threadReopened: true
        case .threadCreated, .fileProgressChanged: false
        }
    }
}

public actor ReviewCommandHandler {
    public let reviewID: ReviewID
    private let repository: any EventRepository
    private let resolver: ReviewAnchorResolver
    private let preflight: any ReviewMutationPreflight
    private var reducer: ReviewReducer
    private var verificationAvailable = true
    private var knownEvents: [UUID: ReviewEvent] = [:]
    private var proposals: [UUID: PendingReviewEvent] = [:]
    private var commandInProgress = false
    private var commandWaiters: [CheckedContinuation<Void, Never>] = []

    private init(manifest: ReviewManifest, repository: any EventRepository, anchors: any AnchorArtifactSource, mutationPreflight: any ReviewMutationPreflight) throws {
        reviewID = manifest.id; self.repository = repository; resolver = ReviewAnchorResolver(source: anchors); preflight = mutationPreflight; reducer = try ReviewReducer(manifest: manifest)
    }

    public static func open(manifest: ReviewManifest, repository: any EventRepository, anchors: any AnchorArtifactSource, mutationPreflight: any ReviewMutationPreflight) async throws -> ReviewCommandHandler {
        let handler = try ReviewCommandHandler(manifest: manifest, repository: repository, anchors: anchors, mutationPreflight: mutationPreflight)
        try await handler.hydrate(); return handler
    }

    public func snapshot() -> ReviewSnapshot { reducer.snapshot(verificationAvailable: verificationAvailable) }
    public var revisionState: ReviewRevisionState { reducer.revisionState }
    public func snapshotThreads() -> [ReviewThread] { snapshot().threads }
    public func snapshotProgress() -> [FileProgress] { snapshot().progress }
    public func viewedCount() -> Int { snapshot().viewedCount }
    public func anchorIssues() async -> [UUID: RTCDomainError] {
        var issues: [UUID: RTCDomainError] = [:]
        for thread in reducer.threads.values {
            do {
                let result=try await resolver.resolve(thread.anchor, for: reducer.revisionState.revision)
                if !result.resolved { issues[thread.id]=result.reason ?? .invalidAnchor }
            } catch { issues[thread.id] = .staleAnchor }
        }
        return issues
    }
    public func markHead(_ headSHA: String) { reducer.markHead(headSHA) }

    @discardableResult public func createDraft(anchor: ReviewAnchor, body: RichText, promotedFrom conversationID: UUID? = nil, messageID: UUID? = nil, operationID: UUID = UUID()) async throws -> UUID {
        let event = try await persist(kind: .threadCreated, operationID: operationID, existingMatches: { event in
            let stored=try ReviewPayloadCodec.decode(ThreadCreatedPayload.self, from: event.payload).thread
            return stored.anchor == anchor && stored.latestMessage?.body == body && stored.promotedConversationID == conversationID && stored.promotedMessageID == messageID
        }) {
            try reducer.validateAnchor(anchor); try validateBody(body)
            let message = ThreadMessage(id: operationID, sequence: 1, author: .captain, body: body)
            let thread = ReviewThread(id: operationID, reviewID: reviewID, revision: reducer.revisionState.revision, anchor: anchor, messages: [message], promotedConversationID: conversationID, promotedMessageID: messageID)
            return try ReviewPayloadCodec.encode(ThreadCreatedPayload(thread: thread))
        }
        return try ReviewPayloadCodec.decode(ThreadCreatedPayload.self, from: event.payload).thread.id
    }

    @discardableResult public func reply(threadID: UUID, body: RichText, operationID: UUID = UUID()) async throws -> ReviewEvent {
        try await persist(kind: .threadMessageAdded, operationID: operationID, existingMatches: { event in
            let stored=try ReviewPayloadCodec.decode(ThreadMessageAddedPayload.self, from: event.payload)
            return stored.threadID == threadID && stored.message.body == body
        }) {
            guard let thread = reducer.threads[threadID], thread.state == .open else { throw RTCDomainError.invalidTransition }
            try validateBody(body)
            let message = ThreadMessage(id: operationID, sequence: thread.messages.count + 1, author: .captain, body: body)
            return try ReviewPayloadCodec.encode(ThreadMessageAddedPayload(threadID: threadID, message: message))
        }
    }

    @discardableResult public func resolve(threadID: UUID, operationID: UUID = UUID()) async throws -> ReviewEvent {
        try await persist(kind: .threadResolved, operationID: operationID, existingMatches: { try ReviewPayloadCodec.decode(ThreadIDPayload.self, from: $0.payload).threadID == threadID }) {
            guard reducer.threads[threadID]?.state == .open else { throw RTCDomainError.invalidTransition }
            return try ReviewPayloadCodec.encode(ThreadIDPayload(threadID: threadID))
        }
    }

    @discardableResult public func reopen(threadID: UUID, operationID: UUID = UUID()) async throws -> ReviewEvent {
        try await persist(kind: .threadReopened, operationID: operationID, existingMatches: { try ReviewPayloadCodec.decode(ThreadIDPayload.self, from: $0.payload).threadID == threadID }) {
            guard reducer.threads[threadID]?.state == .resolved else { throw RTCDomainError.invalidTransition }
            return try ReviewPayloadCodec.encode(ThreadIDPayload(threadID: threadID))
        }
    }

    @discardableResult public func markViewed(path: String, viewed: Bool = true, expectedVersion: Int? = nil, operationID: UUID = UUID()) async throws -> ReviewEvent {
        try await persist(kind: .fileProgressChanged, operationID: operationID, existingMatches: { event in
            let stored=try ReviewPayloadCodec.decode(FileProgressPayload.self, from: event.payload).progress
            return stored.path == path && stored.viewed == viewed && expectedVersion.map { stored.version == $0 + 1 } ?? true
        }) {
            guard let current = reducer.progress[path] else { throw RTCDomainError.invalidTransition }
            return try ReviewPayloadCodec.encode(FileProgressPayload(progress: try current.updating(viewed: viewed, expectedVersion: expectedVersion)))
        }
    }

    public func sendReview(threadIDs: [UUID], operationID: UUID = UUID()) async throws -> ReviewEvent {
        try await persist(kind: .feedback, operationID: operationID, existingMatches: { try ReviewPayloadCodec.decode(ThreadIDsPayload.self, from: $0.payload).threadIDs == sortedUnique(threadIDs) }) {
            let ids = sortedUnique(threadIDs)
            guard ids.count == threadIDs.count, !ids.isEmpty else { throw RTCDomainError.invalidTransition }
            try await validateDraftAnchors(ids)
            return try ReviewPayloadCodec.encode(ThreadIDsPayload(threadIDs: ids))
        }
    }

    public func requestChanges(threadIDs: [UUID], summary: RichText? = nil, operationID: UUID = UUID()) async throws -> ReviewEvent {
        try await persist(kind: .changesRequested, operationID: operationID, existingMatches: { event in
            let stored=try ReviewPayloadCodec.decode(RequestChangesPayload.self, from: event.payload)
            return stored.threadIDs == sortedUnique(threadIDs) && stored.summary == summary
        }) {
            let ids = sortedUnique(threadIDs)
            guard ids.count == threadIDs.count, !ids.isEmpty || summary != nil else { throw RTCDomainError.invalidTransition }
            if let summary { try validateBody(summary) }; try await validateDraftAnchors(ids)
            return try ReviewPayloadCodec.encode(RequestChangesPayload(threadIDs: ids, summary: summary))
        }
    }

    public func approveExactRevision(operationID: UUID = UUID()) async throws -> ReviewEvent {
        try await persist(kind: .approval, operationID: operationID, existingMatches: { _ in true }) {
            var warnings = Set(reducer.threads.values.filter { $0.state == .draft || $0.state == .open }.map { $0.state.rawValue })
            let unviewed = reducer.progress.values.filter { !$0.viewed }.count
            if unviewed > 0 { warnings.insert("unviewedFiles:\(unviewed)") }
            return try ReviewPayloadCodec.encode(ApprovalPayload(warnings: warnings.sorted()))
        }
    }

    public func closeReview(operationID: UUID = UUID()) async throws -> ReviewEvent {
        try await persist(kind: .close, operationID: operationID, existingMatches: { _ in true }) { try ReviewPayloadCodec.encode(EmptyPayload()) }
    }

    private func hydrate() async throws {
        let events = try await repository.events(after: 0, reviewID: reviewID)
        do { try reducer.replay(events) } catch { throw ReviewStateError.corrupt("review replay: \(error)") }
        knownEvents = Dictionary(uniqueKeysWithValues: events.map { ($0.id, $0) })
    }

    private func refreshFromRepository() async throws {
        let events = try await repository.events(after: reducer.cursor, reviewID: reviewID)
        do { for event in events { try reducer.apply(event); knownEvents[event.id] = event } }
        catch { throw ReviewStateError.corrupt("review replay: \(error)") }
    }

    private func persist(kind: ReviewEventKind, operationID: UUID, existingMatches: (ReviewEvent) throws -> Bool, prepare: () async throws -> [String: String]) async throws -> ReviewEvent {
        await acquireCommandSlot()
        defer { releaseCommandSlot() }
        if let existing = knownEvents[operationID] {
            guard existing.kind == kind, try existingMatches(existing) else { throw EventRepositoryError.idempotencyConflict }
            return existing
        }
        for _ in 0..<8 {
            let proposal: PendingReviewEvent
            if let retained = proposals[operationID] {
                let candidate = ReviewEvent(id: retained.id, reviewID: retained.reviewID, revision: retained.revision, sequence: 0, kind: retained.kind, payload: retained.payload, createdAt: retained.createdAt)
                guard retained.kind == kind, retained.reviewID == reviewID,
                      retained.revision == reducer.revisionState.revision, try existingMatches(candidate) else { throw EventRepositoryError.idempotencyConflict }
                proposal = retained
            } else {
                try await guardMutable()
                proposal = PendingReviewEvent(
                    id: operationID,
                    reviewID: reviewID,
                    revision: reducer.revisionState.revision,
                    kind: kind,
                    payload: try await prepare(),
                    createdAt: Date()
                )
                proposals[operationID] = proposal
            }
            do {
                let stored = try await repository.append(proposal, after: reducer.cursor)
                guard stored.id == proposal.id, stored.reviewID == proposal.reviewID, stored.revision == proposal.revision, stored.kind == proposal.kind, stored.payload == proposal.payload, stored.createdAt == proposal.createdAt else { throw EventRepositoryError.idempotencyConflict }
                if stored.sequence == reducer.cursor + 1 { try reducer.apply(stored) }
                else if stored.sequence > reducer.cursor { try await refreshFromRepository() }
                guard reducer.eventIDs.contains(stored.id) else { throw ReviewStateError.corrupt("stored event missing from replay") }
                knownEvents[stored.id] = stored; proposals[operationID] = nil; return stored
            } catch EventRepositoryError.concurrentModification {
                // The repository definitively rejected this candidate. Discard it,
                // replay the winning tail, then prepare and validate a new candidate.
                proposals[operationID] = nil
                try await refreshFromRepository()
            }
        }
        throw ReviewStateError.concurrentModification
    }

    private func acquireCommandSlot() async {
        if !commandInProgress { commandInProgress=true; return }
        await withCheckedContinuation { commandWaiters.append($0) }
    }
    private func releaseCommandSlot() {
        if commandWaiters.isEmpty { commandInProgress=false }
        else { commandWaiters.removeFirst().resume() }
    }

    private func guardMutable() async throws {
        let head: String
        do { head = try await preflight.currentHead(for: reducer.revisionState.revision); verificationAvailable = true }
        catch { verificationAvailable = false; throw RTCDomainError.readOnly }
        reducer.markHead(head)
        guard !reducer.revisionState.stale else { throw RTCDomainError.staleRevision }
        guard snapshot().isMutable else { throw RTCDomainError.readOnly }
    }

    private func validateDraftAnchors(_ ids: [UUID]) async throws {
        for id in ids {
            guard let thread = reducer.threads[id], thread.state == .draft else { throw RTCDomainError.invalidTransition }
            let result = try await resolver.resolve(thread.anchor, for: reducer.revisionState.revision)
            guard result.resolved else { throw result.reason ?? RTCDomainError.invalidAnchor }
        }
    }
    private func sortedUnique(_ ids: [UUID]) -> [UUID] { Array(Set(ids)).sorted { $0.uuidString < $1.uuidString } }
    private func validateBody(_ body: RichText) throws {
        guard body.runs.count <= 256,
              body.runs.allSatisfy({ $0.text.value.count <= 4_096 && $0.text.value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) && $0.value != 0 } }),
              body.runs.reduce(0, { $0 + $1.text.value.utf8.count }) <= RTCConstants.maxCommentBytes else { throw RTCContractError.invalid("comment bytes") }
    }
}
