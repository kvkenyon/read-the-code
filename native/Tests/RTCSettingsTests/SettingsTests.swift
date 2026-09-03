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
        for endpoint in ["https://127.0.0.1:443", "http://localhost:11434", "http://127.0.0.1:11434@evil.test", "http://token@127.0.0.1:11434", "http://127.0.0.1:11434?key=secret", "http://192.168.1.2:11434"] {
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
    private func temporaryDirectory() throws -> URL { let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url }
}

private final class MemoryPersistence: RTCSettingsPersistence, @unchecked Sendable {
    private var value = RTCSettings.default
    func load() throws -> RTCSettings { value }; func save(_ settings: RTCSettings) throws { value = settings }; func reset() throws { value = .default }
}
private actor RecordingLifecycle: AppLifecycleService {
    private var calls = [Bool]()
    func activate(reviewID: ReviewID?) async {}
    func launchAtLogin(enabled: Bool) async throws { calls.append(enabled) }
    func values() -> [Bool] { calls }
}
