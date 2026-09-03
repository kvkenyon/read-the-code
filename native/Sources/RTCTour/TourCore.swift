import Foundation
import RTCContracts

private func decoded<T: Decodable>(_ object: Any, as type: T.Type) -> T {
    let data = try! JSONSerialization.data(withJSONObject: object)
    return try! JSONDecoder().decode(type, from: data)
}
private func jsonObject<T: Encodable>(_ value: T) -> Any {
    try! JSONSerialization.jsonObject(with: RTCCanonicalJSON.encode(value), options: [.fragmentsAllowed])
}

extension TourProgress {
    public init(phase: BoundedString, fraction: Double) { self = decoded(["phase": jsonObject(phase), "fraction": fraction], as: TourProgress.self) }
}
extension TourGenerationRequest {
    public init(revision: RevisionIdentity, contextDigest: SHA256Digest) {
        self = decoded(["revision": jsonObject(revision), "contextDigest": jsonObject(contextDigest)], as: TourGenerationRequest.self)
    }
}
extension DiffSliceReference {
    public init(path: String, hunkIndex: Int, startLine: Int, endLine: Int) { self = decoded(["path": path, "hunkIndex": hunkIndex, "startLine": startLine, "endLine": endLine], as: DiffSliceReference.self) }
}
extension TourChapter {
    public init(id: BoundedString, title: BoundedString, summary: RichText, anchors: [ReviewAnchor], blocks: [TourBlock]) {
        self = decoded(["id": jsonObject(id), "title": jsonObject(title), "summary": jsonObject(summary), "anchors": jsonObject(anchors), "blocks": jsonObject(blocks)], as: TourChapter.self)
    }
}

public enum TourValidationCode: String, Codable, Equatable, Sendable {
    case invalidStructure = "INVALID_STRUCTURE"
    case revisionMismatch = "REVISION_MISMATCH"
    case unresolvedAnchor = "UNRESOLVED_ANCHOR"
    case duplicateID = "DUPLICATE_ID"
    case invalidDiagram = "INVALID_DIAGRAM"
    case insufficientGrounding = "INSUFFICIENT_GROUNDING"
    case prohibitedContent = "PROHIBITED_CONTENT"
    case limitExceeded = "LIMIT_EXCEEDED"
}

public struct TourValidationIssue: Codable, Equatable, Sendable {
    public let code: TourValidationCode
    public let location: String
    public let message: String
    public init(code: TourValidationCode, location: String, message: String) {
        self.code = code; self.location = location; self.message = message
    }
}

public struct TourValidationFailure: Error, Codable, Equatable, Sendable {
    public let issues: [TourValidationIssue]
    public init(issues: [TourValidationIssue]) { self.issues = issues }
}

public struct ContextOmission: Codable, Equatable, Sendable {
    public let path: String
    public let reason: String
    public let omittedBytes: Int
    public init(path: String, reason: String, omittedBytes: Int) {
        self.path = path; self.reason = reason; self.omittedBytes = omittedBytes
    }
}

public struct ContextFile: Codable, Equatable, Sendable {
    public let path: String
    public let status: ChangeStatus
    public let additions: Int
    public let deletions: Int
    public let hunks: [DiffHunk]
    public init(path: String, status: ChangeStatus, additions: Int, deletions: Int, hunks: [DiffHunk]) {
        self.path = path; self.status = status; self.additions = additions; self.deletions = deletions; self.hunks = hunks
    }
}

public struct ContextPack: Codable, Equatable, Sendable {
    public let revision: RevisionIdentity
    public let files: [ContextFile]
    public let omissions: [ContextOmission]
    public let byteCount: Int
    public init(revision: RevisionIdentity, files: [ContextFile], omissions: [ContextOmission], byteCount: Int) {
        self.revision = revision; self.files = files; self.omissions = omissions; self.byteCount = byteCount
    }
    public var digest: SHA256Digest { (try? RTCCanonicalJSON.digest(self)) ?? SHA256Digest(data: Data()) }
}

public protocol ExactArtifactSource: Sendable {
    func manifest(for revision: RevisionIdentity) async throws -> ReviewManifest
}

public struct ContextPackBuilder: Sendable {
    public let inputBudget: Int
    public init(inputBudget: Int = 128 * 1024) { self.inputBudget = max(1, inputBudget) }

