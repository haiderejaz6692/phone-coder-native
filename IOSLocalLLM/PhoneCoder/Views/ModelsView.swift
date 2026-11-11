import SwiftUI

@MainActor
final class PhoneCoderModelsModel: ObservableObject {
    let coordinator: PhoneCoderInferenceCoordinator
    @Published private(set) var installed: [PhoneCoderModelDescriptor] = []
    @Published private(set) var loadedID: String?
    @Published private(set) var busy = false
    @Published var error: String?
    private let onModelLoaded: @MainActor () async -> Void
    init(coordinator: PhoneCoderInferenceCoordinator, onModelLoaded: @escaping @MainActor () async -> Void = {}) {
        self.coordinator = coordinator; self.onModelLoaded = onModelLoaded
    }
    func refresh() async {
        installed = await coordinator.installedModels()
        let state = await coordinator.state()
        loadedID = state.availability == .available ? state.modelSession?.modelID : nil
    }
    func load(_ id: String) async {
        guard !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            _ = try await coordinator.switchModel(to: id)
            await onModelLoaded()
        }
        catch { self.error = phoneCoderError(error) }
        await refresh()
    }
    func unload() async {
        guard !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        do { try await coordinator.unloadModel() }
        catch { self.error = phoneCoderError(error) }
        await refresh()
    }
    func delete(_ model: DownloadableModel) async {
        guard !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            // Drain through the coordinator before removing mapped weights.
            // Strict local/API requests cannot autoload the cleared session.
            let current = await coordinator.state()
            if current.modelSession?.modelID == LocalModelRegistry.assistantSelectionID(for: model) {
                try await coordinator.unloadModel()
            }
            try model.delete()
            ModelDownloadCenter.shared.refreshAllStates()
            ModelDownloadCenter.shared.refreshStorageStats()
        } catch { self.error = phoneCoderError(error) }
        await refresh()
    }
}

struct PhoneCoderModelsView: View {
    @ObservedObject var model: PhoneCoderModelsModel
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var device: PhoneCoderDeviceSnapshotModel
    @ObservedObject private var catalog = ModelDownloadCenter.shared
    @State private var deletion: DownloadableModel?
    init(model: PhoneCoderModelsModel,
         deviceSnapshotProvider: (any PhoneCoderDeviceSnapshotProviding)? = nil) {
        self.model = model
        _device = StateObject(wrappedValue: PhoneCoderDeviceSnapshotModel(provider: deviceSnapshotProvider))
    }

