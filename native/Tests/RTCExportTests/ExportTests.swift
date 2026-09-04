import Foundation
import RTCContracts
@_spi(Testing) import RTCExport
import RTCIPC
import RTCReview

struct AcceptingExportAnchors: AnchorArtifactSource {
    func validate(_ anchor: ReviewAnchor) async throws -> Bool { true }
}

struct CountingExportAnchors: AnchorArtifactSource {
    let counter: AnchorCounter
    func validate(_ anchor: ReviewAnchor) async throws -> Bool {
        await counter.increment()
        return true
    }
}

actor AnchorCounter {
    private var value = 0
    func increment() { value += 1 }
    func count() -> Int { value }
}

struct AcceptingPeer: IPCPeerAuthenticator {
    func isAuthorized(fileDescriptor: Int32) -> Bool { true }
}

struct FixedDiagnosticSource: DiagnosticExportSource {
    let value: DiagnosticExportInput
    func input(for reviewID: ReviewID) async throws -> DiagnosticExportInput { value }
}

actor OneShotDelay {
    private var delayed = false
    func pauseOnce() async {
        guard !delayed else { return }
        delayed = true
        try? await Task.sleep(for: .milliseconds(20))
    }
}

final class CancellationGate: @unchecked Sendable {
    let reached = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var paused = false

    func pauseOnSecondChunk(_ point: DiagnosticIOPoint) {
        guard case .stagingBeforeWrite(_, let offset) = point, offset >= 4_096 else { return }
        lock.lock()
        let shouldPause = !paused
        paused = true
        lock.unlock()
        if shouldPause {
            reached.signal()
            release.wait()
        }
    }

    func waitUntilReached() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: self.reached.wait(timeout: .now() + 2) == .success)
            }
        }
    }
}

final class StagingRootSwap: @unchecked Sendable {
    private let lock = NSLock()
    private var swapped = false
    let root: URL
    let moved: URL

    init(root: URL, moved: URL) {
        self.root = root
        self.moved = moved
    }

    func swapAfterFirstLeaf(_ point: DiagnosticIOPoint) throws {
        guard case .stagingAfterCreate = point else { return }
        lock.lock()
        let shouldSwap = !swapped
        swapped = true
        lock.unlock()
        guard shouldSwap else { return }
        try FileManager.default.moveItem(at: root, to: moved)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }
}

enum ExportTestFailure: Error {
    case failed(String)
}

