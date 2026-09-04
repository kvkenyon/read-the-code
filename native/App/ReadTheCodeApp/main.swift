import AppKit
import RTCAgentChat
import RTCContracts
import RTCDesign
import RTCDiffCanvas
import RTCDomain
import RTCGit
import RTCInboxFeature
import RTCIngest
import RTCLifecycle
import RTCReview
import RTCReviewWorkspace
import RTCStore
import RTCTourIntegration
import RTCWorkspaceShell
import SwiftUI
import TourWorkspace
#if canImport(UserNotifications)
import UserNotifications
#endif

@main
struct ReadTheCodeApp: App {
    @StateObject private var model = NativeApplicationModel()

    var body: some Scene {
        WindowGroup {
            NativeApplicationView(model: model)
                .frame(
                    minWidth: WorkspaceSizing.minimumWindow.width,
                    minHeight: WorkspaceSizing.minimumWindow.height)
                .task { await model.start() }
        }
        .defaultSize(
            width: WorkspaceSizing.minimumWindowWithAgent.width,
            height: WorkspaceSizing.minimumWindowWithAgent.height)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Repository…") { model.chooseRepository() }
                    .keyboardShortcut("o", modifiers: [.command])
            }
        }
    }
}

private struct NativeApplicationView: View {
    @ObservedObject var model: NativeApplicationModel

    var body: some View {
        Group {
            if let inbox = model.inbox {
                switch model.route {
                case let .review(id): review(id)
                case .inbox: inboxView(inbox)
                }
            } else if let error = model.errorMessage {
                RTCErrorState(title: "Inbox unavailable", message: error)
            } else {
                ProgressView("Opening private review state…")
            }
        }
        .background(RTCDesign.color(.canvas))
    }

    @ViewBuilder
    private func review(_ id: ReviewID) -> some View {
        if let session = model.reviewSession, session.id == id {
            NativeReviewView(session: session) { model.showInbox() }
        } else if let error = model.reviewErrorMessage {
            VStack(spacing: 16) {
                RTCErrorState(
                    title: "Review unavailable", message: error,
                    retry: { Task { await model.openReview(id) } })
                Button("Back to Inbox") { model.showInbox() }
                    .buttonStyle(RTCButtonStyle())
            }
            .padding(32)
        } else {
            ProgressView("Opening exact committed revision…")
                .task(id: id.value) { await model.openReview(id) }
        }
    }

    private func inboxView(_ inbox: InboxModel) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Review inbox").font(.headline)
                    Text("Exact committed comparisons, stored outside repositories")
                        .font(.caption)
                        .foregroundStyle(RTCDesign.color(.textSecondary))
                }
                Spacer()
                if model.notificationAuthorization == .notDetermined {
                    Button("Enable Ready Notifications") {
                        Task { await model.enableNotifications() }
                    }
                    .buttonStyle(RTCButtonStyle())
                    .accessibilityHint("Requests macOS notification permission")
                }
                Button { model.chooseRepository() } label: {
                    Label(
                        model.isOpeningRepository ? "Opening…" : "Open Repository…",
                        systemImage: "folder")
                }
                .buttonStyle(RTCButtonStyle(prominent: true))
                .disabled(model.isOpeningRepository)
                .help("Review HEAD^ → HEAD without reading working-tree changes")
            }
            .padding(12)
            Divider()
            if let error = model.openRepositoryError {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(error).font(.caption)
                    Spacer()
                    Button("Dismiss") { model.openRepositoryError = nil }.buttonStyle(.plain)
                }
                .padding(8)
                .background(RTCDesign.color(.surface))
            }
            InboxView(model: inbox)
        }
    }
}

@MainActor
private final class ReviewNavigationState: ObservableObject {
    @Published var mode: WorkspaceMode = .tour
    @Published var agentRailOpen = false
}

@MainActor
private final class NativeReviewSession: ObservableObject {
    let id: ReviewID
    let title: String
    let repositoryName: String
    let revision: RevisionIdentity
    let review: ReviewWorkspaceModel
    let tour: TourWorkspaceModel
    let conversation: AgentConversationRailModel
    let navigation: ReviewNavigationState