    public func build(manifest: ReviewManifest) throws -> ContextPack {
        var used = 0; var files: [ContextFile] = []; var omissions: [ContextOmission] = []
        for file in manifest.files {
            let candidate = ContextFile(path: file.path, status: file.status, additions: file.additions, deletions: file.deletions, hunks: file.hunks)
            let size = (try? RTCCanonicalJSON.encode(candidate).count) ?? Int.max
            if used + size <= inputBudget {
                files.append(candidate); used += size
            } else if files.isEmpty {
                let metadataOnly = ContextFile(path: file.path, status: file.status, additions: file.additions, deletions: file.deletions, hunks: [])
                let metadataSize = (try? RTCCanonicalJSON.encode(metadataOnly).count) ?? 0
                files.append(metadataOnly); used = min(metadataSize, inputBudget)
                omissions.append(ContextOmission(path: file.path, reason: "hunks exceed input budget", omittedBytes: max(0, size - metadataSize)))
            } else {
                omissions.append(ContextOmission(path: file.path, reason: "input budget", omittedBytes: size))
            }
        }
        return ContextPack(revision: manifest.revision, files: files, omissions: omissions, byteCount: used)
    }
}

public struct ChangeSignals: Codable, Equatable, Sendable {
    public let controlFlow: Double
    public let stateTransition: Double
    public let dataFlow: Double
    public let architecture: Double
    public let changedBranches: Int
    public let publicContractChanges: Int
    public init(controlFlow: Double, stateTransition: Double, dataFlow: Double, architecture: Double, changedBranches: Int, publicContractChanges: Int) {
        self.controlFlow = controlFlow; self.stateTransition = stateTransition; self.dataFlow = dataFlow; self.architecture = architecture; self.changedBranches = changedBranches; self.publicContractChanges = publicContractChanges
    }
}

public struct DiagramIntent: Codable, Equatable, Sendable {
    public let kind: DiagramKind
    public let material: Bool
    public let score: Double
    public let rationale: String
    public init(kind: DiagramKind, material: Bool, score: Double, rationale: String) {
        self.kind = kind; self.material = material; self.score = score; self.rationale = rationale
    }
}

public struct SignalAnalyzer: Sendable {
    public init() {}
    public func analyze(_ pack: ContextPack) -> ChangeSignals {
        var branches = 0, contracts = 0, state = 0, data = 0, architecture = 0
        for file in pack.files {
            let name = file.path.lowercased()
            if name.contains("protocol") || name.contains("api") || name.contains("contract") { contracts += 1 }
            if name.contains("test") || name.contains("spec") { architecture += 1 }
            for hunk in file.hunks {
                for line in hunk.lines where line.kind != .context {
                    let text = line.text.lowercased()
                    if ["if ", "else", "switch ", "guard ", "catch ", "case "].contains(where: text.contains) { branches += 1 }
                    if ["state", "status", "phase", "transition"].contains(where: text.contains) { state += 1 }
                    if ["import ", "func ", "class ", "struct ", "protocol ", "database", "store"].contains(where: text.contains) { data += 1 }
                    if text.contains("public ") || text.contains("api") { contracts += 1 }
                }
            }
            if file.status == .renamed || file.status == .deleted { architecture += 1 }
        }
        func score(_ value: Int, _ divisor: Double = 4) -> Double { min(1, Double(value) / divisor) }
        return ChangeSignals(controlFlow: score(branches), stateTransition: score(state), dataFlow: score(data), architecture: score(architecture), changedBranches: branches, publicContractChanges: contracts)
    }
    public func intents(_ signals: ChangeSignals) -> [DiagramIntent] {
        let values: [(DiagramKind, Double, String)] = [(.controlFlow, signals.controlFlow, "changed branch or guard signals"), (.stateTransition, signals.stateTransition, "state/status transition signals"), (.dataFlow, signals.dataFlow, "data and call-flow signals"), (.architecture, signals.architecture, "module, test, or file-boundary signals")]
        return values.map { DiagramIntent(kind: $0.0, material: $0.1 >= 0.5, score: $0.1, rationale: $0.1 >= 0.5 ? $0.2 : "below calibrated materiality threshold") }
    }
}

