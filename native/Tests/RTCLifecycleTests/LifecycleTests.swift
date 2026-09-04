import Foundation
import RTCContracts
import RTCLifecycle

final class RecordingPresenter: NotificationPresenter, @unchecked Sendable {
    var requests = [NotificationRequestData]()
    let state: NotificationAuthorization = .authorized
    func authorization() async -> NotificationAuthorization { state }
    func requestAuthorization() async throws -> NotificationAuthorization { state }
    func present(_ request: NotificationRequestData) async throws { requests.append(request) }
    func setBadge(_ value: Int) async {}
}

@main struct LifecycleTests {
    static func check(_ value: @autoclosure () -> Bool, _ message: String) { precondition(value(), message) }
    static func main() async throws {
        notificationRuntimeRequiresAnApplicationBundle()
        let review = try ReviewID("0123456789abcdef01234567")
        let presenter = RecordingPresenter()
        let deliveries = InMemoryNotificationDeliveryStore()
        let service = DeduplicatingNotificationService(presenter: presenter, deliveryStore: deliveries)
        try await service.notify(reviewID: review, generic: true)
        try await service.notify(reviewID: review, generic: true)
        check(presenter.requests.count == 1, "duplicate notification")
        check(presenter.requests[0].privatePreview == false, "generic preview")

        let crashPresenter = CrashAwarePresenter()
        let crashStore = FailingDeliveryStore()
        let firstAttempt = DeduplicatingNotificationService(presenter: crashPresenter, deliveryStore: crashStore)
        do { try await firstAttempt.notify(reviewID: review, generic: true); preconditionFailure("delivery mark failure") }
        catch DeliveryProbe.failure {}
        let resumed = DeduplicatingNotificationService(presenter: crashPresenter, deliveryStore: crashStore)
        try await resumed.notify(reviewID: review, generic: true)
        let crashCount = await crashPresenter.count
        let crashPermissionRequests = await crashPresenter.permissionRequests
        check(crashCount == 1, "platform identifier reconciles crash after presentation")
        check(crashPermissionRequests == 0, "background delivery never requests permission")

        let received = ReceivedEvents()
        let registrar = InMemoryLaunchAtLoginRegistrar()
        let lifecycle = LifecycleCoordinator(registrar: registrar) { event in received.append(event) }
        await lifecycle.activate(reviewID: review)
        let routes = received.values()
        check(routes == [ActivationRouteEvent(route: .review(review))], "review route")
        try await lifecycle.launchAtLogin(enabled: true)
        let optedIn = await lifecycle.launchAtLoginState()
        check(optedIn.enabled, "login opt-in")
        try await lifecycle.launchAtLogin(enabled: false)
        let optedOut = await lifecycle.launchAtLoginState()
        check(!optedOut.enabled, "login opt-out")
        print("RTC lifecycle checks passed")
    }

    static func notificationRuntimeRequiresAnApplicationBundle() {
        precondition(!NotificationRuntimeSupport.canUseSystemCenter(
            bundleURL: URL(fileURLWithPath: "/tmp/ReadTheCode"), bundleIdentifier: nil))
        precondition(!NotificationRuntimeSupport.canUseSystemCenter(
            bundleURL: URL(fileURLWithPath: "/tmp/ReadTheCode"), bundleIdentifier: "com.readthecode.app"))
        precondition(NotificationRuntimeSupport.canUseSystemCenter(
            bundleURL: URL(fileURLWithPath: "/Applications/ReadTheCode.app"),
            bundleIdentifier: "com.readthecode.app"))
    }

    final class ReceivedEvents: @unchecked Sendable {
        let lock = NSLock()
        var events = [ActivationRouteEvent]()
        func append(_ event: ActivationRouteEvent) { lock.lock(); events.append(event); lock.unlock() }
        func values() -> [ActivationRouteEvent] { lock.lock(); defer { lock.unlock() }; return events }
    }
}

private enum DeliveryProbe: Error { case failure }

private actor FailingDeliveryStore: NotificationDeliveryStore {
    private var delivered = false
    private var failures = 1
    func wasDelivered(reviewID: ReviewID) async throws -> Bool { delivered }
    func markDelivered(reviewID: ReviewID) async throws {
        if failures > 0 { failures -= 1; throw DeliveryProbe.failure }
        delivered = true
    }
}

private actor CrashAwarePresenter: NotificationPresenter {
    private var presented = Set<ReviewID>()
    private(set) var permissionRequests = 0
    var count: Int { presented.count }
    func authorization() async -> NotificationAuthorization { .authorized }
    func requestAuthorization() async throws -> NotificationAuthorization { permissionRequests += 1; return .authorized }
    func present(_ request: NotificationRequestData) async throws { presented.insert(request.reviewID) }
    func setBadge(_ value: Int) async {}
    func hasPendingOrDelivered(reviewID: ReviewID) async -> Bool { presented.contains(reviewID) }
}
