import Foundation
import CryptoKit

public enum RTCContractError: Error, Equatable, Sendable { case invalid(String) }

public enum RTCConstants {
    public static let schemaMajor = 2
    public static let schemaVersion = 2
    public static let maxChapters = 32, maxBlocks = 256, maxFocuses = 100
    public static let maxProseBytes = 64 * 1024, maxAnchors = 500, maxDiagrams = 12
    public static let maxNodes = 64, maxEdges = 128, maxLabelCharacters = 160
    public static let maxDocumentBytes = 1024 * 1024, maxFiles = 2_000
    public static let maxPatchBytesPerFile = 1_000_000, maxPatchBytesTotal = 8_000_000
    public static let maxCommentBytes = 20_000, maxRequestBytes = 128_000, maxPathBytes = 4_096
}

public struct BoundedString: Codable, Hashable, Sendable, ExpressibleByStringLiteral {
    public let value: String
    public init(stringLiteral value: String) { self.value = value }
    public init(_ value: String, maxCharacters: Int = 4_096) throws {
        guard value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && $0.value != 0 }), value.count <= maxCharacters else { throw RTCContractError.invalid("bounded string") }
        self.value = value
    }
    public init(from decoder: Decoder) throws { try self.init(String(from: decoder)) }
    public func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}

