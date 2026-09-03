import Foundation
import RTCContracts

public struct RTCSyntaxRun: Hashable, Sendable {
    public let span: SyntaxSpan
    public let text: String
    public init(span: SyntaxSpan, text: String) { self.span = span; self.text = text }
}

public enum RTCSyntaxAttributedRuns {
    public static func convert(source: String, spans: [SyntaxSpan]) -> [RTCSyntaxRun] {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return spans.compactMap { span in
            guard span.line > 0, span.line <= lines.count else { return nil }
            let scalars = Array(lines[span.line - 1].unicodeScalars)
            guard span.startColumn <= scalars.count, span.endColumn <= scalars.count else { return nil }
            let text = String(String.UnicodeScalarView(scalars[span.startColumn..<span.endColumn]))
            return RTCSyntaxRun(span: span, text: text)
        }
    }
}

struct RTCSyntaxLexer {
    static func lex(line: String, lineNumber: Int, language: RTCSyntaxLanguage) throws -> [SyntaxSpan] {
        if language == .plain { return [] }
        let chars = Array(line.unicodeScalars)
        var result: [SyntaxSpan] = []
        var index = 0
        let keywords = keywordSet(for: language)
        let commentMarker: String? = language == .python || language == .yaml || language == .bash ? "#" :
            language == .markdown ? "" : "//"
        while index < chars.count {
            if let marker = commentMarker, !marker.isEmpty, starts(chars, index, marker) {
                try append(&result, lineNumber, index, chars.count, "comment")
                break
            }
            if language == .markdown && chars[index] == "#" {
                try append(&result, lineNumber, index, chars.count, "heading"); break
            }
            if chars[index] == "\"" || chars[index] == "'" || chars[index] == "`" {
                let quote = chars[index]; let start = index; index += 1
                while index < chars.count {
                    if chars[index] == "\\" { index += min(2, chars.count - index) }
                    else { let done = chars[index] == quote; index += 1; if done { break } }
                }
                try append(&result, lineNumber, start, index, "string"); continue
            }
            if chars[index].properties.isWhitespace { index += 1; continue }
            if chars[index].properties.numericType != nil {
                let start = index; while index < chars.count && (chars[index].properties.numericType != nil || chars[index] == ".") { index += 1 }
                try append(&result, lineNumber, start, index, "number"); continue
            }
            if chars[index].properties.isAlphabetic || chars[index] == "_" {
                let start = index; index += 1
                while index < chars.count && (chars[index].properties.isAlphabetic || chars[index].properties.numericType != nil || chars[index] == "_") { index += 1 }
                let word = String(String.UnicodeScalarView(chars[start..<index]))
                try append(&result, lineNumber, start, index, keywords.contains(word) ? "keyword" : "identifier"); continue
            }
            let start = index; index += 1
            try append(&result, lineNumber, start, index, "operator")
        }
        return result
    }

    private static func starts(_ chars: [Unicode.Scalar], _ index: Int, _ marker: String) -> Bool {
        let markerScalars = Array(marker.unicodeScalars)
        return index + markerScalars.count <= chars.count && Array(chars[index..<index + markerScalars.count]) == markerScalars
    }
    private static func append(_ output: inout [SyntaxSpan], _ line: Int, _ start: Int, _ end: Int, _ token: String) throws {
        output.append(try SyntaxSpan(line: line, startColumn: start, endColumn: end, token: BoundedString(token)))
    }
    private static func keywordSet(for language: RTCSyntaxLanguage) -> Set<String> {
        let common = "if else for while return let var const func class struct enum import from in true false nil null await async throw throws public private internal static var type interface extends def fn pub impl match package use mod select case switch guard where protocol self Self".split(separator: " ").map(String.init)
        switch language { case .json: return Set(["true", "false", "null"]); case .yaml: return Set(["true", "false", "null", "yes", "no"]); default: return Set(common) }
    }
}
