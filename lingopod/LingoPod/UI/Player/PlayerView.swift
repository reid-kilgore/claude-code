// M2
// The full-screen Now Playing surface (M2 spec §8.2).
import LingoPodKit
import SwiftData
import SwiftUI

struct PlayerView: View {
    @Environment(AppContainer.self) private var container
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    // Seek-on-release pattern (§8.2): while scrubbing, the slider's
    // displayed value is driven only by local drag state, immune to the
    // engine's live `currentTime` updates; on release, fire exactly one
    // `seek(to:)` with the final dragged value.
    @State private var isScrubbing = false
    @State private var scrubTime: TimeInterval = 0
    @State private var showTranscript = false

    var body: some View {
        let engine = container.playerEngine
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    artwork(engine: engine)
                    titles(engine: engine)
                    failureBanner(engine: engine)
                    scrubber(engine: engine)
                    transport(engine: engine)
                    PlaybackRateMenu(engine: engine)
                    transcriptSection(engine: engine)
                }
                .padding()
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private func artwork(engine: PlayerEngine) -> some View {
        ZStack {
            AsyncImage(url: engine.currentArtworkURL) { image in
                image.resizable().scaledToFit()
            } placeholder: {
                RoundedRectangle(cornerRadius: 12).fill(.secondary.opacity(0.15))
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12))

            // Buffering (§7.2) is UI-only; shown as a spinner overlay while
            // `state == .playing`, never surfaced via `PlaybackState` itself.
            if engine.isBuffering, engine.state == .playing {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
                    .padding()
                    .background(.black.opacity(0.35), in: Circle())
            }
        }
        .padding(.horizontal, 24)
    }

    private func titles(engine: PlayerEngine) -> some View {
        VStack(spacing: 4) {
            Text(engine.currentEpisodeTitle)
                .font(.headline)
                .multilineTextAlignment(.center)
                .lineLimit(2)
            Text(engine.currentPodcastTitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    /// §7.1: genuine unexpected-error case (not a predictable availability
    /// enum) — rendered inline with a retry affordance, never a modal alert.
    @ViewBuilder
    private func failureBanner(engine: PlayerEngine) -> some View {
        if case .failed(let error) = engine.state {
            VStack(spacing: 8) {
                Text("Playback failed")
                    .font(.subheadline.weight(.semibold))
                Text(error.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let episode = resolveCurrentEpisode(engine: engine) {
                    Button("Retry") {
                        Task { await engine.load(episode: episode, autoplay: false) }
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding()
            .frame(maxWidth: .infinity)
            .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func scrubber(engine: PlayerEngine) -> some View {
        VStack(spacing: 4) {
            Slider(
                value: Binding(
                    get: { isScrubbing ? scrubTime : engine.currentTime },
                    set: { scrubTime = $0 }
                ),
                in: 0...max(engine.duration ?? 1, 1),
                onEditingChanged: { editing in
                    isScrubbing = editing
                    if !editing {
                        let target = scrubTime
                        Task { await engine.seek(to: target) }
                    }
                }
            )

            HStack {
                Text(formattedTime(isScrubbing ? scrubTime : engine.currentTime))
                Spacer()
                Text(remainingTimeLabel(engine: engine))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
    }

    private func transport(engine: PlayerEngine) -> some View {
        HStack(spacing: 40) {
            SkipButton(direction: .backward, seconds: 15) {
                Task { await engine.skip(by: -15) }
            }

            Button {
                engine.togglePlayPause()
            } label: {
                Image(systemName: engine.state == .playing ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 64))
            }
            .buttonStyle(.plain)

            SkipButton(direction: .forward, seconds: 30) {
                Task { await engine.skip(by: 30) }
            }
        }
    }

    @ViewBuilder
    private func transcriptSection(engine: PlayerEngine) -> some View {
        if let episode = resolveCurrentEpisode(engine: engine) {
            VStack(spacing: 6) {
                Button {
                    showTranscript = true
                } label: {
                    Label("Transcript", systemImage: "text.bubble")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)

                // Auto-download hint (§6): disappears once
                // `episode.downloadState == .downloaded`. Reads the
                // resolved `Episode` directly rather than mirroring
                // `downloadState` through the engine, per §6's guidance.
                if episode.downloadState != .downloaded {
                    Text("Downloading for transcript…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .fullScreenCover(isPresented: $showTranscript) {
                TranscriptOverlayView(
                    episode: episode,
                    engine: engine,
                    transcriptProvider: container.transcriptProvider
                )
            }
        }
    }

    // MARK: - Helpers

    private func resolveCurrentEpisode(engine: PlayerEngine) -> Episode? {
        guard let id = engine.currentEpisodeID else { return nil }
        return try? modelContext.model(for: id) as? Episode
    }

    private func formattedTime(_ time: TimeInterval) -> String {
        let clamped = max(0, time)
        let minutes = Int(clamped) / 60
        let seconds = Int(clamped) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func remainingTimeLabel(engine: PlayerEngine) -> String {
        guard let duration = engine.duration else { return "--:--" }
        let current = isScrubbing ? scrubTime : engine.currentTime
        let remaining = max(0, duration - current)
        return "-" + formattedTime(remaining)
    }
}