public struct SHA256Digest: Codable, Hashable, Sendable, ExpressibleByStringLiteral {
    public let hex: String
    public init(stringLiteral value: String) { self.hex = value }
    public init(_ hex: String) throws { guard hex.count == 64, hex.allSatisfy({ $0.isHexDigit }) else { throw RTCContractError.invalid("sha256") }; self.hex = hex.lowercased() }
    public init(data: Data) { hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    public init(from decoder: Decoder) throws { try self.init(String(from: decoder)) }
    public func encode(to encoder: Encoder) throws { try hex.encode(to: encoder) }
}

public struct RevisionIdentity: Codable, Hashable, Sendable {
    public let repositoryPath: String, baseSHA: String, headSHA: String
    public init(repositoryPath: String, baseSHA: String, headSHA: String) throws {
        guard !repositoryPath.isEmpty, [baseSHA, headSHA].allSatisfy({ $0.count == 40 && $0.allSatisfy(\.isHexDigit) }) else { throw RTCContractError.invalid("revision") }
        self.repositoryPath = URL(fileURLWithPath: repositoryPath).standardizedFileURL.path
        self.baseSHA = baseSHA.lowercased(); self.headSHA = headSHA.lowercased()
    }
    public var reviewID: ReviewID { ReviewID(identity: self) }
}

public struct ReviewID: Codable, Hashable, Sendable { public let value: String
    public init(identity: RevisionIdentity) { let bytes = Data((identity.repositoryPath + "\0" + identity.baseSHA + "\0" + identity.headSHA).utf8); value = SHA256Digest(data: bytes).hex.prefix(24).description }
    public init(_ value: String) throws { guard value.count == 24, value.allSatisfy(\.isHexDigit) else { throw RTCContractError.invalid("review id") }; self.value = value.lowercased() }
}

public enum AnchorScope: String, Codable, Sendable { case line, file, general, hunk, symbol }
public enum AnchorSide: String, Codable, Sendable { case old, new }
public struct ReviewAnchor: Codable, Hashable, Sendable {
    public let revision: RevisionIdentity, path: String, oldPath: String?, scope: AnchorScope, side: AnchorSide?
    public let startLine: Int?, endLine: Int?, startContextHash: SHA256Digest?, endContextHash: SHA256Digest?, hunkIndex: Int?, symbol: BoundedString?
    public init(revision: RevisionIdentity, path: String, oldPath: String? = nil, scope: AnchorScope, side: AnchorSide? = nil, startLine: Int? = nil, endLine: Int? = nil, startContextHash: SHA256Digest? = nil, endContextHash: SHA256Digest? = nil, hunkIndex: Int? = nil, symbol: BoundedString? = nil) throws {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.split(separator: "/").contains(".."), (startLine == nil && endLine == nil || startLine ?? 0 > 0 && endLine ?? 0 >= startLine ?? 0), scope == .line ? side != nil : true else { throw RTCContractError.invalid("anchor") }
        self.revision = revision; self.path = path; self.oldPath = oldPath; self.scope = scope; self.side = side; self.startLine = startLine; self.endLine = endLine; self.startContextHash = startContextHash; self.endContextHash = endContextHash; self.hunkIndex = hunkIndex; self.symbol = symbol
    }
}

public enum ChangeStatus: String, Codable, Sendable { case modified, added, deleted, renamed, binary }
public enum DiffLineKind: String, Codable, Sendable { case context, addition, deletion }
public enum ContextPosition: String, Codable, Sendable { case before, after }
public struct DiffLine: Codable, Hashable, Sendable { public let kind: DiffLineKind; public let oldLine: Int?, newLine: Int?, text: String, contextHash: SHA256Digest; public init(kind: DiffLineKind, oldLine: Int?, newLine: Int?, text: String, contextHash: SHA256Digest) { self.kind=kind; self.oldLine=oldLine; self.newLine=newLine; self.text=text; self.contextHash=contextHash } }
public struct DiffHunk: Codable, Hashable, Sendable { public let header: BoundedString; public let oldStart, oldLines, newStart, newLines: Int; public let lines: [DiffLine]; public init(header: BoundedString, oldStart: Int, oldLines: Int, newStart: Int, newLines: Int, lines: [DiffLine]) { self.header=header; self.oldStart=oldStart; self.oldLines=oldLines; self.newStart=newStart; self.newLines=newLines; self.lines=lines } }
public struct DiffArtifact: Codable, Hashable, Sendable { public let path: String, oldPath: String?, status: ChangeStatus, additions, deletions: Int, binary, truncated: Bool, oldLineCount, newLineCount: Int?, hunks: [DiffHunk]; public init(path: String, oldPath: String? = nil, status: ChangeStatus, additions: Int, deletions: Int, binary: Bool, truncated: Bool, oldLineCount: Int? = nil, newLineCount: Int? = nil, hunks: [DiffHunk]) { self.path=path; self.oldPath=oldPath; self.status=status; self.additions=additions; self.deletions=deletions; self.binary=binary; self.truncated=truncated; self.oldLineCount=oldLineCount; self.newLineCount=newLineCount; self.hunks=hunks } }
public struct ReviewSummary: Codable, Hashable, Sendable { public let files, additions, deletions: Int; public init(files: Int, additions: Int, deletions: Int) { self.files=files; self.additions=additions; self.deletions=deletions } }
public struct ReviewManifest: Codable, Hashable, Sendable { public let schemaVersion: Int, id: ReviewID, revision: RevisionIdentity, createdAt, updatedAt: Date, status: ReviewStatus, stale: Bool, summary: ReviewSummary, files: [DiffArtifact]; public init(schemaVersion: Int = 2, id: ReviewID, revision: RevisionIdentity, createdAt: Date, updatedAt: Date, status: ReviewStatus, stale: Bool, summary: ReviewSummary, files: [DiffArtifact]) { self.schemaVersion=schemaVersion; self.id=id; self.revision=revision; self.createdAt=createdAt; self.updatedAt=updatedAt; self.status=status; self.stale=stale; self.summary=summary; self.files=files }
    public init(from decoder: Decoder) throws { let c = try decoder.container(keyedBy: CodingKeys.self); guard try c.decode(Int.self, forKey: .schemaVersion) == RTCConstants.schemaVersion else { throw RTCContractError.invalid("unknown schema major") }; schemaVersion = RTCConstants.schemaVersion; id = try c.decode(ReviewID.self, forKey: .id); revision = try c.decode(RevisionIdentity.self, forKey: .revision); createdAt = try c.decode(Date.self, forKey: .createdAt); updatedAt = try c.decode(Date.self, forKey: .updatedAt); status = try c.decode(ReviewStatus.self, forKey: .status); stale = try c.decode(Bool.self, forKey: .stale); summary = try c.decode(ReviewSummary.self, forKey: .summary); files = try c.decode([DiffArtifact].self, forKey: .files) }
}
public enum ReviewStatus: String, Codable, Sendable { case accepted, materializing, ready, inReview, waitingOnWorker, approved, changesRequested, closed, failed, superseded }

public enum ReviewEventKind: String, Codable, Sendable { case feedback, changesRequested, approval, close, threadResolved, threadReopened }
public struct ReviewEvent: Codable, Hashable, Sendable { public let schemaVersion: Int, id: UUID, reviewID: ReviewID, revision: RevisionIdentity, sequence: Int, kind: ReviewEventKind, payload: [String: String], createdAt: Date
    public init(from decoder: Decoder) throws { let c = try decoder.container(keyedBy: CodingKeys.self); guard try c.decode(Int.self, forKey: .schemaVersion) == RTCConstants.schemaVersion else { throw RTCContractError.invalid("unknown schema major") }; schemaVersion=2; id=try c.decode(UUID.self,forKey:.id); reviewID=try c.decode(ReviewID.self,forKey:.reviewID); revision=try c.decode(RevisionIdentity.self,forKey:.revision); sequence=try c.decode(Int.self,forKey:.sequence); kind=try c.decode(ReviewEventKind.self,forKey:.kind); payload=try c.decode([String:String].self,forKey:.payload); createdAt=try c.decode(Date.self,forKey:.createdAt) }
}
public enum ConversationEventKind: String, Codable, Sendable { case humanMessageQueued, workerWakeSignaled, workerAcknowledged, assistantMessageStarted, assistantMessageDelta, assistantMessageCompleted, assistantMessageFailed, workerAvailabilityChanged, conversationEnded }
public struct ConversationEvent: Codable, Hashable, Sendable { public let schemaVersion: Int, id: UUID, reviewID: ReviewID, conversationID: UUID, sequence: Int, kind: ConversationEventKind, body: RichText?, citedAnchors: [ReviewAnchor], createdAt: Date
    public init(from decoder: Decoder) throws { let c=try decoder.container(keyedBy:CodingKeys.self); guard try c.decode(Int.self,forKey:.schemaVersion)==2 else { throw RTCContractError.invalid("unknown schema major") }; schemaVersion=2; id=try c.decode(UUID.self,forKey:.id); reviewID=try c.decode(ReviewID.self,forKey:.reviewID); conversationID=try c.decode(UUID.self,forKey:.conversationID); sequence=try c.decode(Int.self,forKey:.sequence); kind=try c.decode(ConversationEventKind.self,forKey:.kind); body=try c.decodeIfPresent(RichText.self,forKey:.body); citedAnchors=try c.decode([ReviewAnchor].self,forKey:.citedAnchors); createdAt=try c.decode(Date.self,forKey:.createdAt) }
}

public enum RichTextRunKind: String, Codable, Sendable { case plain, emphasis, strong, code }
public struct RichTextRun: Codable, Hashable, Sendable { public let kind: RichTextRunKind, text: BoundedString; public init(kind: RichTextRunKind, text: BoundedString) { self.kind = kind; self.text = text } }
public struct RichText: Codable, Hashable, Sendable { public let runs: [RichTextRun]
    public init(runs: [RichTextRun]) throws { guard runs.count <= 256, runs.reduce(0, { $0 + $1.text.value.utf8.count }) <= RTCConstants.maxProseBytes else { throw RTCContractError.invalid("rich text limit") }; self.runs = runs }
}
public enum TourProducer: String, Codable, Sendable { case localModel, workerSupplied }
public enum CalloutKind: String, Codable, Sendable { case note, warning, risk }
public enum DiagramKind: String, Codable, Sendable { case controlFlow, stateTransition, dataFlow, architecture }
public enum NodeRole: String, Codable, Sendable { case entry, action, decision, state, data, component, exit }
public enum EdgeRole: String, Codable, Sendable { case next, yes, no, calls, reads, writes, transitions }
public struct DiagramNode: Codable, Hashable, Sendable { public let id: BoundedString, label: BoundedString, role: NodeRole, anchors: [ReviewAnchor] }
public struct DiagramEdge: Codable, Hashable, Sendable { public let from: BoundedString, to: BoundedString, label: BoundedString?, role: EdgeRole, anchors: [ReviewAnchor] }
public struct DiagramGroup: Codable, Hashable, Sendable { public let id: BoundedString, label: BoundedString, nodeIDs: [BoundedString] }
public struct DiagramDocument: Codable, Hashable, Sendable { public let id: BoundedString, kind: DiagramKind, title: BoundedString, summary: RichText, nodes: [DiagramNode], edges: [DiagramEdge], groups: [DiagramGroup], anchors: [ReviewAnchor] }
public struct ReviewFocus: Codable, Hashable, Sendable { public let title: BoundedString, body: RichText, anchors: [ReviewAnchor] }
public struct DiffSliceReference: Codable, Hashable, Sendable { public let path: String, hunkIndex: Int, startLine: Int, endLine: Int }
public enum TourBlock: Codable, Hashable, Sendable { case paragraph(RichText), bulletList([RichText]), callout(CalloutKind, RichText, [ReviewAnchor]), diffSlice(DiffSliceReference), diagram(DiagramDocument) }
public struct TourChapter: Codable, Hashable, Sendable { public let id: BoundedString, title: BoundedString, summary: RichText, anchors: [ReviewAnchor], blocks: [TourBlock] }
public struct TourDocument: Codable, Hashable, Sendable { public let schemaVersion: Int, id: UUID, revision: RevisionIdentity, producer: TourProducer, inputDigest: SHA256Digest, title: BoundedString, overview: [TourBlock], reviewFocuses: [ReviewFocus], chapters: [TourChapter], risks: [ReviewFocus]
    public init(id: UUID, revision: RevisionIdentity, producer: TourProducer, inputDigest: SHA256Digest, title: BoundedString, overview: [TourBlock], reviewFocuses: [ReviewFocus], chapters: [TourChapter], risks: [ReviewFocus]) throws { guard overview.count > 0, chapters.count <= RTCConstants.maxChapters, overview.count + chapters.reduce(0, { $0 + $1.blocks.count }) <= RTCConstants.maxBlocks, reviewFocuses.count <= RTCConstants.maxFocuses else { throw RTCContractError.invalid("tour limit") }; schemaVersion = 2; self.id=id; self.revision=revision; self.producer=producer; self.inputDigest=inputDigest; self.title=title; self.overview=overview; self.reviewFocuses=reviewFocuses; self.chapters=chapters; self.risks=risks }
    public init(from decoder: Decoder) throws { let c=try decoder.container(keyedBy:CodingKeys.self); guard try c.decode(Int.self,forKey:.schemaVersion)==2 else { throw RTCContractError.invalid("unknown schema major") }; try self.init(id:try c.decode(UUID.self,forKey:.id), revision:try c.decode(RevisionIdentity.self,forKey:.revision), producer:try c.decode(TourProducer.self,forKey:.producer), inputDigest:try c.decode(SHA256Digest.self,forKey:.inputDigest), title:try c.decode(BoundedString.self,forKey:.title), overview:try c.decode([TourBlock].self,forKey:.overview), reviewFocuses:try c.decode([ReviewFocus].self,forKey:.reviewFocuses), chapters:try c.decode([TourChapter].self,forKey:.chapters), risks:try c.decode([ReviewFocus].self,forKey:.risks)) }
}

public enum RTCErrorCode: String, Codable, Sendable { case invalidJSON = "INVALID_JSON", unknownMajor = "UNKNOWN_MAJOR", invalidRevision = "INVALID_REVISION", invalidRef = "INVALID_REF", staleRevision = "STALE_REVISION", invalidAnchor = "INVALID_ANCHOR", limitExceeded = "LIMIT_EXCEEDED", gitTimeout = "GIT_TIMEOUT", gitCancelled = "GIT_CANCELLED", gitOutputLimit = "GIT_OUTPUT_LIMIT", unauthorized = "UNAUTHORIZED", appUnavailable = "APP_UNAVAILABLE", tourRejected = "TOUR_REJECTED", tourIDConflict = "TOUR_ID_CONFLICT", insufficientGrounding = "INSUFFICIENT_GROUNDING", modelUnavailable = "MODEL_UNAVAILABLE", internalError = "INTERNAL_ERROR" }
public struct RTCError: Codable, Error, Hashable, Sendable { public let code: RTCErrorCode, message: BoundedString, retryable: Bool; public init(code: RTCErrorCode, message: BoundedString, retryable: Bool) { self.code=code; self.message=message; self.retryable=retryable } }
public struct IPCRequest: Codable, Sendable { public let schemaVersion: Int, id: UUID, operation: BoundedString, reviewID: ReviewID?, payload: Data?; public init(schemaVersion: Int, id: UUID, operation: BoundedString, reviewID: ReviewID?, payload: Data?) { self.schemaVersion=schemaVersion; self.id=id; self.operation=operation; self.reviewID=reviewID; self.payload=payload } }
public struct IPCResponse: Codable, Sendable { public let schemaVersion: Int, requestID: UUID, ok: Bool, error: RTCError?, payload: Data?; public init(schemaVersion: Int, requestID: UUID, ok: Bool, error: RTCError?, payload: Data?) { self.schemaVersion=schemaVersion; self.requestID=requestID; self.ok=ok; self.error=error; self.payload=payload } }

public struct GitContextRequest: Codable, Hashable, Sendable { public let revision: RevisionIdentity, path: String, hunkIndex: Int, position: ContextPosition, lineCount: Int; public init(revision: RevisionIdentity, path: String, hunkIndex: Int, position: ContextPosition, lineCount: Int) { self.revision=revision; self.path=path; self.hunkIndex=hunkIndex; self.position=position; self.lineCount=lineCount } }
public struct GitContext: Codable, Hashable, Sendable { public let path: String, hunkIndex: Int, lines: [DiffLine]; public init(path: String, hunkIndex: Int, lines: [DiffLine]) { self.path=path; self.hunkIndex=hunkIndex; self.lines=lines } }
public struct GitCancellation: Codable, Hashable, Sendable { public let requested: Bool; public init(requested: Bool) { self.requested=requested } }
public protocol ExactGitService: Sendable { func materialize(_ revision: RevisionIdentity) async throws -> ReviewManifest; func context(_ request: GitContextRequest) async throws -> GitContext; func verifyCurrentHead(_ revision: RevisionIdentity) async throws -> Bool; func cancel(_ cancellation: GitCancellation) async }
public protocol GitService: ExactGitService {}
public protocol ReviewRepository: Sendable { func review(id: ReviewID) async throws -> ReviewManifest?; func save(_ review: ReviewManifest) async throws; func markStale(_ id: ReviewID) async throws }
public enum JobKind: String, Codable, Sendable { case materialize, tourGeneration, notification, wake }
public enum JobState: String, Codable, Sendable { case queued, running, succeeded, failed, cancelled }
public struct JobRecord: Codable, Hashable, Sendable { public let id: UUID, kind: JobKind, reviewID: ReviewID, state: JobState, attempt: Int, availableAt: Date, leaseOwner: BoundedString?; public init(id: UUID, kind: JobKind, reviewID: ReviewID, state: JobState, attempt: Int, availableAt: Date, leaseOwner: BoundedString? = nil) { self.id=id; self.kind=kind; self.reviewID=reviewID; self.state=state; self.attempt=attempt; self.availableAt=availableAt; self.leaseOwner=leaseOwner } }
public struct JobLease: Codable, Hashable, Sendable { public let jobID: UUID, owner: BoundedString, expiresAt: Date; public init(jobID: UUID, owner: BoundedString, expiresAt: Date) { self.jobID=jobID; self.owner=owner; self.expiresAt=expiresAt } }
public protocol JobRepository: Sendable { func enqueue(_ job: JobRecord) async throws; func leaseNext(owner: BoundedString, now: Date) async throws -> (JobRecord, JobLease)?; func complete(_ jobID: UUID, state: JobState) async throws }
public protocol EventRepository: Sendable { func append(_ event: ReviewEvent) async throws; func events(after sequence: Int, reviewID: ReviewID) async throws -> [ReviewEvent] }
public protocol ConversationEventRepository: Sendable { func append(_ event: ConversationEvent) async throws; func replay(reviewID: ReviewID, conversationID: UUID, after sequence: Int) async throws -> [ConversationEvent] }
public protocol IPCOperationHandler: Sendable { func handle(_ request: IPCRequest) async -> IPCResponse }
public protocol AnchorArtifactSource: Sendable { func validate(_ anchor: ReviewAnchor) async throws -> Bool }
public struct TourGenerationRequest: Codable, Sendable { public let revision: RevisionIdentity, contextDigest: SHA256Digest }
public struct TourProgress: Codable, Sendable { public let phase: BoundedString, fraction: Double }
public protocol TourProvider: Sendable { var descriptor: BoundedString { get }; func generate(request: TourGenerationRequest, progress: @Sendable (TourProgress) async -> Void) async throws -> TourDocument }
public protocol ModelAdapter: Sendable { func discoverModels() async throws -> [BoundedString]; func health() async throws -> Bool; func generateStructured(request: Data, schema: Data) async throws -> Data; func cancel() async }
public struct SyntaxSpan: Codable, Hashable, Sendable { public let line: Int, startColumn: Int, endColumn: Int, token: BoundedString; public init(line: Int, startColumn: Int, endColumn: Int, token: BoundedString) throws { guard line > 0, startColumn >= 0, endColumn >= startColumn else { throw RTCContractError.invalid("syntax span") }; self.line=line; self.startColumn=startColumn; self.endColumn=endColumn; self.token=token } }
public protocol SyntaxHighlighter: Sendable { func highlight(path: String, fileDigest: SHA256Digest, source: String, language: BoundedString?, lines: Range<Int>?) async throws -> [SyntaxSpan]; func cancel(fileDigest: SHA256Digest) async }
public protocol WakeSink: Sendable { func wake(reviewID: ReviewID, conversationID: UUID, highestSequence: Int) async throws }
public protocol NotificationService: Sendable { func notify(reviewID: ReviewID, generic: Bool) async throws }
public protocol AppLifecycleService: Sendable { func activate(reviewID: ReviewID?) async; func launchAtLogin(enabled: Bool) async throws }

public enum RTCCanonicalJSON {
    public static func encode<T: Encodable>(_ value: T) throws -> Data { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; encoder.dateEncodingStrategy = .iso8601; return try encoder.encode(value) }
    public static func digest<T: Encodable>(_ value: T) throws -> SHA256Digest { SHA256Digest(data: try encode(value)) }
}