    init(
        id: ReviewID, title: String, repositoryName: String,
        revision: RevisionIdentity, review: ReviewWorkspaceModel,
        tour: TourWorkspaceModel, conversation: AgentConversationRailModel,
        navigation: ReviewNavigationState
    ) {
        self.id = id
        self.title = title
        self.repositoryName = repositoryName
        self.revision = revision
        self.review = review
        self.tour = tour
        self.conversation = conversation
        self.navigation = navigation
    }
}

private struct NativeReviewView: View {
    @ObservedObject var session: NativeReviewSession
    @ObservedObject private var navigation: ReviewNavigationState
    let showInbox: () -> Void

    init(session: NativeReviewSession, showInbox: @escaping () -> Void) {
        self.session = session
        _navigation = ObservedObject(wrappedValue: session.navigation)
        self.showInbox = showInbox
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button(action: showInbox) { Label("Inbox", systemImage: "tray") }
                    .buttonStyle(RTCButtonStyle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title).font(.headline).lineLimit(1)
                    HStack(spacing: 6) {
                        Text(session.repositoryName)
                        Text("·")
                        Text(session.revision.baseSHA.prefix(8) + " → " + session.revision.headSHA.prefix(8))
                            .font(.system(.caption, design: .monospaced))
                    }
                    .font(.caption)
                    .foregroundStyle(RTCDesign.color(.textSecondary))
                }
                .help("Exact committed revision: \(session.revision.baseSHA) → \(session.revision.headSHA)")
                Spacer()
                Picker("Review mode", selection: $navigation.mode) {
                    Text("Diff").tag(WorkspaceMode.diff)
                    Text("Tour").tag(WorkspaceMode.tour)
                }
                .pickerStyle(.segmented)
                .frame(width: 150)
                Button { navigation.agentRailOpen.toggle() } label: {
                    Label("Agent", systemImage: "bubble.left.and.bubble.right")
                }
                .buttonStyle(RTCButtonStyle())
                .keyboardShortcut("i", modifiers: [.command])
                .help("Show the revision-scoped worker conversation")
            }
            .padding(10)
            .background(RTCDesign.color(.surface))
            Divider()
            HStack(spacing: 0) {
                Group {
                    switch navigation.mode {
                    case .diff: RTCReviewWorkspaceView(model: session.review)
                    case .tour: TourWorkspaceView(model: session.tour)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if navigation.agentRailOpen {
                    Divider()
                    AgentConversationRail(model: session.conversation)
                        .frame(minWidth: 340, idealWidth: 380, maxWidth: 480)
                        .background(RTCDesign.color(.surface))
                }
            }
        }
    }
}

@MainActor
final class NativeApplicationModel: ObservableObject {
    @Published var inbox: InboxModel?
    @Published var route: ActivationRoute = .inbox
    @Published fileprivate var reviewSession: NativeReviewSession?
    @Published var errorMessage: String?
    @Published var reviewErrorMessage: String?
    @Published var openRepositoryError: String?
    @Published var isOpeningRepository = false
    @Published var notificationAuthorization: NotificationAuthorization = .notDetermined

    private var runtime: RTCIngestRuntime?
    private var lifecycle: LifecycleCoordinator?
    #if canImport(UserNotifications)
    private var notificationDelegate: NotificationResponseDelegate?
    #endif

    func start() async {
        guard runtime == nil else { return }
        do {
            let lifecycle = LifecycleCoordinator(
                registrar: InMemoryLaunchAtLoginRegistrar()
            ) { [weak self] event in
                Task { @MainActor in
                    self?.route = event.route
                    if case let .review(id) = event.route { await self?.openReview(id) }
                }
            }
            let presenter: any NotificationPresenter
            #if canImport(UserNotifications)
            if NotificationRuntimeSupport.canUseSystemCenter() {
                let systemPresenter = SystemNotificationPresenter()
                let delegate = NotificationResponseDelegate(coordinator: lifecycle)
                UNUserNotificationCenter.current().delegate = delegate
                notificationDelegate = delegate
                presenter = systemPresenter
            } else {
                presenter = DisabledNotificationPresenter()
            }
            #else
            presenter = DisabledNotificationPresenter()
            #endif
            let runtime = try await RTCIngestRuntime(
                paths: RTCInstallationPaths.applicationSupport(),
                notificationPresenter: presenter)
            inbox = InboxModel(
                records: runtime.records, coordinator: runtime.coordinator
            ) { [weak self] id in
                await self?.activate(id)
            }
            self.lifecycle = lifecycle
            self.runtime = runtime
            try await runtime.start()
            if ProcessInfo.processInfo.arguments.contains("--uitest-inbox-fixture") {
                try await seedInboxFixture(runtime)
            }
            notificationAuthorization = await runtime.notificationService.authorization()
            await inbox?.refresh()
        } catch {
            errorMessage = "Private review state could not be opened."
        }
    }

