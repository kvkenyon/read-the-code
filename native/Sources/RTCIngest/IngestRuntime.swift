import Foundation
import RTCContracts
import RTCGit
import RTCIPC
import RTCLifecycle
import RTCStore

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public struct RTCInstallationPaths: Sendable {
    public let root: URL
    public let store: URL
    public let spool: URL
    public let socket: URL
    public let capability: URL

    public init(root: URL) {
        self.root = root
        store = root.appendingPathComponent("State", isDirectory: true)
        spool = root.appendingPathComponent("Spool", isDirectory: true)
        socket = root.appendingPathComponent("reviewd.sock")
        capability = root.appendingPathComponent("install-capability")
    }

    public static func applicationSupport() throws -> RTCInstallationPaths {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw IPCTransportError.unavailable
        }
        return RTCInstallationPaths(root: base.appendingPathComponent("ReadTheCode", isDirectory: true))
    }

    public func prepare(createCapability: Bool) throws -> String {
        try protectDirectory(root); try protectDirectory(spool)
        if let value = try? readCapability() {
            do { try syncIPCDirectory(root) }
            catch { throw IPCTransportError.unavailable }
            return value
        }
        guard createCapability else { throw IPCTransportError.unavailable }
        let value = UUID().uuidString.replacingOccurrences(of: "-", with: "") + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let fd = open(capability.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        if fd < 0 {
            guard errno == EEXIST else { throw IPCTransportError.unavailable }
            return try readCapability()
        }
        defer { close(fd) }
        let data = Data(value.utf8)
        guard fchmod(fd, 0o600) == 0 else { throw IPCTransportError.unavailable }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if count > 0 { offset += count; continue }
                if count < 0, errno == EINTR { continue }
                throw IPCTransportError.unavailable
            }
        }
        guard fsync(fd) == 0 else { throw IPCTransportError.unavailable }
        do { try syncIPCDirectory(root) }
        catch { throw IPCTransportError.unavailable }
        return value
    }

    private func protectDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == geteuid() else { throw IPCTransportError.unavailable }
        guard chmod(url.path, 0o700) == 0 else { throw IPCTransportError.unavailable }
    }

    private func readCapability() throws -> String {
        let fd = open(capability.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw IPCTransportError.unavailable }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == geteuid(),
              (info.st_mode & 0o777) == 0o600, info.st_size == 64 else { throw IPCTransportError.unavailable }
        var data = Data(count: 65)
        var offset = 0
        try data.withUnsafeMutableBytes { raw in
            while offset < 65 {
                let count = read(fd, raw.baseAddress!.advanced(by: offset), 65 - offset)
                if count > 0 { offset += count; continue }
                if count == 0 { break }
                if errno == EINTR { continue }
                throw IPCTransportError.unavailable
            }
        }
        guard offset == 64 else { throw IPCTransportError.unavailable }
        data.removeSubrange(64..<data.count)
        guard let value = String(data: data, encoding: .utf8), value.allSatisfy(\.isHexDigit) else { throw IPCTransportError.unavailable }
        return value.lowercased()
    }
}

public final class RTCIngestRuntime: @unchecked Sendable {
    private static let allowedOperations: Set<String> = ["submitReview", "status", "pollReviewEvents", "closeReview", "retryReview"]
    public let records: SQLiteIngestRepository
    public let reviewRepository: SQLiteReviewRepository
    public let coordinator: SubmissionCoordinator
    public let handler: SubmissionOperationHandler
    public let notificationService: DeduplicatingNotificationService

    private let server: IPCServer
    private let paths: RTCInstallationPaths
    private let capability: String
    private var replayTask: Task<Void, Never>?

    public init(
        paths: RTCInstallationPaths,
        notificationPresenter: any NotificationPresenter
    ) async throws {
        self.paths = paths
        capability = try paths.prepare(createCapability: true)
        let store = try SQLiteStore(rootURL: paths.store)
        let records = SQLiteIngestRepository(store: store)
        let deliveries = SQLiteNotificationDeliveryStore(store: store)
        let notifications = DeduplicatingNotificationService(
            presenter: notificationPresenter,
            deliveryStore: deliveries
        )
        let reviewRepository = SQLiteReviewRepository(store: store)
        let coordinator = SubmissionCoordinator(git: ExactGitEngine(), records: records, notifications: notifications)
        let handler = SubmissionOperationHandler(coordinator: coordinator)
        self.records = records
        self.reviewRepository = reviewRepository
        self.coordinator = coordinator
        self.handler = handler
        notificationService = notifications
        server = IPCServer(
            socketPath: paths.socket.path,
            dispatcher: IPCDispatcher(
                handler: handler,
                peer: SameUIDPeerAuthenticator(),
                capabilities: IPCOperationAllowList([capability: Self.allowedOperations])
            )
        )
    }

