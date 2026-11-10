import SwiftUI

@MainActor
struct PhoneCoderRootView: View {
    @State private var defaultSelection: PhoneCoderTab = .server
    private let selection: Binding<PhoneCoderTab>?
    private let services: PhoneCoderServerServices
    @StateObject private var server: PhoneCoderServerModel
    @StateObject private var models: PhoneCoderModelsModel
    @StateObject private var chat: PhoneCoderChatModel
    @StateObject private var settings: PhoneCoderSettingsModel
    @ObservedObject private var approval: PhoneCoderPairingApproval

    /// A supplied binding lets a parent control navigation. Otherwise the
    /// root owns mutable selection, starting on the center Server tab.
    init(selection: Binding<PhoneCoderTab>? = nil, services: PhoneCoderServerServices = .shared) {
        self.selection = selection
        self.services = services
        _server = StateObject(wrappedValue: PhoneCoderServerModel(services: services))
        _models = StateObject(wrappedValue: PhoneCoderModelsModel(coordinator: services.coordinator,
            onModelLoaded: { await services.controller.modelDidLoad() }))
        _chat = StateObject(wrappedValue: PhoneCoderChatModel(coordinator: services.coordinator))
        _settings = StateObject(wrappedValue: PhoneCoderSettingsModel())
        _approval = ObservedObject(wrappedValue: services.pairingApproval)
    }

    var body: some View {
        TabView(selection: selection ?? $defaultSelection) {
            ForEach(PhoneCoderTab.allCases) { tab in
                NavigationStack {
                    destination(tab)
                        .navigationTitle(tab.accessibilityLabel)
                        .navigationBarTitleDisplayMode(.inline)
                }
                .tabItem {
                    Label(tab.accessibilityLabel, systemImage: tab.systemImage)
                        .accessibilityLabel(tab.accessibilityLabel)
                }
                .tag(tab)
            }
        }
        .accessibilityIdentifier(PhoneCoderBuildManifest.current.bundleIdentifier + ".root")
        .alert("Pair device?", isPresented: Binding(get: { approval.pending != nil && !server.showPairing }, set: { _ in }), presenting: approval.pending) { pending in
            Button("Approve") { approval.resolve(id: pending.id, approved: true) }
            Button("Deny", role: .cancel) { approval.resolve(id: pending.id, approved: false) }
        } message: { pending in Text("Allow \(pending.name) to use this phone’s model?") }
        .onChange(of: settings.historyEnabled) { _, value in chat.historyEnabled = value }
    }

    private func openModels() { (selection ?? $defaultSelection).wrappedValue = .models }

    @ViewBuilder private func destination(_ tab: PhoneCoderTab) -> some View {
        switch tab {
        case .chat: PhoneCoderChatView(model: chat, settings: settings, openModels: openModels)
        case .models: PhoneCoderModelsView(model: models)
        case .server: PhoneCoderServerView(model: server, controller: services.controller, openModels: openModels)
        case .images: PhoneCoderImagesView()
        case .settings: PhoneCoderSettingsView(services: services, settings: settings, chat: chat, controller: services.controller)
        }
    }
}
