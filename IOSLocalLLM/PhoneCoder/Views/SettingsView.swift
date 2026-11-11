import SwiftUI
import UIKit

struct PhoneCoderSettingsView: View {
    let services: PhoneCoderServerServices
    @ObservedObject var settings: PhoneCoderSettingsModel
    @ObservedObject var chat: PhoneCoderChatModel
    @ObservedObject var controller: PhoneCoderServerController
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var device: PhoneCoderDeviceSnapshotModel
    @ObservedObject private var downloads = ModelDownloadCenter.shared
    @State private var port = ""
    @State private var error: String?
    @State private var notice: String?
    @State private var clearConversations = false
    @State private var clearActivity = false
    @State private var loadedModel = "None loaded"
    init(services: PhoneCoderServerServices, settings: PhoneCoderSettingsModel,
         chat: PhoneCoderChatModel, controller: PhoneCoderServerController,
         deviceSnapshotProvider: (any PhoneCoderDeviceSnapshotProviding)? = nil) {
        self.services = services; self.settings = settings; self.chat = chat; self.controller = controller
        _device = StateObject(wrappedValue: PhoneCoderDeviceSnapshotModel(provider: deviceSnapshotProvider))
    }

    private var diagnostics: String {
        let build = PhoneCoderBuildManifest.current
        return "\(build.productName)\nAPI: \(build.apiProfile)\nVersion: \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown")\nBuild: \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown")\niOS: \(UIDevice.current.systemVersion)\n\(device.snapshot?.diagnostics ?? "Device snapshot: Unavailable")\nServer: \(PhoneCoderServerPresentation(controller.state).title)\nPort: \(services.listener.port)"
    }
    var body: some View {
        Form {
            Section("Server") {
                TextField("Port", text: $port).keyboardType(.numberPad).phoneCoderTarget()
                Button("Apply port") {
                    guard let value = PhoneCoderSettingsModel.validPort(port) else {
                        error = "Use a port from 1024 through 65535."; return
                    }
                    do {
                        try services.listener.setPort(value)
                        AppSettings.shared.localAPIPort = Int(value)
                        error = nil; notice = "Port saved. Start the server when ready."
                    } catch { self.error = phoneCoderError(error) }
                }.disabled(controller.servingRequested).phoneCoderTarget()
                Text("Stop the server before changing its port. Your client must use the same port.").font(.footnote).foregroundStyle(.secondary)
                PhoneCoderInlineError(message: error)
                if let notice { Text(notice).font(.callout) }
            }
            Section("Local data") {
                Toggle("Save local conversation history", isOn: $settings.historyEnabled).phoneCoderTarget()
                Text("Turning history off keeps the current conversation private from then on and prevents later backfill. Previously saved chats remain until you clear them.").font(.footnote).foregroundStyle(.secondary)
                Button("Clear conversations", role: .destructive) { clearConversations = true }.phoneCoderTarget()
                Button("Clear server activity", role: .destructive) { clearActivity = true }.phoneCoderTarget()
            }
            Section("This device") {
                LabeledContent("Device", value: UIDevice.current.model)
                LabeledContent("System", value: "iOS \(UIDevice.current.systemVersion)")
                if let snapshot = device.snapshot {
                    ForEach(snapshot.rows) { row in LabeledContent(row.label, value: row.value) }
                    LabeledContent("Sampled at", value: snapshot.sampledAtText)
                } else { Text("Device snapshot: Unavailable") }
                Button("Refresh device readings") { device.refresh() }.phoneCoderTarget()
                Text("Physical memory is total device capacity, not free memory. App footprint includes memory charged to this app. Process available is raw kernel headroom; model headroom applies the process ceiling. Raw values are measured, derived values use those readings, and estimated ceilings are policy fallbacks. Unavailable means a reading could not be obtained. These readings are advisory; runtime safety checks run again before loading or generation.")
                    .font(.footnote).foregroundStyle(.secondary)
                LabeledContent("Model downloads", value: ByteCountFormatter.string(fromByteCount: downloads.totalStorageUsed, countStyle: .file))
                LabeledContent("Text model", value: loadedModel)
            }
            Section("Privacy") {
                Text("Model generation runs on this phone. Downloads need internet access. Server clients connect through your Tailscale network with a paired credential.")
                Text("Server activity stores request metadata for seven days, without prompts, responses or credentials. Local chat history is separate and controlled above.")
                Text("The app does not add a prompt blocklist or output classifier. Model behavior and this phone’s memory, temperature and foreground limits still apply.")
            }
            Section("About") {
                LabeledContent("App", value: PhoneCoderBuildManifest.current.productName)
                LabeledContent("API", value: PhoneCoderBuildManifest.current.apiProfile)
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown")
                LabeledContent("Build", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown")
                ShareLink(item: diagnostics) { Label("Share technical diagnostics", systemImage: "square.and.arrow.up") }.phoneCoderTarget()
                Text("Diagnostics include only build, device and server state. They exclude chat text, model output, clients, addresses and credentials.").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .task {
            device.refresh()
            port = "\(services.listener.port)"; downloads.refreshStorageStats()
            loadedModel = await services.coordinator.state().modelSession?.modelID ?? "None loaded"
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { device.refresh() }
        }
        .refreshable { device.refresh() }
        .confirmationDialog("Delete all saved conversations?", isPresented: $clearConversations, titleVisibility: .visible) {
            Button("Delete conversations", role: .destructive) {
                chat.newConversation()
                let store = ConversationStore.shared
                for id in store.conversations.map(\.id) { store.delete(id: id) }
                store.flush(); notice = "Conversations cleared."
            }
        }
        .confirmationDialog("Clear server activity?", isPresented: $clearActivity, titleVisibility: .visible) {
            Button("Clear activity", role: .destructive) {
                Task {
                    do { try await services.activity.clear(); error = nil; notice = "Server activity cleared." }
                    catch { self.error = phoneCoderError(error) }
                }
            }
        }
    }
}
