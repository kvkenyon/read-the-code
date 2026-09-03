import RTCContracts
import RTCDesign
import RTCDomain
import RTCInboxFeature
import RTCIngest
import RTCIPC
import RTCLifecycle
import RTCReview
import RTCStore
import SwiftUI
#if canImport(UserNotifications)
import UserNotifications
#endif

@main
struct ReadTheCodeApp: App {
    @StateObject private var model = NativeApplicationModel()

    var body: some Scene {
        WindowGroup {
            Group {
                if let inbox = model.inbox {
                    switch model.route {
                    case let .review(id):
                        VStack(spacing: 16) {
                            Text("Review \(id.value)").font(.headline).textSelection(.enabled)
                            Text("The exact review is selected. The review workspace lands in RTC-202.")
                                .foregroundStyle(.secondary)
                            Button("Back to Inbox") { model.route = .inbox }
                        }
                        .frame(minWidth: 520, minHeight: 360)
                    case .inbox:
                        InboxView(model: inbox)
                    }
                } else if let error = model.errorMessage {
                    ContentUnavailableView("Inbox unavailable", systemImage: "exclamationmark.triangle", description: Text(error))
                } else {
                    ProgressView("Opening Inbox…")
                }
            }
            .task { await model.start() }
        }
    }
}

@MainActor
final class NativeApplicationModel: ObservableObject {
    @Published var inbox: InboxModel?
    @Published var route: ActivationRoute = .inbox
    @Published var errorMessage: String?

    private var runtime: RTCIngestRuntime?
    private var lifecycle: LifecycleCoordinator?
#if canImport(UserNotifications)
    private var notificationDelegate: NotificationResponseDelegate?
#endif

    func start() async {
        guard runtime == nil else { return }
        do {
            let lifecycle = LifecycleCoordinator(registrar: InMemoryLaunchAtLoginRegistrar()) { [weak self] event in
                Task { @MainActor in self?.route = event.route }
            }
#if canImport(UserNotifications)
            let presenter: any NotificationPresenter = SystemNotificationPresenter()
            let delegate = NotificationResponseDelegate(coordinator: lifecycle)
            UNUserNotificationCenter.current().delegate = delegate
            notificationDelegate = delegate
#else
            let presenter: any NotificationPresenter = DisabledNotificationPresenter()
#endif
            let runtime = try await RTCIngestRuntime(
                paths: RTCInstallationPaths.applicationSupport(),
                notificationPresenter: presenter
            )
            inbox = InboxModel(records: runtime.records, coordinator: runtime.coordinator) { id in
                await lifecycle.activate(reviewID: id)
            }
            self.lifecycle = lifecycle
            self.runtime = runtime
            try await runtime.start()
            await inbox?.refresh()
        } catch {
            errorMessage = "Private review state could not be opened."
        }
    }
}

#if !canImport(UserNotifications)
private struct DisabledNotificationPresenter: NotificationPresenter {
    func authorization() async -> NotificationAuthorization { .denied }
    func requestAuthorization() async throws -> NotificationAuthorization { .denied }
    func present(_ request: NotificationRequestData) async throws {}
    func setBadge(_ value: Int) async {}
}
#endif
