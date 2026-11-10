import SwiftUI

struct PhoneCoderImagesView: View {
    @ObservedObject private var service = ImageGenerationService.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var prompt = ""
    @State private var negativePrompt = ""
    @State private var steps = "4"
    @State private var seed = ""
    @State private var error: String?
    @State private var deleteModel = false
    var body: some View {
        let presentation = PhoneCoderImagePresentation(service.state, hasImage: service.image != nil)
        Form {
            Section("Image model") {
                Picker("Model", selection: Binding(get: { service.selectedModelID }, set: { service.select($0); steps = "\(service.selectedModel.defaultSteps)" })) {
                    ForEach(ImageGenerationService.catalog) { model in Text(model.displayName).tag(model.id) }
                }.disabled(presentation.canCancel).phoneCoderTarget()
                Text(service.selectedModel.subtitle).font(.caption).foregroundStyle(.secondary)
                Text("\(service.selectedModel.sizeLabel) · \(service.selectedModel.pixelEdge) × \(service.selectedModel.pixelEdge)").font(.caption)
                if service.isInstalled(service.selectedModel) {
                    Label("Downloaded", systemImage: "checkmark.circle")
                    Button("Delete image model", role: .destructive) { deleteModel = true }.disabled(presentation.canCancel).phoneCoderTarget()
                } else if service.isDownloading(service.selectedModel) {
                    ProgressView("Downloading image model", value: service.downloadProgress(for: service.selectedModel))
                } else {
                    Button("Download model", systemImage: "arrow.down.circle") { service.startDownload(service.selectedModel) }
                        .disabled(presentation.canCancel).phoneCoderTarget()
                }
                PhoneCoderInlineError(message: service.directDownloadErrors[service.selectedModelID])
            }
            Section("Create an image") {
                TextField("Describe your image", text: $prompt, axis: .vertical).lineLimit(3...10).phoneCoderTarget()
                DisclosureGroup("Generation options") {
                    TextField("Negative prompt (optional)", text: $negativePrompt, axis: .vertical).phoneCoderTarget()
                    TextField("Steps (1–100)", text: $steps).keyboardType(.numberPad).phoneCoderTarget()
                    TextField("Seed (empty for random)", text: $seed).keyboardType(.numberPad).phoneCoderTarget()
                }.disabled(presentation.canCancel)
                switch service.state {
                case .loading: ProgressView("Loading image model")
                case .downloading(let progress): ProgressView("Downloading", value: progress)
                case .generating(let progress): ProgressView("Generating", value: progress)
                case .failed(let reason): PhoneCoderInlineError(message: reason)
                default: EmptyView()
                }
                if !service.statusMessage.isEmpty { Text(service.statusMessage).font(.caption).foregroundStyle(.secondary) }
                PhoneCoderInlineError(message: error)
                if presentation.canCancel {
                    Button("Cancel generation", role: .destructive) { service.cancel() }.phoneCoderTarget()
                } else {
                    Button("Generate image", systemImage: "sparkles") {
                        do {
                            let parameters = try PhoneCoderImageParameters(prompt: prompt, steps: steps, seed: seed)
                            error = nil
                            service.generate(prompt: prompt, negativePrompt: negativePrompt, steps: parameters.steps, seed: parameters.seed)
                        } catch { self.error = phoneCoderError(error) }
                    }.buttonStyle(.borderedProminent).phoneCoderTarget()
                }
                Text("Images generate on this phone. Text and image models share working memory; you may need to reload your text model afterwards.").font(.footnote).foregroundStyle(.secondary)
            }
            if let image = service.image {
                Section("Result") {
                    Image(uiImage: image).resizable().scaledToFit().accessibilityLabel("Generated image")
                    if presentation.canShare {
                        ShareLink(item: Image(uiImage: image), preview: SharePreview("Generated image", image: Image(uiImage: image))) {
                            Label("Share image", systemImage: "square.and.arrow.up")
                        }.phoneCoderTarget()
                    }
                }
            }
        }
        .onAppear { steps = "\(service.selectedModel.defaultSteps)" }
        .onChange(of: scenePhase) { _, phase in if phase != .active { service.cancel() } }
        .confirmationDialog("Delete the image model download?", isPresented: $deleteModel, titleVisibility: .visible) {
            Button("Delete model", role: .destructive) { service.deleteModel(service.selectedModel) }
        }
    }
}
