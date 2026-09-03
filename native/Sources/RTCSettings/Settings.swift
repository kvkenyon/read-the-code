import Foundation
import RTCContracts
import RTCModelAdapters
import RTCLifecycle

/// App-private configuration only. Credentials stay behind `ModelCredentialLookup`.
public struct RTCSettings: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 2
    public static let maximumStoredBytes = 64 * 1024
    public static let maximumModelCharacters = 256
    public static let maximumEndpointCharacters = 2_048
    public static let maximumCredentialReferenceCharacters = 256
    public enum NotificationPreference: String, Codable, CaseIterable, Sendable { case off, on }
    public enum Appearance: String, Codable, CaseIterable, Sendable { case system, light, dark }
    public enum EditorBehavior: String, Codable, CaseIterable, Sendable { case followSystem, preserveTabs }
    public enum ModelKind: String, Codable, CaseIterable, Sendable { case ollama, openAICompatible }
    public struct Privacy: Codable, Equatable, Sendable {
        public var showPrivateNotificationPreviews: Bool
        public var shareDiagnostics: Bool
        public init(showPrivateNotificationPreviews: Bool = false, shareDiagnostics: Bool = false) { self.showPrivateNotificationPreviews = showPrivateNotificationPreviews; self.shareDiagnostics = shareDiagnostics }
    }
    public struct LocalModel: Codable, Equatable, Sendable {
        public var kind: ModelKind
        public var endpoint: String
        public var model: String
        /// Keychain lookup label only; never a token/API key.
        public var credentialKey: String?
        public init(kind: ModelKind, endpoint: String, model: String, credentialKey: String? = nil) { self.kind = kind; self.endpoint = endpoint; self.model = model; self.credentialKey = credentialKey }
        public func validate() throws {
            guard endpoint.count <= RTCSettings.maximumEndpointCharacters,
                  endpoint.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
                  let url = URL(string: endpoint) else { throw RTCSettingsError.invalidStoredSettings }
            _ = try LoopbackEndpoint(url)
            guard Self.isSafeReference(model, maximum: RTCSettings.maximumModelCharacters), credentialKey.map({ Self.isSafeReference($0, maximum: RTCSettings.maximumCredentialReferenceCharacters) }) ?? true else { throw RTCSettingsError.invalidStoredSettings }
        }
        public func validatedEndpoint() throws -> LoopbackEndpoint { try validate(); return try LoopbackEndpoint(URL(string: endpoint)!) }
        private static func isSafeReference(_ value: String, maximum: Int) -> Bool { !value.isEmpty && value.count <= maximum && value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) } }
    }
    public var schemaVersion: Int
    public var notifications: NotificationPreference
    public var launchAtLogin: Bool
    public var appearance: Appearance
    public var editorBehavior: EditorBehavior
    public var privacy: Privacy
    public var selectedLocalModel: LocalModel?
    public init(schemaVersion: Int = RTCSettings.currentSchemaVersion, notifications: NotificationPreference = .off, launchAtLogin: Bool = false, appearance: Appearance = .system, editorBehavior: EditorBehavior = .followSystem, privacy: Privacy = .init(), selectedLocalModel: LocalModel? = nil) {
        self.schemaVersion = schemaVersion; self.notifications = notifications; self.launchAtLogin = launchAtLogin; self.appearance = appearance; self.editorBehavior = editorBehavior; self.privacy = privacy; self.selectedLocalModel = selectedLocalModel
    }
    public func validate() throws { guard schemaVersion == Self.currentSchemaVersion else { throw RTCSettingsError.unsupportedSchema }; try selectedLocalModel?.validate() }
    public static let `default` = RTCSettings()
}

/// Deliberately redacted: hostile file contents and endpoint strings never reach UI/logs.
public enum RTCSettingsError: Error, Equatable, Sendable { case unsupportedSchema, invalidStoredSettings, fileTooLarge, persistenceFailure, inconsistentLifecycleState }
public protocol RTCSettingsPersistence: Sendable { func load() throws -> RTCSettings; func save(_ settings: RTCSettings) throws; func reset() throws }

