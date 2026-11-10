import SwiftUI
import UIKit

@main
struct PhoneCoderApp: App {
    @UIApplicationDelegateAdaptor(PhoneCoderAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    private let services = PhoneCoderServerServices.shared

    var body: some Scene {
        WindowGroup {
            PhoneCoderRootView(services: services)
                .environmentObject(services.controller)
                .task { handleScenePhase(scenePhase) }
                .onReceive(DeviceSafetyMonitor.shared.objectWillChange) { _ in
                    Task { await services.controller.refreshHealth() }
                }
                .onReceive(CodingAssistantService.shared.$state) { _ in
                    Task { await services.controller.refreshHealth() }
                }
        }
        .onChange(of: scenePhase) { _, newPhase in
            handleScenePhase(newPhase)
        }
    }

    private func handleScenePhase(_ phase: ScenePhase) {
        // Clear the crash marker synchronously before any async cancellation.
        // iOS suspension or termination during drain is a clean background exit.
        if phase == .active { CrashReporter.shared.markRunning() }
        else if phase == .background { CrashReporter.shared.markCleanShutdown() }
        services.controller.handle(scenePhase: phase)
    }
}

@MainActor
final class PhoneCoderAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        CrashReporter.shared.install()
        Diagnostics.shared.breadcrumb(PhoneCoderBuildManifest.current.productName + " launch", category: "lifecycle")
        _ = DeviceSafetyMonitor.shared
        MemoryPressureCoordinator.shared.start()
        return true
    }

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == BackgroundDownloadCoordinator.sessionIdentifier else {
            completionHandler()
            return
        }
        RuntimeLogCenter.emit(
            "Reattaching background model-download session",
            subsystem: "download"
        )
        Task { @MainActor in
            let coordinator = BackgroundDownloadCoordinator.shared
            coordinator.systemCompletionHandler = completionHandler
            coordinator.reattach()
        }
    }
}

/// One graph for the native server and local UI. Every consumer shares these
/// authentication, request, runtime and lifecycle authorities.
@MainActor
final class PhoneCoderServerServices {
    static let shared = PhoneCoderServerServices()

    let ledger: PhoneCoderRequestLedger
    let coordinator: PhoneCoderInferenceCoordinator
    let inferenceLifecycle: PhoneCoderInferenceLifecycle
    let controller: PhoneCoderServerController
    let pairings: PhoneCoderPairingStore
    let pairingExchange: PhoneCoderPairingExchange
    let pairingApproval: PhoneCoderPairingApproval
    let activity: PhoneCoderServerActivityStore
    let apiServer: PhoneCoderAPIServer
    let listener: PhoneCoderNetworkListener

    private init() {
        let ledger = PhoneCoderRequestLedger(sessionID: UUID(), completedRecordLimit: 16, outputByteLimit: 2_097_152)
        let coordinator = PhoneCoderInferenceCoordinator.shared
        let lifecycle = PhoneCoderInferenceLifecycle(coordinator: coordinator, ledger: ledger) {
            // Signal native load/generation cancellation after queue closure. Existing
            // runtime owners retain Metal resources until their work retires;
            // the memory-pressure coordinator remains the unload authority.
            // MLXGenerationGate owns its background-notification queue/cache
            // cleanup. Do not dispatch an untracked clear here that could run
            // after a newer foreground request has already been admitted.
            CodingAssistantService.shared.cancelLoad()
            CodingAssistantService.shared.stopGeneration()
        }
        self.ledger = ledger
        self.coordinator = coordinator
        self.inferenceLifecycle = lifecycle
        let pairings = PhoneCoderPairingStore()
        let pairingExchange = PhoneCoderPairingExchange(store: pairings)
        let pairingApproval = PhoneCoderPairingApproval()
        let activity = PhoneCoderServerActivityStore(url: PhoneCoderServerActivityStore.defaultURL)
        let server = PhoneCoderAPIServer(coordinator: coordinator, ledger: ledger, pairings: pairings,
            exchange: pairingExchange, activity: activity,
            approval: { [weak pairingApproval] name in await pairingApproval?.request(name: name) ?? false },
            deviceFacts: {
                let thermal: String = switch DeviceSafetyMonitor.shared.thermalState {
                case .nominal: "nominal"
                case .fair: "fair"
                case .serious: "serious"
                case .critical: "critical"
                @unknown default: "unknown"
                }
                return .init(availableMemoryBytes: UInt64(MemoryAdvisor.availableMemoryForModel), thermal: thermal)
            })
        let savedPort = UInt16(exactly: AppSettings.shared.localAPIPort).flatMap { $0 >= 1024 ? $0 : nil } ?? 11434
        let listener = PhoneCoderNetworkListener(server: server, port: savedPort, cancelApproval: { [weak pairingApproval] in pairingApproval?.cancel() })
        self.pairings = pairings; self.pairingExchange = pairingExchange
        self.pairingApproval = pairingApproval; self.activity = activity
        self.apiServer = server; self.listener = listener
        controller = PhoneCoderServerController(listener: listener,
            inference: lifecycle, intent: PhoneCoderDefaultsServingIntent(defaults: .standard),
            clock: PhoneCoderContinuousServerClock(),
            setIdleTimerDisabled: { UIApplication.shared.isIdleTimerDisabled = $0 })
        listener.controller = controller
        _ = lifecycle.suspend()
    }
}
