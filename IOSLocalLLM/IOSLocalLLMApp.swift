import SwiftUI
import UIKit

@main
struct PhoneCoderApp: App {
    @UIApplicationDelegateAdaptor(PhoneCoderAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    private let services = PhoneCoderServerServices.shared

    var body: some Scene {
        WindowGroup {
            PhoneCoderRootView()
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

/// One graph for the native server and local UI. Task 6 installs its transport
/// at this composition point; Tasks 6/7 must share these actor instances.
@MainActor
final class PhoneCoderServerServices {
    static let shared = PhoneCoderServerServices()

    let ledger: PhoneCoderRequestLedger
    let coordinator: PhoneCoderInferenceCoordinator
    let inferenceLifecycle: PhoneCoderInferenceLifecycle
    let controller: PhoneCoderServerController

    private init() {
        let ledger = PhoneCoderRequestLedger(sessionID: UUID())
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
        controller = PhoneCoderServerController(listener: PhoneCoderUnconfiguredListener(),
            inference: lifecycle, intent: PhoneCoderDefaultsServingIntent(defaults: .standard),
            clock: PhoneCoderContinuousServerClock(),
            setIdleTimerDisabled: { UIApplication.shared.isIdleTimerDisabled = $0 })
        _ = lifecycle.suspend()
    }
}

/// Fail closed until the authenticated transport is composed in Task 6. This
/// must never be replaced with a no-op listener that advertises false readiness.
@MainActor
private final class PhoneCoderUnconfiguredListener: PhoneCoderServerListening {
    func start(sessionID: UUID) async throws { throw PhoneCoderListenerError.networkUnavailable }
    func stop() {}
}
