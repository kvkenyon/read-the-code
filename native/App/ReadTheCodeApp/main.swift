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
                        VStack(spacing: 0) {
                            if model.notificationAuthorization == .notDetermined {
                                Button("Enable Ready Notifications") { Task { await model.enableNotifications() } }
                                    .padding(8)
                                    .accessibilityHint("Requests macOS notification permission")
                            }
                            InboxView(model: inbox)
                        }
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
    @Published var notificationAuthorization: NotificationAuthorization = .notDetermined

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
            if ProcessInfo.processInfo.arguments.contains("--uitest-inbox-fixture") { try await seedInboxFixture(runtime) }
            notificationAuthorization = await runtime.notificationService.authorization()
            await inbox?.refresh()
        } catch {
            errorMessage = "Private review state could not be opened."
        }
    }

    func enableNotifications() async {
        guard let runtime else { return }
        do { notificationAuthorization = try await runtime.notificationService.requestPermissionIfNeeded() }
        catch { errorMessage = "Notification permission could not be requested." }
    }

    private func seedInboxFixture(_ runtime: RTCIngestRuntime) async throws {
        let base = String(repeating: "a", count: 40), head = String(repeating: "b", count: 40)
        let revision = try RevisionIdentity(repositoryPath: "/tmp/rtc-ui-fixture", baseSHA: base, headSHA: head)
        let submission = ReviewSubmission(
            idempotencyKey: UUID(uuidString: "00000000-0000-0000-0000-000000000201")!,
            repositoryPath: revision.repositoryPath,
            repositoryIdentity: SHA256Digest(data: Data("rtc-ui-fixture".utf8)),
            base: SubmittedRef(label: "base", expectedSHA: base), head: SubmittedRef(label: "head", expectedSHA: head),
            title: "Exact revision fixture", notify: false
        )
        _ = try await runtime.records.accept(submission, revision: revision)
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
