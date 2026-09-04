import Foundation
import RTCContracts

#if canImport(AppKit)
import AppKit
#endif

#if canImport(UserNotifications)
@preconcurrency import UserNotifications
#endif

#if canImport(ServiceManagement)
import ServiceManagement
#endif

/// The small, platform-neutral event emitted when the application should show a review.
public enum ActivationRoute: Equatable, Sendable {
    case inbox
    case review(ReviewID)
}

public struct ActivationRouteEvent: Equatable, Sendable {
    public let route: ActivationRoute
    public init(route: ActivationRoute) { self.route = route }
}

public enum NotificationAuthorization: String, Codable, Sendable {
    case notDetermined, denied, provisional, authorized
}

/// `UNUserNotificationCenter.current()` aborts when called by a raw SwiftPM
/// executable because that process has no application-bundle proxy. Keep the
/// CLT launch path notification-free while retaining the system center for the
/// generated `.app` target.
public enum NotificationRuntimeSupport {
    public static func canUseSystemCenter(
        bundleURL: URL = Bundle.main.bundleURL,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> Bool {
        bundleURL.pathExtension.lowercased() == "app"
            && !(bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }
}

public struct LaunchAtLoginState: Equatable, Sendable {
    public let enabled: Bool
    public let registrationError: String?
    public init(enabled: Bool, registrationError: String? = nil) {
        self.enabled = enabled
        self.registrationError = registrationError
    }
}

/// Abstracts the durable idempotency bit from the notification platform.
public protocol NotificationDeliveryStore: Sendable {
    func wasDelivered(reviewID: ReviewID) async throws -> Bool
    func markDelivered(reviewID: ReviewID) async throws
}

public actor InMemoryNotificationDeliveryStore: NotificationDeliveryStore {
    private var delivered = Set<ReviewID>()
    public init() {}
    public func wasDelivered(reviewID: ReviewID) -> Bool { delivered.contains(reviewID) }
    public func markDelivered(reviewID: ReviewID) { delivered.insert(reviewID) }
}

public struct NotificationRequestData: Equatable, Sendable {
    public let reviewID: ReviewID
    public let title: String
    public let body: String
    public let privatePreview: Bool
    public init(reviewID: ReviewID, title: String, body: String, privatePreview: Bool) {
        self.reviewID = reviewID; self.title = title; self.body = body; self.privatePreview = privatePreview
    }
}

public protocol NotificationPresenter: Sendable {
    func authorization() async -> NotificationAuthorization
    func requestAuthorization() async throws -> NotificationAuthorization
    func present(_ request: NotificationRequestData) async throws
    func setBadge(_ value: Int) async
    func hasPendingOrDelivered(reviewID: ReviewID) async -> Bool
}

public extension NotificationPresenter {
    func hasPendingOrDelivered(reviewID: ReviewID) async -> Bool { false }
}

/// Keeps permission prompting at the lifecycle boundary and lets settings invoke it
/// only in response to an explicit user action.
public protocol NotificationPermissionRequester: Sendable {
    func requestPermissionIfNeeded() async throws -> NotificationAuthorization
}

/// A notification service whose durable delivery mark is written only after the post succeeds.
/// A denied notification permission therefore cannot prevent the caller from committing a review.
public actor DeduplicatingNotificationService: NotificationService, NotificationPermissionRequester {
    private let presenter: any NotificationPresenter
    private let deliveryStore: any NotificationDeliveryStore
    private let privatePreview: Bool
    private var permissionPrompted = false

    public init(presenter: any NotificationPresenter, deliveryStore: any NotificationDeliveryStore, privatePreview: Bool = false) {
        self.presenter = presenter; self.deliveryStore = deliveryStore; self.privatePreview = privatePreview
    }

    public func requestPermissionIfNeeded() async throws -> NotificationAuthorization {
        guard await presenter.authorization() == .notDetermined, !permissionPrompted else {
            return await presenter.authorization()
        }
        permissionPrompted = true
        return try await presenter.requestAuthorization()
    }

    public func authorization() async -> NotificationAuthorization { await presenter.authorization() }

    public func notify(reviewID: ReviewID, generic: Bool) async throws {
        guard try await !deliveryStore.wasDelivered(reviewID: reviewID) else { return }
        if await presenter.hasPendingOrDelivered(reviewID: reviewID) {
            try await deliveryStore.markDelivered(reviewID: reviewID)
            return
        }
        let usePrivate = privatePreview && !generic
        let request = NotificationRequestData(
            reviewID: reviewID,
            title: usePrivate ? "Review ready" : "Read the Code",
            body: usePrivate ? "A review is ready to open." : "A new review is ready.",
            privatePreview: usePrivate
        )
        try await presenter.present(request)
        try await deliveryStore.markDelivered(reviewID: reviewID)
    }
}

public actor NotificationOutboxConsumer {
    private let service: any NotificationService
    public init(service: any NotificationService) { self.service = service }
    public func consume(reviewID: ReviewID, generic: Bool = true) async throws { try await service.notify(reviewID: reviewID, generic: generic) }
}

public protocol LaunchAtLoginRegistrar: Sendable {
    func status() async -> LaunchAtLoginState
    func setEnabled(_ enabled: Bool) async throws -> LaunchAtLoginState
}

public actor LifecycleCoordinator: AppLifecycleService {
    private let registrar: any LaunchAtLoginRegistrar
    private let routeSink: @Sendable (ActivationRouteEvent) -> Void
    private var lastRoute: ActivationRouteEvent?

    public init(registrar: any LaunchAtLoginRegistrar, routeSink: @escaping @Sendable (ActivationRouteEvent) -> Void) {
        self.registrar = registrar; self.routeSink = routeSink
    }

    public func activate(reviewID: ReviewID?) async {
        let event = ActivationRouteEvent(route: reviewID.map(ActivationRoute.review) ?? .inbox)
        lastRoute = event
        routeSink(event)
    }

    public func launchAtLogin(enabled: Bool) async throws { _ = try await registrar.setEnabled(enabled) }
    public func launchAtLoginEnabled() async -> Bool { await registrar.status().enabled }
    public func launchAtLoginState() async -> LaunchAtLoginState { await registrar.status() }
    public func pendingRoute() -> ActivationRouteEvent? { lastRoute }
}

public struct InMemoryLaunchAtLoginRegistrar: LaunchAtLoginRegistrar {
    private let state: StateBox
    public init(enabled: Bool = false) { state = StateBox(enabled: enabled) }
    public func status() async -> LaunchAtLoginState { await state.get() }
    public func setEnabled(_ enabled: Bool) async throws -> LaunchAtLoginState { await state.set(enabled: enabled, error: nil) }
    public func setError(_ message: String) async { _ = await state.set(enabled: false, error: message) }
    private actor StateBox {
        var current: LaunchAtLoginState
        init(enabled: Bool) { current = LaunchAtLoginState(enabled: enabled) }
        func get() -> LaunchAtLoginState { current }
        func set(enabled: Bool, error: String?) -> LaunchAtLoginState { current = LaunchAtLoginState(enabled: enabled, registrationError: error); return current }
    }
}

#if canImport(UserNotifications)
public final class SystemNotificationPresenter: NotificationPresenter, @unchecked Sendable {
    private let center: UNUserNotificationCenter
    public init(center: UNUserNotificationCenter = .current()) { self.center = center }
    public func authorization() async -> NotificationAuthorization {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .denied: return .denied
        case .provisional: return .provisional
        case .authorized, .ephemeral: return .authorized
        default: return .notDetermined
        }
    }
    public func requestAuthorization() async throws -> NotificationAuthorization {
        _ = try await center.requestAuthorization(options: [.alert, .badge, .sound])
        return await authorization()
    }
    public func present(_ request: NotificationRequestData) async throws {
        let content = UNMutableNotificationContent(); content.title = request.title; content.body = request.body
        content.userInfo = ["reviewID": request.reviewID.value]
        let notification = UNNotificationRequest(identifier: "review-\(request.reviewID.value)", content: content, trigger: nil)
        try await center.add(notification)
    }
    public func setBadge(_ value: Int) async { try? await center.setBadgeCount(value) }
    public func hasPendingOrDelivered(reviewID: ReviewID) async -> Bool {
        let identifier = "review-\(reviewID.value)"
        let pending = await center.pendingNotificationRequests()
        if pending.contains(where: { $0.identifier == identifier }) { return true }
        let delivered = await center.deliveredNotifications()
        return delivered.contains(where: { $0.request.identifier == identifier })
    }
}
#endif

#if canImport(ServiceManagement)
public struct SystemLaunchAtLoginRegistrar: LaunchAtLoginRegistrar {
    public init() {}
    public func status() async -> LaunchAtLoginState { LaunchAtLoginState(enabled: SMAppService.mainApp.status == .enabled) }
    public func setEnabled(_ enabled: Bool) async throws -> LaunchAtLoginState {
        if enabled { try SMAppService.mainApp.register() } else { try await SMAppService.mainApp.unregister() }
        return await status()
    }
}
#endif

#if canImport(AppKit)
@MainActor
public final class AppDelegateBridge: NSObject, NSApplicationDelegate {
    private let coordinator: any AppLifecycleService
    public init(coordinator: any AppLifecycleService) { self.coordinator = coordinator }
    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    public func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "readthecode" {
            let id = url.host.flatMap { try? ReviewID($0) }
            Task { await coordinator.activate(reviewID: id) }
        }
    }
    public func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String : Any]) {
        let id = (userInfo["reviewID"] as? String).flatMap { try? ReviewID($0) }
        Task { await coordinator.activate(reviewID: id) }
    }
}

public final class NotificationResponseDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    private let coordinator: any AppLifecycleService
    public init(coordinator: any AppLifecycleService) { self.coordinator = coordinator }
    public func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let id = (response.notification.request.content.userInfo["reviewID"] as? String).flatMap { try? ReviewID($0) }
        await coordinator.activate(reviewID: id)
    }
}
#endif