    private var textModels: [DownloadableModel] {
        catalog.models.filter { $0.supportsCategory(.assistant) && !$0.capabilities.contains(.vision) }
            .sorted { ($0.approxRAMBytes ?? Int64.max) < ($1.approxRAMBytes ?? Int64.max) }
    }
    var body: some View {
        List {
            Section("On-device text models") {
                Text("Start with a smaller model: download it below, then tap Load in Installed models. Loading another model replaces the current runtime.").font(.callout)
                LabeledContent("Downloaded storage", value: ByteCountFormatter.string(fromByteCount: catalog.totalStorageUsed, countStyle: .file))
                if model.busy { ProgressView("Updating model runtime") }
                PhoneCoderInlineError(message: model.error)
                if model.error != nil { Button("Refresh models") { Task { await model.refresh() } }.phoneCoderTarget() }
            }
            Section("Working memory") {
                if let snapshot = device.snapshot {
                    ForEach(snapshot.rows.filter { ["footprint", "modelHeadroom", "thermal", "safety"].contains($0.id) }) { row in
                        LabeledContent(row.label, value: row.value)
                    }
                    DisclosureGroup("Technical device readings") {
                        ForEach(snapshot.rows.filter { !["footprint", "modelHeadroom", "thermal", "safety"].contains($0.id) }) { row in
                            LabeledContent(row.label, value: row.value)
                        }
                        LabeledContent("Sampled at", value: snapshot.sampledAtText)
                    }
                } else { Text("Device snapshot: Unavailable") }
                Button("Refresh device readings") { device.refresh() }.phoneCoderTarget()
                Text("Working-memory estimates include runtime overhead and differ from download size. Raw values are measured; derived values use those readings; estimated ceilings are policy fallbacks. Model headroom is advisory and changes as models load. The runtime rechecks memory and temperature before heavy work.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Installed models") {
                if model.installed.isEmpty { Text("No callable text model yet. Download one from the catalog below.").foregroundStyle(.secondary) }
                ForEach(model.installed, id: \.id) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(item.displayName).font(.headline).fixedSize(horizontal: false, vertical: true)
                        Text(item.id).font(.caption).foregroundStyle(.secondary)
                        if model.loadedID == item.id {
                            Label("Loaded", systemImage: "checkmark.circle")
                            Button("Unload") { Task { await model.unload() } }.disabled(model.busy).phoneCoderTarget()
                        } else {
                            Button(model.loadedID == nil ? "Load" : "Switch to this model") { Task { await model.load(item.id) } }
                                .disabled(model.busy).phoneCoderTarget()
                        }
                    }
                }
            }
            Section("Download catalog · smallest first") {
                ForEach(textModels) { item in
                    if let downloader = item.downloader {
                        PhoneCoderDownloadRow(model: item, downloader: downloader, delete: { deletion = item })
                    }
                }
            }
        }
        .task {
            device.refresh()
            catalog.refreshAllStates(); catalog.refreshStorageStats()
            while !Task.isCancelled {
                await model.refresh()
                do { try await Task.sleep(for: .seconds(2)) } catch { break }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { device.refresh() }
        }
        .refreshable { device.refresh(); catalog.refreshAllStates(); catalog.refreshStorageStats(); await model.refresh() }
        .confirmationDialog("Delete this downloaded model?", isPresented: Binding(get: { deletion != nil }, set: { if !$0 { deletion = nil } }), titleVisibility: .visible) {
            if let deletion {
                Button("Delete \(deletion.displayName)", role: .destructive) { Task { await model.delete(deletion) }; self.deletion = nil }
            }
        }
    }
}

private struct PhoneCoderDownloadRow: View {
    let model: DownloadableModel
    @ObservedObject var downloader: HFModelDownloadManager
    let delete: () -> Void
    @State private var error: String?
    var body: some View {
        let action = PhoneCoderModelAction.action(for: downloader.state)
        VStack(alignment: .leading, spacing: 8) {
            Text(model.displayName).font(.headline).fixedSize(horizontal: false, vertical: true)
            Text(model.subtitle).font(.caption).foregroundStyle(.secondary)
            Text(model.sizeLabel).font(.caption)
            if let ram = model.approxRAMBytes {
                Text("Estimated working memory: \(ByteCountFormatter.string(fromByteCount: ram, countStyle: .memory))").font(.caption)
            }
            if let context = model.contextWindowTokens { Text("Context: \(context) tokens").font(.caption) }
            if let compatibility = model.platformCompatibility { Text(compatibility.detail).font(.caption) }
            if downloader.state.isActive || downloader.state.isPaused {
                ProgressView(value: downloader.progress) { Text(downloader.state.isPaused ? "Download paused" : "Downloading") }
                    .accessibilityValue(downloader.progress.formatted(.percent.precision(.fractionLength(0))))
            }
            if case .failed(let reason) = downloader.state { PhoneCoderInlineError(message: reason) }
            PhoneCoderInlineError(message: error)
            if action == .installed {
                Label("Downloaded", systemImage: "checkmark.circle")
                Button("Delete download", role: .destructive, action: delete).phoneCoderTarget()
            } else {
                Button(action.title) {
                    error = nil
                    if action == .pause { model.pause(); return }
                    if let compatibility = model.platformCompatibility, !compatibility.supportsCurrentPlatform {
                        error = compatibility.detail; return
                    }
                    let bytes = model.approxRAMBytes ?? MemoryAdvisor.estimatedFootprint(for: model.id)
                    if bytes > 0, case .over = MemoryAdvisor.fit(forFootprint: bytes) {
                        error = "This model needs more working memory than this phone can provide. Choose a smaller model."; return
                    }
                    if action == .resume { model.resume() } else { model.start() }
                }.phoneCoderTarget()
            }
        }
    }
}
