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
        let review = try ReviewID("0123456789abcdef01234567")
        let presenter = RecordingPresenter()
        let deliveries = InMemoryNotificationDeliveryStore()
        let service = DeduplicatingNotificationService(presenter: presenter, deliveryStore: deliveries)
        try await service.notify(reviewID: review, generic: true)
        try await service.notify(reviewID: review, generic: true)
        check(presenter.requests.count == 1, "duplicate notification")
        check(presenter.requests[0].privatePreview == false, "generic preview")

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

    final class ReceivedEvents: @unchecked Sendable {
        let lock = NSLock()
        var events = [ActivationRouteEvent]()
        func append(_ event: ActivationRouteEvent) { lock.lock(); events.append(event); lock.unlock() }
        func values() -> [ActivationRouteEvent] { lock.lock(); defer { lock.unlock() }; return events }
    }
}
