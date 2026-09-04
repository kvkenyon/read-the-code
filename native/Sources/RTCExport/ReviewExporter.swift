import Foundation
import RTCContracts
import RTCDiagram
import RTCReview
import RTCTour

private struct ThreadCreatedExportPayload: Decodable { let thread: ReviewThread }
private struct ThreadMessageAddedExportPayload: Decodable { let threadID: UUID; let message: ThreadMessage }
private struct FileProgressExportPayload: Decodable { let progress: FileProgress }
private struct ThreadIDsExportPayload: Decodable { let threadIDs: [UUID] }
private struct RequestChangesExportPayload: Decodable { let threadIDs: [UUID]; let summary: RichText? }
private struct ApprovalExportPayload: Decodable { let warnings: [String] }
private struct ThreadIDExportPayload: Decodable { let threadID: UUID }

private enum DecodedReviewEventPayload {
    case threadCreated(ReviewThread)
    case threadMessageAdded(UUID, ThreadMessage)
    case fileProgressChanged(FileProgress)
    case feedback([UUID])
    case changesRequested([UUID], RichText?)
    case approval([String])
    case close
    case threadResolved(UUID)
    case threadReopened(UUID)
}

public struct ReviewExportInput: Sendable {
    public let manifest: ReviewManifest
    public let events: [ReviewEvent]
    public let threads: [ReviewThread]
    public let progress: [FileProgress]
    public let tours: [TourDocument]

    public init(
        manifest: ReviewManifest,
        events: [ReviewEvent] = [],
        threads: [ReviewThread] = [],
        progress: [FileProgress] = [],
        tours: [TourDocument] = []
    ) {
        self.manifest = manifest
        self.events = events
        self.threads = threads
        self.progress = progress
        self.tours = tours
    }
}

/// Builds a portable record from a closed allowlist. Repository paths, source
/// hunks, capabilities, configuration, prompts, environment, and opaque blobs
/// have no representable field in the normal export.
public struct ReviewExporter: Sendable {
    private let anchors: any AnchorArtifactSource
    private let redactor = ExportRedactor()
    let diagnosticIOFaults: DiagnosticIOFaults?

    public init(anchors: any AnchorArtifactSource) {
        self.anchors = anchors
        self.diagnosticIOFaults = nil
    }

    @_spi(Testing)
    public init(anchors: any AnchorArtifactSource, diagnosticIOFaults: DiagnosticIOFaults) {
        self.anchors = anchors
        self.diagnosticIOFaults = diagnosticIOFaults
    }

    public func normalExport(_ input: ReviewExportInput) async throws -> Data {
        try await normalExportResult(input).data
    }

    func normalExportResult(_ input: ReviewExportInput) async throws -> (
        data: Data, findings: [RedactionFinding], value: ExportValue
    ) {
        try preflight(input)
        try validateReviewConsistency(input)
        try await validateCommentAnchors(input.threads, revision: input.manifest.revision)
        for tour in input.tours {
            try await validate(tour, manifest: input.manifest)
        }
        let root = try buildNormal(input)
        let scrubbed = redactor.scrub(root, applyStructuralCaps: false)
        let data = try canonicalData(scrubbed.value)
        guard data.count <= RTCExportLimits.maxNormalBytes else {
            throw RTCContractError.invalid("normal export size limit")
        }
        return (data, scrubbed.findings, scrubbed.value)
    }

