import SwiftUI
import UIKit

struct PhoneCoderImagesView: View {
    @ObservedObject private var service = ImageGenerationService.shared
    @StateObject private var device = PhoneCoderDeviceSnapshotModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var prompt = ""
    @State private var negativePrompt = ""
    @State private var steps = "4"
    @State private var seed = ""
    @State private var error: String?
    @State private var deleteModel = false
    private enum Field: Hashable { case prompt, negativePrompt, steps, seed }
    @FocusState private var focusedField: Field?

    var body: some View {
        let operation = service.imageOperation
        let readiness = PhoneCoderImageReadiness(
            installed: service.isInstalled(service.selectedModel),
            downloading: service.isDownloading(service.selectedModel), snapshot: device.snapshot,
            requiredBytes: service.selectedModel.approxRAMBytes + MemoryAdvisor.loadHeadroomReserve)
        let diagnostics = operation.diagnostics(snapshot: device.snapshot)
        ScrollViewReader { scroll in
            Form {
                Section("Image model") {
                    Picker("Model", selection: Binding(get: { service.selectedModelID }, set: { service.select($0); steps = "\(service.selectedModel.defaultSteps)" })) {
                        ForEach(ImageGenerationService.catalog) { model in Text(model.displayName).tag(model.id) }
                    }.disabled(operation.isBusy).phoneCoderTarget()
                    Text(readiness.title).font(.headline)
                    Text(readiness.detail).font(.caption).foregroundStyle(.secondary)
                    Text(readiness.memoryFit).font(.caption).foregroundStyle(.secondary)
                    Text("\(service.selectedModel.sizeLabel) download · default \(service.selectedModel.pixelEdge) × \(service.selectedModel.pixelEdge)")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if let image = operation.image, operation.resultOperationID == operation.id {
                    Section("Result") {
                        Image(uiImage: image).resizable().scaledToFit().accessibilityLabel("Generated image")
                        if let width = operation.resultWidth, let height = operation.resultHeight {
                            Text("\(width) × \(height) pixels").font(.caption)
                        }
                        ShareLink(item: Image(uiImage: image), preview: SharePreview("Generated image", image: Image(uiImage: image))) {
                            Label("Share image", systemImage: "square.and.arrow.up")
                        }.phoneCoderTarget()
                    }.id("image-result")
                }

                Section("Create an image") {
                    TextField("Describe your image", text: $prompt, axis: .vertical).lineLimit(3...10).phoneCoderTarget()
                        .focused($focusedField, equals: .prompt).accessibilityIdentifier("phonecoder.images.prompt")
                        .disabled(operation.isBusy)
                    DisclosureGroup("Generation options") {
                        TextField("Negative prompt (optional)", text: $negativePrompt, axis: .vertical).phoneCoderTarget()
                            .focused($focusedField, equals: .negativePrompt).accessibilityIdentifier("phonecoder.images.negative")
                        TextField("Steps (1–100)", text: $steps).keyboardType(.numberPad).phoneCoderTarget()
                            .focused($focusedField, equals: .steps).accessibilityIdentifier("phonecoder.images.steps")
                        TextField("Seed (empty for random)", text: $seed).keyboardType(.numberPad).phoneCoderTarget()
                            .focused($focusedField, equals: .seed).accessibilityIdentifier("phonecoder.images.seed")
                    }.disabled(operation.isBusy)
                    if operation.isBusy {
                        if operation.phase == .denoising || operation.phase == .downloading {
                            ProgressView(operation.phase.title, value: operation.progress)
                        } else { ProgressView(operation.phase.title) }
                        if operation.phase == .finalizing {
                            Text("Denoising is complete. Decoding and preparing the image still need to finish.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } else if service.isDownloading(service.selectedModel) {
                        ProgressView("Downloading image model", value: service.downloadProgress(for: service.selectedModel))
                    }
                    if let failure = operation.failure { PhoneCoderInlineError(message: failure.recovery) }
                    if operation.phase == .cancelled { Text(service.statusMessage).font(.callout).foregroundStyle(.secondary) }
                    PhoneCoderInlineError(message: service.directDownloadErrors[service.selectedModelID])
                    PhoneCoderInlineError(message: error)
                    if operation.isBusy {
                        Button("Cancel generation", role: .destructive) { service.cancel() }
                            .disabled(operation.phase == .cancelling).phoneCoderTarget()
                    } else {
                        switch readiness.action {
                        case .download:
                            Button("Download model", systemImage: "arrow.down.circle") { service.startDownload(service.selectedModel) }
                                .buttonStyle(.borderedProminent).phoneCoderTarget()
                        case .downloading:
                            Button("Cancel download", role: .destructive) { service.cancelDownload(service.selectedModel) }.phoneCoderTarget()
                        case .generate:
                            Button("Generate image", systemImage: "sparkles") {
                                do {
                                    let parameters = try PhoneCoderImageParameters(prompt: prompt, steps: steps, seed: seed)
                                    error = nil
                                    device.refresh()
                                    let previousID = service.imageOperation.id
                                    service.generate(prompt: prompt, negativePrompt: negativePrompt, steps: parameters.steps, seed: parameters.seed)
                                    focusedField = PhoneCoderKeyboardFocus.afterSubmission(
                                        accepted: service.imageOperation.id != previousID && service.imageOperation.isBusy,
                                        current: focusedField)
                                } catch { self.error = phoneCoderError(error) }
                            }.buttonStyle(.borderedProminent).phoneCoderTarget()
                                .accessibilityIdentifier("phonecoder.images.generate")
                        }
                    }
                    Text("Images generate on this phone. Text and image models share working memory; you may need to reload your text model afterwards.")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                Section {
                    DisclosureGroup("Technical details") {
                        Text(service.selectedModel.subtitle).font(.caption)
                        if let edge = operation.effectivePixelEdge {
                            Text("Effective requested size: \(edge) × \(edge)").font(.caption)
                        }
                        if let snapshot = device.snapshot {
                            Text("Memory sampled at \(snapshot.sampledAtText)").font(.caption).foregroundStyle(.secondary)
                            ForEach(snapshot.rows) { row in
                                LabeledContent(row.label, value: row.value).font(.caption)
                            }
                        }
                        Button("Refresh device snapshot", systemImage: "arrow.clockwise") { device.refresh() }.phoneCoderTarget()
                        Button("Copy diagnostics", systemImage: "doc.on.doc") { UIPasteboard.general.string = diagnostics }.phoneCoderTarget()
                        ShareLink(item: diagnostics) { Label("Share diagnostics", systemImage: "square.and.arrow.up") }.phoneCoderTarget()
                        Text("Diagnostics include operation and device metadata only.").font(.caption).foregroundStyle(.secondary)
                        if service.isInstalled(service.selectedModel) {
                            Button("Delete image model", role: .destructive) { focusedField = nil; deleteModel = true }
                                .disabled(operation.isBusy || service.isDownloading(service.selectedModel)).phoneCoderTarget()
                        }
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: operation.resultOperationID) { _, id in
                if id != nil { withAnimation { scroll.scrollTo("image-result", anchor: .top) } }
            }
        }
        .phoneCoderKeyboard($focusedField)
        .onAppear { steps = "\(service.selectedModel.defaultSteps)"; device.refresh() }
        .onChange(of: service.imageOperation.phase) { _, _ in device.refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { focusedField = nil; service.cancel(reason: .background) }
            else { device.refresh() }
        }
        .confirmationDialog("Delete the image model download?", isPresented: $deleteModel, titleVisibility: .visible) {
            Button("Delete model", role: .destructive) { service.deleteModel(service.selectedModel) }
        }
    }
}
