import Foundation

@_spi(Testing)
public struct ExportRedactor: Sendable {
    private let sensitiveKey = try! NSRegularExpression(
        pattern:
            #"(?i)(capability|credential|password|secret|token|keychain|raw.?prompt|environment|(^|[^a-z])env([^a-z]|$)|repository.?path|state.?path|socket.?path|wake.?file|endpoint|stderr|process.?arguments)"#
    )
    private let absolutePath = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9:])/(?:[^\s\"'<>]+/?)+"#
    )
    private let fileURL = try! NSRegularExpression(pattern: #"(?i)file://[^\s\"'<>]+"#)
    private let bearer = try! NSRegularExpression(pattern: #"(?i)\bBearer\s+[^\s,;]+"#)
    private let assignment = try! NSRegularExpression(
        pattern: #"(?i)\b(token|key|secret|password|credential)\s*[=:]\s*[^\s,;]+"#
    )

    public init() {}

    @_spi(Testing)
    public func scrub(
        _ value: ExportValue,
        applyStructuralCaps: Bool = true
    ) -> (value: ExportValue, findings: [RedactionFinding]) {
        var findings: [RedactionFinding] = []
        let scrubbed = scrub(
            value,
            path: "$",
            depth: 0,
            applyStructuralCaps: applyStructuralCaps,
            findings: &findings
        )
        return (scrubbed, findings)
    }

    func scrubText(_ value: String, fieldID: String, findings: inout [RedactionFinding]) -> String {
        var result = truncate(value, fieldID: fieldID, findings: &findings)
        for candidate in canonicalCandidates(result) where candidate != result {
            if matches(fileURL, candidate) || matches(absolutePath, candidate) {
                findings.append(RedactionFinding(fieldID: fieldID, category: "encoded-path"))
                return "<redacted:path>"
            }
            if matches(bearer, candidate) || matches(assignment, candidate) {
                findings.append(RedactionFinding(fieldID: fieldID, category: "encoded-credential"))
                return "<redacted:credential>"
            }
        }
        result = replace(
            fileURL, in: result, with: "<redacted:path>", category: "path", fieldID: fieldID, findings: &findings)
        result = replace(
            absolutePath, in: result, with: "<redacted:path>", category: "path", fieldID: fieldID, findings: &findings)
        result = replace(
            bearer, in: result, with: "Bearer <redacted:credential>", category: "credential", fieldID: fieldID,
            findings: &findings)
        result = replace(
            assignment, in: result, with: "$1=<redacted:credential>", category: "credential", fieldID: fieldID,
            findings: &findings)
        return result
    }

    private func scrub(
        _ value: ExportValue,
        path: String,
        depth: Int,
        applyStructuralCaps: Bool,
        findings: inout [RedactionFinding]
    ) -> ExportValue {
        guard !applyStructuralCaps || depth <= RTCExportLimits.maxDiagnosticDepth else {
            findings.append(RedactionFinding(fieldID: path, category: "depth-cap"))
            return .string("<truncated:depth>")
        }
        switch value {
        case .null, .bool, .integer, .number: return value
        case .string(let string): return .string(scrubText(string, fieldID: path, findings: &findings))
        case .array(let values):
            let limit = applyStructuralCaps ? RTCExportLimits.maxDiagnosticCollectionItems : values.count
            let kept = values.prefix(limit)
            if kept.count != values.count {
                findings.append(RedactionFinding(fieldID: path, category: "count-cap"))
            }
            return .array(
                kept.enumerated().map { index, child in
                    scrub(
                        child,
                        path: "\(path)[\(index)]",
                        depth: depth + 1,
                        applyStructuralCaps: applyStructuralCaps,
                        findings: &findings
                    )
                })
        case .object(let object):
            var result: [String: ExportValue] = [:]
            let keys = object.keys.sorted()
            let limit = applyStructuralCaps ? RTCExportLimits.maxDiagnosticCollectionItems : keys.count
            let kept = keys.prefix(limit)
            if kept.count != keys.count {
                findings.append(RedactionFinding(fieldID: path, category: "count-cap"))
            }
            var redactedKeyIndex = 0
            for (ordinal, key) in kept.enumerated() {
                // Keys are schema-owned. Finding identifiers use only their stable
                // ordinal so an accidentally sensitive input key is never echoed.
                let childPath = "\(path).field[\(ordinal)]"
                if matches(sensitiveKey, key) {
                    redactedKeyIndex += 1
                    let redactedKey = unique("redacted-field-\(redactedKeyIndex)", in: result)
                    result[redactedKey] = .string("<redacted:sensitive-field>")
                    findings.append(RedactionFinding(fieldID: childPath, category: "sensitive-key"))
                    continue
                }
                var safeKeyFindings: [RedactionFinding] = []
                let safeKey = scrubText(key, fieldID: childPath, findings: &safeKeyFindings)
                findings.append(contentsOf: safeKeyFindings)
                let uniqueKey = unique(safeKey, in: result)
                result[uniqueKey] = scrub(
                    object[key]!,
                    path: childPath,
                    depth: depth + 1,
                    applyStructuralCaps: applyStructuralCaps,
                    findings: &findings
                )
            }
            return .object(result)
        }
    }

    private func truncate(_ value: String, fieldID: String, findings: inout [RedactionFinding]) -> String {
        guard value.utf8.count > RTCExportLimits.maxDiagnosticStringBytes else { return value }
        findings.append(RedactionFinding(fieldID: fieldID, category: "size-cap"))
        var bytes = Array(value.utf8.prefix(RTCExportLimits.maxDiagnosticStringBytes))
        while String(bytes: bytes, encoding: .utf8) == nil { bytes.removeLast() }
        return String(decoding: bytes, as: UTF8.self) + "<truncated:size>"
    }

    private func replace(
        _ expression: NSRegularExpression,
        in value: String,
        with replacement: String,
        category: String,
        fieldID: String,
        findings: inout [RedactionFinding]
    ) -> String {
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard expression.firstMatch(in: value, range: range) != nil else { return value }
        findings.append(RedactionFinding(fieldID: fieldID, category: category))
        return expression.stringByReplacingMatches(in: value, range: range, withTemplate: replacement)
    }

    private func matches(_ expression: NSRegularExpression, _ value: String) -> Bool {
        expression.firstMatch(in: value, range: NSRange(value.startIndex..<value.endIndex, in: value)) != nil
    }

    private func canonicalCandidates(_ value: String) -> [String] {
        var candidates = [value.precomposedStringWithCompatibilityMapping]
        if let decoded = value.removingPercentEncoding { candidates.append(decoded) }
        let compact = value.filter { !$0.isWhitespace }
        if compact.count >= 12, compact.count % 4 == 0,
            let data = Data(base64Encoded: compact),
            let decoded = String(data: data, encoding: .utf8)
        {
            candidates.append(decoded)
        }
        // A small deterministic skeleton covers common credential-key
        // confusables without pretending to implement full UTS #39.
        candidates.append(
            candidates[0].replacingOccurrences(of: "о", with: "o")
                .replacingOccurrences(of: "е", with: "e")
                .replacingOccurrences(of: "а", with: "a")
                .replacingOccurrences(of: "і", with: "i"))
        return candidates
    }

    private func unique(_ key: String, in object: [String: ExportValue]) -> String {
        guard object[key] != nil else { return key }
        var index = 2
        while object["\(key)-\(index)"] != nil { index += 1 }
        return "\(key)-\(index)"
    }
}
