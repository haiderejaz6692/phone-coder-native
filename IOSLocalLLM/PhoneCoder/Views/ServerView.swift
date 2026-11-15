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
        await refreshStoredData(pairings: services.pairings, activity: services.activity)
    }
    func refreshStoredData(pairings: PhoneCoderPairingStore, activity store: PhoneCoderServerActivityStore) async {
        do {
            clients = try await pairings.clients()
            activity = Array(try await store.entries().reversed().prefix(50))
            error = nil
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
                PhoneCoderStatusHeader(title: status.title, detail: status.detail, systemImage: status.icon, tint: status.tint)
                    .accessibilityIdentifier("phonecoder.server.status")
                Button(status.action.title) { model.perform(status.action, openModels: openModels) }
                    .buttonStyle(.borderedProminent).phoneCoderTarget()
                    .accessibilityIdentifier("phonecoder.server.primary")
                if status.offersModels {
                    Button("Open Models", action: openModels).phoneCoderTarget()
                }
                if controller.servingRequested, status.action != .stop {
                    Button("Stop server", role: .destructive) { controller.stopServing() }.phoneCoderTarget()
                }
            }
            Section("Runtime") {
                PhoneCoderDetailRow("Model", value: model.runtimeState?.modelSession?.modelID ?? "No model loaded")
                DisclosureGroup("Runtime details") {
                    PhoneCoderDetailRow("Connections", value: "\(controller.connectionCount)")
                    PhoneCoderDetailRow("Queued requests", value: "\(model.runtimeState?.waitingCount ?? 0)")
                    PhoneCoderDetailRow("Current request", value: model.runtimeState?.activeRequestID?.rawValue ?? "None")
                }
            }
            Section("Private connection") {
                if model.addresses.isEmpty { Text("Connect Tailscale to get this phone’s private address.").foregroundStyle(.secondary) }
                ForEach(model.addresses, id: \.self) { address in
                    Text(address).textSelection(.enabled).font(.system(.body, design: .monospaced))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("Server address, \(address)")
                }
                Text("Keep this app open while serving. Both devices must be on your tailnet.").font(.footnote).foregroundStyle(.secondary)
                Button("Pair a device", systemImage: "qrcode") { model.showPairing = true }
                    .disabled(!controller.servingRequested || model.addresses.isEmpty).phoneCoderTarget()
            }
            Section("Paired clients") {
                if model.clients.isEmpty { Text("No paired clients").foregroundStyle(.secondary) }
                ForEach(model.clients) { client in
                    VStack(alignment: .leading, spacing: PhoneCoderSpacing.compact) {
                        Label(client.name, systemImage: "laptopcomputer").fixedSize(horizontal: false, vertical: true)
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: PhoneCoderSpacing.content) { clientActions(client).fixedSize(horizontal: true, vertical: false) }
                            VStack(alignment: .leading, spacing: PhoneCoderSpacing.compact) { clientActions(client) }
                        }.buttonStyle(.borderless)
                    }
                }
            }
            Section("Recent activity") {
                if model.activity.isEmpty { Text("No server requests yet").foregroundStyle(.secondary) }
                ForEach(model.activity) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.clientName).font(.headline).fixedSize(horizontal: false, vertical: true)
                        Text(item.modelID).font(.caption).fixedSize(horizontal: false, vertical: true)
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
        .listStyle(.insetGrouped)
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

    @ViewBuilder private func clientActions(_ client: PhoneCoderClientSummary) -> some View {
        Button("Rotate and pair again") { Task { await model.rotate(client) } }.phoneCoderTarget()
        Button("Revoke", role: .destructive) { revokeClient = client }.phoneCoderTarget()
    }
}
