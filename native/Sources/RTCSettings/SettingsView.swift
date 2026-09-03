import SwiftUI

@MainActor
public final class RTCSettingsMenuRouter: ObservableObject {
    @Published public var isPresented = false
    public init() {}
    public func open() { isPresented = true }
}

public struct RTCSettingsCommands: Commands {
    @ObservedObject private var router: RTCSettingsMenuRouter
    public init(router: RTCSettingsMenuRouter) { self.router = router }
    public var body: some Commands {
        CommandGroup(replacing: .appSettings) { Button("Settings…") { router.open() }.keyboardShortcut(",") }
    }
}

public struct RTCSettingsView: View {
    @ObservedObject private var viewModel: RTCSettingsViewModel
    public init(viewModel: RTCSettingsViewModel) { self.viewModel = viewModel }
    public var body: some View {
        Form {
            Button(viewModel.draft.notifications == .on ? "Disable notifications" : "Enable notifications") {
                Task { await viewModel.setNotificationsFromUser(viewModel.draft.notifications != .on) }
            }
            Toggle("Launch at login", isOn: $viewModel.draft.launchAtLogin)
            Picker("Appearance", selection: $viewModel.draft.appearance) { ForEach(RTCSettings.Appearance.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
            Picker("Editor behavior", selection: $viewModel.draft.editorBehavior) { ForEach(RTCSettings.EditorBehavior.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
            Toggle("Show private notification previews", isOn: $viewModel.draft.privacy.showPrivateNotificationPreviews)
            Toggle("Share diagnostics", isOn: $viewModel.draft.privacy.shareDiagnostics)
            Section("Local model") {
                Toggle("Use a local model", isOn: Binding(get: { viewModel.draft.selectedLocalModel != nil }, set: { enabled in
                    viewModel.draft.selectedLocalModel = enabled ? RTCSettings.LocalModel(kind: .ollama, endpoint: "http://127.0.0.1:11434", model: "") : nil
                }))
                if viewModel.draft.selectedLocalModel != nil {
                    Picker("Adapter", selection: Binding(get: { viewModel.draft.selectedLocalModel!.kind }, set: { viewModel.draft.selectedLocalModel!.kind = $0 })) { ForEach(RTCSettings.ModelKind.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    TextField("Endpoint", text: Binding(get: { viewModel.draft.selectedLocalModel!.endpoint }, set: { viewModel.draft.selectedLocalModel!.endpoint = $0 }))
                    TextField("Model", text: Binding(get: { viewModel.draft.selectedLocalModel!.model }, set: { viewModel.draft.selectedLocalModel!.model = $0 }))
                    Button("Check health") { Task { await viewModel.checkHealth() } }
                    healthLabel
                }
            }
            if let error = viewModel.loadError ?? viewModel.validationError { Text(error).foregroundStyle(.red) }
            HStack { Button("Reset") { Task { await viewModel.reset() } }; Spacer(); Button("Cancel") { viewModel.cancel() }; Button("Apply") { Task { await viewModel.apply() } }.disabled(!viewModel.hasChanges) }
        }.padding().frame(minWidth: 440)
    }
    @ViewBuilder private var healthLabel: some View {
        switch viewModel.health {
        case .idle: EmptyView()
        case .checking: Text("Checking local endpoint…")
        case .healthy(let models): Text(models.isEmpty ? "Endpoint is healthy." : "Available: \(models.joined(separator: ", "))")
        case .unavailable(let message): Text(message).foregroundStyle(.red)
        }
    }
}
