import Foundation
import RTCContracts
import RTCModelAdapters
import RTCLifecycle

/// The settings file is deliberately app-private. It contains configuration only;
/// credentials remain behind `ModelCredentialLookup` (normally Keychain-backed).
public struct RTCSettings: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 2

    public enum NotificationPreference: String, Codable, CaseIterable, Sendable { case off, on }
    public enum Appearance: String, Codable, CaseIterable, Sendable { case system, light, dark }
    public enum EditorBehavior: String, Codable, CaseIterable, Sendable { case followSystem, preserveTabs }
    public enum ModelKind: String, Codable, CaseIterable, Sendable { case ollama, openAICompatible }

    public struct Privacy: Codable, Equatable, Sendable {
        public var showPrivateNotificationPreviews: Bool
        public var shareDiagnostics: Bool
        public init(showPrivateNotificationPreviews: Bool = false, shareDiagnostics: Bool = false) {
            self.showPrivateNotificationPreviews = showPrivateNotificationPreviews
            self.shareDiagnostics = shareDiagnostics
        }
    }

    public struct LocalModel: Codable, Equatable, Sendable {
        public var kind: ModelKind
        public var endpoint: String
        public var model: String
        /// A stable lookup label only; never a token or API key.
        public var credentialKey: String?
        public init(kind: ModelKind, endpoint: String, model: String, credentialKey: String? = nil) {
            self.kind = kind; self.endpoint = endpoint; self.model = model; self.credentialKey = credentialKey
        }

        public func validatedEndpoint() throws -> LoopbackEndpoint {
            guard let url = URL(string: endpoint) else { throw ModelAdapterError.invalidEndpoint("endpoint is malformed") }
            return try LoopbackEndpoint(url)
        }
    }

    public var schemaVersion: Int
    public var notifications: NotificationPreference
    public var launchAtLogin: Bool
    public var appearance: Appearance
    public var editorBehavior: EditorBehavior
    public var privacy: Privacy
    public var selectedLocalModel: LocalModel?

    public init(schemaVersion: Int = RTCSettings.currentSchemaVersion, notifications: NotificationPreference = .off,
                launchAtLogin: Bool = false, appearance: Appearance = .system,
                editorBehavior: EditorBehavior = .followSystem, privacy: Privacy = .init(),
                selectedLocalModel: LocalModel? = nil) {
        self.schemaVersion = schemaVersion; self.notifications = notifications; self.launchAtLogin = launchAtLogin
        self.appearance = appearance; self.editorBehavior = editorBehavior; self.privacy = privacy
        self.selectedLocalModel = selectedLocalModel
    }

    public static let `default` = RTCSettings()
}

public enum RTCSettingsError: Error, Equatable, Sendable { case unsupportedSchema(Int), invalidModel(String), persistence(String) }

public protocol RTCSettingsPersistence: Sendable {
    func load() throws -> RTCSettings
    func save(_ settings: RTCSettings) throws
    func reset() throws
}

