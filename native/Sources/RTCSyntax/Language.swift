import Foundation
import RTCContracts

public enum RTCSyntaxLanguage: String, Sendable, CaseIterable {
    case swift, typescript, javascript, tsx, python, go, rust, json, yaml, bash, markdown, css, html, plain
}

public enum RTCLanguageDetector {
    public static func detect(path: String, source: String = "") -> RTCSyntaxLanguage {
        let name = URL(fileURLWithPath: path).lastPathComponent.lowercased()
        let ext = URL(fileURLWithPath: name).pathExtension
        let byExtension: [String: RTCSyntaxLanguage] = [
            "swift": .swift, "ts": .typescript, "tsx": .tsx, "js": .javascript, "jsx": .tsx,
            "mjs": .javascript, "cjs": .javascript, "py": .python, "go": .go, "rs": .rust,
            "json": .json, "jsonc": .json, "yaml": .yaml, "yml": .yaml, "sh": .bash,
            "bash": .bash, "zsh": .bash, "md": .markdown, "markdown": .markdown,
            "css": .css, "html": .html, "htm": .html
        ]
        if let language = byExtension[ext] { return language }
        let firstLine = source.split(whereSeparator: { $0.isNewline }).first.map(String.init) ?? ""
        if firstLine.hasPrefix("#!") && (firstLine.contains("python") || firstLine.contains("python3")) { return .python }
        if firstLine.hasPrefix("#!") && (firstLine.contains("bash") || firstLine.contains("/sh")) { return .bash }
        return .plain
    }
}

public enum RTCSyntaxSource {
    /// Replacement decoding is explicit and deterministic for data from disk.
    public static func decodeUTF8(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }
}

public struct RTCSyntaxGrammarRegistry: Sendable {
    public let languages: Set<RTCSyntaxLanguage>
    public init(languages: Set<RTCSyntaxLanguage> = Set(RTCSyntaxLanguage.allCases.filter { $0 != .plain })) { self.languages = languages }
    public func supports(_ language: RTCSyntaxLanguage) -> Bool { languages.contains(language) }
}
