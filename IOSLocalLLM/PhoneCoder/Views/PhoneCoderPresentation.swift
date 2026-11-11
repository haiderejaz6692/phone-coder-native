import SwiftUI
import UIKit
import Hub

enum PhoneCoderServerAction: Equatable {
    case start, stop, retry, models
    var title: String {
        switch self { case .start: "Start server"; case .stop: "Stop server"; case .retry: "Retry server"; case .models: "Open Models" }
    }
    @MainActor @discardableResult
    func perform(controller: PhoneCoderServerController, openModels: () -> Void) -> Task<Void, Never> {
        switch self {
        case .start: return controller.startServing()
        case .stop: return controller.stopServing()
        case .retry: return controller.retryNow()
        case .models: openModels(); return Task {}
        }
    }
}

struct PhoneCoderServerPresentation {
    let title: String
    let detail: String
    let icon: String
    let tint: Color
    let action: PhoneCoderServerAction
    let offersModels: Bool
    init(_ state: PhoneCoderServerState) {
        offersModels = state == .lowMemory
        switch state {
        case .stopped: (title, detail, icon, tint, action) = ("Server off", "Load a text model, connect Tailscale, then start serving.", "power", .secondary, .start)
        case .starting: (title, detail, icon, tint, action) = ("Starting", "Opening the private network listener.", "hourglass", .blue, .stop)
        case .ready: (title, detail, icon, tint, action) = ("Ready", "Waiting for a paired client on your tailnet.", "checkmark.circle", .green, .stop)
        case .serving: (title, detail, icon, tint, action) = ("Connected", "A client is connected to your phone.", "network", .green, .stop)
        case .generating: (title, detail, icon, tint, action) = ("Generating", "The shared on-device runtime is working.", "sparkles", .blue, .stop)
        case .recovering(let attempt, _): (title, detail, icon, tint, action) = ("Reconnecting", "Connection recovery attempt \(attempt). You can retry now.", "arrow.clockwise", .orange, .retry)
        case .pausedBackground: (title, detail, icon, tint, action) = ("Paused", "Keep Phone Coder open in the foreground to serve requests.", "pause.circle", .orange, .stop)
        case .coolingDown: (title, detail, icon, tint, action) = ("Cooling down", "Let the phone cool before retrying generation.", "thermometer", .orange, .retry)
        case .lowMemory: (title, detail, icon, tint, action) = ("Memory pressure", "Close other apps or load a smaller model in Models, then retry the server.", "memorychip", .orange, .retry)
        case .authenticationError: (title, detail, icon, tint, action) = ("Credential store unavailable", "The server could not access its credential store. Serving was stopped. Unlock this device, then Start server to try again.", "key", .orange, .start)
        case .networkUnavailable: (title, detail, icon, tint, action) = ("Network unavailable", "Connect Tailscale on both devices, then retry.", "wifi.slash", .orange, .retry)
        case .modelUnavailable: (title, detail, icon, tint, action) = ("Load a model", "Download and load a compatible text model in Models.", "shippingbox", .orange, .models)
        }
    }
}

enum PhoneCoderModelAction: Equatable {
    case download, pause, resume, installed, retry
    static func action(for state: HFModelDownloadManager.DownloadState) -> Self {
        switch state { case .idle: .download; case .enumerating, .downloading: .pause; case .paused: .resume; case .ready: .installed; case .failed: .retry }
    }
    var title: String {
        switch self { case .download: "Download"; case .pause: "Pause download"; case .resume: "Resume download"; case .installed: "Downloaded"; case .retry: "Retry download" }
    }
}

struct PhoneCoderImageParameters {
    let steps: Int
    let seed: UInt64?
    init(prompt: String, steps: String, seed: String) throws {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PhoneCoderAPIError.invalid("Enter an image prompt.")
        }
        guard let count = Int(steps), (1...100).contains(count) else {
            throw PhoneCoderAPIError.invalid("Use 1 through 100 steps.")
        }
        let trimmed = seed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty || UInt64(trimmed) != nil else { throw PhoneCoderAPIError.invalid("Use a positive whole-number seed, or leave it empty for random.") }
        self.steps = count
        self.seed = UInt64(trimmed)
    }
}

struct PhoneCoderImagePresentation {
    let canCancel: Bool
    let canShare: Bool
    init(_ state: ImageGenerationService.State, hasImage: Bool) {
        switch state {
        case .loading, .generating, .downloading: canCancel = true
        default: canCancel = false
        }
        canShare = hasImage && !canCancel
    }
}