/// Stores settings under Application Support, never alongside a reviewed repository.
public final class FileRTCSettingsPersistence: RTCSettingsPersistence, @unchecked Sendable {
    public let fileURL: URL
    private let fileManager: FileManager
    public init(fileURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.fileURL = fileURL ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ReadTheCode", isDirectory: true).appendingPathComponent("settings.json")
    }
    public func load() throws -> RTCSettings {
        guard fileManager.fileExists(atPath: fileURL.path) else { return .default }
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        if let settings = try? decoder.decode(RTCSettings.self, from: data) {
            guard settings.schemaVersion <= RTCSettings.currentSchemaVersion else { throw RTCSettingsError.unsupportedSchema(settings.schemaVersion) }
            return settings.schemaVersion == RTCSettings.currentSchemaVersion ? settings : try migrate(data)
        }
        return try migrate(data)
    }
    public func save(_ settings: RTCSettings) throws {
        guard settings.schemaVersion == RTCSettings.currentSchemaVersion else { throw RTCSettingsError.unsupportedSchema(settings.schemaVersion) }
        if let model = settings.selectedLocalModel { _ = try model.validatedEndpoint() }
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fileURL.deletingLastPathComponent().path)
        let data = try JSONEncoder().encode(settings)
        try data.write(to: fileURL, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
    public func reset() throws {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        try fileManager.removeItem(at: fileURL)
    }
    private func migrate(_ data: Data) throws -> RTCSettings {
        struct V1: Decodable { let schemaVersion: Int; let notifications: RTCSettings.NotificationPreference?; let launchAtLogin: Bool?; let endpoint: String?; let model: String? }
        let old = try JSONDecoder().decode(V1.self, from: data)
        guard old.schemaVersion == 1 else { throw RTCSettingsError.unsupportedSchema(old.schemaVersion) }
        let selected = (old.endpoint.flatMap { endpoint in old.model.map { RTCSettings.LocalModel(kind: .ollama, endpoint: endpoint, model: $0) } })
        let migrated = RTCSettings(notifications: old.notifications ?? .off, launchAtLogin: old.launchAtLogin ?? false, selectedLocalModel: selected)
        try save(migrated)
        return migrated
    }
}

public enum ModelHealthStatus: Equatable, Sendable { case idle, checking, healthy([String]), unavailable(String) }

@MainActor
public final class RTCSettingsViewModel: ObservableObject {
    @Published public private(set) var persisted: RTCSettings
    @Published public var draft: RTCSettings
    @Published public private(set) var validationError: String?
    @Published public private(set) var health: ModelHealthStatus = .idle
    private let persistence: any RTCSettingsPersistence
    private let lifecycle: any AppLifecycleService
    private let notificationService: (any NotificationPermissionRequester)?
    private let credentials: any ModelCredentialLookup
    private let transport: any ModelHTTPTransport

    public init(persistence: any RTCSettingsPersistence, lifecycle: any AppLifecycleService,
                notificationService: (any NotificationPermissionRequester)? = nil, credentials: any ModelCredentialLookup = NoCredentials(),
                transport: any ModelHTTPTransport = URLSessionModelTransport()) {
        self.persistence = persistence; self.lifecycle = lifecycle; self.notificationService = notificationService
        self.credentials = credentials; self.transport = transport
        let initial = (try? persistence.load()) ?? .default
        self.persisted = initial; self.draft = initial
    }
    public var hasChanges: Bool { draft != persisted }
    public func cancel() { draft = persisted; validationError = nil; health = .idle }
    public func reset() {
        do { try persistence.reset(); persisted = .default; draft = .default; validationError = nil; health = .idle }
        catch { validationError = "Could not reset settings." }
    }
    public func apply() async {
        do {
            if let model = draft.selectedLocalModel { _ = try model.validatedEndpoint() }
            try await lifecycle.launchAtLogin(enabled: draft.launchAtLogin)
            try persistence.save(draft)
            persisted = draft; validationError = nil
        } catch { validationError = Self.redacted(error) }
    }
    /// Call only from the explicit notification toggle action in the Settings UI.
    public func requestNotificationPermission() async {
        guard draft.notifications == .on, let notificationService else { return }
        do { _ = try await notificationService.requestPermissionIfNeeded() }
        catch { validationError = "Notification permission could not be requested." }
    }
    public func checkHealth() async {
        guard let model = draft.selectedLocalModel else { health = .idle; return }
        do {
            health = .checking
            let endpoint = try model.validatedEndpoint()
            let models: [String]
            switch model.kind {
            case .ollama: models = try await OllamaAdapter(endpoint: endpoint, model: model.model, transport: transport, credentials: credentials).discoverModels().map(\.value)
            case .openAICompatible: models = try await OpenAICompatibleAdapter(endpoint: endpoint, model: model.model, credentialKey: model.credentialKey ?? "openai-compatible", transport: transport, credentials: credentials).discoverModels().map(\.value)
            }
            health = .healthy(models)
        } catch { health = .unavailable(Self.redacted(error)) }
    }
    private static func redacted(_ error: Error) -> String {
        if error is ModelAdapterError { return "The local model endpoint could not be used." }
        return "The settings could not be saved."
    }
}
