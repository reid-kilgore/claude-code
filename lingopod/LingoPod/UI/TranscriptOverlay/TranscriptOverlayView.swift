// M2 (placeholder — M4 replaces this file's contents; keep the initializer
// signature stable or update docs/specs/M2-playback.md + PlayerView's call
// site together, per M2 spec §8.4)
import LingoPodKit
import SwiftData
import SwiftUI

struct TranscriptOverlayView: View {
    let episode: Episode
    let engine: any PlayerEngineProtocol
    let transcriptProvider: any TranscriptProviderProtocol

    @Environment(\.dismiss) private var dismiss

    init(episode: Episode, engine: any PlayerEngineProtocol, transcriptProvider: any TranscriptProviderProtocol) {
        self.episode = episode
        self.engine = engine
        self.transcriptProvider = transcriptProvider
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text("Transcript overlay coming soon")
                    .font(.headline)
                Text(episode.title)
                    .foregroundStyle(.secondary)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}
