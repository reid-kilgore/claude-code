// M1
// Small presentational subview for `PodcastDetailView`'s episode list
// (spec §6.4): title, date/duration, and a trailing download-state
// indicator/action.
import SwiftUI
import LingoPodKit

struct EpisodeRowView: View {
    @Environment(AppContainer.self) private var container
    let episode: Episode

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(episode.title)
                    .font(.body)
                    .lineLimit(2)
                HStack(spacing: 8) {
                    if let publishedAt = episode.publishedAt {
                        Text(publishedAt, style: .date)
                    }
                    if let duration = episode.duration {
                        Text(Self.formattedDuration(duration))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            downloadIndicator
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var downloadIndicator: some View {
        switch episode.downloadState {
        case .none:
            Button {
                Task { try? await container.catalogService.download(episodeID: episode.persistentModelID) }
            } label: {
                Image(systemName: "arrow.down.circle")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Download episode")

        case .inProgress(let progress):
            Button {
                // `removeDownload` already cancels any in-flight download
                // (spec §5.10 step 2) — reused here rather than adding a
                // separate cancel-only path (spec §6.4).
                Task { try? await container.catalogService.removeDownload(episodeID: episode.persistentModelID) }
            } label: {
                ProgressView(value: progress)
                    .progressViewStyle(.circular)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Downloading, \(Int(progress * 100)) percent. Tap to cancel.")

        case .downloaded:
            Button {
                Task { try? await container.catalogService.removeDownload(episodeID: episode.persistentModelID) }
            } label: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Downloaded. Tap to remove.")

        case .failed(let reason):
            Button {
                Task { try? await container.catalogService.download(episodeID: episode.persistentModelID) }
            } label: {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(.orange)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Download failed: \(reason). Tap to retry.")
        }
    }

    private static func formattedDuration(_ duration: TimeInterval) -> String {
        let totalSeconds = Int(duration.rounded())
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}
