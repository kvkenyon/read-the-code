import Foundation
import RTCContracts

public enum StrictTourDecoder {
    public static func decode(_ data: Data) throws -> TourDocument {
        guard data.count <= RTCConstants.maxDocumentBytes,
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw TourIntegrationError.invalidPayload
        }
        try validateDocument(root)
        do { return try JSONDecoder().decode(TourDocument.self, from: data) } catch {
            throw TourIntegrationError.invalidPayload
        }
    }

    private static func validateDocument(_ value: [String: Any]) throws {
        try keys(
            value,
            exactly: [
                "schemaVersion", "id", "revision", "producer", "inputDigest", "title", "overview", "reviewFocuses",
                "chapters", "risks",
            ])
        try validateRevision(object(value["revision"]))
        try array(value["overview"]).forEach(validateBlock)
        try array(value["reviewFocuses"]).forEach { try validateFocus(object($0)) }
        try array(value["chapters"]).forEach { try validateChapter(object($0)) }
        try array(value["risks"]).forEach { try validateFocus(object($0)) }
    }

    private static func validateRevision(_ value: [String: Any]) throws {
        try keys(value, exactly: ["repositoryPath", "baseSHA", "headSHA"])
    }

    private static func validateRichText(_ value: [String: Any]) throws {
        try keys(value, exactly: ["runs"])
        try array(value["runs"]).forEach { try keys(object($0), exactly: ["kind", "text"]) }
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
            try keys(object(payload["_0"]), exactly: ["path", "hunkIndex", "startLine", "endLine"])
        case "diagram":
            try keys(payload, exactly: ["_0"]); try validateDiagram(object(payload["_0"]))
        default: throw TourIntegrationError.invalidPayload
        }
    }

    private static func validateDiagram(_ value: [String: Any]) throws {
        try keys(value, exactly: ["id", "kind", "title", "summary", "nodes", "edges", "groups", "anchors"])
        try validateRichText(object(value["summary"]))
        try array(value["anchors"]).forEach { try validateAnchor(object($0)) }
        try array(value["nodes"]).forEach {
            let node = try object($0); try keys(node, exactly: ["id", "label", "role", "anchors"])
            try array(node["anchors"]).forEach { try validateAnchor(object($0)) }
        }
        try array(value["edges"]).forEach {
            let edge = try object($0)
            try keys(
                edge, allowed: ["from", "to", "label", "role", "anchors"],
                required: ["from", "to", "role", "anchors"])
            try array(edge["anchors"]).forEach { try validateAnchor(object($0)) }
        }
        try array(value["groups"]).forEach {
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
