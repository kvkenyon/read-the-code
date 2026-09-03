import Foundation
import RTCContracts
import RTCSyntax

@main struct SyntaxTests {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }

    static func main() async throws {
        check(RTCLanguageDetector.detect(path: "Example.swift") == .swift, "swift detection")
        check(RTCLanguageDetector.detect(path: "unknown", source: "#!/usr/bin/env python3\nprint(1)") == .python, "shebang detection")
        check(RTCLanguageDetector.detect(path: "unknown") == .plain, "plain fallback")
        check(RTCSyntaxSource.decodeUTF8(Data([0x66, 0x80, 0x67])) == "f�g", "replacement decoding")
        let digest = SHA256Digest(data: Data("let answer = 42".utf8))
        let highlighter = RTCSyntaxHighlighter()
        let spans = try await highlighter.highlight(path: "Example.swift", fileDigest: digest, source: "let answer = 42", language: nil, lines: nil)
        check(spans.contains { $0.token.value == "keyword" }, "keyword token")
        check(spans.contains { $0.token.value == "number" }, "number token")
        let plainSpans = try await highlighter.highlight(path: "Example.bin", fileDigest: digest, source: "let answer = 42", language: nil, lines: nil)
        check(plainSpans.isEmpty, "plain fallback is immediate")
        let partial = try await highlighter.highlight(path: "Example.swift", fileDigest: SHA256Digest(data: Data("a\nb".utf8)), source: "let a = 1\nlet b = 2", language: nil, lines: 2..<3)
        check(partial.allSatisfy { $0.line == 2 }, "range tokenization")
        check(!RTCSyntaxAttributedRuns.convert(source: "let answer = 42", spans: spans).isEmpty, "attributed-run conversion")
        await highlighter.cancel(fileDigest: digest)
        print("RTC syntax checks passed")
    }
}
