// M1
// Root Library screen: grid of subscribed podcasts, pull-to-refresh,
// foreground-refresh-on-active, empty state, and a toolbar entry point
// into search (architecture §2's `UI/Library/`; spec §6.1). Replaces M0's
// placeholder stub.
import SwiftUI
import SwiftData
import os
import LingoPodKit

struct LibraryView: View {
    @Environment(AppContainer.self) private var container
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \Podcast.subscribedAt, order: .reverse) private var podcasts: [Podcast]

    @State private var lastAutoRefreshAt: Date?

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 16)]
    private static let logger = Logger(subsystem: "com.lingopod.app", category: "Library")

    var body: some View {
        NavigationStack {
            Group {
                if podcasts.isEmpty {
                    ContentUnavailableView {
                        Label("No Podcasts Yet", systemImage: "books.vertical")
                    } description: {
                        Text("Search for a podcast or paste an RSS URL to subscribe.")
                    } actions: {
                        NavigationLink("Search Podcasts") {
                            SearchView()
                        }
                    }
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 16) {
                            ForEach(podcasts) { podcast in
                                NavigationLink {
                                    PodcastDetailView(podcast: podcast)
                                } label: {
                                    PodcastGridItemView(podcast: podcast)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding()
                    }
                    .refreshable {
                        await refreshAll()
                    }
                }
            }
            .navigationTitle("Library")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink {
                        SearchView()
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .accessibilityLabel("Search Podcasts")
                }
            }
            .onChange(of: scenePhase) { oldValue, newValue in
                guard newValue == .active, oldValue != .active else { return }
                // Debounce so a manual pull-to-refresh isn't immediately
                // followed by a duplicate auto-refresh (spec §6.1).
                if let lastAutoRefreshAt, Date.now.timeIntervalSince(lastAutoRefreshAt) < 60 {
                    return
                }
                Task { await refreshAll() }
            }
        }
    }

    /// Refreshes every subscribed podcast concurrently; one dead feed must
    /// not block refreshing the rest of the library (spec §6.1).
    private func refreshAll() async {
        lastAutoRefreshAt = .now
        let ids = podcasts.map(\.persistentModelID)
        let catalogService = container.catalogService
        await withTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask {
                    do {
                        try await catalogService.refresh(podcastID: id)
                    } catch {
                        Self.logger.error("Refresh failed: \(error.localizedDescription, privacy: .public)")
                    }
                }
            }
        }
    }
}
