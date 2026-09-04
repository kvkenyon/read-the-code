import Foundation
import RTCContracts
import RTCTour

public enum StrictTourDecoder {
    public static func decode(_ data: Data) throws -> TourDocument {
        guard data.count <= RTCConstants.maxDocumentBytes else {
            throw TourIntegrationError.invalidPayload
        }
        do {
            try RTCJSONPreflight.validate(data, maxDepth: 32, maxItems: 50_000)
        } catch {
            throw TourIntegrationError.invalidPayload
        }
        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw TourIntegrationError.invalidPayload
        }
        try validateDocument(root)
        do { return try JSONDecoder().decode(TourDocument.self, from: data) } catch {
            throw TourIntegrationError.invalidPayload
        }
    }

    public static func decodeWorkerEnvelope(_ data: Data) throws -> DecodedWorkerTourEnvelope {
        guard data.count <= RTCConstants.maxDocumentBytes else { throw TourIntegrationError.invalidPayload }
        do { try RTCJSONPreflight.validate(data, maxDepth: 32, maxItems: 50_000) } catch {
            throw TourIntegrationError.invalidPayload
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TourIntegrationError.invalidPayload
        }
        try keys(root, exactly: ["schemaVersion", "document", "attribution"])
        guard root["schemaVersion"] as? Int == RTCConstants.schemaVersion else {
            throw TourIntegrationError.invalidPayload
        }
        let attributionObject = try object(root["attribution"])
        try keys(
            attributionObject,
            allowed: ["identityLabel", "generatorName", "generatorVersion"],
            required: ["identityLabel"])
        let documentData = try JSONSerialization.data(
            withJSONObject: object(root["document"]), options: [.sortedKeys])
        let attributionData = try JSONSerialization.data(
            withJSONObject: attributionObject, options: [.sortedKeys])
        let document = try decode(documentData)
        let attribution: WorkerTourAttribution
        do { attribution = try JSONDecoder().decode(WorkerTourAttribution.self, from: attributionData) } catch {
            throw TourIntegrationError.invalidPayload
        }
        return DecodedWorkerTourEnvelope(
            document: document, rawDocumentPayload: documentData, attribution: attribution)
    }

    private static func validateDocument(_ value: [String: Any]) throws {
        try keys(
            value,
            exactly: [
                "schemaVersion", "id", "revision", "producer", "inputDigest", "title", "overview", "reviewFocuses",
                "chapters", "risks",
            ])
        try validateRevision(object(value["revision"]))
        let overview = try array(value["overview"]), focuses = try array(value["reviewFocuses"])
        let chapters = try array(value["chapters"]), risks = try array(value["risks"])
        guard !overview.isEmpty, overview.count <= RTCConstants.maxBlocks,
            focuses.count <= RTCConstants.maxFocuses, chapters.count <= RTCConstants.maxChapters,
            risks.count <= RTCConstants.maxFocuses
        else { throw TourIntegrationError.invalidPayload }
        try overview.forEach(validateBlock)
        try focuses.forEach { try validateFocus(object($0)) }
        try chapters.forEach { try validateChapter(object($0)) }
        try risks.forEach { try validateFocus(object($0)) }
    }

    private static func validateRevision(_ value: [String: Any]) throws {
        try keys(value, exactly: ["repositoryPath", "baseSHA", "headSHA"])
    }

    private static func validateRichText(_ value: [String: Any]) throws {
        try keys(value, exactly: ["runs"])
        let runs = try array(value["runs"])
        guard runs.count <= 256 else { throw TourIntegrationError.invalidPayload }
        try runs.forEach { try keys(object($0), exactly: ["kind", "text"]) }
    }

    private static func validateAnchor(_ value: [String: Any]) throws {
        try keys(
            value,
            allowed: [
                "revision", "path", "oldPath", "scope", "side", "startLine", "endLine", "startContextHash",
                "endContextHash", "hunkIndex", "symbol",
            ],
            required: ["revision", "path", "scope"])
        try validateRevision(object(value["revision"]))
    }

    private static func validateFocus(_ value: [String: Any]) throws {
        try keys(value, exactly: ["title", "body", "anchors"])
        try validateRichText(object(value["body"]))
        try array(value["anchors"]).forEach { try validateAnchor(object($0)) }
    }

    private static func validateChapter(_ value: [String: Any]) throws {
        try keys(value, exactly: ["id", "title", "summary", "anchors", "blocks"])
        try validateRichText(object(value["summary"]))
        try array(value["anchors"]).forEach { try validateAnchor(object($0)) }
        try array(value["blocks"]).forEach(validateBlock)
    }

    private static func validateBlock(_ raw: Any) throws {
        let value = try object(raw)
        guard value.count == 1, let name = value.keys.first,
            ["paragraph", "bulletList", "callout", "diffSlice", "diagram"].contains(name)
        else {
            throw TourIntegrationError.invalidPayload
        }
        let payload = try object(value[name])
        switch name {
        case "paragraph":
            try keys(payload, exactly: ["_0"]); try validateRichText(object(payload["_0"]))
        case "bulletList":
            try keys(payload, exactly: ["_0"])
            try array(payload["_0"]).forEach { try validateRichText(object($0)) }
        case "callout":
            try keys(payload, exactly: ["_0", "_1", "_2"])
            try validateRichText(object(payload["_1"]))
            try array(payload["_2"]).forEach { try validateAnchor(object($0)) }
        case "diffSlice":
            try keys(payload, exactly: ["_0"])
            try keys(
                object(payload["_0"]),
                allowed: ["path", "hunkIndex", "side", "startLine", "endLine", "startContextHash", "endContextHash"],
                required: ["path", "hunkIndex", "side", "startLine", "endLine", "startContextHash", "endContextHash"])
        case "diagram":
            try keys(payload, exactly: ["_0"]); try validateDiagram(object(payload["_0"]))
        default: throw TourIntegrationError.invalidPayload
        }
    }

    private static func validateDiagram(_ value: [String: Any]) throws {
        try keys(value, exactly: ["id", "kind", "title", "summary", "nodes", "edges", "groups", "anchors"])
        try validateRichText(object(value["summary"]))
        let anchors = try array(value["anchors"]), nodes = try array(value["nodes"])
        let edges = try array(value["edges"]), groups = try array(value["groups"])
        guard anchors.count <= RTCConstants.maxAnchors, nodes.count <= RTCConstants.maxNodes,
            edges.count <= RTCConstants.maxEdges, groups.count <= RTCConstants.maxNodes
        else {
            throw TourIntegrationError.invalidPayload
        }
        try anchors.forEach { try validateAnchor(object($0)) }
        try nodes.forEach {
            let node = try object($0); try keys(node, exactly: ["id", "label", "role", "anchors"])
            try array(node["anchors"]).forEach { try validateAnchor(object($0)) }
        }
        try edges.forEach {
            let edge = try object($0)
            try keys(
                edge, allowed: ["from", "to", "label", "role", "anchors"],
                required: ["from", "to", "role", "anchors"])
            try array(edge["anchors"]).forEach { try validateAnchor(object($0)) }
        }
        try groups.forEach {
            try keys(object($0), exactly: ["id", "label", "nodeIDs"])
        }
    }

    private static func keys(_ value: [String: Any], exactly expected: Set<String>) throws {
        guard Set(value.keys) == expected else { throw TourIntegrationError.invalidPayload }
    }

    private static func keys(_ value: [String: Any], allowed: Set<String>, required: Set<String>) throws {
        let actual = Set(value.keys)
        guard actual.isSubset(of: allowed), required.isSubset(of: actual) else {
            throw TourIntegrationError.invalidPayload
        }
    }

    private static func object(_ value: Any?) throws -> [String: Any] {
        guard let result = value as? [String: Any] else { throw TourIntegrationError.invalidPayload }
        return result
    }

    private static func array(_ value: Any?) throws -> [Any] {
        guard let result = value as? [Any] else { throw TourIntegrationError.invalidPayload }
        return result
    }
}