func phoneCoderError(_ error: Error) -> String {
    if let budget = error as? LocalAPIStrictBudgetError {
        let reason = budget.code == "context_length_exceeded"
            ? "The conversation exceeds the model’s context budget, including runtime overhead. Shorten the last input or start a new conversation."
            : "The requested output exceeds this model’s runtime limits. Load a model with valid output limits and start a new conversation."
        return "\(budget.promptTokens) prompt tokens + \(budget.outputTokens) output tokens; \(budget.contextWindow)-token context. \(reason)"
    }
    if let api = error as? PhoneCoderAPIError { return api.message }
    if let runtime = error as? PhoneCoderRuntimeError {
        switch runtime {
        case .cancelled: return "Generation stopped. You can retry."
        case .modelUnavailable, .staleSession, .residencyUnavailable: return "Load a text model in Models, then retry."
        case .memoryPressure: return "Not enough working memory. Load a smaller model."
        case .thermal: return "The phone needs to cool down. Retry when it is cooler."
        case .queueFull: return "The request queue is full. Wait for current requests to finish."
        case .switchingModel: return "A model change is in progress. Wait, then retry."
        case .lifecycleUnavailable: return "Keep Phone Coder open and try again."
        case .outputLimit: return "The response reached the local output limit. Start a new conversation."
        default: return "The model could not finish. Reload it in Models and retry."
        }
    }
    return "The operation could not finish. Check storage and connectivity, then retry."
}

struct PhoneCoderInlineError: View {
    let message: String?
    var body: some View {
        if let message {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.callout).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Needs attention. " + message)
        }
    }
}

extension View {
    func phoneCoderTarget() -> some View { frame(minWidth: 44, minHeight: 44) }
}

@MainActor
final class PhoneCoderSettingsModel: ObservableObject {
    @Published var historyEnabled: Bool {
        didSet { defaults.set(historyEnabled, forKey: Self.historyKey) }
    }
    private let defaults: UserDefaults
    private static let historyKey = "com.haider.phonecoder.historyEnabled"
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        historyEnabled = defaults.object(forKey: Self.historyKey) as? Bool ?? true
    }
    static func validPort(_ text: String) -> UInt16? {
        guard let value = UInt16(text.trimmingCharacters(in: .whitespacesAndNewlines)), value >= 1024 else { return nil }
        return value
    }
}

enum PhoneCoderImageCancellation: String { case user, background, safety }

enum PhoneCoderImagePhase: String {
    case idle, preparing, downloading, loading, denoising, finalizing, cancelling, ready, failed, cancelled
    var isBusy: Bool {
        switch self { case .preparing, .downloading, .loading, .denoising, .finalizing, .cancelling: true; default: false }
    }
    var title: String {
        switch self {
        case .idle: "Ready for a new image"
        case .preparing: "Preparing working memory"
        case .downloading: "Downloading image model"
        case .loading: "Loading image model"
        case .denoising: "Denoising"
        case .finalizing: "Finishing image"
        case .cancelling: "Stopping safely"
        case .ready: "Image ready"
        case .failed: "Image could not finish"
        case .cancelled: "Image generation stopped"
        }
    }
}

enum PhoneCoderImageFailure: String {
    case memory, residency, network, access, incompleteDownload, imageEncode, imageDecode, priorInterruption, generation
    static func category(for error: Error) -> Self {
        let ns = error as NSError
        if ns.domain == "ImageGen" {
            switch ns.code { case -3: return .memory; case -2: return .residency; case -1: return .imageEncode; default: break }
        }
        if ns.domain == NSURLErrorDomain { return .network }
        if ns.domain == "HFDownload", [401, 403, 404].contains(ns.code) { return .access }
        if let hub = error as? Hub.HubClientError {
            switch hub {
            case .fileNotFound, .resourceNotFound, .authorizationRequired: return .access
            case .httpStatusCode(let code) where [401, 403, 404].contains(code): return .access
            default: break
            }
        }
        return .generation
    }
    var recovery: String {
        switch self {
        case .memory: "Not enough working memory, or memory could not be measured. Close other apps or choose a lighter image model, then retry."
        case .residency: "Another model is still retiring. Wait for it to stop, then retry."
        case .network: "The download could not finish. Check connectivity, then retry."
        case .access: "Model access is required. Check your Hugging Face token in Settings and accept the model license, then retry."
        case .incompleteDownload: "The model download is incomplete. Retry the download."
        case .imageEncode, .imageDecode: "The generated image could not be opened. Retry generation."
        case .priorInterruption: "This model was disabled after repeated interrupted attempts. Choose a lighter image model."
        case .generation: "The image model could not finish. Retry, or choose a lighter image model."
        }
    }
}

