import XCTest
import RTCContracts
import RTCModelAdapters
import RTCLifecycle
@testable import RTCSettings

final class SettingsTests: XCTestCase {
    func testDefaultsArePrivateAndConservative() {
        let settings = RTCSettings.default
        XCTAssertEqual(settings.notifications, .off)
        XCTAssertFalse(settings.launchAtLogin)
        XCTAssertFalse(settings.privacy.showPrivateNotificationPreviews)
        XCTAssertFalse(settings.privacy.shareDiagnostics)
        XCTAssertNil(settings.selectedLocalModel)
    }
    func testV1MigratesWithoutSecrets() throws {
        let dir = try temporaryDirectory(); let file = dir.appendingPathComponent("settings.json")
        try Data(#"{"schemaVersion":1,"notifications":"on","launchAtLogin":true,"endpoint":"http://127.0.0.1:11434","model":"llama"}"#.utf8).write(to: file)
        let loaded = try FileRTCSettingsPersistence(fileURL: file).load()
        XCTAssertEqual(loaded.schemaVersion, RTCSettings.currentSchemaVersion)
        XCTAssertEqual(loaded.selectedLocalModel?.endpoint, "http://127.0.0.1:11434")
        XCTAssertFalse(try String(contentsOf: file).contains("token"))
    }
    func testCraftedEndpointsAreRejected() throws {
        for endpoint in ["https://127.0.0.1:443", "http://localhost:11434", "http://127.0.0.1:11434@evil.test", "http://token@127.0.0.1:11434", "http://127.0.0.1:11434?key=secret", "http://192.168.1.2:11434", "http://127.256.0.1:11434", "http://127.999.999.999:11434", "http://127.-1.-1.-1:11434"] {
            XCTAssertThrowsError(try RTCSettings.LocalModel(kind: .ollama, endpoint: endpoint, model: "local").validatedEndpoint(), endpoint)
        }
    }
    func testSecretErrorsAreRedactedAndLifecycleIsDelegated() async throws {
        let persistence = MemoryPersistence(); let lifecycle = RecordingLifecycle()
        let model = RTCSettings.LocalModel(kind: .ollama, endpoint: "http://127.0.0.1:11434", model: "local")
        let vm = await MainActor.run { RTCSettingsViewModel(persistence: persistence, lifecycle: lifecycle) }
        await MainActor.run { vm.draft.launchAtLogin = true; vm.draft.selectedLocalModel = model }
        await vm.apply()
        let calls = await lifecycle.values()
        XCTAssertEqual(calls, [true])
        XCTAssertEqual(try persistence.load().selectedLocalModel, model)
    }
    func testHealthErrorsDoNotExposeEndpointSecrets() async {
        let persistence = MemoryPersistence(); let lifecycle = RecordingLifecycle()
        let vm = await MainActor.run { RTCSettingsViewModel(persistence: persistence, lifecycle: lifecycle) }
        await MainActor.run { vm.draft.selectedLocalModel = RTCSettings.LocalModel(kind: .ollama, endpoint: "http://token:secret@127.0.0.1:11434", model: "local") }
        await vm.checkHealth()
        let status = await MainActor.run { vm.health }
        guard case .unavailable(let message) = status else { return XCTFail("invalid endpoint was checked") }
        XCTAssertFalse(message.contains("secret"))
        XCTAssertFalse(message.contains("token"))
    }
    func testHostileAndIncompleteStoredFilesAreRejected() throws {
        for value in ["{", #"{"schemaVersion":99}"#, #"{"schemaVersion":2,"notifications":"off"}"#, #"{"schemaVersion":1,"endpoint":"http://127.0.0.1:11434"}"#, #"{"schemaVersion":2,"notifications":"off","launchAtLogin":false,"appearance":"system","editorBehavior":"followSystem","privacy":{"showPrivateNotificationPreviews":false,"shareDiagnostics":false},"selectedLocalModel":{"kind":"ollama","endpoint":"http://127.0.0.1:11434","model":"bad\nname"}}"#] {
            let dir = try temporaryDirectory(); let file = dir.appendingPathComponent("settings.json"); try Data(value.utf8).write(to: file)
            XCTAssertThrowsError(try FileRTCSettingsPersistence(fileURL: file).load())
        }
        let dir = try temporaryDirectory(); let file = dir.appendingPathComponent("settings.json")
        try Data(repeating: 65, count: RTCSettings.maximumStoredBytes + 1).write(to: file)
        XCTAssertThrowsError(try FileRTCSettingsPersistence(fileURL: file).load())
    }
    func testApplyRollsBackAndResetDisablesLifecycle() async throws {
        let persistence = FailingPersistence(value: RTCSettings(launchAtLogin: false), failSave: true)
        let lifecycle = RecordingLifecycle()
        let vm = await MainActor.run { RTCSettingsViewModel(persistence: persistence, lifecycle: lifecycle) }
        await MainActor.run { vm.draft.launchAtLogin = true }
        await vm.apply()
        let calls = await lifecycle.values(); let persisted = await MainActor.run { vm.persisted.launchAtLogin }
        XCTAssertEqual(calls, [true, false]); XCTAssertEqual(persisted, false)
        await vm.cancel()
        let draft = await MainActor.run { vm.draft.launchAtLogin }; XCTAssertEqual(draft, false)

        let resetPersistence = FailingPersistence(value: RTCSettings(launchAtLogin: true))
        let resetLifecycle = RecordingLifecycle()
        let resetVM = await MainActor.run { RTCSettingsViewModel(persistence: resetPersistence, lifecycle: resetLifecycle) }
        await resetVM.reset()
        let resetCalls = await resetLifecycle.values(); let resetPersisted = await MainActor.run { resetVM.persisted.launchAtLogin }
        XCTAssertEqual(resetCalls, [false]); XCTAssertFalse(resetPersisted)
    }
    func testLifecycleAndRollbackFailuresRemainExplicit() async {
        let lifecycleFailure = RecordingLifecycle(failCalls: [true])
        let vm = await MainActor.run { RTCSettingsViewModel(persistence: FailingPersistence(value: .default), lifecycle: lifecycleFailure) }
        await MainActor.run { vm.draft.launchAtLogin = true }; await vm.apply()
        let lifecycleError = await MainActor.run { vm.validationError }; XCTAssertEqual(lifecycleError, "Launch at login could not be updated.")

        let rollbackFailure = RecordingLifecycle(failCalls: [false])
        let rollbackVM = await MainActor.run { RTCSettingsViewModel(persistence: FailingPersistence(value: .default, failSave: true), lifecycle: rollbackFailure) }
        await MainActor.run { rollbackVM.draft.launchAtLogin = true }; await rollbackVM.apply()
        let rollbackError = await MainActor.run { rollbackVM.validationError }; XCTAssertEqual(rollbackError, "Settings and launch-at-login could not be reconciled.")
    }
    func testLoadErrorDoesNotPretendDefaultsWerePersisted() async {
        let vm = await MainActor.run { RTCSettingsViewModel(persistence: FailingPersistence(value: .default, failLoad: true), lifecycle: RecordingLifecycle()) }
        let loadError = await MainActor.run { vm.loadError }; XCTAssertNotNil(loadError)
        await vm.apply()
        let applyError = await MainActor.run { vm.validationError }; XCTAssertEqual(applyError, "Settings could not be loaded. Reset settings before applying changes.")
    }
    func testNotificationPermissionRequiresExplicitUserAction() async {
        let requester = RecordingPermissionRequester()
        let vm = await MainActor.run { RTCSettingsViewModel(persistence: MemoryPersistence(), lifecycle: RecordingLifecycle(), notificationService: requester) }
        await MainActor.run { vm.draft.notifications = .on }
        await vm.cancel(); await vm.reset()
        let beforeExplicitAction = await requester.count(); XCTAssertEqual(beforeExplicitAction, 0)
        await vm.setNotificationsFromUser(true)
        let afterExplicitAction = await requester.count(); XCTAssertEqual(afterExplicitAction, 1)
    }
    func testFilePersistenceSerializesConcurrentCalls() throws {
        let directory = try temporaryDirectory(); let persistence = FileRTCSettingsPersistence(fileURL: directory.appendingPathComponent("settings.json"))
        let group = DispatchGroup(); let queue = DispatchQueue(label: "settings-test", attributes: .concurrent)
        let errors = ErrorCollector()
        for index in 0..<40 { group.enter(); queue.async { defer { group.leave() }; do { try persistence.save(RTCSettings(launchAtLogin: index.isMultiple(of: 2))) } catch { errors.append(error) } } }
        XCTAssertEqual(group.wait(timeout: .now() + 3), .success)
        XCTAssertTrue(errors.values().isEmpty)
        let final = RTCSettings(notifications: .on, launchAtLogin: true)
        try persistence.save(final)
        XCTAssertEqual(try persistence.load(), final)
    }
    func testCorruptLoadResetUsesActualLifecycleStateAndCompensatesFailure() async {
        let successfulLifecycle = RecordingLifecycle(enabled: true)
        let successful = await MainActor.run { RTCSettingsViewModel(persistence: FailingPersistence(value: .default, failLoad: true), lifecycle: successfulLifecycle) }
        await successful.reset()
        let successCalls = await successfulLifecycle.values(); let successEnabled = await successfulLifecycle.enabled()
        XCTAssertEqual(successCalls, [false]); XCTAssertFalse(successEnabled)

        let failedLifecycle = RecordingLifecycle(enabled: true)
        let failed = await MainActor.run { RTCSettingsViewModel(persistence: FailingPersistence(value: .default, failLoad: true, failReset: true), lifecycle: failedLifecycle) }
        await failed.reset()
        let failedCalls = await failedLifecycle.values(); let failedEnabled = await failedLifecycle.enabled()
        XCTAssertEqual(failedCalls, [false, true]); XCTAssertTrue(failedEnabled)

        let rollbackLifecycle = RecordingLifecycle(enabled: true, failCalls: [true])
        let rollback = await MainActor.run { RTCSettingsViewModel(persistence: FailingPersistence(value: .default, failLoad: true, failReset: true), lifecycle: rollbackLifecycle) }
        await rollback.reset()
        let error = await MainActor.run { rollback.validationError }
        XCTAssertEqual(error, "Settings and launch-at-login could not be reconciled.")
    }
    func testDelayedHealthCannotOverwriteNewerCancelResetOrModelEdit() async {
        let transport = DelayedTransport(); let model = RTCSettings.LocalModel(kind: .ollama, endpoint: "http://127.0.0.1:11434", model: "old")
        let persistence = MemoryPersistence(); let vm = await MainActor.run { RTCSettingsViewModel(persistence: persistence, lifecycle: RecordingLifecycle(), transport: transport) }
        await MainActor.run { vm.draft.selectedLocalModel = model }
        let old = Task { await vm.checkHealth() }; await transport.waitForRequests(1)
        await MainActor.run { vm.draft.selectedLocalModel?.model = "new" }
        let fresh = Task { await vm.checkHealth() }; await transport.waitForRequests(2)
        transport.finish(1, models: ["fresh"]); await fresh
        transport.finish(0, models: ["stale"]); await old
        let freshHealth = await MainActor.run { vm.health }; XCTAssertEqual(freshHealth, .healthy(["fresh"]))

        await MainActor.run { vm.draft.selectedLocalModel = model }
        let cancelled = Task { await vm.checkHealth() }; await transport.waitForRequests(3)
        await vm.cancel(); transport.finish(2, models: ["stale"]); await cancelled
        let cancelledHealth = await MainActor.run { vm.health }; XCTAssertEqual(cancelledHealth, .idle)

        await MainActor.run { vm.draft.selectedLocalModel = model }
        let reset = Task { await vm.checkHealth() }; await transport.waitForRequests(4)
        await vm.reset(); transport.finish(3, models: ["stale"]); await reset
        let resetHealth = await MainActor.run { vm.health }; XCTAssertEqual(resetHealth, .idle)
    }
    private func temporaryDirectory() throws -> URL { let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url }
}

private final class MemoryPersistence: RTCSettingsPersistence, @unchecked Sendable {
    private var value = RTCSettings.default
    func load() throws -> RTCSettings { value }; func save(_ settings: RTCSettings) throws { value = settings }; func reset() throws { value = .default }
}
private final class FailingPersistence: RTCSettingsPersistence, @unchecked Sendable {
    private let lock = NSLock(); private var value: RTCSettings; private let failSave: Bool; private let failLoad: Bool; private let failReset: Bool
    init(value: RTCSettings, failSave: Bool = false, failLoad: Bool = false, failReset: Bool = false) { self.value = value; self.failSave = failSave; self.failLoad = failLoad; self.failReset = failReset }
    func load() throws -> RTCSettings { lock.lock(); defer { lock.unlock() }; if failLoad { throw RTCSettingsError.invalidStoredSettings }; return value }
    func save(_ settings: RTCSettings) throws { if failSave { throw RTCSettingsError.persistenceFailure }; lock.lock(); defer { lock.unlock() }; value = settings }
    func reset() throws { if failReset { throw RTCSettingsError.persistenceFailure }; lock.lock(); defer { lock.unlock() }; value = .default }
}
private actor RecordingLifecycle: AppLifecycleService {
    private var calls = [Bool]()
    private var state: Bool
    private let failCalls: Set<Bool>
    init(enabled: Bool = false, failCalls: Set<Bool> = []) { self.state = enabled; self.failCalls = failCalls }
    func activate(reviewID: ReviewID?) async {}
    func launchAtLogin(enabled: Bool) async throws { calls.append(enabled); if failCalls.contains(enabled) { throw RTCSettingsError.persistenceFailure }; state = enabled }
    func launchAtLoginEnabled() async -> Bool { state }
    func values() -> [Bool] { calls }
    func enabled() -> Bool { state }
}
private final class ErrorCollector: @unchecked Sendable { private let lock = NSLock(); private var errors = [Error](); func append(_ error: Error) { lock.lock(); defer { lock.unlock() }; errors.append(error) }; func values() -> [Error] { lock.lock(); defer { lock.unlock() }; return errors } }
private actor RecordingPermissionRequester: NotificationPermissionRequester {
    private var requests = 0
    func requestPermissionIfNeeded() async throws -> NotificationAuthorization { requests += 1; return .authorized }
    func count() -> Int { requests }
}
private final class DelayedTransport: ModelHTTPTransport, @unchecked Sendable {
    private let lock = NSLock(); private var continuations = [AsyncThrowingStream<Data, Error>.Continuation]()
    func send(_ request: URLRequest, limits: ModelLimits) async throws -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in lock.lock(); continuations.append(continuation); lock.unlock() }
    }
    func waitForRequests(_ expected: Int) async { while count() < expected { await Task.yield() } }
    func finish(_ index: Int, models: [String]) { lock.lock(); let continuation = continuations[index]; lock.unlock(); continuation.yield(try! JSONSerialization.data(withJSONObject: ["models": models.map { ["name": $0] }])); continuation.finish() }
    private func count() -> Int { lock.lock(); defer { lock.unlock() }; return continuations.count }
}
