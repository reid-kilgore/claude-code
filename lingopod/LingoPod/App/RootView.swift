// M0
import SwiftUI

struct RootView: View {
    @Environment(AppContainer.self) private var container
    @State private var selectedTab: RootTab = .library

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $selectedTab) {
                Tab(RootTab.library.title, systemImage: RootTab.library.systemImage, value: .library) {
                    LibraryView()
                }
                Tab(RootTab.search.title, systemImage: RootTab.search.systemImage, value: .search) {
                    SearchPlaceholderView()
                }
            }

            // Miniplayer overlay slot. M2 replaces `MiniPlayerView`'s body
            // with the real now-playing bar; M0 only reserves the slot and
            // hides it when nothing is loaded so empty state doesn't show
            // a blank bar.
            MiniPlayerView()
                .padding(.bottom, 49) // approx. tab bar height; M2 may
                                      // replace with a GeometryReader-based
                                      // measurement instead of a constant.
        }
        // M5: invisible host for the Translation framework's
        // .translationTask session lifecycle (see TranslationHostView).
        .background(TranslationHostView())
    }
}

private enum RootTab: Hashable {
    case library
    case search

    var title: String {
        switch self {
        case .library: "Library"
        case .search: "Search"
        }
    }

    var systemImage: String {
        switch self {
        case .library: "books.vertical"
        case .search: "magnifyingglass"
        }
    }
}

/// M0 stub. M1 replaces this with the real search UI (part of M1 UI per
/// architecture §2's `UI/Library/` — search lives alongside subscriptions
/// in that directory per the repo layout table).
private struct SearchPlaceholderView: View {
    var body: some View {
        ContentUnavailableView(
            "Search",
            systemImage: "magnifyingglass",
            description: Text("Podcast search will appear here.")
        )
    }
}