@main struct ExportTests {
    static let prepareCapability = "prepare-capability"
    static let confirmCapability = "confirm-capability"

    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw ExportTestFailure.failed(message) }
    }

    static func composition(
        exporter: ReviewExporter,
        input: DiagnosticExportInput,
        staging: URL,
        approvalLifetime: TimeInterval = 60,
        beforeApprovalConsumption: (@Sendable () async -> Void)? = nil
    ) throws -> DiagnosticExportIPCComposition {
        try DiagnosticExportIPCComposition(
            exporter: exporter,
            source: FixedDiagnosticSource(value: input),
            stagingRoot: staging,
            peer: AcceptingPeer(),
            prepareCapability: prepareCapability,
            confirmCapability: confirmCapability,
            approvalLifetime: approvalLifetime,
            beforeApprovalConsumption: beforeApprovalConsumption
        )
    }

    static func dispatch<T: Encodable>(
        _ dispatcher: IPCDispatcher,
        operation: String,
        capability: String,
        body: T
    ) async throws -> IPCEnvelopeResponse {
        let request = IPCEnvelope(
            operation: operation,
            capability: capability,
            body: try RTCCanonicalJSON.encode(body)
        )
        let responseFrame = await dispatcher.dispatch(
            frame: try IPCFrameCodec.encode(request),
            fileDescriptor: -1
        )
        let responseData = try IPCFrameCodec.decode(responseFrame)
        return try IPCFrameCodec.decodeJSON(IPCEnvelopeResponse.self, from: responseData)
    }

    static func prepare(
        _ composition: DiagnosticExportIPCComposition,
        reviewID: ReviewID
    ) async throws -> DiagnosticExportPreview {
        let response = try await dispatch(
            composition.prepareDispatcher,
            operation: DiagnosticExportIPCComposition.prepareOperation,
            capability: prepareCapability,
            body: DiagnosticPrepareRequest(reviewID: reviewID)
        )
        try check(response.ok, "diagnostic preparation failed")
        guard let body = response.body else { throw ExportTestFailure.failed("preparation omitted response") }
        return try JSONDecoder().decode(DiagnosticPrepareResponse.self, from: body).preview
    }

    static func confirm(
        _ composition: DiagnosticExportIPCComposition,
        pendingID: UUID,
        destination: URL,
        dispatcher: IPCDispatcher? = nil,
        capability: String = confirmCapability
    ) async throws -> IPCEnvelopeResponse {
        try await dispatch(
            dispatcher ?? composition.confirmDispatcher,
            operation: DiagnosticExportIPCComposition.confirmOperation,
            capability: capability,
            body: DiagnosticConfirmRequest(
                pendingID: pendingID,
                destinationDirectory: destination.path
            )
        )
    }

    static func main() async throws {
        let input = try fixtureInput()
        let exporter = ReviewExporter(anchors: AcceptingExportAnchors())
        let first = try await exporter.normalExport(input)
        let second = try await exporter.normalExport(input)
        try check(first == second, "normal export is not deterministic")

        let text = String(decoding: first, as: UTF8.self)
        for canary in [
            "/tmp/repo", "source-canary", "credential-canary",
        ] {
            try check(!text.contains(canary), "normal export leaked \(canary)")
        }
        try check(text.contains("Sources/App.swift"), "portable relative path missing")
        try check(text.contains("<redacted:path>"), "comment path was not redacted")
        try check(text.contains("Bearer <redacted:credential>"), "comment credential was not redacted")
        try check(text.contains(#""decisions":[{"createdAt""#), "portable decision record missing")

        let normal = try JSONSerialization.jsonObject(with: first) as! [String: Any]
        try check(
            Set(normal.keys) == ["schemaVersion", "exportKind", "review", "events", "comments", "decisions", "progress", "tours"],
            "normal export top-level allowlist drifted"
        )
        let review = normal["review"] as! [String: Any]
        let exportedRevision = review["revision"] as! [String: Any]
        try check(
            Set(exportedRevision.keys) == ["baseSHA", "headSHA"],
            "normal revision exposed a repository path"
        )
        let exportedFile = (review["files"] as! [[String: Any]])[0]
        try check(exportedFile["hunks"] == nil, "normal file exported source hunks")
        let exportedEvents = normal["events"] as! [[String: Any]]
        try check(
            Set((exportedEvents[0]["payload"] as! [String: Any]).keys) == ["threadIDs"],
            "feedback event escaped its payload allowlist"
        )
        try check(
            Set((exportedEvents[1]["payload"] as! [String: Any]).keys) == ["headSHA", "warnings"],
            "approval event escaped its payload allowlist"
        )

        let recursivelyScrubbed = ExportRedactor().scrub(
            .object([
                "outer": .array([
                    .object([
                        "repositoryPath": .string("/Users/private/repository-path-canary"),
                        "message": .string("failed at /private/path-canary with Bearer recursive-credential-canary"),
                    ])
                ])
            ]))
        let recursivelyScrubbedText = String(
            decoding: try RTCCanonicalJSON.encode(recursivelyScrubbed.value), as: UTF8.self)
        for canary in ["repositoryPath", "repository-path-canary", "path-canary", "recursive-credential-canary"] {
            try check(!recursivelyScrubbedText.contains(canary), "recursive scrub leaked \(canary)")
        }
        for category in ["sensitive-key", "path", "credential"] {
            try check(
                recursivelyScrubbed.findings.contains(where: { $0.category == category }),
                "recursive scrub omitted \(category) finding"
            )
        }
        let cappedCollection = ExportRedactor().scrub(
            .array(Array(repeating: .string("safe"), count: RTCExportLimits.maxDiagnosticCollectionItems + 1)))
        guard case .array(let cappedValues) = cappedCollection.value else {
            throw ExportTestFailure.failed("recursive scrub changed collection type")
        }
        try check(
            cappedValues.count == RTCExportLimits.maxDiagnosticCollectionItems
                && cappedCollection.findings.contains(where: { $0.category == "count-cap" }),
            "recursive collection cap was not deterministic"
        )

        let diagramInput = try diagramTourInput(input, label: "Validated node")
        let diagramExport = try await exporter.normalExport(diagramInput)
        try check(
            String(decoding: diagramExport, as: UTF8.self).contains(#""kind":"diagram""#),
            "validated diagram was not exported"
        )

        let root = URL(fileURLWithPath: ".test-state/rtc-export-tests-\(UUID().uuidString)", isDirectory: true)
        let staging = root.appendingPathComponent("private", isDirectory: true)
        let destination = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let diagnostic = DiagnosticExportInput(
            review: input,
            records: [
                try DiagnosticRecord(
                    operation: "export.prepare", phase: "failed",
                    message: "failed at /Users/private/repository token=credential-canary",
                    durationMilliseconds: 12, itemCount: 4),
                try DiagnosticRecord(
                    operation: "export.prepare", phase: "percent",
                    message: "%2FUsers%2Fprivate%2Fencoded-canary"),
                try DiagnosticRecord(
                    operation: "export.prepare", phase: "base64",
                    message: Data("/Users/private/base64-canary".utf8).base64EncodedString()),
                try DiagnosticRecord(
                    operation: "export.prepare", phase: "confusable",
                    message: "fіle:///Users/private/confusable-canary"),
            ],
            attachments: [
                DiagnosticAttachment(
                    filename: "../../sk-live-filename-secret-canary.log",
                    text: "Bearer attachment-credential at /private/state/file",
                    approvedForExport: true
                ),
                DiagnosticAttachment(
                    filename: "raw-source.txt", text: "unapproved-blob-canary", approvedForExport: false),
            ]
        )
        do {
            _ = try await exporter.prepareDiagnosticExport(
                diagnostic,
                privateStagingRoot: URL(fileURLWithPath: "/tmp/repo/export-must-not-be-created")
            )
            throw ExportTestFailure.failed("staging inside the reviewed repository was accepted")
        } catch is RTCContractError {}
        let diagnosticComposition = try composition(exporter: exporter, input: diagnostic, staging: staging)
        let preview = try await prepare(diagnosticComposition, reviewID: input.manifest.id)
        try check(preview.requiresConfirmation, "diagnostic preview did not require confirmation")
        try check(preview.omittedAttachmentCount == 1, "unapproved attachment was not omitted")
        try check(preview.redactions.contains(where: { $0.category == "path" }), "path redaction missing")
        try check(
            preview.redactions.contains(where: { $0.category == "encoded-path" }),
            "encoded path redaction missing")
        try check(
            preview.includedFieldPaths.contains("$.review.revision.baseSHA"),
            "preview did not enumerate normal export fields"
        )
        try check(
            !preview.includedFieldPaths.contains(where: {
                $0.localizedCaseInsensitiveContains("repositoryPath")
            }),
            "preview exposed a repository-path field"
        )
        try check(
            preview.files.contains(where: { $0.filename == "attachment-001.log" }),
            "diagnostic filename was not generated"
        )
        try check(
            !String(describing: preview).contains("filename-secret-canary"), "preview leaked input filename")
        try check(
            (try FileManager.default.contentsOfDirectory(atPath: destination.path)).isEmpty, "preview published files")

        let prepareCannotConfirm = try await confirm(
            diagnosticComposition,
            pendingID: preview.pendingID,
            destination: destination,
            dispatcher: diagnosticComposition.prepareDispatcher,
            capability: prepareCapability
        )
        try check(!prepareCannotConfirm.ok, "preparation capability consumed a diagnostic export")

        let stagedEntries = try FileManager.default.contentsOfDirectory(atPath: staging.path)
        try check(stagedEntries.count == 1, "expected one private staged bundle")
        let stagedBundle = staging.appendingPathComponent(stagedEntries[0], isDirectory: true)
        try check(permissions(stagedBundle) == 0o700, "staged bundle permissions are not private")
        for filename in try FileManager.default.contentsOfDirectory(atPath: stagedBundle.path) {
            try check(
                permissions(stagedBundle.appendingPathComponent(filename)) == 0o600,
                "staged file permissions are not private")
        }

        let confirmed = try await confirm(
            diagnosticComposition,
            pendingID: preview.pendingID,
            destination: destination
        )
        try check(confirmed.ok, "independently provisioned confirmation capability failed")
        guard let confirmedBody = confirmed.body else {
            throw ExportTestFailure.failed("confirmation omitted response")
        }
        let publishedName = try JSONDecoder().decode(DiagnosticConfirmResponse.self, from: confirmedBody).filename
        let published = destination.appendingPathComponent(publishedName, isDirectory: true)
        let diagnosticData = try Data(contentsOf: published.appendingPathComponent("diagnostics.json"))
        let diagnosticText = String(decoding: diagnosticData, as: UTF8.self)
        for canary in [
            "/tmp/repo", "/Users/private/repository", "credential-canary", "encoded-canary", "base64-canary",
            "confusable-canary", "unapproved-blob-canary",
        ] {
            try check(!diagnosticText.contains(canary), "diagnostic export leaked \(canary)")
        }
        try check(
            !FileManager.default.fileExists(atPath: stagedBundle.path), "private staging remained after confirmation")
        let consumedAgain = try await confirm(
            diagnosticComposition,
            pendingID: preview.pendingID,
            destination: destination
        )
        try check(!consumedAgain.ok, "confirmation capability consumed one pending export twice")

        do {
            var attachments: [DiagnosticAttachment] = []
            for index in 0..<RTCExportLimits.maxDiagnosticFiles {
                attachments.append(
                    DiagnosticAttachment(filename: "\(index).txt", text: "safe", approvedForExport: true))
            }
            _ = try await exporter.prepareDiagnosticExport(
                DiagnosticExportInput(review: input, attachments: attachments),
                privateStagingRoot: staging
            )
            throw ExportTestFailure.failed("diagnostic file cap was not enforced")
        } catch is RTCContractError {}

        do {
            let record = try DiagnosticRecord(operation: "export.prepare", phase: "bounded")
            _ = try await exporter.prepareDiagnosticExport(
                DiagnosticExportInput(
                    review: input,
                    records: Array(repeating: record, count: RTCExportLimits.maxDiagnosticCollectionItems + 1)
                ),
                privateStagingRoot: root.appendingPathComponent("record-cap", isDirectory: true)
            )
            throw ExportTestFailure.failed("diagnostic record count cap was not enforced")
        } catch is RTCContractError {}

        do {
            _ = try await exporter.prepareDiagnosticExport(
                DiagnosticExportInput(
                    review: input,
                    attachments: [
                        DiagnosticAttachment(
                            filename: "oversized.txt",
                            text: String(repeating: "x", count: RTCExportLimits.maxDiagnosticFileBytes + 1),
                            approvedForExport: true
                        )
                    ]
                ),
                privateStagingRoot: root.appendingPathComponent("attachment-cap", isDirectory: true)
            )
            throw ExportTestFailure.failed("diagnostic attachment input cap was not enforced")
        } catch is RTCContractError {}

        let destinationTwo = root.appendingPathComponent("destination-two", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationTwo, withIntermediateDirectories: true)
        let repeatPreview = try await prepare(diagnosticComposition, reviewID: input.manifest.id)
        let repeatConfirmation = try await confirm(
            diagnosticComposition,
            pendingID: repeatPreview.pendingID,
            destination: destinationTwo
        )
        try check(repeatConfirmation.ok, "repeated diagnostic confirmation failed")
        guard let repeatBody = repeatConfirmation.body else {
            throw ExportTestFailure.failed("repeated confirmation omitted response")
        }
        let repeatName = try JSONDecoder().decode(DiagnosticConfirmResponse.self, from: repeatBody).filename
        let repeatPublished = destinationTwo.appendingPathComponent(repeatName, isDirectory: true)
        try check(
            try Data(contentsOf: published.appendingPathComponent("manifest.json"))
                == Data(contentsOf: repeatPublished.appendingPathComponent("manifest.json")),
            "diagnostic logical manifest is not deterministic"
        )

        let delay = OneShotDelay()
        let expiryStaging = root.appendingPathComponent("expiry-private", isDirectory: true)
        let expiryDestination = root.appendingPathComponent("expiry-destination", isDirectory: true)
        try FileManager.default.createDirectory(at: expiryDestination, withIntermediateDirectories: true)
        let expiryComposition = try composition(
            exporter: exporter,
            input: diagnostic,
            staging: expiryStaging,
            approvalLifetime: 0.001,
            beforeApprovalConsumption: { await delay.pauseOnce() }
        )
        let expiryPreview = try await prepare(expiryComposition, reviewID: input.manifest.id)
        let expired = try await confirm(
            expiryComposition,
            pendingID: expiryPreview.pendingID,
            destination: expiryDestination
        )
        try check(!expired.ok, "expired confirmation approval was consumed")
        try check(
            (try FileManager.default.contentsOfDirectory(atPath: expiryDestination.path)).isEmpty,
            "expired confirmation published output"
        )
        let fresh = try await confirm(
            expiryComposition,
            pendingID: expiryPreview.pendingID,
            destination: expiryDestination
        )
        try check(fresh.ok, "fresh confirmation approval did not consume pending export")

        let cancellationGate = CancellationGate()
        let cancelledStaging = root.appendingPathComponent("cancelled-private", isDirectory: true)
        let cancellationExporter = ReviewExporter(
            anchors: AcceptingExportAnchors(),
            diagnosticIOFaults: DiagnosticIOFaults { cancellationGate.pauseOnSecondChunk($0) }
        )
        let cancellationInput = DiagnosticExportInput(
            review: input,
            attachments: [
                DiagnosticAttachment(
                    filename: "large.log",
                    text: String(repeating: "safe diagnostic text ", count: 1_000),
                    approvedForExport: true
                )
            ]
        )
        let cancellationComposition = try composition(
            exporter: cancellationExporter,
            input: cancellationInput,
            staging: cancelledStaging
        )
        let cancelled = Task {
            try await dispatch(
                cancellationComposition.prepareDispatcher,
                operation: DiagnosticExportIPCComposition.prepareOperation,
                capability: prepareCapability,
                body: DiagnosticPrepareRequest(reviewID: input.manifest.id)
            )
        }
        try check(await cancellationGate.waitUntilReached(), "mid-write gate was not reached")
        cancelled.cancel()
        cancellationGate.release.signal()
        let cancelledResponse = try await cancelled.value
        try check(!cancelledResponse.ok, "cancelled preparation returned a pending export")
        try check(
            !FileManager.default.fileExists(atPath: cancelledStaging.path)
                || (try FileManager.default.contentsOfDirectory(atPath: cancelledStaging.path)).isEmpty,
            "mid-write cancellation left private staging residue"
        )

        for (name, fault) in [
            (
                "write",
                DiagnosticIOFaults { point in
                    if case .stagingBeforeWrite = point { throw RTCContractError.invalid("injected write failure") }
                }
            ),
            (
                "sync",
                DiagnosticIOFaults { point in
                    if case .stagingBeforeSync = point { throw RTCContractError.invalid("injected sync failure") }
                }
            ),
        ] {
            let faultStaging = root.appendingPathComponent("fault-\(name)", isDirectory: true)
            let faultExporter = ReviewExporter(anchors: AcceptingExportAnchors(), diagnosticIOFaults: fault)
            let faultComposition = try composition(
                exporter: faultExporter,
                input: diagnostic,
                staging: faultStaging
            )
            let response = try await dispatch(
                faultComposition.prepareDispatcher,
                operation: DiagnosticExportIPCComposition.prepareOperation,
                capability: prepareCapability,
                body: DiagnosticPrepareRequest(reviewID: input.manifest.id)
            )
            try check(!response.ok, "injected \(name) failure prepared an export")
            try check(
                !FileManager.default.fileExists(atPath: faultStaging.path)
                    || (try FileManager.default.contentsOfDirectory(atPath: faultStaging.path)).isEmpty,
                "injected \(name) failure left private staging residue"
            )
        }

        for (name, fault) in [
            (
                "write",
                DiagnosticIOFaults { point in
                    if case .publishBeforeWrite = point { throw RTCContractError.invalid("injected write failure") }
                }
            ),
            (
                "sync",
                DiagnosticIOFaults { point in
                    if case .publishBeforeSync = point { throw RTCContractError.invalid("injected sync failure") }
                }
            ),
        ] {
            let publishStaging = root.appendingPathComponent("publish-fault-private-\(name)", isDirectory: true)
            let publishDestination = root.appendingPathComponent("publish-fault-destination-\(name)", isDirectory: true)
            try FileManager.default.createDirectory(at: publishDestination, withIntermediateDirectories: true)
            let faultExporter = ReviewExporter(anchors: AcceptingExportAnchors(), diagnosticIOFaults: fault)
            let faultComposition = try composition(
                exporter: faultExporter,
                input: diagnostic,
                staging: publishStaging
            )
            let faultPreview = try await prepare(faultComposition, reviewID: input.manifest.id)
            let response = try await confirm(
                faultComposition,
                pendingID: faultPreview.pendingID,
                destination: publishDestination
            )
            try check(!response.ok, "injected publish \(name) failure succeeded")
            try check(
                (try FileManager.default.contentsOfDirectory(atPath: publishDestination.path)).isEmpty,
                "injected publish \(name) failure left destination residue"
            )
        }

        let swapStaging = root.appendingPathComponent("swap-private", isDirectory: true)
        let movedStaging = root.appendingPathComponent("swap-private-original", isDirectory: true)
        let swapDestination = root.appendingPathComponent("swap-destination", isDirectory: true)
        try FileManager.default.createDirectory(at: swapDestination, withIntermediateDirectories: true)
        let swap = StagingRootSwap(root: swapStaging, moved: movedStaging)
        let swapExporter = ReviewExporter(
            anchors: AcceptingExportAnchors(),
            diagnosticIOFaults: DiagnosticIOFaults { try swap.swapAfterFirstLeaf($0) }
        )
        let swapComposition = try composition(exporter: swapExporter, input: diagnostic, staging: swapStaging)
        let swapPreview = try await prepare(swapComposition, reviewID: input.manifest.id)
        try check(
            (try FileManager.default.contentsOfDirectory(atPath: swapStaging.path)).isEmpty,
            "ancestor swap redirected staging into replacement root"
        )
        try check(
            (try FileManager.default.contentsOfDirectory(atPath: movedStaging.path)).count == 1,
            "descriptor-held staging root lost the pending bundle"
        )
        let swapConfirmed = try await confirm(
            swapComposition,
            pendingID: swapPreview.pendingID,
            destination: swapDestination
        )
        try check(swapConfirmed.ok, "descriptor-held pending export could not be confirmed")
        try check(
            (try FileManager.default.contentsOfDirectory(atPath: movedStaging.path)).isEmpty,
            "descriptor-relative cleanup left residue after ancestor swap"
        )

        let symlinkTarget = root.appendingPathComponent("symlink-target", isDirectory: true)
        let symlinkParent = root.appendingPathComponent("destination-alias", isDirectory: true)
        let symlinkChild = symlinkParent.appendingPathComponent("inside", isDirectory: true)
        try FileManager.default.createDirectory(
            at: symlinkTarget.appendingPathComponent("inside"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: symlinkParent, withDestinationURL: symlinkTarget)
        let symlinkPreview = try await prepare(diagnosticComposition, reviewID: input.manifest.id)
        let symlinkResponse = try await confirm(
            diagnosticComposition,
            pendingID: symlinkPreview.pendingID,
            destination: symlinkChild
        )
        try check(!symlinkResponse.ok, "symlink ancestor destination was accepted")

        let concurrentDestination = root.appendingPathComponent("concurrent", isDirectory: true)
        try FileManager.default.createDirectory(at: concurrentDestination, withIntermediateDirectories: true)
        let concurrentPreview = try await prepare(diagnosticComposition, reviewID: input.manifest.id)
        let results = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for _ in 0..<2 {
                group.addTask {
                    (try? await confirm(
                        diagnosticComposition,
                        pendingID: concurrentPreview.pendingID,
                        destination: concurrentDestination
                    ).ok) == true
                }
            }
            var values = [Bool]()
            for await value in group { values.append(value) }
            return values
        }
        try check(results.filter { $0 }.count == 1, "concurrent confirmation was not one-shot")

        let readOnlyDestination = root.appendingPathComponent("read-only", isDirectory: true)
        try FileManager.default.createDirectory(at: readOnlyDestination, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: readOnlyDestination.path)
        let readOnlyPreview = try await prepare(diagnosticComposition, reviewID: input.manifest.id)
        let readOnlyResponse = try await confirm(
            diagnosticComposition,
            pendingID: readOnlyPreview.pendingID,
            destination: readOnlyDestination
        )
        try check(!readOnlyResponse.ok, "read-only destination was published")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: readOnlyDestination.path)
        try check(
            (try FileManager.default.contentsOfDirectory(atPath: readOnlyDestination.path)).isEmpty,
            "failed publication left partial state")

        let cleanupDestination = root.appendingPathComponent("cleanup-failure", isDirectory: true)
        try FileManager.default.createDirectory(at: cleanupDestination, withIntermediateDirectories: true)
        let cleanupPreview = try await prepare(diagnosticComposition, reviewID: input.manifest.id)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: staging.path)
        let cleanupResponse = try await confirm(
            diagnosticComposition,
            pendingID: cleanupPreview.pendingID,
            destination: cleanupDestination
        )
        try check(!cleanupResponse.ok, "post-publication cleanup failure was not reported")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: staging.path)
        try check(
            !(try FileManager.default.contentsOfDirectory(atPath: cleanupDestination.path)).isEmpty,
            "cleanup failure did not preserve published output")
        let cleanupRetry = try await confirm(
            diagnosticComposition,
            pendingID: cleanupPreview.pendingID,
            destination: cleanupDestination
        )
        try check(!cleanupRetry.ok, "published cleanup failure was retried")

        let inRepositoryPreview = try await prepare(diagnosticComposition, reviewID: input.manifest.id)
        let inRepositoryResponse = try await confirm(
            diagnosticComposition,
            pendingID: inRepositoryPreview.pendingID,
            destination: URL(fileURLWithPath: input.manifest.revision.repositoryPath)
        )
        try check(!inRepositoryResponse.ok, "repository destination was accepted")
        try check(
            !String(describing: inRepositoryResponse).contains(input.manifest.revision.repositoryPath),
            "raw repository path escaped in diagnostic error"
        )

        do {
            let largeRun = RichTextRun(
                kind: .plain,
                text: try BoundedString(String(repeating: "x", count: 4_096))
            )
            let largeBody = try RichText(runs: [largeRun])
            let anchor = try ReviewAnchor(
                revision: input.manifest.revision,
                path: "Sources/App.swift",
                scope: .file
            )
            let messages = (1...1_100).map { sequence in
                ThreadMessage(
                    sequence: sequence,
                    author: .captain,
                    body: largeBody,
                    createdAt: Date(timeIntervalSince1970: 0)
                )
            }
            let largeThread = ReviewThread(
                reviewID: input.manifest.id,
                revision: input.manifest.revision,
                anchor: anchor,
                state: .open,
                messages: messages
            )
            _ = try await exporter.normalExport(
                ReviewExportInput(manifest: input.manifest, threads: [largeThread])
            )
            throw ExportTestFailure.failed("normal export byte cap was not enforced")
        } catch is RTCContractError {}

        for hostileText in [
            "<svg onload=alert>",
            "javascript:alert",
            "[resource](file)",
            "url(resource)",
            "$(command)",
            "`command`",
        ] {
            do {
                _ = try await exporter.normalExport(try diagramTourInput(input, label: hostileText))
                throw ExportTestFailure.failed("hostile diagram text was exported: \(hostileText)")
            } catch is RTCContractError {}
            do {
                _ = try await exporter.normalExport(try nestedTourTextInput(input, text: hostileText))
                throw ExportTestFailure.failed("hostile nested tour text was exported: \(hostileText)")
            } catch is RTCContractError {}
        }

        do {
            _ = try await exporter.normalExport(
                try nestedTourTextInput(input, text: "safe words", kind: .code))
            throw ExportTestFailure.failed("executable rich-text run was exported")
        } catch is RTCContractError {}

        do {
            _ = try await exporter.normalExport(try ungroundedSliceInput(input))
            throw ExportTestFailure.failed("ungrounded diff slice was exported")
        } catch is RTCContractError {}

        let contextOne = DiffLine(
            kind: .context, oldLine: 1, newLine: 1, text: "one",
            contextHash: SHA256Digest(data: Data("one".utf8)))
        let deletion = DiffLine(
            kind: .deletion, oldLine: 2, newLine: nil, text: "old two",
            contextHash: SHA256Digest(data: Data("old two".utf8)))
        let addition = DiffLine(
            kind: .addition, oldLine: nil, newLine: 2, text: "new two",
            contextHash: SHA256Digest(data: Data("new two".utf8)))
        let contextThree = DiffLine(
            kind: .context, oldLine: 3, newLine: 3, text: "three",
            contextHash: SHA256Digest(data: Data("three".utf8)))
        let exactLines = [contextOne, deletion, addition, contextThree]
        _ = try await exporter.normalExport(
            try diffSliceInput(
                input, lines: exactLines, side: .old, start: 1, end: 2,
                startHash: contextOne.contextHash, endHash: deletion.contextHash))
        _ = try await exporter.normalExport(
            try diffSliceInput(
                input, lines: exactLines, side: .new, start: 2, end: 3,
                startHash: addition.contextHash, endHash: contextThree.contextHash))
        let invalidSlices: [(String, ReviewExportInput)] = [
            (
                "mixed old side",
                try diffSliceInput(
                    input, lines: exactLines, side: .old, start: 1, end: 3,
                    startHash: contextOne.contextHash, endHash: contextThree.contextHash)
            ),
            (
                "mixed new side",
                try diffSliceInput(
                    input, lines: exactLines, side: .new, start: 1, end: 3,
                    startHash: contextOne.contextHash, endHash: contextThree.contextHash)
            ),
            (
                "gapped side",
                try diffSliceInput(
                    input, lines: [contextOne, contextThree], side: .new, start: 1, end: 3,
                    startHash: contextOne.contextHash, endHash: contextThree.contextHash)
            ),
            (
                "digest mismatch",
                try diffSliceInput(
                    input, lines: exactLines, side: .old, start: 1, end: 2,
                    startHash: SHA256Digest(data: Data("wrong".utf8)), endHash: deletion.contextHash)
            ),
            (
                "binary artifact",
                try diffSliceInput(
                    input, lines: exactLines, side: .old, start: 1, end: 2,
                    startHash: contextOne.contextHash, endHash: deletion.contextHash, binary: true)
            ),
            (
                "truncated artifact",
                try diffSliceInput(
                    input, lines: exactLines, side: .old, start: 1, end: 2,
                    startHash: contextOne.contextHash, endHash: deletion.contextHash, truncated: true)
            ),
            (
                "wrong hunk",
                try diffSliceInput(
                    input, lines: exactLines, side: .old, start: 1, end: 2,
                    startHash: contextOne.contextHash, endHash: deletion.contextHash, hunkIndex: 1)
            ),
            (
                "wrong path",
                try diffSliceInput(
                    input, lines: exactLines, side: .old, start: 1, end: 2,
                    startHash: contextOne.contextHash, endHash: deletion.contextHash,
                    slicePath: "Sources/Other.swift")
            ),
        ]
        for (name, candidate) in invalidSlices {
            do {
                _ = try await exporter.normalExport(candidate)
                throw ExportTestFailure.failed("invalid diff slice was exported: \(name)")
            } catch is RTCContractError {}
        }

        do {
            _ = try await exporter.normalExport(try diagramTourInput(input, label: "safe", groupCount: 65))
            throw ExportTestFailure.failed("unbounded diagram groups were exported")
        } catch is RTCContractError {}

        let anchorCounter = AnchorCounter()
        let preflightExporter = ReviewExporter(anchors: CountingExportAnchors(counter: anchorCounter))
        do {
            _ = try await preflightExporter.normalExport(
                try diagramTourInput(input, label: "safe", groupCount: 65))
            throw ExportTestFailure.failed("preflight accepted an oversized nested diagram")
        } catch is RTCContractError {}
        try check(await anchorCounter.count() == 0, "anchor resolution began before aggregate preflight rejection")

        do {
            _ = try await exporter.normalExport(
                try replacingApprovalPayload(
                    input,
                    payload: try reviewPayload([
                        "warnings": ["open"],
                        "credential": "opaque-canary",
                    ])))
            throw ExportTestFailure.failed("unallowlisted event payload was exported")
        } catch is RTCContractError {}

        print("RTC export checks passed")
    }

    static func fixtureInput() throws -> ReviewExportInput {
        let tourData = try Data(contentsOf: URL(fileURLWithPath: "native/Fixtures/Tours/valid-tour.json"))
        let tour = try JSONDecoder().decode(TourDocument.self, from: tourData)
        let revision = tour.revision
        let sourceLine = DiffLine(
            kind: .addition,
            oldLine: nil,
            newLine: 1,
            text: "source-canary",
            contextHash: SHA256Digest(data: Data("source-canary".utf8))
        )
        let hunk = DiffHunk(
            header: "@@ -0,0 +1 @@", oldStart: 0, oldLines: 0, newStart: 1, newLines: 1, lines: [sourceLine])
        let file = DiffArtifact(
            path: "Sources/App.swift",
            status: .added,
            additions: 1,
            deletions: 0,
            binary: false,
            truncated: false,
            oldLineCount: 0,
            newLineCount: 1,
            hunks: [hunk]
        )
        let instant = Date(timeIntervalSince1970: 1_700_000_000)
        let manifest = ReviewManifest(
            id: revision.reviewID,
            revision: revision,
            createdAt: instant,
            updatedAt: instant,
            status: .inReview,
            stale: false,
            summary: ReviewSummary(files: 1, additions: 1, deletions: 0),
            files: [file]
        )
        let anchor = try ReviewAnchor(revision: revision, path: file.path, scope: .file)
        let body = try RichText(runs: [
            RichTextRun(kind: .plain, text: "inspect /tmp/repo and Bearer credential-canary")
        ])
        let message = ThreadMessage(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000206")!,
            sequence: 1,
            author: .captain,
            body: body,
            createdAt: instant
        )
        let thread = ReviewThread(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000207")!,
            reviewID: revision.reviewID,
            revision: revision,
            anchor: anchor,
            state: .open,
            messages: [message]
        )
        let event = ReviewEvent(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000208")!,
            reviewID: revision.reviewID,
            revision: revision,
            sequence: 1,
            kind: .feedback,
            payload: try reviewPayload(["threadIDs": [thread.id.uuidString]]),
            createdAt: instant
        )
        let decision = ReviewEvent(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000209")!,
            reviewID: revision.reviewID,
            revision: revision,
            sequence: 2,
            kind: .approval,
            payload: try reviewPayload(["warnings": ["open"]]),
            createdAt: instant
        )
        return ReviewExportInput(
            manifest: manifest,
            events: [event, decision],
            threads: [thread],
            progress: [FileProgress(path: file.path, viewed: true, version: 1)],
            tours: [tour]
        )
    }

    static func diagramTourInput(
        _ input: ReviewExportInput,
        label: String,
        groupCount: Int = 0
    ) throws -> ReviewExportInput {
        var tourObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(input.tours[0])) as! [String: Any]
        let anchor = try ReviewAnchor(revision: input.manifest.revision, path: "Sources/App.swift", scope: .file)
        let anchorObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(anchor)) as! [String: Any]
        let diagram: [String: Any] = [
            "id": "validated-diagram",
            "kind": "architecture",
            "title": "Architecture",
            "summary": ["runs": [["kind": "plain", "text": "Validated structure"]]],
            "nodes": [
                ["id": "entry", "label": label, "role": "entry", "anchors": [anchorObject]]
            ],
            "edges": [],
            "groups": (0..<groupCount).map { index in
                ["id": "group-\(index)", "label": "Group \(index)", "nodeIDs": ["entry"]]
            },
            "anchors": [anchorObject],
        ]
        var overview = tourObject["overview"] as! [[String: Any]]
        overview.append(["diagram": ["_0": diagram]])
        tourObject["overview"] = overview
        let tour = try JSONDecoder().decode(
            TourDocument.self,
            from: JSONSerialization.data(withJSONObject: tourObject, options: [.sortedKeys])
        )
        return ReviewExportInput(
            manifest: input.manifest,
            events: input.events,
            threads: input.threads,
            progress: input.progress,
            tours: [tour]
        )
    }

    static func nestedTourTextInput(
        _ input: ReviewExportInput,
        text: String,
        kind: RichTextRunKind = .plain
    ) throws -> ReviewExportInput {
        let nested = try RichText(runs: [RichTextRun(kind: kind, text: try BoundedString(text))])
        let original = input.tours[0]
        let tour = try TourDocument(
            id: original.id,
            revision: original.revision,
            producer: original.producer,
            inputDigest: original.inputDigest,
            title: original.title,
            overview: original.overview + [.bulletList([nested])],
            reviewFocuses: original.reviewFocuses,
            chapters: original.chapters,
            risks: original.risks
        )
        return ReviewExportInput(
            manifest: input.manifest,
            events: input.events,
            threads: input.threads,
            progress: input.progress,
            tours: [tour]
        )
    }

    static func diffSliceInput(
        _ input: ReviewExportInput,
        lines: [DiffLine],
        side: AnchorSide,
        start: Int,
        end: Int,
        startHash: SHA256Digest,
        endHash: SHA256Digest,
        binary: Bool = false,
        truncated: Bool = false,
        hunkIndex: Int = 0,
        slicePath: String = "Sources/App.swift"
    ) throws -> ReviewExportInput {
        let hunk = DiffHunk(
            header: "@@ -1,3 +1,3 @@",
            oldStart: 1,
            oldLines: 3,
            newStart: 1,
            newLines: 3,
            lines: lines
        )
        let file = DiffArtifact(
            path: "Sources/App.swift",
            status: binary ? .binary : .modified,
            additions: 1,
            deletions: 1,
            binary: binary,
            truncated: truncated,
            oldLineCount: 3,
            newLineCount: 3,
            hunks: [hunk]
        )
        let manifest = ReviewManifest(
            id: input.manifest.id,
            revision: input.manifest.revision,
            createdAt: input.manifest.createdAt,
            updatedAt: input.manifest.updatedAt,
            status: input.manifest.status,
            stale: input.manifest.stale,
            summary: ReviewSummary(files: 1, additions: 1, deletions: 1),
            files: [file]
        )
        var tourObject =
            try JSONSerialization.jsonObject(
                with: JSONEncoder().encode(input.tours[0])) as! [String: Any]
        var overview = tourObject["overview"] as! [[String: Any]]
        overview.append([
            "diffSlice": [
                "_0": [
                    "path": slicePath,
                    "hunkIndex": hunkIndex,
                    "side": side.rawValue,
                    "startLine": start,
                    "endLine": end,
                    "startContextHash": startHash.hex,
                    "endContextHash": endHash.hex,
                ]
            ]
        ])
        tourObject["overview"] = overview
        let tour = try JSONDecoder().decode(
            TourDocument.self,
            from: JSONSerialization.data(withJSONObject: tourObject, options: [.sortedKeys])
        )
        return ReviewExportInput(
            manifest: manifest,
            events: input.events,
            threads: input.threads,
            progress: input.progress,
            tours: [tour]
        )
    }

    static func ungroundedSliceInput(_ input: ReviewExportInput) throws -> ReviewExportInput {
        var tourObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(input.tours[0])) as! [String: Any]
        var overview = tourObject["overview"] as! [[String: Any]]
        overview.append([
            "diffSlice": [
                "_0": [
                    "path": "Not-In-Review.swift", "hunkIndex": 999, "side": "new",
                    "startLine": 1, "endLine": 1,
                    "startContextHash": String(repeating: "0", count: 64),
                    "endContextHash": String(repeating: "0", count: 64),
                ]
            ]
        ])
        tourObject["overview"] = overview
        let tour = try JSONDecoder().decode(
            TourDocument.self,
            from: JSONSerialization.data(withJSONObject: tourObject, options: [.sortedKeys]))
        return ReviewExportInput(
            manifest: input.manifest, events: input.events, threads: input.threads,
            progress: input.progress, tours: [tour])
    }

    static func replacingApprovalPayload(
        _ input: ReviewExportInput,
        payload: [String: String]
    ) throws -> ReviewExportInput {
        let approval = input.events.first { $0.kind == .approval }!
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(approval)) as! [String: Any]
        object["payload"] = payload
        let replaced = try JSONDecoder().decode(
            ReviewEvent.self,
            from: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
        return ReviewExportInput(
            manifest: input.manifest,
            events: input.events.map { $0.id == approval.id ? replaced : $0 },
            threads: input.threads,
            progress: input.progress,
            tours: input.tours
        )
    }

    static func reviewPayload(_ object: [String: Any]) throws -> [String: String] {
        let data = try JSONSerialization.data(
            withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        guard let value = String(data: data, encoding: .utf8) else {
            throw ExportTestFailure.failed("could not encode review payload")
        }
        return ["version": "1", "data": value]
    }

    static func permissions(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }
}
