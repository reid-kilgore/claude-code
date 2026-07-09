// M0
import SwiftUI
import SwiftData

@main
struct LingoPodApp: App {
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