public struct TourValidator: Sendable {
    public init() {}
    public func validate(_ tour: TourDocument, against revision: RevisionIdentity, anchors: AnchorArtifactSource) async -> Result<TourDocument, TourValidationFailure> {
        var issues: [TourValidationIssue] = []
        if tour.schemaVersion != RTCConstants.schemaVersion { issues.append(.init(code: .invalidStructure, location: "schemaVersion", message: "unsupported schema version")) }
        if tour.revision != revision { issues.append(.init(code: .revisionMismatch, location: "revision", message: "tour is not bound to the exact review revision")) }
        if tour.overview.isEmpty || tour.chapters.isEmpty { issues.append(.init(code: .invalidStructure, location: "document", message: "overview and chapters are required")) }
        if tour.chapters.count > RTCConstants.maxChapters || tour.reviewFocuses.count > RTCConstants.maxFocuses { issues.append(.init(code: .limitExceeded, location: "document", message: "tour limits exceeded")) }
        var ids = Set<String>(); var cited = 0; var diagrams = 0
        func checkAnchor(_ anchor: ReviewAnchor, _ location: String) async {
            cited += 1
            if anchor.revision != revision { issues.append(.init(code: .unresolvedAnchor, location: location, message: "anchor does not resolve against exact artifacts")); return }
            let resolves = (try? await anchors.validate(anchor)) ?? false
            if !resolves { issues.append(.init(code: .unresolvedAnchor, location: location, message: "anchor does not resolve against exact artifacts")) }
        }
        func checkText(_ text: RichText, _ location: String) {
            if text.runs.allSatisfy({ $0.text.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) { issues.append(.init(code: .insufficientGrounding, location: location, message: "empty claim")) }
            if text.runs.contains(where: { $0.text.value.range(of: #"(?i)(https?://|javascript:|<script|```|\$\()"#, options: .regularExpression) != nil }) { issues.append(.init(code: .prohibitedContent, location: location, message: "untrusted rich text contains prohibited content")) }
        }
        func checkDiagram(_ diagram: DiagramDocument, _ location: String) async {
            diagrams += 1; let nodeIDs = diagram.nodes.map { $0.id.value }
            if Set(nodeIDs).count != nodeIDs.count || diagram.nodes.count > RTCConstants.maxNodes || diagram.edges.count > RTCConstants.maxEdges { issues.append(.init(code: .invalidDiagram, location: location, message: "duplicate IDs or diagram limits exceeded")) }
            for node in diagram.nodes { if node.anchors.isEmpty { issues.append(.init(code: .insufficientGrounding, location: location, message: "diagram node lacks an anchor")) }; for anchor in node.anchors { await checkAnchor(anchor, location + ".node." + node.id.value) } }
            for edge in diagram.edges { if !nodeIDs.contains(edge.from.value) || !nodeIDs.contains(edge.to.value) || edge.anchors.isEmpty { issues.append(.init(code: .invalidDiagram, location: location, message: "edge is not referentially complete")) }; for anchor in edge.anchors { await checkAnchor(anchor, location + ".edge") } }
        }
        func block(_ block: TourBlock, _ location: String) async {
            switch block {
            case .paragraph(let text): checkText(text, location)
            case .bulletList(let texts): for (i, text) in texts.enumerated() { checkText(text, location + "." + String(i)) }
            case .callout(_, let text, let refs): checkText(text, location); for anchor in refs { await checkAnchor(anchor, location) }
            case .diffSlice(let slice): if slice.startLine <= 0 || slice.endLine < slice.startLine || slice.path.hasPrefix("/") || slice.path.contains("..") { issues.append(.init(code: .invalidStructure, location: location, message: "invalid diff slice")) }
            case .diagram(let diagram): await checkDiagram(diagram, location)
            }
        }
        for (i, blockValue) in tour.overview.enumerated() { await block(blockValue, "overview[\(i)]") }
        for (i, focus) in tour.reviewFocuses.enumerated() { checkText(focus.body, "focus[\(i)]"); if focus.anchors.isEmpty { issues.append(.init(code: .insufficientGrounding, location: "focus[\(i)]", message: "focus lacks a source anchor")) }; for anchor in focus.anchors { await checkAnchor(anchor, "focus[\(i)]") } }
        for (i, chapter) in tour.chapters.enumerated() { if !ids.insert(chapter.id.value).inserted { issues.append(.init(code: .duplicateID, location: "chapter[\(i)]", message: "duplicate chapter ID")) }; checkText(chapter.summary, "chapter[\(i)].summary"); if chapter.anchors.isEmpty { issues.append(.init(code: .insufficientGrounding, location: "chapter[\(i)]", message: "chapter lacks a source anchor")) }; for anchor in chapter.anchors { await checkAnchor(anchor, "chapter[\(i)]") }; for (j, value) in chapter.blocks.enumerated() { await block(value, "chapter[\(i)].block[\(j)]") } }
        for (i, risk) in tour.risks.enumerated() { checkText(risk.body, "risk[\(i)]"); for anchor in risk.anchors { await checkAnchor(anchor, "risk[\(i)]") } }
        if cited > RTCConstants.maxAnchors || diagrams > RTCConstants.maxDiagrams { issues.append(.init(code: .limitExceeded, location: "document", message: "citation or diagram limit exceeded")) }
        return issues.isEmpty ? .success(tour) : .failure(TourValidationFailure(issues: issues))
    }
}

public struct SuppliedTourProvider: TourProvider {
    public let descriptor: BoundedString
    private let tour: TourDocument
    public init(tour: TourDocument, descriptor: BoundedString = "Supplied tour") { self.tour = tour; self.descriptor = descriptor }
    public func generate(request: TourGenerationRequest, progress: @Sendable (TourProgress) async -> Void) async throws -> TourDocument { await progress(TourProgress(phase: "supplied", fraction: 1)); return tour }
}

public struct FallbackTourProvider: TourProvider {
    public let descriptor: BoundedString = "Generated outline unavailable"
    private let source: ExactArtifactSource
    public init(source: ExactArtifactSource) { self.source = source }
    public func generate(request: TourGenerationRequest, progress: @Sendable (TourProgress) async -> Void) async throws -> TourDocument {
        let manifest = try await source.manifest(for: request.revision); let files = manifest.files.sorted { rank($0.path) != rank($1.path) ? rank($0.path) < rank($1.path) : $0.path < $1.path }
        await progress(TourProgress(phase: "fallback", fraction: 0.5))
        let overview = try RichText(runs: [RichTextRun(kind: .plain, text: "Generated outline unavailable. Review the exact committed-tree changes below.")])
        let chapters = try files.map { file in
            let anchor = try ReviewAnchor(revision: request.revision, path: file.path, scope: .file)
            return TourChapter(id: try BoundedString(file.path), title: try BoundedString(file.path), summary: overview, anchors: [anchor], blocks: chapterBlocksFor(file))
        }
        return try TourDocument(id: UUID(), revision: request.revision, producer: .workerSupplied, inputDigest: request.contextDigest, title: "Generated outline unavailable", overview: [.paragraph(overview)], reviewFocuses: [], chapters: chapters, risks: [])
    }
    private func chapterBlocksFor(_ file: DiffArtifact) -> [TourBlock] { [TourBlock.diffSlice(DiffSliceReference(path: file.path, hunkIndex: 0, startLine: 1, endLine: max(1, file.hunks.first?.newLines ?? 1)))] }
    private func rank(_ path: String) -> Int { let p = path.lowercased(); if p.contains("protocol") || p.contains("api") { return 0 }; if p.contains("view") || p.contains("ui") { return 2 }; if p.contains("test") { return 3 }; return 1 }
}

public struct TourCoordinator: Sendable {
    public let validator: TourValidator
    public init(validator: TourValidator = TourValidator()) { self.validator = validator }
    public func run(request: TourGenerationRequest, provider: TourProvider, anchors: AnchorArtifactSource, fallback: TourProvider, progress: @Sendable (TourProgress) async -> Void) async -> Result<TourDocument, RTCError> {
        do { await progress(TourProgress(phase: "generating", fraction: 0)); let candidate = try await provider.generate(request: request, progress: progress); guard !Task.isCancelled else { throw CancellationError() }; switch await validator.validate(candidate, against: request.revision, anchors: anchors) { case .success(let tour): await progress(TourProgress(phase: "validated", fraction: 1)); return .success(tour); case .failure: break } }
        catch is CancellationError { return .failure(RTCError(code: .internalError, message: "cancelled", retryable: true)) }
        catch { }
        do { let candidate = try await fallback.generate(request: request, progress: progress); switch await validator.validate(candidate, against: request.revision, anchors: anchors) { case .success(let tour): return .success(tour); case .failure: return .failure(RTCError(code: .insufficientGrounding, message: "tour and fallback could not be grounded", retryable: false)) } }
        catch { return .failure(RTCError(code: .tourRejected, message: "tour generation failed", retryable: true)) }
    }
}