    func chooseRepository() {
        let panel = NSOpenPanel()
        panel.title = "Choose a repository"
        panel.message = "Review the latest committed change (HEAD^ → HEAD)."
        panel.prompt = "Review Latest Commit"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in await self?.openLatestCommit(in: url) }
        }
    }

    func showInbox() {
        reviewErrorMessage = nil
        route = .inbox
    }

    func openLatestCommit(in selectedURL: URL) async {
        guard let runtime, !isOpeningRepository else { return }
        isOpeningRepository = true
        openRepositoryError = nil
        defer { isOpeningRepository = false }
        do {
            let resolved = try await ExactGitEngine().resolveSubmission(
                repositoryPath: selectedURL.path, base: "HEAD^", head: "HEAD")
            let submission = ReviewSubmission(
                repositoryPath: resolved.revision.repositoryPath,
                repositoryIdentity: resolved.repositoryIdentity,
                base: SubmittedRef(label: "HEAD^", expectedSHA: resolved.revision.baseSHA),
                head: SubmittedRef(label: "HEAD", expectedSHA: resolved.revision.headSHA),
                title: "Latest commit in \(selectedURL.lastPathComponent)", notify: false)
            let receipt = try await runtime.coordinator.submit(submission)
            await runtime.coordinator.runUntilIdle()
            await activate(receipt.reviewID)
        } catch {
            openRepositoryError = "The latest committed change could not be opened. Choose a Git repository with at least two commits."
        }
    }

    func openReview(_ id: ReviewID) async {
        guard let runtime else { return }
        if reviewSession?.id == id { return }
        reviewErrorMessage = nil
        reviewSession = nil
        route = .review(id)
        do {
            guard let record = try await runtime.records.review(id),
                  let manifest = try await runtime.reviewRepository.review(id: id)
            else { throw NativeCompositionError.reviewUnavailable }
            guard ![.accepted, .materializing, .failed].contains(record.status) else {
                throw NativeCompositionError.reviewNotReady
            }

            let anchors = ManifestTourArtifactSource(manifest: manifest)
            let reviewHandler = try await ReviewCommandHandler.open(
                manifest: manifest,
                repository: SQLiteEventRepository(store: runtime.store),
                anchors: anchors,
                mutationPreflight: SubmittedRefMutationPreflight(record: record))
            let review = ReviewWorkspaceModel(
                revision: manifest.revision,
                files: manifest.files.map { CanvasFile(artifact: $0) },
                handler: reviewHandler)
            let navigation = ReviewNavigationState()
            let artifacts = ManifestTourArtifactResolver(manifest: manifest)
            let tourJobs = TourGenerationJobHandler(
                persistence: SQLiteTourPersistence(store: runtime.store),
                jobs: JobQueue(store: runtime.store), artifacts: artifacts,
                reviewStateSource: StoredReviewStateSource(manifest: manifest))
            let tour = TourWorkspaceModel(
                reviewID: id, revision: manifest.revision,
                jobs: tourJobs, artifacts: artifacts
            ) { anchor in
                navigation.mode = .diff
                if let side = anchor.side, let start = anchor.startLine, let end = anchor.endLine {
                    review.navigate(to: CanvasSelection(
                        path: anchor.path, side: side, startLine: start, endLine: end))
                } else {
                    review.selectFile(anchor.path)
                }
            }

            let conversationID = Self.conversationID(for: id)
            let conversationRepository = SQLiteConversationEventRepository(store: runtime.store)
            let coordinator = AgentChatCoordinator(
                reviewID: id, conversationID: conversationID,
                repository: conversationRepository, wakeSink: UnavailableWorkerWake())
            let conversation = AgentConversationRailModel(
                queue: { requestID, body in
                    _ = requestID
                    return try await coordinator.queueMessage(body)
                },
                replay: { cursor in try await coordinator.replay(after: cursor) })

            reviewSession = NativeReviewSession(
                id: id, title: record.title,
                repositoryName: URL(fileURLWithPath: manifest.revision.repositoryPath).lastPathComponent,
                revision: manifest.revision, review: review, tour: tour,
                conversation: conversation, navigation: navigation)
        } catch NativeCompositionError.reviewNotReady {
            reviewErrorMessage = "The exact committed diff is still being prepared. Return to the Inbox and try again when it is Ready."
        } catch {
            reviewErrorMessage = "The stored exact revision could not be opened."
        }
    }

    func enableNotifications() async {
        guard let runtime else { return }
        do {
            notificationAuthorization = try await runtime.notificationService.requestPermissionIfNeeded()
        } catch {
            errorMessage = "Notification permission could not be requested."
        }
    }

    private func activate(_ id: ReviewID) async {
        if let lifecycle { await lifecycle.activate(reviewID: id) }
        else { await openReview(id) }
    }

    private static func conversationID(for reviewID: ReviewID) -> UUID {
        let hex = SHA256Digest(data: Data("conversation\0\(reviewID.value)".utf8)).hex
        let value = "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-4\(hex.dropFirst(13).prefix(3))-a\(hex.dropFirst(17).prefix(3))-\(hex.dropFirst(20).prefix(12))"
        return UUID(uuidString: value)!
    }

    private func seedInboxFixture(_ runtime: RTCIngestRuntime) async throws {
        let base = String(repeating: "a", count: 40)
        let head = String(repeating: "b", count: 40)
        let revision = try RevisionIdentity(
            repositoryPath: "/tmp/rtc-ui-fixture", baseSHA: base, headSHA: head)
        let submission = ReviewSubmission(
            idempotencyKey: UUID(uuidString: "00000000-0000-0000-0000-000000000201")!,
            repositoryPath: revision.repositoryPath,
            repositoryIdentity: SHA256Digest(data: Data("rtc-ui-fixture".utf8)),
            base: SubmittedRef(label: "base", expectedSHA: base),
            head: SubmittedRef(label: "head", expectedSHA: head),
            title: "Exact revision fixture", notify: false)
        _ = try await runtime.records.accept(submission, revision: revision)
    }
}

