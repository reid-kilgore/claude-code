// M0
import SwiftUI
import SwiftData

@main
struct LingoPodApp: App {
    @State private var container = AppContainer()

    var body: some Scene {
        WindowGroup {
            RootView()
                .modelContainer(container.modelContainer)
                .environment(container)
        }
    }
}
