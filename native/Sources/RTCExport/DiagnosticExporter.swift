import Foundation
import RTCContracts
import RTCIPC

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

public struct DiagnosticExportInput: Sendable {
    public let review: ReviewExportInput
    public let records: [DiagnosticRecord]
    public let attachments: [DiagnosticAttachment]

    public init(
        review: ReviewExportInput,
        records: [DiagnosticRecord] = [],
        attachments: [DiagnosticAttachment] = []
    ) {
        self.review = review
        self.records = records
        self.attachments = attachments
    }
}

fileprivate struct DiagnosticOperatorApproval: Sendable {
    fileprivate let pendingID: UUID
    fileprivate let nonce: UUID
    fileprivate let expiresAt: Date
}

/// Owned by the operator-facing operation boundary. Preparing automation gets
/// a pending ID, but this authority and its one-use bearer are not returned.
fileprivate actor DiagnosticApprovalAuthority {
    private var approvals: [UUID: (pendingID: UUID, expiresAt: Date)] = [:]

    init() {}

    func issueOperatorApproval(
        for pendingID: UUID,
        validFor seconds: TimeInterval = 60
    ) throws -> DiagnosticOperatorApproval {
        guard seconds > 0, seconds <= 300 else { throw RTCContractError.invalid("diagnostic confirmation required") }
        let nonce = UUID()
        let expiry = Date().addingTimeInterval(seconds)
        approvals[nonce] = (pendingID, expiry)
        return DiagnosticOperatorApproval(pendingID: pendingID, nonce: nonce, expiresAt: expiry)
    }

    fileprivate func consume(_ approval: DiagnosticOperatorApproval, for pendingID: UUID) throws {
        guard approval.pendingID == pendingID,
            let stored = approvals.removeValue(forKey: approval.nonce),
            stored.pendingID == pendingID
        else { throw RTCContractError.invalid("diagnostic confirmation required") }
        guard stored.expiresAt >= Date(), approval.expiresAt >= Date() else {
            throw RTCContractError.invalid("diagnostic approval expired")
        }
    }
}

