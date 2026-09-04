import Foundation

/// A bounded, non-materializing JSON grammar pass used before Foundation decoding.
/// It rejects duplicate object keys (including differently escaped spellings), excessive
/// nesting, and excessive collection work before a payload can reach a contract decoder.
public enum RTCJSONPreflight {
    public static func validate(
        _ data: Data,
        maxDepth: Int = 32,
        maxItems: Int = 100_000,
        rejectDuplicateKeys: Bool = true
    ) throws {
        guard maxDepth > 0, maxItems > 0 else {
            throw RTCContractError.invalid("json limits")
        }
        var parser = Parser(
            bytes: Array(data), maxDepth: maxDepth, maxItems: maxItems,
            rejectDuplicateKeys: rejectDuplicateKeys)
        try parser.parse()
    }
}

private struct Parser {
    let bytes: [UInt8]
    let maxDepth: Int
    let maxItems: Int
    let rejectDuplicateKeys: Bool
    var index = 0
    var items = 0

    mutating func parse() throws {
        skipWhitespace()
        try value(depth: 1)
        skipWhitespace()
        guard index == bytes.count else { throw invalid() }
    }

    mutating func value(depth: Int) throws {
        guard depth <= maxDepth else { throw invalid("json depth") }
        items += 1
        guard items <= maxItems, index < bytes.count else { throw invalid("json items") }
        switch bytes[index] {
        case 0x7B: try object(depth: depth)
        case 0x5B: try array(depth: depth)
        case 0x22: _ = try string()
        case 0x74: try literal("true")
        case 0x66: try literal("false")
        case 0x6E: try literal("null")
        default:
            if bytes[index] == 0x2D || (0x30...0x39).contains(bytes[index]) { try number() } else { throw invalid() }
        }
    }

    mutating func object(depth: Int) throws {
        index += 1
        skipWhitespace()
        if consume(0x7D) { return }
        var keys = Set<String>()
        while true {
            guard index < bytes.count, bytes[index] == 0x22 else { throw invalid() }
            let key = try string()
            if rejectDuplicateKeys, !keys.insert(key).inserted {
                throw invalid("duplicate json key")
            }
            items += 1
            guard items <= maxItems else { throw invalid("json items") }
            skipWhitespace()
            guard consume(0x3A) else { throw invalid() }
            skipWhitespace()
            try value(depth: depth + 1)
            skipWhitespace()
            if consume(0x7D) { return }
            guard consume(0x2C) else { throw invalid() }
            skipWhitespace()
        }
    }

    mutating func array(depth: Int) throws {
        index += 1
        skipWhitespace()
        if consume(0x5D) { return }
        while true {
            try value(depth: depth + 1)
            skipWhitespace()
            if consume(0x5D) { return }
            guard consume(0x2C) else { throw invalid() }
            skipWhitespace()
        }
    }

    mutating func string() throws -> String {
        let start = index
        index += 1
        var escaped = false
        while index < bytes.count {
            let byte = bytes[index]
            if escaped {
                if byte == 0x75 {
                    guard index + 4 < bytes.count,
                        bytes[(index + 1)...(index + 4)].allSatisfy(isHex)
                    else { throw invalid() }
                    index += 5
                } else {
                    guard [0x22, 0x5C, 0x2F, 0x62, 0x66, 0x6E, 0x72, 0x74].contains(byte)
                    else { throw invalid() }
                    index += 1
                }
                escaped = false
                continue
            }
            if byte == 0x5C {
                escaped = true
                index += 1
            } else if byte == 0x22 {
                index += 1
                let encoded = Data(bytes[start..<index])
                guard let decoded = try? JSONDecoder().decode(String.self, from: encoded) else {
                    throw invalid()
                }
                return decoded
            } else {
                guard byte >= 0x20 else { throw invalid() }
                index += 1
            }
        }
        throw invalid()
    }

    mutating func number() throws {
        if consume(0x2D), index == bytes.count { throw invalid() }
        if consume(0x30) {
            if index < bytes.count, (0x30...0x39).contains(bytes[index]) { throw invalid() }
        } else {
            guard consumeDigit(0x31...0x39) else { throw invalid() }
            while consumeDigit(0x30...0x39) {}
        }
        if consume(0x2E) {
            guard consumeDigit(0x30...0x39) else { throw invalid() }
            while consumeDigit(0x30...0x39) {}
        }
        if index < bytes.count, bytes[index] == 0x65 || bytes[index] == 0x45 {
            index += 1
            if index < bytes.count, bytes[index] == 0x2B || bytes[index] == 0x2D { index += 1 }
            guard consumeDigit(0x30...0x39) else { throw invalid() }
            while consumeDigit(0x30...0x39) {}
        }
    }

    mutating func literal(_ literal: StaticString) throws {
        let expected = Array(String(describing: literal).utf8)
        guard index + expected.count <= bytes.count,
            Array(bytes[index..<(index + expected.count)]) == expected
        else { throw invalid() }
        index += expected.count
    }

    mutating func consume(_ byte: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1
        return true
    }

    mutating func consumeDigit(_ range: ClosedRange<UInt8>) -> Bool {
        guard index < bytes.count, range.contains(bytes[index]) else { return false }
        index += 1
        return true
    }

    mutating func skipWhitespace() {
        while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
    }

    private func isHex(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte) || (0x41...0x46).contains(byte) || (0x61...0x66).contains(byte)
    }

    private func invalid(_ reason: String = "invalid json") -> RTCContractError {
        RTCContractError.invalid("\(reason) at byte \(index)")
    }
}