public struct DecodedWorkerTourEnvelope: Sendable {
    public let document: TourDocument
    public let rawDocumentPayload: Data
    public let attribution: WorkerTourAttribution
}

public struct TourValidationBoundary: Sendable {
    private let validator: TourValidator
    public init(validator: TourValidator = TourValidator()) { self.validator = validator }

    public func validate(
        rawPayload: Data, against revision: RevisionIdentity,
        expectedInputDigest: SHA256Digest, anchors: AnchorArtifactSource,
        provenance: TourDocumentProvenance
    ) async throws -> ValidatedTourDocument {
        let document = try StrictTourDecoder.decode(rawPayload)
        guard producer(for: provenance.provider.kind) == document.producer else {
            throw TourIntegrationError.invalidPayload
        }
        guard
            case .success = await validator.validate(
                document, against: revision, expectedInputDigest: expectedInputDigest,
                anchors: anchors)
        else { throw TourIntegrationError.invalidPayload }
        return ValidatedTourDocument(
            document: document, rawPayload: rawPayload, provenance: provenance)
    }

    public func replay(
        _ record: PersistedTourRecord, against revision: RevisionIdentity,
        expectedInputDigest: SHA256Digest, anchors: AnchorArtifactSource
    ) async throws -> ValidatedTourDocument {
        try record.verifyIntegrity()
        guard record.revision == revision, record.contextDigest == expectedInputDigest else {
            throw TourIntegrationError.revisionMismatch
        }
        return try await validate(
            rawPayload: record.rawPayload, against: revision,
            expectedInputDigest: expectedInputDigest, anchors: anchors,
            provenance: record.provenance)
    }

    private func producer(for kind: TourProviderKind) -> TourProducer {
        switch kind {
        case .workerSupplied: .workerSupplied
        case .ollama, .openAICompatible: .localModel
        case .deterministicFallback: .deterministicFallback
        }
    }
}