private enum NativeCompositionError: Error {
    case reviewUnavailable
    case reviewNotReady
}

private struct SubmittedRefMutationPreflight: ReviewMutationPreflight {
    let record: IngestReviewRecord

    func currentHead(for revision: RevisionIdentity) async throws -> String {
        guard revision == record.revision else { throw NativeCompositionError.reviewUnavailable }
        let resolved = try await ExactGitEngine().resolveSubmission(
            repositoryPath: revision.repositoryPath,
            base: record.baseRef, head: record.headRef)
        guard resolved.repositoryIdentity == record.repositoryIdentity else {
            throw NativeCompositionError.reviewUnavailable
        }
        return resolved.revision.headSHA
    }
}

private struct StoredReviewStateSource: TourReviewStateSource {
    let manifest: ReviewManifest

    func state(for revision: RevisionIdentity) async throws -> TourReviewState {
        guard revision == manifest.revision else { throw NativeCompositionError.reviewUnavailable }
        return TourReviewState(manifest: manifest)
    }
}

private struct UnavailableWorkerWake: WakeSink {
    func wake(reviewID: ReviewID, conversationID: UUID, highestSequence: Int) async throws {
        throw AgentChatError.workerUnavailable
    }
}

private struct DisabledNotificationPresenter: NotificationPresenter {
    func authorization() async -> NotificationAuthorization { .denied }
    func requestAuthorization() async throws -> NotificationAuthorization { .denied }
    func present(_ request: NotificationRequestData) async throws {}
    func setBadge(_ value: Int) async {}
}
