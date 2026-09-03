import Foundation
import RTCContracts

private struct CacheKey: Hashable, Sendable { let digest: SHA256Digest; let range: Range<Int>?; let language: RTCSyntaxLanguage }
private struct CacheEntry: Sendable { let spans: [SyntaxSpan]; let cost: Int }

actor RTCSyntaxCache {
    private var entries: [CacheKey: CacheEntry] = [:]
    private var order: [CacheKey] = []
    private var totalCost = 0
    let capacity: Int
    init(capacity: Int = 2_000_000) { self.capacity = max(1, capacity) }
    fileprivate func value(for key: CacheKey) -> [SyntaxSpan]? {
        guard let entry = entries[key] else { return nil }
        touch(key); return entry.spans
    }
    fileprivate func insert(_ spans: [SyntaxSpan], for key: CacheKey) {
        let cost = spans.reduce(0) { $0 + 32 + $1.token.value.utf8.count }
        if let old = entries.updateValue(CacheEntry(spans: spans, cost: cost), forKey: key) { totalCost -= old.cost }
        else { order.append(key) }
        totalCost += cost
        while totalCost > capacity, let oldest = order.first {
            order.removeFirst(); if let removed = entries.removeValue(forKey: oldest) { totalCost -= removed.cost }
        }
    }
    func removeAll() { entries.removeAll(); order.removeAll(); totalCost = 0 }
    private func touch(_ key: CacheKey) { order.removeAll { $0 == key }; order.append(key) }
}

public actor RTCSyntaxHighlighter: SyntaxHighlighter {
    private static let maxSourceBytes = 8_000_000
    private static let maxSpans = 200_000
    private let cache: RTCSyntaxCache
    private var cancelled: Set<SHA256Digest> = []
    public init(cacheCapacityBytes: Int = 2_000_000) { cache = RTCSyntaxCache(capacity: cacheCapacityBytes) }

    public func highlight(path: String, fileDigest: SHA256Digest, source: String, language: BoundedString?, lines: Range<Int>?) async throws -> [SyntaxSpan] {
        let detected = language.flatMap { RTCSyntaxLanguage(rawValue: $0.value.lowercased()) } ?? RTCLanguageDetector.detect(path: path, source: source)
        let key = CacheKey(digest: fileDigest, range: lines, language: detected)
        if let cached = await cache.value(for: key) { return cached }
        if detected == .plain { return [] }
        guard source.utf8.count <= Self.maxSourceBytes else { return [] }
        let allLines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let selected = lines ?? 1..<(allLines.count + 1)
        var output: [SyntaxSpan] = []
        for lineNumber in selected where lineNumber > 0 && lineNumber <= allLines.count {
            try Task.checkCancellation()
            if cancelled.contains(fileDigest) { cancelled.remove(fileDigest); throw CancellationError() }
            output.append(contentsOf: try RTCSyntaxLexer.lex(line: allLines[lineNumber - 1], lineNumber: lineNumber, language: detected))
            if output.count >= Self.maxSpans { return Array(output.prefix(Self.maxSpans)) }
        }
        await cache.insert(output, for: key)
        return output
    }
    public func cancel(fileDigest: SHA256Digest) async { cancelled.insert(fileDigest) }
    public func clearCache() async { await cache.removeAll() }
}