/// Synchronous API with an internal lock: callers may safely share this Sendable object.
public final class FileRTCSettingsPersistence: RTCSettingsPersistence, @unchecked Sendable {
    public let fileURL: URL
    private let fileManager: FileManager
    private let lock = NSLock()
    public init(fileURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.fileURL = fileURL ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ReadTheCode", isDirectory: true).appendingPathComponent("settings.json")
    }
    public func load() throws -> RTCSettings { try locked { try loadUnlocked() } }
    public func save(_ settings: RTCSettings) throws { try locked { try saveUnlocked(settings) } }
    public func reset() throws { try locked { if fileManager.fileExists(atPath: fileURL.path) { try fileManager.removeItem(at: fileURL) } } }
    private func loadUnlocked() throws -> RTCSettings {
        guard fileManager.fileExists(atPath: fileURL.path) else { return .default }
        let data = try boundedData()
        struct Envelope: Decodable { let schemaVersion: Int }
        let version: Int
        do { version = try JSONDecoder().decode(Envelope.self, from: data).schemaVersion } catch { throw RTCSettingsError.invalidStoredSettings }
        switch version {
        case RTCSettings.currentSchemaVersion:
            do { let settings = try JSONDecoder().decode(RTCSettings.self, from: data); try settings.validate(); return settings }
            catch let error as RTCSettingsError { throw error }
            catch { throw RTCSettingsError.invalidStoredSettings }
        case 1: return try migrateV1(data)
        default: throw RTCSettingsError.unsupportedSchema
        }
    }
    private func boundedData() throws -> Data {
        do {
            let handle = try FileHandle(forReadingFrom: fileURL); defer { try? handle.close() }
            let data = try handle.read(upToCount: RTCSettings.maximumStoredBytes + 1) ?? Data()
            guard data.count <= RTCSettings.maximumStoredBytes else { throw RTCSettingsError.fileTooLarge }
            return data
        } catch let error as RTCSettingsError { throw error }
        catch { throw RTCSettingsError.invalidStoredSettings }
    }
    private func saveUnlocked(_ settings: RTCSettings) throws {
        do {
            try settings.validate()
            try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fileURL.deletingLastPathComponent().path)
            let data = try JSONEncoder().encode(settings)
            guard data.count <= RTCSettings.maximumStoredBytes else { throw RTCSettingsError.fileTooLarge }
            try data.write(to: fileURL, options: [.atomic])
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch let error as RTCSettingsError { throw error }
        catch { throw RTCSettingsError.persistenceFailure }
    }
    private func migrateV1(_ data: Data) throws -> RTCSettings {
        struct V1: Decodable { let schemaVersion: Int; let notifications: RTCSettings.NotificationPreference?; let launchAtLogin: Bool?; let endpoint: String?; let model: String?; let credentialKey: String? }
        do {
            let old = try JSONDecoder().decode(V1.self, from: data)
            guard old.schemaVersion == 1, (old.endpoint == nil) == (old.model == nil) else { throw RTCSettingsError.invalidStoredSettings }
            let selected = try old.endpoint.map { endpoint -> RTCSettings.LocalModel in
                guard let model = old.model else { throw RTCSettingsError.invalidStoredSettings }
                let value = RTCSettings.LocalModel(kind: .ollama, endpoint: endpoint, model: model, credentialKey: old.credentialKey); try value.validate(); return value
            }
            let migrated = RTCSettings(notifications: old.notifications ?? .off, launchAtLogin: old.launchAtLogin ?? false, selectedLocalModel: selected)
            try migrated.validate(); try saveUnlocked(migrated); return migrated
        } catch let error as RTCSettingsError { throw error }
        catch { throw RTCSettingsError.invalidStoredSettings }
    }
    private func locked<T>(_ work: () throws -> T) throws -> T { lock.lock(); defer { lock.unlock() }; return try work() }
}

public enum ModelHealthStatus: Equatable, Sendable { case idle, checking, healthy([String]), unavailable(String) }