    func canonicalData(_ value: ExportValue) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value) + Data([0x0a])
    }

    private func preflight(_ input: ReviewExportInput) throws {
        guard input.events.count <= RTCExportLimits.maxEvents,
            input.threads.count <= RTCExportLimits.maxThreads,
            input.tours.count <= RTCExportLimits.maxTours,
            input.manifest.files.count <= RTCConstants.maxFiles,
            input.progress.count <= RTCConstants.maxFiles
        else {
            throw RTCContractError.invalid("export count limit")
        }
        var messages = 0
        var estimatedBytes = 0
        var anchorsCount = 0
        var bulletItems = 0
        var diagramGroups = 0
        var diagramMembers = 0
        func addBytes(_ count: Int) throws {
            guard count >= 0, count <= RTCExportLimits.maxNormalInputTextBytes - estimatedBytes else {
                throw RTCContractError.invalid("export input byte limit")
            }
            estimatedBytes += count
        }
        func text(_ value: String) throws {
            try addBytes(value.utf8.count)
            var findings: [RedactionFinding] = []
            let scrubbed = redactor.scrubText(value, fieldID: "portable-text", findings: &findings)
            guard isPlainText(scrubbed) else { throw RTCContractError.invalid("prohibited portable text") }
        }
        func identifier(_ value: String) throws {
            guard isPortableIdentifier(value) else { throw RTCContractError.invalid("invalid portable identifier") }
            try addBytes(value.utf8.count)
        }
        func rich(_ value: RichText) throws {
            guard value.runs.count <= 256 else { throw RTCContractError.invalid("rich text count limit") }
            for run in value.runs {
                guard run.kind != .code else { throw RTCContractError.invalid("prohibited portable text") }
                try text(run.text.value)
            }
        }
        func anchor(_ value: ReviewAnchor) throws {
            anchorsCount += 1
            guard anchorsCount <= RTCConstants.maxAnchors else {
                throw RTCContractError.invalid("anchor count limit")
            }
            try validateRelativePath(value.path)
            try addBytes(value.path.utf8.count)
            if let oldPath = value.oldPath { try validateRelativePath(oldPath); try addBytes(oldPath.utf8.count) }
            if let symbol = value.symbol { try text(symbol.value) }
        }
        func diagram(_ value: DiagramDocument) throws {
            guard value.nodes.count <= RTCConstants.maxNodes,
                value.edges.count <= RTCConstants.maxEdges,
                value.groups.count <= RTCConstants.maxNodes
            else { throw RTCContractError.invalid("diagram count limit") }
            guard value.groups.count <= RTCExportLimits.maxTourGroups - diagramGroups else {
                throw RTCContractError.invalid("diagram group limit")
            }
            diagramGroups += value.groups.count
            try identifier(value.id.value); try text(value.title.value); try rich(value.summary)
            for node in value.nodes {
                try identifier(node.id.value); try text(node.label.value)
                for item in node.anchors { try anchor(item) }
            }
            for edge in value.edges {
                try identifier(edge.from.value); try identifier(edge.to.value)
                if let label = edge.label { try text(label.value) }
                for item in edge.anchors { try anchor(item) }
            }
            for group in value.groups {
                guard group.nodeIDs.count <= RTCExportLimits.maxTourGroupMembers - diagramMembers else {
                    throw RTCContractError.invalid("diagram member limit")
                }
                diagramMembers += group.nodeIDs.count
                try identifier(group.id.value); try text(group.label.value)
                for id in group.nodeIDs { try identifier(id.value) }
            }
            for item in value.anchors { try anchor(item) }
        }
        func block(_ value: TourBlock) throws {
            switch value {
            case .paragraph(let value): try rich(value)
            case .bulletList(let values):
                guard values.count <= RTCExportLimits.maxTourBulletItems - bulletItems else {
                    throw RTCContractError.invalid("tour bullet limit")
                }
                bulletItems += values.count
                for value in values { try rich(value) }
            case .callout(_, let value, let anchors):
                try rich(value); for item in anchors { try anchor(item) }
            case .diffSlice(let slice):
                try validateRelativePath(slice.path); try addBytes(slice.path.utf8.count)
            case .diagram(let value): try diagram(value)
            }
        }

        try addBytes(input.events.count * 256)
        try addBytes(input.threads.count * 256)
        try addBytes(input.manifest.files.count * 256)
        for event in input.events {
            for value in event.payload.values { try addBytes(value.utf8.count) }
            let payload = try decodedPayload(event)
            switch payload {
            case .threadCreated(let thread):
                try anchor(thread.anchor)
                for message in thread.messages { try rich(message.body) }
            case .threadMessageAdded(_, let message): try rich(message.body)
            case .fileProgressChanged(let progress):
                try validateRelativePath(progress.path); try addBytes(progress.path.utf8.count)
            case .feedback: break
            case .changesRequested(_, let summary):
                if let summary { try rich(summary) }
            case .approval, .close, .threadResolved, .threadReopened: break
            }
        }
        for file in input.manifest.files {
            try validateRelativePath(file.path); try addBytes(file.path.utf8.count)
            if let oldPath = file.oldPath { try validateRelativePath(oldPath); try addBytes(oldPath.utf8.count) }
        }
        for thread in input.threads {
            guard thread.messages.count <= RTCExportLimits.maxMessages - messages else {
                throw RTCContractError.invalid("message count limit")
            }
            messages += thread.messages.count
            try anchor(thread.anchor)
            for message in thread.messages { try addBytes(256); try rich(message.body) }
        }
        for progress in input.progress {
            try validateRelativePath(progress.path); try addBytes(progress.path.utf8.count)
        }
        for tour in input.tours {
            let bytesBeforeTour = estimatedBytes
            guard tour.chapters.count <= RTCConstants.maxChapters,
                tour.reviewFocuses.count <= RTCConstants.maxFocuses,
                tour.risks.count <= RTCConstants.maxFocuses,
                tour.overview.count <= RTCConstants.maxBlocks
            else { throw RTCContractError.invalid("tour count limit") }
            var blockCount = tour.overview.count
            for chapter in tour.chapters {
                guard chapter.blocks.count <= RTCConstants.maxBlocks - blockCount else {
                    throw RTCContractError.invalid("tour block limit")
                }
                blockCount += chapter.blocks.count
            }
            try addBytes(blockCount * 128)
            try text(tour.title.value)
            for value in tour.overview { try block(value) }
            for focus in tour.reviewFocuses {
                try text(focus.title.value); try rich(focus.body)
                for item in focus.anchors { try anchor(item) }
            }
            for chapter in tour.chapters {
                try identifier(chapter.id.value); try text(chapter.title.value); try rich(chapter.summary)
                for item in chapter.anchors { try anchor(item) }
                for value in chapter.blocks { try block(value) }
            }
            for risk in tour.risks {
                try text(risk.title.value); try rich(risk.body)
                for item in risk.anchors { try anchor(item) }
            }
            try validateTourCollections(tour, manifest: input.manifest)
            guard estimatedBytes - bytesBeforeTour <= RTCExportLimits.maxTourEncodedBytes else {
                throw RTCContractError.invalid("tour input byte limit")
            }
        }
    }

    private func validateReviewConsistency(_ input: ReviewExportInput) throws {
        let manifest = input.manifest
        guard manifest.schemaVersion == RTCConstants.schemaVersion,
            manifest.id == manifest.revision.reviewID,
            manifest.summary.files == manifest.files.count,
            Set(manifest.files.map(\.path)).count == manifest.files.count,
            Set(input.threads.map(\.id)).count == input.threads.count,
            Set(input.progress.map(\.path)).count == input.progress.count,
            Set(input.tours.map(\.id)).count == input.tours.count
        else {
            throw RTCContractError.invalid("inconsistent export review")
        }
        var expectedSequence = 1
        var eventIDs = Set<UUID>()
        for event in input.events.sorted(by: { $0.sequence < $1.sequence }) {
            guard event.schemaVersion == RTCConstants.schemaVersion,
                event.reviewID == manifest.id,
                event.revision == manifest.revision,
                event.sequence == expectedSequence,
                eventIDs.insert(event.id).inserted
            else {
                throw RTCContractError.invalid("inconsistent export event")
            }
            try validateEventPayload(event)
            expectedSequence += 1
        }
        for file in manifest.files {
            try validateRelativePath(file.path)
            if let oldPath = file.oldPath { try validateRelativePath(oldPath) }
        }
        for thread in input.threads {
            guard thread.reviewID == manifest.id, thread.revision == manifest.revision,
                thread.anchor.revision == manifest.revision
            else {
                throw RTCContractError.invalid("inconsistent export thread")
            }
            try validateRelativePath(thread.anchor.path)
            var expectedMessageSequence = 1
            for message in thread.messages.sorted(by: { $0.sequence < $1.sequence }) {
                guard message.sequence == expectedMessageSequence else {
                    throw RTCContractError.invalid("inconsistent export comment sequence")
                }
                expectedMessageSequence += 1
            }
        }
        let exportedPaths = Set(manifest.files.map(\.path))
        for item in input.progress {
            try validateRelativePath(item.path)
            guard exportedPaths.contains(item.path) else {
                throw RTCContractError.invalid("inconsistent export progress")
            }
        }
    }

    private func validateCommentAnchors(
        _ threads: [ReviewThread],
        revision: RevisionIdentity
    ) async throws {
        for thread in threads {
            guard thread.anchor.revision == revision,
                (try? await anchors.validate(thread.anchor)) == true
            else { throw RTCContractError.invalid("unresolved comment anchor") }
        }
    }

    private func validate(_ tour: TourDocument, manifest: ReviewManifest) async throws {
        let revision = manifest.revision
        switch await TourValidator().validate(tour, against: revision, anchors: anchors) {
        case .failure: throw RTCContractError.invalid("tour validation failed")
        case .success: break
        }
        for diagram in diagrams(in: tour) {
            do { _ = try DiagramValidator.validate(diagram) } catch {
                throw RTCContractError.invalid("diagram validation failed")
            }
            guard diagram.groups.count <= RTCExportLimits.maxTourGroups,
                diagram.groups.reduce(0, { $0 + $1.nodeIDs.count }) <= RTCExportLimits.maxTourGroupMembers
            else { throw RTCContractError.invalid("diagram export limit") }
            for anchor in diagram.anchors {
                guard anchor.revision == revision, (try? await anchors.validate(anchor)) == true else {
                    throw RTCContractError.invalid("unresolved diagram anchor")
                }
            }
        }
    }

    private func buildNormal(_ input: ReviewExportInput) throws -> ExportValue {
        let manifest = input.manifest
        return .object([
            "schemaVersion": .integer(RTCConstants.schemaVersion),
            "exportKind": .string("normal"),
            "review": .object([
                "id": .string(manifest.id.value),
                "revision": revision(manifest.revision),
                "createdAt": .string(date(manifest.createdAt)),
                "updatedAt": .string(date(manifest.updatedAt)),
                "status": .string(manifest.status.rawValue),
                "stale": .bool(manifest.stale),
                "summary": .object([
                    "files": .integer(manifest.summary.files),
                    "additions": .integer(manifest.summary.additions),
                    "deletions": .integer(manifest.summary.deletions),
                ]),
                "files": .array(
                    manifest.files.sorted {
                        ($0.path, $0.oldPath ?? "") < ($1.path, $1.oldPath ?? "")
                    }.map(file)
                ),
            ]),
            "events": .array(try input.events.sorted(by: { $0.sequence < $1.sequence }).map(event)),
            "comments": .array(input.threads.sorted(by: { $0.id.uuidString < $1.id.uuidString }).map(thread)),
            "decisions": .array(
                input.events
                    .filter { [.approval, .changesRequested, .close].contains($0.kind) }
                    .sorted(by: { $0.sequence < $1.sequence })
                    .map(decision)
            ),
            "progress": .array(input.progress.sorted(by: { $0.path < $1.path }).map(progress)),
            "tours": .array(input.tours.sorted(by: { $0.id.uuidString < $1.id.uuidString }).map(tour)),
        ])
    }

    private func revision(_ value: RevisionIdentity) -> ExportValue {
        .object(["baseSHA": .string(value.baseSHA), "headSHA": .string(value.headSHA)])
    }

    private func file(_ value: DiffArtifact) -> ExportValue {
        var fields: [String: ExportValue] = [
            "path": .string(value.path),
            "status": .string(value.status.rawValue),
            "additions": .integer(value.additions),
            "deletions": .integer(value.deletions),
            "binary": .bool(value.binary),
            "truncated": .bool(value.truncated),
        ]
        if let oldPath = value.oldPath { fields["oldPath"] = .string(oldPath) }
        if let oldLineCount = value.oldLineCount { fields["oldLineCount"] = .integer(oldLineCount) }
        if let newLineCount = value.newLineCount { fields["newLineCount"] = .integer(newLineCount) }
        return .object(fields)
    }

    private func event(_ value: ReviewEvent) throws -> ExportValue {
        var payload: [String: ExportValue] = [:]
        switch try decodedPayload(value) {
        case .threadCreated(let thread):
            payload["threadID"] = .string(thread.id.uuidString.lowercased())
        case .threadMessageAdded(let threadID, let message):
            payload["threadID"] = .string(threadID.uuidString.lowercased())
            payload["messageID"] = .string(message.id.uuidString.lowercased())
        case .fileProgressChanged(let progress):
            payload["path"] = .string(progress.path)
            payload["viewed"] = .bool(progress.viewed)
            payload["version"] = .integer(progress.version)
        case .feedback(let threadIDs):
            payload["threadIDs"] = .array(threadIDs.map { .string($0.uuidString.lowercased()) })
        case .changesRequested(let threadIDs, let summary):
            payload["threadIDs"] = .array(threadIDs.map { .string($0.uuidString.lowercased()) })
            if let summary { payload["summary"] = richText(summary) }
        case .approval(let warnings):
            payload["headSHA"] = .string(value.revision.headSHA)
            payload["warnings"] = .array(warnings.map { .string($0) })
        case .close:
            payload["headSHA"] = .string(value.revision.headSHA)
        case .threadResolved(let threadID), .threadReopened(let threadID):
            payload["threadID"] = .string(threadID.uuidString.lowercased())
        }
        return .object([
            "id": .string(value.id.uuidString.lowercased()),
            "sequence": .integer(value.sequence),
            "kind": .string(value.kind.rawValue),
            "createdAt": .string(date(value.createdAt)),
            "payload": .object(payload),
        ])
    }

    private func validateEventPayload(_ event: ReviewEvent) throws {
        _ = try decodedPayload(event)
    }

    private func decodedPayload(_ event: ReviewEvent) throws -> DecodedReviewEventPayload {
        switch event.kind {
        case .threadCreated:
            let value = try decodePayload(
                ThreadCreatedExportPayload.self, event: event, required: ["thread"])
            guard value.thread.id == event.id,
                value.thread.reviewID == event.reviewID,
                value.thread.revision == event.revision,
                value.thread.messages.first?.id == event.id
            else { throw RTCContractError.invalid("invalid thread creation payload") }
            return .threadCreated(value.thread)
        case .threadMessageAdded:
            let value = try decodePayload(
                ThreadMessageAddedExportPayload.self, event: event, required: ["message", "threadID"])
            guard value.message.id == event.id else {
                throw RTCContractError.invalid("invalid thread message payload")
            }
            return .threadMessageAdded(value.threadID, value.message)
        case .fileProgressChanged:
            let value = try decodePayload(
                FileProgressExportPayload.self, event: event, required: ["progress"])
            guard value.progress.version > 0 else {
                throw RTCContractError.invalid("invalid progress payload")
            }
            return .fileProgressChanged(value.progress)
        case .feedback:
            let value = try decodePayload(
                ThreadIDsExportPayload.self, event: event, required: ["threadIDs"])
            try validateThreadIDs(value.threadIDs, allowEmpty: false)
            return .feedback(value.threadIDs)
        case .changesRequested:
            let value = try decodePayload(
                RequestChangesExportPayload.self, event: event,
                required: ["threadIDs"], optional: ["summary"])
            try validateThreadIDs(value.threadIDs, allowEmpty: true)
            guard !value.threadIDs.isEmpty || value.summary != nil else {
                throw RTCContractError.invalid("empty changes payload")
            }
            return .changesRequested(value.threadIDs, value.summary)
        case .approval:
            let value = try decodePayload(
                ApprovalExportPayload.self, event: event, required: ["warnings"])
            try validateWarnings(value.warnings)
            return .approval(value.warnings)
        case .close:
            try validatePayloadObject(event, required: [])
            return .close
        case .threadResolved:
            let value = try decodePayload(
                ThreadIDExportPayload.self, event: event, required: ["threadID"])
            return .threadResolved(value.threadID)
        case .threadReopened:
            let value = try decodePayload(
                ThreadIDExportPayload.self, event: event, required: ["threadID"])
            return .threadReopened(value.threadID)
        }
    }

    private func decodePayload<T: Decodable>(
        _ type: T.Type,
        event: ReviewEvent,
        required: Set<String>,
        optional: Set<String> = []
    ) throws -> T {
        let data = try payloadData(event)
        try validatePayloadObject(data, required: required, optional: optional)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do { return try decoder.decode(type, from: data) } catch {
            throw RTCContractError.invalid("invalid event payload")
        }
    }

    private func validatePayloadObject(
        _ event: ReviewEvent,
        required: Set<String>,
        optional: Set<String> = []
    ) throws {
        try validatePayloadObject(try payloadData(event), required: required, optional: optional)
    }

    private func validatePayloadObject(
        _ data: Data,
        required: Set<String>,
        optional: Set<String> = []
    ) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RTCContractError.invalid("invalid event payload shape")
        }
        let keys = Set(object.keys)
        guard required.isSubset(of: keys), keys.isSubset(of: required.union(optional))
        else { throw RTCContractError.invalid("invalid event payload shape") }
    }

    private func payloadData(_ event: ReviewEvent) throws -> Data {
        guard event.payload.count == 2,
            event.payload["version"] == "1",
            let string = event.payload["data"],
            let data = string.data(using: .utf8),
            data.count <= RTCConstants.maxRequestBytes
        else { throw RTCContractError.invalid("invalid event payload envelope") }
        do {
            let object = try JSONSerialization.jsonObject(with: data)
            let canonical = try JSONSerialization.data(
                withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
            guard canonical == data else { throw RTCContractError.invalid("noncanonical event payload") }
        } catch let error as RTCContractError {
            throw error
        } catch {
            throw RTCContractError.invalid("invalid event payload")
        }
        return data
    }

    private func validateThreadIDs(_ values: [UUID], allowEmpty: Bool) throws {
        let sorted = values.sorted { $0.uuidString < $1.uuidString }
        guard (allowEmpty || !values.isEmpty), values.count <= RTCConstants.maxAnchors,
            values == sorted, Set(values).count == values.count
        else { throw RTCContractError.invalid("invalid thread IDs") }
    }

    private func validateWarnings(_ warnings: [String]) throws {
        guard warnings.count <= RTCConstants.maxFiles + 1,
            warnings == warnings.sorted(), Set(warnings).count == warnings.count,
            warnings.allSatisfy({ warning in
                if warning == "draft" || warning == "open" { return true }
                guard warning.hasPrefix("unviewedFiles:"),
                    let count = Int(warning.dropFirst("unviewedFiles:".count))
                else { return false }
                return count > 0 && count <= RTCConstants.maxFiles
            })
        else { throw RTCContractError.invalid("invalid approval warnings") }
    }

    private func decision(_ value: ReviewEvent) -> ExportValue {
        .object([
            "id": .string(value.id.uuidString.lowercased()),
            "sequence": .integer(value.sequence),
            "kind": .string(value.kind.rawValue),
            "headSHA": .string(value.revision.headSHA),
            "createdAt": .string(date(value.createdAt)),
        ])
    }

    private func thread(_ value: ReviewThread) -> ExportValue {
        var fields: [String: ExportValue] = [
            "id": .string(value.id.uuidString.lowercased()),
            "anchor": anchor(value.anchor),
            "state": .string(value.state.rawValue),
            "messages": .array(value.messages.sorted(by: { $0.sequence < $1.sequence }).map(message)),
        ]
        if let id = value.promotedConversationID {
            fields["promotedConversationID"] = .string(id.uuidString.lowercased())
        }
        if let id = value.promotedMessageID { fields["promotedMessageID"] = .string(id.uuidString.lowercased()) }
        return .object(fields)
    }

    private func message(_ value: ThreadMessage) -> ExportValue {
        .object([
            "id": .string(value.id.uuidString.lowercased()),
            "sequence": .integer(value.sequence),
            "author": .string(value.author.rawValue),
            "body": richText(value.body),
            "createdAt": .string(date(value.createdAt)),
        ])
    }

    private func progress(_ value: FileProgress) -> ExportValue {
        .object(["path": .string(value.path), "viewed": .bool(value.viewed), "version": .integer(value.version)])
    }

    private func tour(_ value: TourDocument) -> ExportValue {
        .object([
            "schemaVersion": .integer(value.schemaVersion),
            "id": .string(value.id.uuidString.lowercased()),
            "revision": revision(value.revision),
            "producer": .string(value.producer.rawValue),
            "inputDigest": .string(value.inputDigest.hex),
            "title": .string(value.title.value),
            "overview": .array(value.overview.map(block)),
            "reviewFocuses": .array(value.reviewFocuses.map(focus)),
            "chapters": .array(value.chapters.map(chapter)),
            "risks": .array(value.risks.map(focus)),
        ])
    }

    private func chapter(_ value: TourChapter) -> ExportValue {
        .object([
            "id": .string(value.id.value),
            "title": .string(value.title.value),
            "summary": richText(value.summary),
            "anchors": .array(value.anchors.map(anchor)),
            "blocks": .array(value.blocks.map(block)),
        ])
    }

    private func focus(_ value: ReviewFocus) -> ExportValue {
        .object([
            "title": .string(value.title.value),
            "body": richText(value.body),
            "anchors": .array(value.anchors.map(anchor)),
        ])
    }

    private func block(_ value: TourBlock) -> ExportValue {
        switch value {
        case .paragraph(let text):
            return .object(["kind": .string("paragraph"), "text": richText(text)])
        case .bulletList(let items):
            return .object(["kind": .string("bulletList"), "items": .array(items.map(richText))])
        case .callout(let kind, let text, let anchors):
            return .object([
                "kind": .string("callout"),
                "calloutKind": .string(kind.rawValue),
                "text": richText(text),
                "anchors": .array(anchors.map(anchor)),
            ])
        case .diffSlice(let slice):
            return .object([
                "kind": .string("diffSlice"),
                "path": .string(slice.path),
                "hunkIndex": .integer(slice.hunkIndex),
                "side": .string(slice.side.rawValue),
                "startLine": .integer(slice.startLine),
                "endLine": .integer(slice.endLine),
                "startContextHash": .string(slice.startContextHash.hex),
                "endContextHash": .string(slice.endContextHash.hex),
            ])
        case .diagram(let diagram):
            return .object(["kind": .string("diagram"), "diagram": self.diagram(diagram)])
        }
    }

    private func diagram(_ value: DiagramDocument) -> ExportValue {
        .object([
            "id": .string(value.id.value),
            "kind": .string(value.kind.rawValue),
            "title": .string(value.title.value),
            "summary": richText(value.summary),
            "nodes": .array(
                value.nodes.map { node in
                    .object([
                        "id": .string(node.id.value),
                        "label": .string(node.label.value),
                        "role": .string(node.role.rawValue),
                        "anchors": .array(node.anchors.map(anchor)),
                    ])
                }),
            "edges": .array(
                value.edges.map { edge in
                    var fields: [String: ExportValue] = [
                        "from": .string(edge.from.value),
                        "to": .string(edge.to.value),
                        "role": .string(edge.role.rawValue),
                        "anchors": .array(edge.anchors.map(anchor)),
                    ]
                    if let label = edge.label { fields["label"] = .string(label.value) }
                    return .object(fields)
                }),
            "groups": .array(
                value.groups.map { group in
                    .object([
                        "id": .string(group.id.value),
                        "label": .string(group.label.value),
                        "nodeIDs": .array(group.nodeIDs.map { .string($0.value) }),
                    ])
                }),
            "anchors": .array(value.anchors.map(anchor)),
        ])
    }

    private func anchor(_ value: ReviewAnchor) -> ExportValue {
        var fields: [String: ExportValue] = [
            "revision": revision(value.revision),
            "path": .string(value.path),
            "scope": .string(value.scope.rawValue),
        ]
        if let oldPath = value.oldPath { fields["oldPath"] = .string(oldPath) }
        if let side = value.side { fields["side"] = .string(side.rawValue) }
        if let startLine = value.startLine { fields["startLine"] = .integer(startLine) }
        if let endLine = value.endLine { fields["endLine"] = .integer(endLine) }
        if let digest = value.startContextHash { fields["startContextHash"] = .string(digest.hex) }
        if let digest = value.endContextHash { fields["endContextHash"] = .string(digest.hex) }
        if let hunkIndex = value.hunkIndex { fields["hunkIndex"] = .integer(hunkIndex) }
        if let symbol = value.symbol { fields["symbol"] = .string(symbol.value) }
        return .object(fields)
    }

    private func richText(_ value: RichText) -> ExportValue {
        .object([
            "runs": .array(
                value.runs.map { run in
                    .object(["kind": .string(run.kind.rawValue), "text": .string(run.text.value)])
                })
        ])
    }

    private func diagrams(in tour: TourDocument) -> [DiagramDocument] {
        (tour.overview + tour.chapters.flatMap(\.blocks)).compactMap { block in
            if case .diagram(let diagram) = block { return diagram }
            return nil
        }
    }

    private func validateTourCollections(_ tour: TourDocument, manifest: ReviewManifest) throws {
        var blocks = 0
        var bulletItems = 0
        var anchors =
            tour.reviewFocuses.reduce(0) { $0 + $1.anchors.count }
            + tour.risks.reduce(0) { $0 + $1.anchors.count }
            + tour.chapters.reduce(0) { $0 + $1.anchors.count }
        func validateBlock(_ block: TourBlock) throws {
            blocks += 1
            switch block {
            case .paragraph: break
            case .bulletList(let items): bulletItems += items.count
            case .callout(_, _, let refs): anchors += refs.count
            case .diagram(let diagram):
                anchors += diagram.anchors.count
                anchors += diagram.nodes.reduce(0) { $0 + $1.anchors.count }
                anchors += diagram.edges.reduce(0) { $0 + $1.anchors.count }
            case .diffSlice(let slice):
                guard let file = manifest.files.first(where: { $0.path == slice.path }),
                    !file.binary, !file.truncated,
                    file.hunks.indices.contains(slice.hunkIndex),
                    slice.startLine > 0, slice.endLine >= slice.startLine,
                    slice.endLine < Int.max,
                    slice.endLine - slice.startLine <= RTCConstants.maxProseBytes
                else { throw RTCContractError.invalid("ungrounded diff slice") }
                let hunk = file.hunks[slice.hunkIndex]
                let startIndex = hunk.lines.firstIndex(where: { line in
                    let number = slice.side == .old ? line.oldLine : line.newLine
                    return number == slice.startLine && line.contextHash == slice.startContextHash
                })
                let endIndex = hunk.lines.lastIndex(where: { line in
                    let number = slice.side == .old ? line.oldLine : line.newLine
                    return number == slice.endLine && line.contextHash == slice.endContextHash
                })
                guard let startIndex, let endIndex, startIndex <= endIndex else {
                    throw RTCContractError.invalid("diff slice outside exact hunk")
                }
                var expectedLine = slice.startLine
                for line in hunk.lines[startIndex...endIndex] {
                    let number = slice.side == .old ? line.oldLine : line.newLine
                    guard number == expectedLine else {
                        throw RTCContractError.invalid("diff slice is not contiguous on one side")
                    }
                    expectedLine += 1
                }
                guard expectedLine == slice.endLine + 1 else {
                    throw RTCContractError.invalid("diff slice outside exact hunk")
                }
            }
        }
        for block in tour.overview { try validateBlock(block) }
        for chapter in tour.chapters { for block in chapter.blocks { try validateBlock(block) } }
        guard blocks <= RTCConstants.maxBlocks,
            bulletItems <= RTCExportLimits.maxTourBulletItems,
            anchors <= RTCConstants.maxAnchors
        else { throw RTCContractError.invalid("tour aggregate limit") }
    }

    private func isPlainText(_ value: String) -> Bool {
        var candidate = value
        candidate = candidate.replacingOccurrences(
            of: "=<redacted:credential>", with: " redacted")
        for marker in [
            "<redacted:path>", "<redacted:credential>", "<redacted:sensitive-field>",
            "<truncated:size>", "<truncated:depth>",
        ] {
            candidate = candidate.replacingOccurrences(of: marker, with: "redacted")
        }
        let punctuation = CharacterSet(charactersIn: " .,_-'\"?")
        return candidate.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || punctuation.contains($0)
        }
    }

    private func isPortableIdentifier(_ value: String) -> Bool {
        let first = CharacterSet.alphanumerics
        let rest = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard let scalar = value.unicodeScalars.first, first.contains(scalar) else { return false }
        return value.unicodeScalars.dropFirst().allSatisfy(rest.contains)
    }

    private func validateRelativePath(_ path: String) throws {
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 ._-/@()+,")
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("//"),
            !path.split(separator: "/").contains(".."),
            path.unicodeScalars.allSatisfy(allowed.contains),
            path.utf8.count <= RTCConstants.maxPathBytes
        else {
            throw RTCContractError.invalid("unsafe export path")
        }
    }

    private func date(_ value: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: value)
    }
}
