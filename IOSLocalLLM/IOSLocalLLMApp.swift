import SwiftUI
import UIKit

@main
struct PhoneCoderApp: App {
    @UIApplicationDelegateAdaptor(PhoneCoderAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            PhoneCoderRootView()
        }
        .onChange(of: scenePhase) { _, newPhase in
            PhoneCoderLifecycleController.shared.handle(newPhase)
        }
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

/// Retains the upstream crash tracking and background memory cleanup.
/// Foregrounding this shell does not start a listener or load a model.
@MainActor
final class PhoneCoderLifecycleController {
    static let shared = PhoneCoderLifecycleController()

    private var epoch: UInt64 = 0

    func handle(_ phase: ScenePhase) {
        epoch &+= 1
        let currentEpoch = epoch
        Task { [weak self] in
            guard let self else { return }
            await self.apply(phase, epoch: currentEpoch)
        }
    }

    private func apply(_ phase: ScenePhase, epoch: UInt64) async {
        guard epoch == self.epoch else { return }

        switch phase {
        case .active:
            CrashReporter.shared.markRunning()
        case .background:
            // Clear the crash marker before the first suspension point. iOS
            // may suspend or terminate a backgrounded process while an
            // awaited shutdown is still pending; leaving the foreground
            // marker armed past that await misclassifies an ordinary
            // background termination as a jetsam/watchdog crash next launch.
            CrashReporter.shared.markCleanShutdown()
            await LocalAPIManager.shared.stop()
            guard epoch == self.epoch else { return }
            CodingAssistantService.shared.cancelLoad()
            CodingAssistantService.shared.stopGeneration()
            await CodingAssistantService.shared.unloadAndWaitForCleanup()
            guard epoch == self.epoch else { return }
            await MLXGenerationGate.shared.clearCacheWhenIdle()
        case .inactive:
            break
        @unknown default:
            break
        }
    }
}