    public func start() async throws {
        try server.start()
        do { try await replaySpool(); try await coordinator.resumeOutstanding() }
        catch { server.stop(); throw error }
        replayTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                guard let self else { return }
                do { try await self.replaySpool(); await self.coordinator.runUntilIdle() }
                catch {
                    do { try await self.records.recordRuntimeFailure(code: "SPOOL_REPLAY_FAILED", message: "Queued submissions will be retried.") }
                    catch { /* The next process start retries both store access and spool replay. */ }
                }
            }
        }
    }

    public func stop() { replayTask?.cancel(); replayTask = nil; server.stop() }

    private func replaySpool() async throws {
        let urls = try FileManager.default.contentsOfDirectory(
            at: paths.spool,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        ).filter { $0.pathExtension == "spool" }.sorted { $0.lastPathComponent < $1.lastPathComponent }.prefix(1_024)
        for url in urls {
            if let retry = try await records.spoolRetry(fileName: url.lastPathComponent), retry.nextRetry > Date() { continue }
            let envelope: IPCEnvelope
            let operation: BoundedString
            do {
                let framed = try readSpool(url)
                envelope = try IPCFrameCodec.decodeJSON(
                    IPCEnvelope.self,
                    from: IPCFrameCodec.decode(framed)
                )
                operation = try BoundedString(envelope.operation)
                let grants = IPCOperationAllowList([capability: Self.allowedOperations])
                guard envelope.protocolVersion.major == IPCConstants.protocolMajor,
                      grants.isAuthorized(envelope.capability, operation: operation.value) else { throw IPCFrameError.invalidEnvelope }
            } catch {
                try quarantine(url)
                try await records.clearSpoolRetry(fileName: url.lastPathComponent)
                continue
            }
            let response = await handler.handle(IPCRequest(
                schemaVersion: RTCConstants.schemaVersion,
                id: envelope.requestID,
                operation: operation,
                reviewID: nil,
                payload: envelope.body
            ))
            if response.ok {
                try FileManager.default.removeItem(at: url)
                try syncIPCDirectory(paths.spool)
                try await records.clearSpoolRetry(fileName: url.lastPathComponent)
            } else if response.error?.retryable == true {
                let retry = try await records.recordSpoolRetry(fileName: url.lastPathComponent, code: response.error?.code.rawValue ?? "RETRYABLE")
                if retry.attempt >= 5 { try quarantine(url); try await records.clearSpoolRetry(fileName: url.lastPathComponent) }
            } else {
                try quarantine(url)
                try await records.clearSpoolRetry(fileName: url.lastPathComponent)
            }
        }
    }

    private func readSpool(_ url: URL) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw IPCFrameError.invalidEnvelope }
        defer { close(fd) }
        var info = stat()
        let maximum = IPCConstants.maxFrameBytes + 4
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == geteuid(),
              (info.st_mode & 0o777) == 0o600, info.st_size >= 4, info.st_size <= maximum else { throw IPCFrameError.invalidEnvelope }
        var data = Data(count: Int(info.st_size))
        var offset = 0
        try data.withUnsafeMutableBytes { raw in
            while offset < raw.count {
                let count = read(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if count > 0 { offset += count; continue }
                if count < 0, errno == EINTR { continue }
                throw IPCFrameError.truncated
            }
        }
        return data
    }

    private func quarantine(_ url: URL) throws {
        var target = url.deletingPathExtension().appendingPathExtension("rejected")
        if FileManager.default.fileExists(atPath: target.path) {
            target = url.deletingPathExtension().appendingPathExtension("\(UUID().uuidString).rejected")
        }
        try FileManager.default.moveItem(at: url, to: target)
        try syncIPCDirectory(paths.spool)
    }
}