/// Presentation/publication seam only; never admits or releases a runtime.
/// No prompt, credential, path or raw exception is retained here.
@MainActor
struct PhoneCoderImageOperation {
    private(set) var id: UUID?
    private(set) var modelID: String?
    private(set) var phase: PhoneCoderImagePhase = .idle
    private(set) var progress: Double = 0
    private(set) var failure: PhoneCoderImageFailure?
    private(set) var cancellation: PhoneCoderImageCancellation?
    private(set) var steps: Int?
    private(set) var effectivePixelEdge: Int?
    private(set) var image: UIImage?
    private(set) var resultOperationID: UUID?
    private(set) var resultWidth: Int?
    private(set) var resultHeight: Int?
    private(set) var pngByteCount: Int?
    var isBusy: Bool { phase.isBusy }

    mutating func reset() { self = Self() }
    mutating func begin(id: UUID, modelID: String, steps: Int, pixelEdge: Int) {
        reset()
        self.id = id
        // Only known catalog identifiers can enter presentation/diagnostics.
        self.modelID = ImageGenerationService.model(forID: modelID)?.id
        self.steps = max(1, steps)
        effectivePixelEdge = pixelEdge
        phase = .preparing
    }
    mutating func setEffectivePixelEdge(_ edge: Int, id: UUID) {
        guard self.id == id, isBusy else { return }
        effectivePixelEdge = edge
    }
    mutating func advance(_ next: PhoneCoderImagePhase, id: UUID, progress: Double = 0) {
        guard self.id == id, isBusy, phase != .cancelling else { return }
        let order: [PhoneCoderImagePhase] = [.preparing, .downloading, .loading, .denoising, .finalizing]
        guard let before = order.firstIndex(of: phase), let after = order.firstIndex(of: next), after >= before else { return }
        if next != phase { self.progress = 0 }
        phase = next
        self.progress = max(self.progress, min(1, max(0, progress)))
    }
    mutating func fail(_ failure: PhoneCoderImageFailure, id: UUID) {
        guard self.id == id, isBusy, phase != .cancelling else { return }
        self.failure = failure
        phase = .failed
        image = nil
        resultOperationID = nil
    }
    mutating func requestCancellation(_ reason: PhoneCoderImageCancellation) {
        guard isBusy, phase != .cancelling else { return }
        cancellation = reason
        phase = .cancelling
        image = nil
    }
    mutating func finishCancellation(id: UUID) {
        guard self.id == id, isBusy else { return }
        cancellation = cancellation ?? .safety
        phase = .cancelled
        image = nil
        resultOperationID = nil
    }
    @discardableResult
    mutating func publish(pngData: Data, id: UUID) -> Bool {
        guard self.id == id, phase == .finalizing else { return false }
        guard let decoded = UIImage(data: pngData), let cg = decoded.cgImage, cg.width > 0, cg.height > 0 else {
            fail(.imageDecode, id: id)
            return false
        }
        image = decoded
        resultWidth = cg.width
        resultHeight = cg.height
        pngByteCount = pngData.count
        resultOperationID = id
        phase = .ready
        return true
    }
    func diagnostics(snapshot: PhoneCoderDeviceSnapshot?) -> String {
        // Fixed allowlist only; never stringify service state or an Error.
        ["Image diagnostics (local generation)",
         "Operation: \(id?.uuidString ?? "Unavailable")",
         "Model: \(modelID ?? "Unavailable")", "Phase: \(phase.rawValue)",
         "Failure: \(failure?.rawValue ?? "None")", "Cancellation: \(cancellation?.rawValue ?? "None")",
         "Steps: \(steps.map(String.init) ?? "Unavailable")",
         "Effective requested edge: \(effectivePixelEdge.map(String.init) ?? "Unavailable")",
         "Result: \(resultWidth.map(String.init) ?? "Unavailable") × \(resultHeight.map(String.init) ?? "Unavailable")",
         "PNG bytes: \(pngByteCount.map(String.init) ?? "Unavailable")",
         snapshot?.diagnostics ?? "Device snapshot: Unavailable"].joined(separator: "\n")
    }
}

struct PhoneCoderImageReadiness {
    enum Action: Equatable { case download, generate, downloading }
    let title: String
    let detail: String
    let memoryFit: String
    let action: Action
    init(installed: Bool, downloading: Bool, snapshot: PhoneCoderDeviceSnapshot?, requiredBytes: Int64) {
        title = installed ? "Downloaded on this phone" : downloading ? "Downloading image model" : "Download an image model"
        detail = installed ? "Files are on disk. Phone Coder rechecks working memory, temperature and foreground access before generation." : "Download the model before generating locally."
        action = installed ? .generate : downloading ? .downloading : .download
        if let bytes = snapshot?.modelHeadroomBytes {
            memoryFit = bytes >= requiredBytes ? "Estimated memory fit; recheck required before generation" : "Estimated memory is tight; recheck required before generation"
        } else { memoryFit = "Memory fit unavailable" }
    }
}
