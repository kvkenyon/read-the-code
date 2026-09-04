import Foundation
import RTCContracts
import RTCDiagram

private func decoded<T: Decodable>(_ object: Any, as type: T.Type) -> T {
    let data = try! JSONSerialization.data(withJSONObject: object)
    return try! JSONDecoder().decode(type, from: data)
}
private func jsonObject<T: Encodable>(_ value: T) -> Any {
    try! JSONSerialization.jsonObject(with: RTCCanonicalJSON.encode(value), options: [.fragmentsAllowed])
}

extension TourProgress {
    public init(phase: BoundedString, fraction: Double) {
        self = decoded(["phase": jsonObject(phase), "fraction": fraction], as: TourProgress.self)
    }
}
extension TourGenerationRequest {
    public init(revision: RevisionIdentity, contextDigest: SHA256Digest) {
        self = decoded(
            ["revision": jsonObject(revision), "contextDigest": jsonObject(contextDigest)],
            as: TourGenerationRequest.self)
    }
}
extension DiffSliceReference {
    public init(
        path: String, hunkIndex: Int, side: AnchorSide = .new,
        startLine: Int, endLine: Int,
        startContextHash: SHA256Digest? = nil, endContextHash: SHA256Digest? = nil
    ) {
        var object: [String: Any] = [
            "path": path, "hunkIndex": hunkIndex, "side": side.rawValue,
            "startLine": startLine, "endLine": endLine,
            "startContextHash": NSNull(), "endContextHash": NSNull(),
        ]
        if let startContextHash { object["startContextHash"] = jsonObject(startContextHash) }
        if let endContextHash { object["endContextHash"] = jsonObject(endContextHash) }
        self = decoded(object, as: DiffSliceReference.self)
    }
}
extension TourChapter {
    public init(
        id: BoundedString, title: BoundedString, summary: RichText, anchors: [ReviewAnchor], blocks: [TourBlock]
    ) {
        self = decoded(
            [
                "id": jsonObject(id), "title": jsonObject(title), "summary": jsonObject(summary),
                "anchors": jsonObject(anchors), "blocks": jsonObject(blocks),
            ], as: TourChapter.self)
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
    public let oldPath: String?
    public let status: ChangeStatus
    public let additions: Int
    public let deletions: Int
    public let binary: Bool
    public let truncated: Bool
    public let oldLineCount: Int?
    public let newLineCount: Int?
    public let hunks: [DiffHunk]
    public init(
        path: String, oldPath: String? = nil, status: ChangeStatus, additions: Int, deletions: Int,
        binary: Bool = false, truncated: Bool = false, oldLineCount: Int? = nil,
        newLineCount: Int? = nil, hunks: [DiffHunk]
    ) {
        self.path = path; self.oldPath = oldPath; self.status = status
        self.additions = additions; self.deletions = deletions; self.binary = binary
        self.truncated = truncated; self.oldLineCount = oldLineCount
        self.newLineCount = newLineCount; self.hunks = hunks
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

public enum ContextPackBuildError: Error, Equatable, Sendable {
    case invalidManifest
    case metadataExceedsInputBudget(required: Int, budget: Int)
}

public struct ContextPackBuilder: Sendable {
    public let inputBudget: Int
    public init(inputBudget: Int = 128 * 1024) { self.inputBudget = max(1, inputBudget) }

    public func build(manifest: ReviewManifest) throws -> ContextPack {
        guard manifest.schemaVersion == RTCConstants.schemaVersion,
            manifest.id == manifest.revision.reviewID,
            manifest.files.count <= RTCConstants.maxFiles
        else {
            throw ContextPackBuildError.invalidManifest
        }

        var files = manifest.files.map { contextFile($0, includeHunks: false) }
        var omissions = manifest.files.flatMap { omissionRecords(for: $0) }
        var pack = try sizedPack(revision: manifest.revision, files: files, omissions: omissions)
        guard pack.byteCount <= inputBudget else {
            throw ContextPackBuildError.metadataExceedsInputBudget(required: pack.byteCount, budget: inputBudget)
        }

        // Metadata and explicit omission records are reserved first. Hunk payloads are
        // then admitted in manifest order, making the result canonical and repeatable.
        for (index, artifact) in manifest.files.enumerated() where !artifact.hunks.isEmpty {
            var candidateFiles = files
            candidateFiles[index] = contextFile(artifact, includeHunks: true)
            let candidateOmissions = omissions.filter {
                $0.path != artifact.path || $0.reason != "hunks omitted by input budget"
            }
            let candidate = try sizedPack(
                revision: manifest.revision, files: candidateFiles, omissions: candidateOmissions)
            if candidate.byteCount <= inputBudget {
                files = candidateFiles
                omissions = candidateOmissions
                pack = candidate
            }
        }
        return pack
    }

    private func contextFile(_ file: DiffArtifact, includeHunks: Bool) -> ContextFile {
        ContextFile(
            path: file.path, oldPath: file.oldPath, status: file.status,
            additions: file.additions, deletions: file.deletions,
            binary: file.binary, truncated: file.truncated,
            oldLineCount: file.oldLineCount, newLineCount: file.newLineCount,
            hunks: includeHunks ? file.hunks : [])
    }

    private func omissionRecords(for file: DiffArtifact) -> [ContextOmission] {
        var result: [ContextOmission] = []
        if !file.hunks.isEmpty {
            let withHunks = contextFile(file, includeHunks: true)
            let metadata = contextFile(file, includeHunks: false)
            let fullSize = (try? RTCCanonicalJSON.encode(withHunks).count) ?? 0
            let metadataSize = (try? RTCCanonicalJSON.encode(metadata).count) ?? 0
            result.append(
                ContextOmission(
                    path: file.path, reason: "hunks omitted by input budget",
                    omittedBytes: max(0, fullSize - metadataSize)))
        }
        if file.binary || file.status == .binary {
            result.append(ContextOmission(path: file.path, reason: "binary content excluded", omittedBytes: 0))
        }
        if file.truncated {
            result.append(
                ContextOmission(path: file.path, reason: "truncated artifact content unavailable", omittedBytes: 0))
        }
        return result
    }

    private func sizedPack(revision: RevisionIdentity, files: [ContextFile], omissions: [ContextOmission]) throws
        -> ContextPack
    {
        var size = 0
        for _ in 0..<4 {
            let candidate = ContextPack(revision: revision, files: files, omissions: omissions, byteCount: size)
            let encodedSize = try RTCCanonicalJSON.encode(candidate).count
            if encodedSize == size { return candidate }
            size = encodedSize
        }
        return ContextPack(revision: revision, files: files, omissions: omissions, byteCount: size)
    }
}

public struct ChangeSignals: Codable, Equatable, Sendable {
    public let controlFlow: Double
    public let stateTransition: Double
    public let dataFlow: Double
    public let architecture: Double
    public let changedBranches: Int
    public let publicContractChanges: Int
    public init(
        controlFlow: Double, stateTransition: Double, dataFlow: Double, architecture: Double, changedBranches: Int,
        publicContractChanges: Int
    ) {
        self.controlFlow = controlFlow; self.stateTransition = stateTransition; self.dataFlow = dataFlow;
        self.architecture = architecture; self.changedBranches = changedBranches;
        self.publicContractChanges = publicContractChanges
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
                    if ["if ", "else", "switch ", "guard ", "catch ", "case "].contains(where: text.contains) {
                        branches += 1
                    }
                    if ["state", "status", "phase", "transition"].contains(where: text.contains) { state += 1 }
                    if ["import ", "func ", "class ", "struct ", "protocol ", "database", "store"].contains(
                        where: text.contains)
                    {
                        data += 1
                    }
                    if text.contains("public ") || text.contains("api") { contracts += 1 }
                }
            }
            if file.status == .renamed || file.status == .deleted { architecture += 1 }
        }
        func score(_ value: Int, _ divisor: Double = 4) -> Double { min(1, Double(value) / divisor) }
        return ChangeSignals(
            controlFlow: score(branches), stateTransition: score(state), dataFlow: score(data),
            architecture: score(architecture), changedBranches: branches, publicContractChanges: contracts)
    }
    public func intents(_ signals: ChangeSignals) -> [DiagramIntent] {
        let values: [(DiagramKind, Double, String)] = [
            (.controlFlow, signals.controlFlow, "changed branch or guard signals"),
            (.stateTransition, signals.stateTransition, "state/status transition signals"),
            (.dataFlow, signals.dataFlow, "data and call-flow signals"),
            (.architecture, signals.architecture, "module, test, or file-boundary signals"),
        ]
        return values.map {
            DiagramIntent(
                kind: $0.0, material: $0.1 >= 0.5, score: $0.1,
                rationale: $0.1 >= 0.5 ? $0.2 : "below calibrated materiality threshold")
        }
    }
}

