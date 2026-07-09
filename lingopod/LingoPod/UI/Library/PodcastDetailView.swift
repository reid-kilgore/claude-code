// M1
// Podcast detail screen (spec §6.2): artwork/title/author/description
// header, episode list sorted newest-first, row-tap-to-play (with
// auto-download-on-play), and Unsubscribe.
import SwiftUI
import SwiftData
import LingoPodKit

struct PodcastDetailView: View {
    @Environment(AppContainer.self) private var container
    @Environment(\.dismiss) private var dismiss
    let podcast: Podcast

    @State private var isDescriptionExpanded = false
    @State private var isShowingUnsubscribeConfirm = false
    @State private var unsubscribeError: String?

    private var sortedEpisodes: [Episode] {
        podcast.episodes.sorted { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }
    }

    var body: some View {
        List {
            Section {
                header
            }
            .listRowSeparator(.hidden)

            Section("Episodes") {
                ForEach(sortedEpisodes) { episode in
                    EpisodeRowView(episode: episode)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            playEpisode(episode)
                        }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(podcast.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Unsubscribe", role: .destructive) {
                        isShowingUnsubscribeConfirm = true
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .confirmationDialog(
            "Unsubscribe from \(podcast.title)?",
            isPresented: $isShowingUnsubscribeConfirm,
            titleVisibility: .visible
        ) {
            Button("Unsubscribe", role: .destructive) {
                Task { await unsubscribe() }
            }
            Button("Cancel", role: .cancel) {}
        }
        .safeAreaInset(edge: .bottom) {
            if let unsubscribeError {
                Text(unsubscribeError)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                AsyncImage(url: podcast.artworkURL) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fill)
                    case .failure:
                        Image(systemName: "waveform")
                            .imageScale(.large)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    default:
                        ProgressView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(width: 96, height: 96)
                .background(.quaternary)
                .clipShape(RoundedRectangle(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 4) {
                    Text(podcast.title)
                        .font(.headline)
                    if let author = podcast.author {
                        Text(author)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let description = podcast.feedDescription, !description.isEmpty {
                Text(description)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(isDescriptionExpanded ? nil : 3)
                    .onTapGesture { isDescriptionExpanded.toggle() }
            }
        }
    }

    /// Auto-download-on-play (architecture §6.1): kicks off a background
    /// download so the episode is available offline next time, without
    /// gating playback on it — `PlayerEngine.load` streams from `audioURL`
    /// directly. M2's real `PlayerEngine` isn't guaranteed to be wired in
    /// yet, so this only calls through the protocol surface already
    /// exposed by `AppContainer.playerEngine` (a no-op mock until M2 lands).
    private func playEpisode(_ episode: Episode) {
        if episode.downloadState != .downloaded {
            Task { try? await container.catalogService.download(episodeID: episode.persistentModelID) }
        }
        Task { await container.playerEngine.load(episode: episode, autoplay: true) }
    }

    private func unsubscribe() async {
        do {
            try await container.catalogService.unsubscribe(podcastID: podcast.persistentModelID)
            dismiss()
        } catch {
            unsubscribeError = "Couldn't unsubscribe. Try again."
        }
    }
}
