import Foundation
import RTCContracts

/// JSON data accepted by the diagnostic scrubber. This deliberately excludes
/// opaque bytes and executable/resource-bearing rich-content types.
public enum ExportValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case integer(Int)
    case number(Double)
    case string(String)
    case array([ExportValue])
    case object([String: ExportValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([ExportValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: ExportValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

public enum RTCExportLimits {
    public static let maxNormalBytes = 4 * 1_024 * 1_024
    public static let maxDiagnosticBytes = 4 * 1_024 * 1_024
    public static let maxEvents = 10_000
    public static let maxThreads = 10_000
    public static let maxMessages = 50_000
    public static let maxTours = 32
    public static let maxDiagnosticFiles = 16
    public static let maxDiagnosticFileBytes = 256 * 1_024
    public static let maxDiagnosticDepth = 12
    public static let maxDiagnosticCollectionItems = 256
    public static let maxDiagnosticStringBytes = 32 * 1_024
    public static let maxPreviewFieldPaths = 1_024
    public static let maxPreviewFindings = 1_024
    public static let maxTourGroups = 64
    public static let maxTourGroupMembers = 512
    public static let maxTourRisks = 100
    public static let maxTourBulletItems = 512
    public static let maxTourEncodedBytes = 1 * 1_024 * 1_024
    public static let maxNormalInputTextBytes = 4 * 1_024 * 1_024
}

@_spi(Testing)
public enum DiagnosticIOPoint: Sendable {
    case stagingAfterCreate(String)
    case stagingBeforeWrite(String, Int)
    case stagingBeforeSync(String)
    case publishAfterCreate(String)
    case publishBeforeWrite(String, Int)
    case publishBeforeSync(String)
}

@_spi(Testing)
public struct DiagnosticIOFaults: Sendable {
    public let hit: @Sendable (DiagnosticIOPoint) throws -> Void
    public init(hit: @escaping @Sendable (DiagnosticIOPoint) throws -> Void) { self.hit = hit }
}

/// A closed diagnostic schema. Callers cannot add arbitrary keys or opaque
/// values; each field has a field-specific serializer and redaction policy.
public struct DiagnosticRecord: Sendable {
    public let operation: String
    public let phase: String
    public let message: String?
    public let durationMilliseconds: Int?
    public let itemCount: Int?

    public init(
        operation: String,
        phase: String,
        message: String? = nil,
        durationMilliseconds: Int? = nil,
        itemCount: Int? = nil
    ) throws {
        guard !operation.isEmpty, operation.utf8.count <= 128,
            !phase.isEmpty, phase.utf8.count <= 128,
            durationMilliseconds.map({ $0 >= 0 }).unwrap(or: true),
            itemCount.map({ $0 >= 0 }).unwrap(or: true)
        else { throw RTCContractError.invalid("invalid diagnostic field") }
        self.operation = operation
        self.phase = phase
        self.message = message
        self.durationMilliseconds = durationMilliseconds
        self.itemCount = itemCount
    }
}

public struct DiagnosticAttachment: Sendable {
    public let filename: String
    public let text: String
    public let approvedForExport: Bool

    public init(filename: String, text: String, approvedForExport: Bool) {
        self.filename = filename
        self.text = text
        self.approvedForExport = approvedForExport
    }
}

public struct RedactionFinding: Codable, Equatable, Sendable {
    /// Opaque schema position, never an input key or value.
    public let fieldID: String
    public let category: String

    public init(fieldID: String, category: String) {
        self.fieldID = fieldID
        self.category = category
    }
}

public struct DiagnosticPreviewFile: Codable, Equatable, Sendable {
    public let filename: String
    public let byteCount: Int

    public init(filename: String, byteCount: Int) {
        self.filename = filename
        self.byteCount = byteCount
    }
}

public struct DiagnosticExportPreview: Codable, Equatable, Sendable {
    public let pendingID: UUID
    public let requiresConfirmation: Bool
    public let files: [DiagnosticPreviewFile]
    public let includedFieldPaths: [String]
    public let redactions: [RedactionFinding]
    public let omittedAttachmentCount: Int
    public let totalByteCount: Int

    public init(
        pendingID: UUID,
        files: [DiagnosticPreviewFile],
        includedFieldPaths: [String],
        redactions: [RedactionFinding],
        omittedAttachmentCount: Int,
        totalByteCount: Int
    ) {
        self.pendingID = pendingID
        self.requiresConfirmation = true
        self.files = files
        self.includedFieldPaths = includedFieldPaths
        self.redactions = redactions
        self.omittedAttachmentCount = omittedAttachmentCount
        self.totalByteCount = totalByteCount
    }
}

private extension Optional where Wrapped == Bool {
    func unwrap(or fallback: Bool) -> Bool { self ?? fallback }
}
