import Foundation
import RTCContracts
import RTCGit
import RTCIPC
import RTCLifecycle
import RTCStore

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
        try protectDirectory(root)
        try protectDirectory(spool)
        if FileManager.default.fileExists(atPath: capability.path) {
            let value = try String(contentsOf: capability, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            guard value.count >= 32 else { throw IPCTransportError.unavailable }
            return value
        }
        guard createCapability else { throw IPCTransportError.unavailable }
        let value = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        try Data(value.utf8).write(to: capability, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: capability.path)
        return value
    }

    private func protectDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
}

public final class RTCIngestRuntime: @unchecked Sendable {
    public let records: SQLiteIngestRepository
    public let reviewRepository: SQLiteReviewRepository
    public let coordinator: SubmissionCoordinator
    public let handler: SubmissionOperationHandler

    private let server: IPCServer
    private let paths: RTCInstallationPaths
    private let capability: String

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
        let coordinator = SubmissionCoordinator(
            git: ExactGitEngine(),
            records: records,
            reviews: reviewRepository,
            jobs: JobQueue(store: store),
            notifications: notifications
        )
        let handler = SubmissionOperationHandler(coordinator: coordinator)
        self.records = records
        self.reviewRepository = reviewRepository
        self.coordinator = coordinator
        self.handler = handler
        server = IPCServer(
            socketPath: paths.socket.path,
            dispatcher: IPCDispatcher(
                handler: handler,
                peer: SameUIDPeerAuthenticator(),
                capabilities: IPCAllowList([capability])
            )
        )
    }

    public func start() async throws {
        try server.start()
        try await replaySpool()
        try await coordinator.resumeOutstanding()
    }

    public func stop() { server.stop() }

    private func replaySpool() async throws {
        let urls = try FileManager.default.contentsOfDirectory(
            at: paths.spool,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        ).filter { $0.pathExtension == "spool" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        for url in urls {
            do {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                let framed = try Data(contentsOf: url)
                let envelope = try IPCFrameCodec.decodeJSON(
                    IPCEnvelope.self,
                    from: IPCFrameCodec.decode(framed)
                )
                guard envelope.protocolVersion.major == IPCConstants.protocolMajor,
                      envelope.capability == capability
                else { throw IPCFrameError.invalidEnvelope }
                let response = await handler.handle(IPCRequest(
                    schemaVersion: RTCConstants.schemaVersion,
                    id: envelope.requestID,
                    operation: try BoundedString(envelope.operation),
                    reviewID: nil,
                    payload: envelope.body
                ))
                if response.ok {
                    try FileManager.default.removeItem(at: url)
                } else {
                    throw IPCFrameError.invalidEnvelope
                }
            } catch {
                let rejected = url.deletingPathExtension().appendingPathExtension("rejected")
                try? FileManager.default.moveItem(at: url, to: rejected)
            }
        }
    }
}
