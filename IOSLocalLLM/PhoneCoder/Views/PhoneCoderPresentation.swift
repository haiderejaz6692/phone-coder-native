import SwiftUI
import UIKit

enum PhoneCoderServerAction: Equatable {
    case start, stop, retry, models
    var title: String {
        switch self { case .start: "Start server"; case .stop: "Stop server"; case .retry: "Retry connection"; case .models: "Open Models" }
    }
}

struct PhoneCoderServerPresentation {
    let title: String
    let detail: String
    let icon: String
    let tint: Color
    let action: PhoneCoderServerAction
    init(_ state: PhoneCoderServerState) {
        switch state {
        case .stopped: (title, detail, icon, tint, action) = ("Server off", "Load a text model, connect Tailscale, then start serving.", "power", .secondary, .start)
        case .starting: (title, detail, icon, tint, action) = ("Starting", "Opening the private network listener.", "hourglass", .blue, .stop)
        case .ready: (title, detail, icon, tint, action) = ("Ready", "Waiting for a paired client on your tailnet.", "checkmark.circle", .green, .stop)
        case .serving: (title, detail, icon, tint, action) = ("Connected", "A client is connected to your phone.", "network", .green, .stop)
        case .generating: (title, detail, icon, tint, action) = ("Generating", "The shared on-device runtime is working.", "sparkles", .blue, .stop)
        case .recovering(let attempt, _): (title, detail, icon, tint, action) = ("Reconnecting", "Connection recovery attempt \(attempt). You can retry now.", "arrow.clockwise", .orange, .retry)
        case .pausedBackground: (title, detail, icon, tint, action) = ("Paused", "Keep Phone Coder open in the foreground to serve requests.", "pause.circle", .orange, .stop)
        case .coolingDown: (title, detail, icon, tint, action) = ("Cooling down", "Let the phone cool before retrying generation.", "thermometer", .orange, .retry)
        case .lowMemory: (title, detail, icon, tint, action) = ("Memory pressure", "Close other apps or load a smaller model in Models.", "memorychip", .orange, .models)
        case .authenticationError: (title, detail, icon, tint, action) = ("Authentication issue", "Check Tailscale access and pair the client again.", "key", .orange, .retry)
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
