// M2
// Docked persistently above the tab bar (`RootView`, M0, reserves the
// slot). Hidden entirely when `currentEpisodeID == nil` — nothing has ever
// been loaded this session (M2 spec §8.1).
import SwiftUI

struct MiniPlayerView: View {
    @Environment(AppContainer.self) private var container
    @State private var showPlayer = false

    var body: some View {
        if container.playerEngine.currentEpisodeID != nil {
            bar
                .fullScreenCover(isPresented: $showPlayer) {
                    PlayerView()
                }
        }
    }

    /// Tapping anywhere except the play/pause button presents `PlayerView`
    /// full-screen. The play/pause button is a nested `Button` with its own
    /// tap target; SwiftUI's default "inner tappable view wins" hit-testing
    /// keeps the two from conflicting (§8.1).
    private var bar: some View {
        let engine = container.playerEngine
        return Button {
            showPlayer = true
        } label: {
            HStack(spacing: 12) {
                artwork(engine: engine)

                VStack(alignment: .leading, spacing: 2) {
                    Text(engine.currentEpisodeTitle)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(engine.currentPodcastTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                playPauseButton(engine: engine)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial)
            .overlay(alignment: .bottom) {
                ProgressView(value: progressFraction(engine: engine))
                    .progressViewStyle(.linear)
                    .tint(.accentColor)
                    .frame(height: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func artwork(engine: PlayerEngine) -> some View {
        AsyncImage(url: engine.currentArtworkURL) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Color.secondary.opacity(0.2)
        }
        .frame(width: 40, height: 40)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func playPauseButton(engine: PlayerEngine) -> some View {
        Button {
            engine.togglePlayPause()
        } label: {
            Image(systemName: engine.state == .playing ? "pause.fill" : "play.fill")
                .font(.title3)
                .frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)
    }

    private func progressFraction(engine: PlayerEngine) -> Double {
        guard let duration = engine.duration, duration > 0 else { return 0 }
        return min(max(engine.currentTime / duration, 0), 1)
    }
}