public actor PendingDiagnosticExport {
    private enum State { case prepared, publishing, failed, consumed, publishedCleanupFailed }

    public nonisolated let preview: DiagnosticExportPreview
    private let stagingRootFD: Int32
    private let stagingName: String
    private let bundleName: String
    private let repositoryPath: String
    private let files: [String: Data]
    private let faults: DiagnosticIOFaults?
    private var state: State = .prepared

    fileprivate init(
        preview: DiagnosticExportPreview,
        stagingRootFD: Int32,
        stagingName: String,
        bundleName: String,
        repositoryPath: String,
        files: [String: Data],
        faults: DiagnosticIOFaults?
    ) {
        self.preview = preview
        self.stagingRootFD = stagingRootFD
        self.stagingName = stagingName
        self.bundleName = bundleName
        self.repositoryPath = repositoryPath
        self.files = files
        self.faults = faults
    }

    deinit {
        try? removeDirectory(at: stagingRootFD, name: stagingName, files: Array(files.keys))
        close(stagingRootFD)
    }

    /// Authorization and pre-publication failures are retryable. Publication
    /// itself is one-shot, including when only private-staging cleanup fails.
    fileprivate func confirm(
        using approval: DiagnosticOperatorApproval,
        authority: DiagnosticApprovalAuthority,
        destinationDirectory: URL
    ) async throws -> URL {
        switch state {
        case .prepared, .failed: state = .publishing
        case .publishing, .consumed, .publishedCleanupFailed:
            throw RTCContractError.invalid("diagnostic export already consumed")
        }
        do {
            try Task.checkCancellation()
            try await authority.consume(approval, for: preview.pendingID)
            try Task.checkCancellation()
            let published = try publish(to: destinationDirectory)
            do {
                try removeDirectory(at: stagingRootFD, name: stagingName, files: Array(files.keys))
            } catch {
                state = .publishedCleanupFailed
                throw RTCContractError.invalid("diagnostic published; private cleanup failed")
            }
            state = .consumed
            return published
        } catch let error as RTCContractError {
            if case .publishing = state { state = .failed }
            throw error
        } catch is CancellationError {
            state = .failed
            throw CancellationError()
        } catch {
            state = .failed
            throw RTCContractError.invalid("diagnostic publish failed")
        }
    }

    fileprivate func discard() {
        if case .consumed = state { return }
        try? removeDirectory(at: stagingRootFD, name: stagingName, files: Array(files.keys))
        state = .consumed
    }

    private func publish(to destinationDirectory: URL) throws -> URL {
        guard destinationDirectory.isFileURL else { throw RTCContractError.invalid("invalid diagnostic destination") }
        let destination = destinationDirectory.standardizedFileURL
        let repository = URL(fileURLWithPath: repositoryPath).standardizedFileURL
        if isInside(destination.path, parent: repository.path)
            || isInside(destination.resolvingSymlinksInPath().path, parent: repository.resolvingSymlinksInPath().path)
        {
            throw RTCContractError.invalid("diagnostic destination inside reviewed repository")
        }

        let directoryFD = try openDirectoryNoFollow(destination.path)
        defer { close(directoryFD) }
        guard let actualDestination = descriptorPath(directoryFD),
            !isInside(actualDestination, parent: repository.path),
            !isInside(actualDestination, parent: repository.resolvingSymlinksInPath().path)
        else { throw RTCContractError.invalid("diagnostic destination inside reviewed repository") }
        let temporaryName = ".rtc-export-\(UUID().uuidString)"
        guard mkdirat(directoryFD, temporaryName, 0o700) == 0 else {
            throw RTCContractError.invalid("diagnostic publish failed")
        }
        let temporaryFD = openat(directoryFD, temporaryName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard temporaryFD >= 0 else {
            _ = unlinkat(directoryFD, temporaryName, AT_REMOVEDIR)
            throw RTCContractError.invalid("diagnostic publish failed")
        }
        defer { close(temporaryFD) }
        var created = [String]()
        var renamed = false
        defer {
            if !renamed {
                for filename in created { _ = unlinkat(temporaryFD, filename, 0) }
                _ = unlinkat(directoryFD, temporaryName, AT_REMOVEDIR)
            }
        }
        for filename in files.keys.sorted() {
            try Task.checkCancellation()
            guard isSafeLeaf(filename), let data = files[filename] else {
                throw RTCContractError.invalid("diagnostic publish failed")
            }
            let fd = openat(temporaryFD, filename, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { throw RTCContractError.invalid("diagnostic publish failed") }
            created.append(filename)
            do {
                try faults?.hit(.publishAfterCreate(filename))
                try writeAll(data, to: fd) { offset in
                    try faults?.hit(.publishBeforeWrite(filename, offset))
                }
                try faults?.hit(.publishBeforeSync(filename))
                guard fsync(fd) == 0 else { throw RTCContractError.invalid("diagnostic publish failed") }
            } catch {
                close(fd)
                throw error
            }
            close(fd)
        }
        guard fsync(temporaryFD) == 0 else { throw RTCContractError.invalid("diagnostic publish failed") }
        #if canImport(Darwin)
            guard renameatx_np(directoryFD, temporaryName, directoryFD, bundleName, UInt32(RENAME_EXCL)) == 0 else {
                if errno == EEXIST { throw RTCContractError.invalid("diagnostic destination exists") }
                throw RTCContractError.invalid("diagnostic publish failed")
            }
        #else
            guard renameat(directoryFD, temporaryName, directoryFD, bundleName) == 0 else {
                if errno == EEXIST { throw RTCContractError.invalid("diagnostic destination exists") }
                throw RTCContractError.invalid("diagnostic publish failed")
            }
        #endif
        renamed = true
        _ = fsync(directoryFD)
        return destination.appendingPathComponent(bundleName, isDirectory: true)
    }
}

public extension ReviewExporter {
    func prepareDiagnosticExport(
        _ input: DiagnosticExportInput,
        privateStagingRoot: URL
    ) async throws -> PendingDiagnosticExport {
        try Task.checkCancellation()
        guard privateStagingRoot.isFileURL else { throw RTCContractError.invalid("invalid diagnostic staging") }
        try preflightDiagnosticInput(input)
        let root = privateStagingRoot.standardizedFileURL
        let repositoryURL = URL(fileURLWithPath: input.review.manifest.revision.repositoryPath).standardizedFileURL
        let repository = repositoryURL.path
        let resolvedRepository = repositoryURL.resolvingSymlinksInPath().path
        guard !isInside(root.path, parent: repository),
            !isInside(root.resolvingSymlinksInPath().path, parent: resolvedRepository)
        else { throw RTCContractError.invalid("diagnostic staging inside reviewed repository") }
        let normalResult = try await normalExportResult(input.review)
        try Task.checkCancellation()
        let rootFD = try openOrCreateDirectoryTreeNoFollow(root.path, mode: 0o700)
        guard let actualRoot = descriptorPath(rootFD),
            !isInside(actualRoot, parent: repository),
            !isInside(actualRoot, parent: resolvedRepository)
        else {
            close(rootFD)
            throw RTCContractError.invalid("diagnostic staging inside reviewed repository")
        }
        let nonce = UUID().uuidString
        let working = ".building-\(nonce)"
        let staged = ".pending-\(nonce)"
        guard mkdirat(rootFD, working, 0o700) == 0 else {
            close(rootFD)
            throw RTCContractError.invalid("diagnostic staging failed")
        }
        let workingFD = openat(rootFD, working, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard workingFD >= 0 else {
            _ = unlinkat(rootFD, working, AT_REMOVEDIR)
            close(rootFD)
            throw RTCContractError.invalid("diagnostic staging failed")
        }
        var created = [String]()
        var transferred = false
        defer {
            close(workingFD)
            if !transferred {
                try? removeDirectory(at: rootFD, name: working, files: created)
                try? removeDirectory(at: rootFD, name: staged, files: created)
                close(rootFD)
            }
        }

        return try await withTaskCancellationHandler(
            operation: {
                let redactor = ExportRedactor()
                var findings = normalResult.findings
                var diagnosticValues = [ExportValue]()
                for (index, record) in input.records.enumerated() {
                    try Task.checkCancellation()
                    var fields: [String: ExportValue] = [
                        "operation": .string(try diagnosticTag(record.operation)),
                        "phase": .string(try diagnosticTag(record.phase)),
                    ]
                    if let value = record.durationMilliseconds { fields["durationMilliseconds"] = .integer(value) }
                    if let value = record.itemCount { fields["itemCount"] = .integer(value) }
                    if let message = record.message {
                        fields["message"] = .string(
                            redactor.scrubText(
                                message, fieldID: "diagnostic.record[\(index)].message", findings: &findings))
                    }
                    diagnosticValues.append(.object(fields))
                }
                let diagnosticsValue = ExportValue.object(["records": .array(diagnosticValues)])
                let diagnostics = try canonicalData(diagnosticsValue)

                let approved = input.attachments.filter(\.approvedForExport)
                let omitted = input.attachments.count - approved.count
                guard approved.count + 3 <= RTCExportLimits.maxDiagnosticFiles else {
                    throw RTCContractError.invalid("diagnostic file count limit")
                }

                var files: [String: Data] = ["review.json": normalResult.data, "diagnostics.json": diagnostics]
                for (index, attachment) in approved.enumerated() {
                    try Task.checkCancellation()
                    var attachmentFindings: [RedactionFinding] = []
                    let text = redactor.scrubText(
                        attachment.text,
                        fieldID: "diagnostic.attachment[\(index)].text",
                        findings: &attachmentFindings
                    )
                    findings.append(contentsOf: attachmentFindings)
                    let data = Data(text.utf8)
                    guard data.count <= RTCExportLimits.maxDiagnosticFileBytes else {
                        throw RTCContractError.invalid("diagnostic attachment size limit")
                    }
                    files[generatedAttachmentName(index: index, original: attachment.filename)] = data
                }
                files["manifest.json"] = try diagnosticManifest(files)
                let total = files.values.reduce(0) { $0 + $1.count }
                guard total <= RTCExportLimits.maxDiagnosticBytes else {
                    throw RTCContractError.invalid("diagnostic export size limit")
                }

                for filename in files.keys.sorted() {
                    try Task.checkCancellation()
                    let fd = openat(workingFD, filename, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
                    guard fd >= 0 else { throw RTCContractError.invalid("diagnostic staging failed") }
                    created.append(filename)
                    do {
                        try diagnosticIOFaults?.hit(.stagingAfterCreate(filename))
                        try writeAll(files[filename]!, to: fd) { offset in
                            try diagnosticIOFaults?.hit(.stagingBeforeWrite(filename, offset))
                        }
                        try diagnosticIOFaults?.hit(.stagingBeforeSync(filename))
                        guard fsync(fd) == 0 else { throw RTCContractError.invalid("diagnostic staging failed") }
                    } catch {
                        close(fd)
                        throw error
                    }
                    close(fd)
                }
                try Task.checkCancellation()
                guard fsync(workingFD) == 0,
                    renameat(rootFD, working, rootFD, staged) == 0,
                    fsync(rootFD) == 0
                else {
                    throw RTCContractError.invalid("diagnostic staging failed")
                }
                try Task.checkCancellation()

                let pendingID = UUID()
                let preview = DiagnosticExportPreview(
                    pendingID: pendingID,
                    files: files.keys.sorted().map { DiagnosticPreviewFile(filename: $0, byteCount: files[$0]!.count) },
                    includedFieldPaths: diagnosticPreviewFields(input.records),
                    redactions: boundedFindings(findings),
                    omittedAttachmentCount: omitted,
                    totalByteCount: total
                )
                transferred = true
                return PendingDiagnosticExport(
                    preview: preview,
                    stagingRootFD: rootFD,
                    stagingName: staged,
                    bundleName: "read-the-code-diagnostic-\(input.review.manifest.id.value).rtcdiagnostic",
                    repositoryPath: repository,
                    files: files,
                    faults: diagnosticIOFaults
                )
            },
            onCancel: {})
    }

    private func preflightDiagnosticInput(_ input: DiagnosticExportInput) throws {
        guard input.records.count <= RTCExportLimits.maxDiagnosticCollectionItems,
            input.attachments.count <= RTCExportLimits.maxDiagnosticCollectionItems
        else { throw RTCContractError.invalid("diagnostic input count limit") }
        let approvedCount = input.attachments.reduce(0) { $0 + ($1.approvedForExport ? 1 : 0) }
        guard approvedCount + 3 <= RTCExportLimits.maxDiagnosticFiles else {
            throw RTCContractError.invalid("diagnostic file count limit")
        }
        var bytes = 0
        func add(_ count: Int) throws {
            guard count >= 0, count <= RTCExportLimits.maxDiagnosticBytes - bytes else {
                throw RTCContractError.invalid("diagnostic input byte limit")
            }
            bytes += count
        }
        for record in input.records {
            _ = try diagnosticTag(record.operation)
            _ = try diagnosticTag(record.phase)
            try add(record.operation.utf8.count)
            try add(record.phase.utf8.count)
            if let message = record.message { try add(message.utf8.count) }
        }
        for attachment in input.attachments where attachment.approvedForExport {
            try add(attachment.filename.utf8.count)
            guard attachment.text.utf8.count <= RTCExportLimits.maxDiagnosticFileBytes else {
                throw RTCContractError.invalid("diagnostic attachment size limit")
            }
            try add(attachment.text.utf8.count)
        }
    }

    private func diagnosticTag(_ value: String) throws -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard value.unicodeScalars.allSatisfy(allowed.contains), !value.contains("..") else {
            throw RTCContractError.invalid("invalid diagnostic field")
        }
        return value
    }

    private func diagnosticPreviewFields(_ records: [DiagnosticRecord]) -> [String] {
        var fields = [
            "$.review", "$.review.revision.baseSHA", "$.review.revision.headSHA",
            "$.events", "$.comments", "$.decisions", "$.progress", "$.tours",
        ]
        if !records.isEmpty {
            fields += ["$.diagnostics.records[].operation", "$.diagnostics.records[].phase"]
        }
        if records.contains(where: { $0.message != nil }) {
            fields.append("$.diagnostics.records[].message")
        }
        if records.contains(where: { $0.durationMilliseconds != nil }) {
            fields.append("$.diagnostics.records[].durationMilliseconds")
        }
        if records.contains(where: { $0.itemCount != nil }) {
            fields.append("$.diagnostics.records[].itemCount")
        }
        return fields.sorted()
    }

    private func diagnosticManifest(_ files: [String: Data]) throws -> Data {
        let entries = files.keys.sorted().map { name in
            ExportValue.object([
                "byteCount": .integer(files[name]!.count),
                "filename": .string(name),
                "sha256": .string(SHA256Digest(data: files[name]!).hex),
            ])
        }
        return try canonicalData(.object(["schemaVersion": .integer(1), "files": .array(entries)]))
    }

    private func generatedAttachmentName(index: Int, original: String) -> String {
        let allowed = Set(["txt", "log", "json", "md"])
        let candidate = URL(fileURLWithPath: original).pathExtension.lowercased()
        let ext = allowed.contains(candidate) ? candidate : "txt"
        return String(format: "attachment-%03d.%@", index + 1, ext)
    }

    private func boundedFindings(_ findings: [RedactionFinding]) -> [RedactionFinding] {
        guard findings.count > RTCExportLimits.maxPreviewFindings else { return findings }
        return Array(findings.prefix(RTCExportLimits.maxPreviewFindings - 1))
            + [RedactionFinding(fieldID: "diagnostic", category: "preview-cap")]
    }
}

public protocol DiagnosticExportSource: Sendable {
    func input(for reviewID: ReviewID) async throws -> DiagnosticExportInput
}

public struct DiagnosticPrepareRequest: Codable, Sendable {
    public let reviewID: ReviewID
    public init(reviewID: ReviewID) { self.reviewID = reviewID }
}

public struct DiagnosticPrepareResponse: Codable, Sendable {
    public let preview: DiagnosticExportPreview
    public init(preview: DiagnosticExportPreview) { self.preview = preview }
}

public struct DiagnosticConfirmRequest: Codable, Sendable {
    public let pendingID: UUID
    public let destinationDirectory: String
    public init(pendingID: UUID, destinationDirectory: String) {
        self.pendingID = pendingID
        self.destinationDirectory = destinationDirectory
    }
}

public struct DiagnosticConfirmResponse: Codable, Sendable {
    public let filename: String
    public init(filename: String) { self.filename = filename }
}

private actor DiagnosticPendingRegistry {
    private var pending: [UUID: PendingDiagnosticExport] = [:]

    func insert(_ prepared: PendingDiagnosticExport) {
        pending[prepared.preview.pendingID] = prepared
    }

    func lookup(_ pendingID: UUID) -> PendingDiagnosticExport? {
        pending[pendingID]
    }

    func remove(_ pendingID: UUID) {
        pending.removeValue(forKey: pendingID)
    }
}

/// The preparation service has no confirmation authority. Its only shared
/// dependency is an actor that stores opaque pending exports for the
/// independently provisioned confirmation service.
private actor DiagnosticPrepareOperationHandler: IPCOperationHandler {
    private let exporter: ReviewExporter
    private let source: any DiagnosticExportSource
    private let stagingRoot: URL
    private let registry: DiagnosticPendingRegistry

    init(
        exporter: ReviewExporter,
        source: any DiagnosticExportSource,
        stagingRoot: URL,
        registry: DiagnosticPendingRegistry
    ) {
        self.exporter = exporter
        self.source = source
        self.stagingRoot = stagingRoot
        self.registry = registry
    }

    func handle(_ request: IPCRequest) async -> IPCResponse {
        do {
            guard request.operation.value == DiagnosticExportIPCComposition.prepareOperation else {
                throw RTCContractError.invalid("unsupported diagnostic export operation")
            }
            let body = try decodeDiagnosticRequest(DiagnosticPrepareRequest.self, request.payload)
            let input = try await source.input(for: body.reviewID)
            guard input.review.manifest.id == body.reviewID else {
                throw RTCContractError.invalid("diagnostic review mismatch")
            }
            let prepared = try await exporter.prepareDiagnosticExport(input, privateStagingRoot: stagingRoot)
            await registry.insert(prepared)
            return try diagnosticSuccess(request, DiagnosticPrepareResponse(preview: prepared.preview))
        } catch {
            return diagnosticFailure(request)
        }
    }
}

/// The confirmation service owns the only approval authority. It is not
/// reachable through the preparation dispatcher or capability.
private actor DiagnosticConfirmOperationHandler: IPCOperationHandler {
    private let registry: DiagnosticPendingRegistry
    private let authority = DiagnosticApprovalAuthority()
    private let approvalLifetime: TimeInterval
    private let beforeApprovalConsumption: (@Sendable () async -> Void)?

    init(
        registry: DiagnosticPendingRegistry,
        approvalLifetime: TimeInterval,
        beforeApprovalConsumption: (@Sendable () async -> Void)?
    ) {
        self.registry = registry
        self.approvalLifetime = approvalLifetime
        self.beforeApprovalConsumption = beforeApprovalConsumption
    }

    func handle(_ request: IPCRequest) async -> IPCResponse {
        do {
            guard request.operation.value == DiagnosticExportIPCComposition.confirmOperation else {
                throw RTCContractError.invalid("unsupported diagnostic export operation")
            }
            let body = try decodeDiagnosticRequest(DiagnosticConfirmRequest.self, request.payload)
            guard let prepared = await registry.lookup(body.pendingID) else {
                throw RTCContractError.invalid("diagnostic confirmation unavailable")
            }
            guard body.destinationDirectory.hasPrefix("/"),
                body.destinationDirectory.utf8.count <= RTCConstants.maxPathBytes,
                body.destinationDirectory.unicodeScalars.allSatisfy({
                    !CharacterSet.controlCharacters.contains($0) && $0.value != 0
                })
            else { throw RTCContractError.invalid("invalid diagnostic destination") }
            let approval = try await authority.issueOperatorApproval(
                for: body.pendingID, validFor: approvalLifetime)
            await beforeApprovalConsumption?()
            let published = try await prepared.confirm(
                using: approval,
                authority: authority,
                destinationDirectory: URL(fileURLWithPath: body.destinationDirectory, isDirectory: true)
            )
            await registry.remove(body.pendingID)
            return try diagnosticSuccess(request, DiagnosticConfirmResponse(filename: published.lastPathComponent))
        } catch {
            return diagnosticFailure(request)
        }
    }
}

private func decodeDiagnosticRequest<T: Decodable>(_ type: T.Type, _ payload: Data?) throws -> T {
    guard let payload, payload.count <= RTCExportLimits.maxDiagnosticStringBytes else {
        throw RTCContractError.invalid("invalid diagnostic request")
    }
    do { return try JSONDecoder().decode(type, from: payload) } catch {
        throw RTCContractError.invalid("invalid diagnostic request")
    }
}

private func diagnosticSuccess<T: Encodable>(_ request: IPCRequest, _ body: T) throws -> IPCResponse {
    IPCResponse(
        schemaVersion: RTCConstants.schemaVersion,
        requestID: request.id,
        ok: true,
        error: nil,
        payload: try RTCCanonicalJSON.encode(body)
    )
}

private func diagnosticFailure(_ request: IPCRequest) -> IPCResponse {
    IPCResponse(
        schemaVersion: RTCConstants.schemaVersion,
        requestID: request.id,
        ok: false,
        error: RTCError(
            code: .internalError,
            message: "Diagnostic export request failed",
            retryable: false),
        payload: nil
    )
}

/// Composes preparation and confirmation as separate dispatchers with disjoint
/// capabilities. Possession of the preparation dispatcher/capability cannot
/// invoke the confirmation service or mint its private one-use approval.
public struct DiagnosticExportIPCComposition: Sendable {
    public static let prepareOperation = "export.prepare"
    public static let confirmOperation = "export.confirm"

    public let prepareDispatcher: IPCDispatcher
    public let confirmDispatcher: IPCDispatcher

    public init(
        exporter: ReviewExporter,
        source: any DiagnosticExportSource,
        stagingRoot: URL,
        peer: any IPCPeerAuthenticator,
        prepareCapability: String,
        confirmCapability: String
    ) throws {
        try self.init(
            exporter: exporter,
            source: source,
            stagingRoot: stagingRoot,
            peer: peer,
            prepareCapability: prepareCapability,
            confirmCapability: confirmCapability,
            approvalLifetime: 60,
            beforeApprovalConsumption: nil
        )
    }

    @_spi(Testing)
    public init(
        exporter: ReviewExporter,
        source: any DiagnosticExportSource,
        stagingRoot: URL,
        peer: any IPCPeerAuthenticator,
        prepareCapability: String,
        confirmCapability: String,
        approvalLifetime: TimeInterval,
        beforeApprovalConsumption: (@Sendable () async -> Void)?
    ) throws {
        guard !prepareCapability.isEmpty, !confirmCapability.isEmpty,
            prepareCapability != confirmCapability,
            approvalLifetime > 0, approvalLifetime <= 300
        else { throw RTCContractError.invalid("diagnostic capabilities must be distinct") }
        let registry = DiagnosticPendingRegistry()
        prepareDispatcher = IPCDispatcher(
            handler: DiagnosticPrepareOperationHandler(
                exporter: exporter,
                source: source,
                stagingRoot: stagingRoot,
                registry: registry
            ),
            peer: peer,
            capabilities: IPCScopedCapabilityStore([prepareCapability: [Self.prepareOperation]])
        )
        confirmDispatcher = IPCDispatcher(
            handler: DiagnosticConfirmOperationHandler(
                registry: registry,
                approvalLifetime: approvalLifetime,
                beforeApprovalConsumption: beforeApprovalConsumption
            ),
            peer: peer,
            capabilities: IPCScopedCapabilityStore([confirmCapability: [Self.confirmOperation]])
        )
    }
}

private func isInside(_ path: String, parent: String) -> Bool {
    let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
    let normalizedParent = URL(fileURLWithPath: parent).standardizedFileURL.path
    return normalized == normalizedParent || normalized.hasPrefix(normalizedParent + "/")
}

private func isSafeLeaf(_ name: String) -> Bool {
    !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
}

private func openDirectoryNoFollow(_ path: String) throws -> Int32 {
    guard path.hasPrefix("/") else { throw RTCContractError.invalid("invalid diagnostic destination") }
    var fd = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    guard fd >= 0 else { throw RTCContractError.invalid("invalid diagnostic destination") }
    for component in path.split(separator: "/").map(String.init) {
        let next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        if next < 0 {
            close(fd)
            if errno == ELOOP { throw RTCContractError.invalid("diagnostic destination symlink") }
            throw RTCContractError.invalid("invalid diagnostic destination")
        }
        close(fd)
        fd = next
    }
    return fd
}

private func openOrCreateDirectoryTreeNoFollow(_ path: String, mode: mode_t) throws -> Int32 {
    guard path.hasPrefix("/") else { throw RTCContractError.invalid("invalid diagnostic staging") }
    var fd = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    guard fd >= 0 else { throw RTCContractError.invalid("invalid diagnostic staging") }
    for component in path.split(separator: "/").map(String.init) {
        var next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        if next < 0, errno == ENOENT {
            guard mkdirat(fd, component, mode) == 0 || errno == EEXIST else {
                close(fd)
                throw RTCContractError.invalid("diagnostic staging failed")
            }
            next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        }
        guard next >= 0 else {
            close(fd)
            throw RTCContractError.invalid("invalid diagnostic staging")
        }
        close(fd)
        fd = next
    }
    guard fchmod(fd, mode) == 0 else {
        close(fd)
        throw RTCContractError.invalid("diagnostic staging failed")
    }
    return fd
}

private func descriptorPath(_ fd: Int32) -> String? {
    #if canImport(Darwin)
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard fcntl(fd, F_GETPATH, &buffer) == 0 else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    #else
        return URL(fileURLWithPath: "/proc/self/fd/\(fd)").resolvingSymlinksInPath().path
    #endif
}

private func removeDirectory(at parentFD: Int32, name: String, files: [String]) throws {
    let directoryFD = openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    if directoryFD < 0 {
        if errno == ENOENT { return }
        throw RTCContractError.invalid("diagnostic cleanup failed")
    }
    defer { close(directoryFD) }
    for filename in files where isSafeLeaf(filename) {
        if unlinkat(directoryFD, filename, 0) != 0, errno != ENOENT {
            throw RTCContractError.invalid("diagnostic cleanup failed")
        }
    }
    guard unlinkat(parentFD, name, AT_REMOVEDIR) == 0 || errno == ENOENT else {
        throw RTCContractError.invalid("diagnostic cleanup failed")
    }
}

private func writeAll(
    _ data: Data,
    to fd: Int32,
    beforeChunk: (Int) throws -> Void
) throws {
    try data.withUnsafeBytes { raw in
        var offset = 0
        while offset < data.count {
            try Task.checkCancellation()
            try beforeChunk(offset)
            let requested = min(4_096, data.count - offset)
            #if canImport(Darwin)
                let count = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), requested)
            #else
                let count = Glibc.write(fd, raw.baseAddress!.advanced(by: offset), requested)
            #endif
            guard count > 0 else { throw RTCContractError.invalid("diagnostic publish failed") }
            offset += count
        }
    }
}
