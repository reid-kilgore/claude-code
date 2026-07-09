// M0
import SwiftUI
import SwiftData
import UIKit

/// Receives the OS callback when the app is relaunched to service the
/// background download `URLSession` (M1 spec §8.5). `AppContainer.init`
/// registers the coordinator here; if the callback arrives first (app was
/// relaunched directly into the background), the handler is parked and
/// drained by `AppContainer.init`.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    static var downloadCoordinator: DownloadCoordinator?
    static var pendingBackgroundCompletionHandler: (() -> Void)?

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        if let coordinator = Self.downloadCoordinator {
            Task { await coordinator.attach(backgroundCompletionHandler: completionHandler) }
        } else {
            Self.pendingBackgroundCompletionHandler = completionHandler
        }
    }
}

@main
struct LingoPodApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var container = AppContainer()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .modelContainer(container.modelContainer)
                .environment(container)
                .onChange(of: scenePhase) { _, newPhase in
                    switch newPhase {
                    case .background:
                        // M2: near-zero playback-position loss on backgrounding.
                        container.playerEngine.persistPositionForBackgrounding()
                    case .active:
                        // M6: Apple Intelligence state can change while backgrounded.
                        (container.explainService as? ExplainService)?.refreshAvailability()
                    default:
                        break
                    }
                }
        }
    }
}