public struct TourValidator: Sendable {
    public init() {}
    public func validate(
        _ tour: TourDocument, against revision: RevisionIdentity,
        expectedInputDigest: SHA256Digest? = nil,
        anchors: AnchorArtifactSource
    ) async -> Result<TourDocument, TourValidationFailure> {
        var issues: [TourValidationIssue] = []
        if tour.schemaVersion != RTCConstants.schemaVersion {
            issues.append(
                .init(code: .invalidStructure, location: "schemaVersion", message: "unsupported schema version"))
        }
        if tour.revision != revision {
            issues.append(
                .init(
                    code: .revisionMismatch, location: "revision",
                    message: "tour is not bound to the exact review revision"))
        }
        if let expectedInputDigest, tour.inputDigest != expectedInputDigest {
            issues.append(
                .init(
                    code: .insufficientGrounding, location: "inputDigest",
                    message: "tour was not generated from the canonical context pack"))
        }
        if tour.overview.isEmpty || tour.chapters.isEmpty {
            issues.append(
                .init(code: .invalidStructure, location: "document", message: "overview and chapters are required"))
        }
        let blockCount = tour.overview.count + tour.chapters.reduce(0) { $0 + $1.blocks.count }
        if tour.chapters.count > RTCConstants.maxChapters || tour.reviewFocuses.count > RTCConstants.maxFocuses
            || tour.risks.count > RTCConstants.maxFocuses || blockCount > RTCConstants.maxBlocks
        {
            issues.append(.init(code: .limitExceeded, location: "document", message: "tour limits exceeded"))
        }
        if (try? RTCCanonicalJSON.encode(tour).count) ?? Int.max > RTCConstants.maxDocumentBytes {
            issues.append(
                .init(code: .limitExceeded, location: "document", message: "encoded tour exceeds document limit"))
        }
        let reservedIDs: Set<String> = ["overview", "focuses", "history", "attachments"]
        var ids = reservedIDs; var cited = 0; var diagrams = 0; var proseBytes = 0
        func checkID(_ value: String, _ location: String) {
            checkLabel(value, location)
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                !reservedIDs.contains(value), ids.insert(value).inserted
            else {
                issues.append(
                    .init(
                        code: .duplicateID, location: location,
                        message: "identifier is empty, reserved, or collides across namespaces"))
                return
            }
        }
        func checkAnchor(_ anchor: ReviewAnchor, _ location: String) async {
            cited += 1
            let hasRange = anchor.startLine != nil || anchor.endLine != nil
            let structurallyValid: Bool
            switch anchor.scope {
            case .general, .file:
                structurallyValid = anchor.side == nil && !hasRange && anchor.hunkIndex == nil && anchor.symbol == nil
            case .line:
                structurallyValid = anchor.side != nil && hasRange && anchor.hunkIndex == nil && anchor.symbol == nil
            case .hunk:
                structurallyValid =
                    anchor.hunkIndex.map({ $0 >= 0 }) ?? false
                    && anchor.symbol == nil && (!hasRange || anchor.side != nil)
            case .symbol:
                structurallyValid =
                    anchor.symbol.map({ !$0.value.isEmpty }) ?? false
                    && anchor.side == nil && !hasRange && anchor.hunkIndex == nil
            }
            guard structurallyValid, hasRange || anchor.startContextHash == nil && anchor.endContextHash == nil else {
                issues.append(
                    .init(
                        code: .unresolvedAnchor, location: location,
                        message: "anchor structure is invalid"))
                return
            }
            if anchor.revision != revision {
                issues.append(
                    .init(
                        code: .unresolvedAnchor, location: location,
                        message: "anchor does not resolve against exact artifacts"));
                return
            }
            let resolves = (try? await anchors.validate(anchor)) ?? false
            if !resolves {
                issues.append(
                    .init(
                        code: .unresolvedAnchor, location: location,
                        message: "anchor does not resolve against exact artifacts"))
            }
        }
        func checkText(_ text: RichText, _ location: String) {
            proseBytes += text.runs.reduce(0) { $0 + $1.text.value.utf8.count }
            if text.runs.allSatisfy({ $0.text.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                issues.append(.init(code: .insufficientGrounding, location: location, message: "empty claim"))
            }
            for run in text.runs { checkString(run.text.value, location) }
        }
        func checkString(_ value: String, _ location: String) {
            let pattern =
                #"(?i)(<\s*/?\s*(?:[a-z][a-z0-9:-]*|!doctype)\b[^>]*>|\b(?:javascript|vbscript|data|file):|\bhttps?://|```\s*mermaid\b|\bmermaid\s+(?:flowchart|graph|sequenceDiagram|stateDiagram|classDiagram|erDiagram)\b|<\s*svg\b|<\s*script\b|\$\()"#
            if value.range(of: pattern, options: .regularExpression) != nil {
                issues.append(
                    .init(
                        code: .prohibitedContent, location: location,
                        message: "untrusted structured text contains prohibited content"))
            }
        }
        func checkLabel(_ value: String, _ location: String) {
            checkString(value, location)
            if value.count > RTCConstants.maxLabelCharacters {
                issues.append(.init(code: .limitExceeded, location: location, message: "label exceeds character limit"))
            }
        }
        func checkDiagram(_ diagram: DiagramDocument, _ location: String) async {
            diagrams += 1
            checkID(diagram.id.value, location + ".id")
            do { _ = try DiagramValidator.validate(diagram) } catch {
                issues.append(
                    .init(code: .invalidDiagram, location: location, message: "diagram IR is invalid or exceeds bounds")
                )
            }
            checkLabel(diagram.title.value, location + ".title"); checkText(diagram.summary, location + ".summary")
            for anchor in diagram.anchors { await checkAnchor(anchor, location + ".anchor") }
            for (index, node) in diagram.nodes.enumerated() {
                let nodeLocation = location + ".node[\(index)]"
                checkID(node.id.value, nodeLocation + ".id"); checkLabel(node.label.value, nodeLocation + ".label")
                if node.anchors.isEmpty {
                    issues.append(
                        .init(code: .insufficientGrounding, location: location, message: "diagram node lacks an anchor")
                    )
                }
                for anchor in node.anchors { await checkAnchor(anchor, nodeLocation) }
            }
            for (index, edge) in diagram.edges.enumerated() {
                let edgeLocation = location + ".edge[\(index)]"
                if edge.anchors.isEmpty {
                    issues.append(
                        .init(code: .insufficientGrounding, location: location, message: "diagram edge lacks an anchor")
                    )
                }
                if let label = edge.label { checkLabel(label.value, edgeLocation + ".label") }
                for anchor in edge.anchors { await checkAnchor(anchor, edgeLocation) }
            }
            for (index, group) in diagram.groups.enumerated() {
                checkID(group.id.value, location + ".group[\(index)].id");
                checkLabel(group.label.value, location + ".group[\(index)].label")
            }
        }
        func block(_ block: TourBlock, _ location: String) async {
            switch block {
            case .paragraph(let text): checkText(text, location)
            case .bulletList(let texts):
                for (i, text) in texts.enumerated() { checkText(text, location + "." + String(i)) }
            case .callout(_, let text, let refs):
                checkText(text, location)
                if refs.isEmpty {
                    issues.append(
                        .init(
                            code: .insufficientGrounding, location: location,
                            message: "callout claim lacks a source anchor"))
                }
                for anchor in refs { await checkAnchor(anchor, location) }
            case .diffSlice(let slice):
                guard slice.hunkIndex >= 0, slice.startLine > 0, slice.endLine >= slice.startLine,
                    !slice.path.hasPrefix("/"), !slice.path.split(separator: "/").contains("..")
                else {
                    issues.append(.init(code: .invalidStructure, location: location, message: "invalid diff slice"));
                    return
                }
                do {
                    let reference = try ReviewAnchor(
                        revision: revision, path: slice.path, scope: .hunk,
                        side: slice.side,
                        startLine: slice.startLine, endLine: slice.endLine,
                        startContextHash: slice.startContextHash,
                        endContextHash: slice.endContextHash,
                        hunkIndex: slice.hunkIndex)
                    await checkAnchor(reference, location + ".diffSlice")
                } catch {
                    issues.append(.init(code: .invalidStructure, location: location, message: "invalid diff slice"))
                }
            case .diagram(let diagram): await checkDiagram(diagram, location)
            }
        }
        checkLabel(tour.title.value, "title")
        for (i, blockValue) in tour.overview.enumerated() { await block(blockValue, "overview[\(i)]") }
        for (i, focus) in tour.reviewFocuses.enumerated() {
            checkLabel(focus.title.value, "focus[\(i)].title"); checkText(focus.body, "focus[\(i)]");
            if focus.anchors.isEmpty {
                issues.append(
                    .init(code: .insufficientGrounding, location: "focus[\(i)]", message: "focus lacks a source anchor")
                )
            }; for anchor in focus.anchors { await checkAnchor(anchor, "focus[\(i)]") }
        }
        for (i, chapter) in tour.chapters.enumerated() {
            checkID(chapter.id.value, "chapter[\(i)].id"); checkLabel(chapter.title.value, "chapter[\(i)].title");
            checkText(chapter.summary, "chapter[\(i)].summary");
            if chapter.anchors.isEmpty {
                issues.append(
                    .init(
                        code: .insufficientGrounding, location: "chapter[\(i)]",
                        message: "chapter lacks a source anchor"))
            }; for anchor in chapter.anchors { await checkAnchor(anchor, "chapter[\(i)]") };
            for (j, value) in chapter.blocks.enumerated() { await block(value, "chapter[\(i)].block[\(j)]") }
        }
        for (i, risk) in tour.risks.enumerated() {
            checkLabel(risk.title.value, "risk[\(i)].title"); checkText(risk.body, "risk[\(i)]");
            if risk.anchors.isEmpty {
                issues.append(
                    .init(code: .insufficientGrounding, location: "risk[\(i)]", message: "risk lacks a source anchor"))
            }; for anchor in risk.anchors { await checkAnchor(anchor, "risk[\(i)]") }
        }
        if cited > RTCConstants.maxAnchors || diagrams > RTCConstants.maxDiagrams
            || proseBytes > RTCConstants.maxProseBytes
        {
            issues.append(
                .init(code: .limitExceeded, location: "document", message: "citation, prose, or diagram limit exceeded")
            )
        }
        return issues.isEmpty ? .success(tour) : .failure(TourValidationFailure(issues: issues))
    }
}

public struct SuppliedTourProvider: TourProvider {
    public let descriptor: BoundedString
    private let tour: TourDocument
    public init(tour: TourDocument, descriptor: BoundedString = "Supplied tour") {
        self.tour = tour; self.descriptor = descriptor
    }
    public func generate(request: TourGenerationRequest, progress: @Sendable (TourProgress) async -> Void) async throws
        -> TourDocument
    { await progress(TourProgress(phase: "supplied", fraction: 1)); return tour }
}

public struct FallbackTourProvider: TourProvider {
    public let descriptor: BoundedString = "Generated outline unavailable"
    private let source: ExactArtifactSource
    public init(source: ExactArtifactSource) { self.source = source }
    public func generate(request: TourGenerationRequest, progress: @Sendable (TourProgress) async -> Void) async throws
        -> TourDocument
    {
        let manifest = try await source.manifest(for: request.revision);
        let files = manifest.files.sorted {
            rank($0.path) != rank($1.path) ? rank($0.path) < rank($1.path) : $0.path < $1.path
        }
        await progress(TourProgress(phase: "fallback", fraction: 0.5))
        let overview = try RichText(runs: [
            RichTextRun(
                kind: .plain, text: "Generated outline unavailable. Review the exact committed-tree changes below.")
        ])
        let chapters = try files.prefix(RTCConstants.maxChapters).map { file in
            let anchor = try ReviewAnchor(revision: request.revision, path: file.path, scope: .file)
            return TourChapter(
                id: try BoundedString(file.path), title: try BoundedString(file.path), summary: overview,
                anchors: [anchor], blocks: chapterBlocksFor(file))
        }
        await progress(TourProgress(phase: "fallback", fraction: 1))
        return try TourDocument(
            id: deterministicID(revision: request.revision, digest: request.contextDigest), revision: request.revision,
            producer: .deterministicFallback, inputDigest: request.contextDigest,
            title: "Generated outline unavailable", overview: [.paragraph(overview)], reviewFocuses: [],
            chapters: chapters, risks: [])
    }
    private func chapterBlocksFor(_ file: DiffArtifact) -> [TourBlock] {
        guard let hunk = file.hunks.first else { return [] }
        let side: AnchorSide = hunk.newLines > 0 ? .new : .old
        let start = side == .new ? hunk.newStart : hunk.oldStart
        let count = side == .new ? hunk.newLines : hunk.oldLines
        return [
            .diffSlice(
                DiffSliceReference(
                    path: file.path, hunkIndex: 0, side: side,
                    startLine: max(1, start), endLine: max(1, start + max(1, count) - 1)))
        ]
    }
    private func deterministicID(revision: RevisionIdentity, digest: SHA256Digest) -> UUID {
        let hex = SHA256Digest(data: Data((revision.reviewID.value + digest.hex + descriptor.value).utf8)).hex
        let value =
            "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-4\(hex.dropFirst(13).prefix(3))-a\(hex.dropFirst(17).prefix(3))-\(hex.dropFirst(20).prefix(12))"
        return UUID(uuidString: value)!
    }
    private func rank(_ path: String) -> Int {
        let p = path.lowercased(); if p.contains("protocol") || p.contains("api") { return 0 };
        if p.contains("view") || p.contains("ui") { return 2 }; if p.contains("test") { return 3 }; return 1
    }
}

public struct TourCoordinator: Sendable {
    public let validator: TourValidator
    public init(validator: TourValidator = TourValidator()) { self.validator = validator }
    public func run(
        request: TourGenerationRequest, provider: TourProvider, anchors: AnchorArtifactSource, fallback: TourProvider,
        progress: @Sendable (TourProgress) async -> Void
    ) async -> Result<TourDocument, RTCError> {
        do {
            await progress(TourProgress(phase: "generating", fraction: 0));
            let candidate = try await provider.generate(request: request, progress: progress);
            guard !Task.isCancelled else { throw CancellationError() };
            switch await validator.validate(
                candidate, against: request.revision, expectedInputDigest: request.contextDigest, anchors: anchors)
            {
            case .success(let tour):
                await progress(TourProgress(phase: "validated", fraction: 1)); return .success(tour);
            case .failure: break
            }
        } catch is CancellationError {
            return .failure(RTCError(code: .internalError, message: "cancelled", retryable: true))
        } catch {}
        do {
            let candidate = try await fallback.generate(request: request, progress: progress);
            switch await validator.validate(
                candidate, against: request.revision, expectedInputDigest: request.contextDigest, anchors: anchors)
            {
            case .success(let tour): return .success(tour);
            case .failure:
                return .failure(
                    RTCError(
                        code: .insufficientGrounding, message: "tour and fallback could not be grounded",
                        retryable: false))
            }
        } catch { return .failure(RTCError(code: .tourRejected, message: "tour generation failed", retryable: true)) }
    }
}
