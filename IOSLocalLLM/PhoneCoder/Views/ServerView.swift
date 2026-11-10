import SwiftUI
import UIKit

@MainActor
final class PhoneCoderServerModel: ObservableObject {
    let services: PhoneCoderServerServices
    @Published private(set) var clients: [PhoneCoderClientSummary] = []
    @Published private(set) var activity: [PhoneCoderServerActivity] = []
    @Published private(set) var addresses: [String] = []
    @Published private(set) var runtimeState: PhoneCoderRuntimeState?
    @Published var error: String?
    @Published var showPairing = false
    init(services: PhoneCoderServerServices) { self.services = services }
    func refresh() async {
        await services.controller.refreshHealth()
        runtimeState = await services.coordinator.state()
        addresses = PhoneCoderNetworkExposure.addresses().map {
            "http://\($0.contains(":") ? "[\($0)]" : $0):\(services.listener.port)"
        }
        do {
            clients = try await services.pairings.clients()
            activity = Array(try await services.activity.entries().reversed().prefix(50))
        } catch { clients = []; self.error = phoneCoderError(error) }
    }
    func perform(_ action: PhoneCoderServerAction, openModels: () -> Void) {
        action.perform(controller: services.controller, openModels: openModels)
    }
    func revoke(_ client: PhoneCoderClientSummary) async {
        do { try await services.pairings.revoke(id: client.id); error = nil; await refresh() }
        catch { self.error = phoneCoderError(error) }
    }
    func rotate(_ client: PhoneCoderClientSummary) async {
        // Rotate by revoking and explicitly exchanging a new credential with
        // owner approval. Never put a long-lived bearer in the UI/QR/pasteboard.
        do { try await services.pairings.revoke(id: client.id); error = nil; await refresh(); showPairing = true }
        catch { self.error = phoneCoderError(error) }
    }
    func clearActivity() async {
        do { try await services.activity.clear(); activity = []; error = nil }
        catch { self.error = phoneCoderError(error) }
    }
}

struct PhoneCoderServerView: View {
    @ObservedObject var model: PhoneCoderServerModel
    @ObservedObject var controller: PhoneCoderServerController
    let openModels: () -> Void
    @State private var clearActivity = false
    @State private var revokeClient: PhoneCoderClientSummary?
    var body: some View {
        let status = PhoneCoderServerPresentation(controller.state)
        List {
            Section {
                Label(status.title, systemImage: status.icon).font(.title2.bold()).foregroundStyle(status.tint)
                Text(status.detail).foregroundStyle(.secondary)
                Button(status.action.title) { model.perform(status.action, openModels: openModels) }
                    .buttonStyle(.borderedProminent).phoneCoderTarget()
                if status.offersModels {
                    Button("Open Models", action: openModels).phoneCoderTarget()
                }
                if controller.servingRequested, status.action != .stop {
                    Button("Stop server", role: .destructive) { controller.stopServing() }.phoneCoderTarget()
                }
            }
            Section("Runtime") {
                LabeledContent("Model", value: model.runtimeState?.modelSession?.modelID ?? "No model loaded")
                LabeledContent("Connections", value: "\(controller.connectionCount)")
                LabeledContent("Queued requests", value: "\(model.runtimeState?.waitingCount ?? 0)")
                LabeledContent("Current request", value: model.runtimeState?.activeRequestID?.rawValue ?? "None")
            }
            Section("Private connection") {
                if model.addresses.isEmpty { Text("Connect Tailscale to get this phone’s private address.").foregroundStyle(.secondary) }
                ForEach(model.addresses, id: \.self) { address in
                    Text(address).textSelection(.enabled).font(.system(.body, design: .monospaced))
                        .accessibilityLabel("Server address, \(address)")
                }
                Text("Keep this app open while serving. Both devices must be on your tailnet.").font(.footnote).foregroundStyle(.secondary)
                Button("Pair a device", systemImage: "qrcode") { model.showPairing = true }
                    .disabled(!controller.servingRequested || model.addresses.isEmpty).phoneCoderTarget()
            }
            Section("Paired clients") {
                if model.clients.isEmpty { Text("No paired clients").foregroundStyle(.secondary) }
                ForEach(model.clients) { client in
                    VStack(alignment: .leading) {
                        Label(client.name, systemImage: "laptopcomputer").fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button("Rotate and pair again") { Task { await model.rotate(client) } }.phoneCoderTarget()
                            Button("Revoke", role: .destructive) { revokeClient = client }.phoneCoderTarget()
                        }.buttonStyle(.borderless)
                    }
                }
            }
            Section("Recent activity") {
                if model.activity.isEmpty { Text("No server requests yet").foregroundStyle(.secondary) }
                ForEach(model.activity) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.clientName).font(.headline)
                        Text(item.modelID).font(.caption)
                        Text("\(item.terminal.rawValue) · \(item.inputTokens) input · \(item.outputTokens) output tokens").font(.caption)
                        Text(item.endedAt, style: .relative).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("Only request metadata is recorded. Prompts, responses and credentials are not included.").font(.footnote)
                Button("Clear activity", role: .destructive) { clearActivity = true }.disabled(model.activity.isEmpty).phoneCoderTarget()
            }
            Section {
                PhoneCoderInlineError(message: model.error)
                if model.error != nil { Button("Refresh status") { Task { await model.refresh() } }.phoneCoderTarget() }
            }
        }
        .refreshable { await model.refresh() }
        .task {
            while !Task.isCancelled {
                await model.refresh()
                do { try await Task.sleep(for: .seconds(2)) } catch { break }
            }
        }
        .onChange(of: controller.state) { _, state in
            UIAccessibility.post(notification: .announcement, argument: PhoneCoderServerPresentation(state).title)
        }
        .sheet(isPresented: $model.showPairing) { PhoneCoderPairingSheet(services: model.services, address: model.addresses.first) }
        .confirmationDialog("Clear server activity?", isPresented: $clearActivity, titleVisibility: .visible) {
            Button("Clear activity", role: .destructive) { Task { await model.clearActivity() } }
        }
        .confirmationDialog("Revoke this client?", isPresented: Binding(get: { revokeClient != nil }, set: { if !$0 { revokeClient = nil } }), titleVisibility: .visible) {
            if let client = revokeClient { Button("Revoke \(client.name)", role: .destructive) { Task { await model.revoke(client) }; revokeClient = nil } }
        }
    }
}