@MainActor
public final class RTCSettingsViewModel: ObservableObject {
    @Published public private(set) var persisted: RTCSettings
    @Published public var draft: RTCSettings
    @Published public private(set) var validationError: String?
    @Published public private(set) var loadError: String?
    @Published public private(set) var health: ModelHealthStatus = .idle
    private let persistence: any RTCSettingsPersistence
    private let lifecycle: any AppLifecycleService
    private let notificationService: (any NotificationPermissionRequester)?
    private let credentials: any ModelCredentialLookup
    private let transport: any ModelHTTPTransport
    private var canPersist = true
    private var healthGeneration = 0
    public init(persistence: any RTCSettingsPersistence, lifecycle: any AppLifecycleService, notificationService: (any NotificationPermissionRequester)? = nil, credentials: any ModelCredentialLookup = NoCredentials(), transport: any ModelHTTPTransport = URLSessionModelTransport()) {
        self.persistence = persistence; self.lifecycle = lifecycle; self.notificationService = notificationService; self.credentials = credentials; self.transport = transport
        do { let initial = try persistence.load(); persisted = initial; draft = initial }
        catch { persisted = .default; draft = .default; canPersist = false; loadError = "Settings could not be loaded. Existing settings were not changed." }
    }
    public var hasChanges: Bool { draft != persisted }
    public func cancel() { healthGeneration += 1; draft = persisted; validationError = nil; health = .idle }
    public func reset() async { await transition(to: .default, persistenceAction: { try self.persistence.reset() }, success: { self.canPersist = true; self.loadError = nil }) }
    public func apply() async {
        guard canPersist else { validationError = "Settings could not be loaded. Reset settings before applying changes."; return }
        let target = draft; await transition(to: target, persistenceAction: { try self.persistence.save(target) })
    }
    private func transition(to target: RTCSettings, persistenceAction: () throws -> Void, success: (() -> Void)? = nil) async {
        do { try target.validate() } catch { validationError = "The local model endpoint could not be used."; return }
        let previous = persisted; let changedLaunch = previous.launchAtLogin != target.launchAtLogin
        do {
            if changedLaunch { try await lifecycle.launchAtLogin(enabled: target.launchAtLogin) }
            do { try persistenceAction() }
            catch {
                if changedLaunch {
                    do { try await lifecycle.launchAtLogin(enabled: previous.launchAtLogin) }
                    catch { validationError = "Settings and launch-at-login could not be reconciled."; return }
                }
                validationError = "The settings could not be saved."; return
            }
            persisted = target; draft = target; validationError = nil; success?()
        } catch { validationError = "Launch at login could not be updated." }
    }
    /// Invoked only by the explicit user-facing notification control.
    public func setNotificationsFromUser(_ enabled: Bool) async {
        draft.notifications = enabled ? .on : .off
        guard enabled, let notificationService else { return }
        do { _ = try await notificationService.requestPermissionIfNeeded() }
        catch { validationError = "Notification permission could not be requested." }
    }
    public func checkHealth() async {
        guard let model = draft.selectedLocalModel else { healthGeneration += 1; health = .idle; return }
        healthGeneration += 1; let generation = healthGeneration; health = .checking
        do {
            let endpoint = try model.validatedEndpoint(); let models: [String]
            switch model.kind {
            case .ollama: models = try await OllamaAdapter(endpoint: endpoint, model: model.model, transport: transport, credentials: credentials).discoverModels().map(\.value)
            case .openAICompatible: models = try await OpenAICompatibleAdapter(endpoint: endpoint, model: model.model, credentialKey: model.credentialKey ?? "openai-compatible", transport: transport, credentials: credentials).discoverModels().map(\.value)
            }
            guard generation == healthGeneration, draft.selectedLocalModel == model else { return }
            health = .healthy(models)
        } catch {
            guard generation == healthGeneration, draft.selectedLocalModel == model else { return }
            health = .unavailable("The local model endpoint could not be used.")
        }
    }
}
