// M4
// Popover content for word/phrase translation (docs/specs/M4-overlay-ui.md
// §7.1). Handles both a single-word tap and a multi-word selection — same
// component, per spec ("it already handles arbitrary-length source text").
import SwiftUI

struct WordTranslationPopover: View {
    let originalText: String
    let lookup: TranslationLookupState
    let onDownloadLanguage: () async -> Void
    let onExplainMore: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(originalText)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)

            translationSection

            Button(action: onExplainMore) {
                Label("Explain more", systemImage: "sparkles")
                    .font(.subheadline)
            }
        }
        .padding()
        .frame(minWidth: 220, maxWidth: 320)
    }

    @ViewBuilder
    private var translationSection: some View {
        switch lookup {
        case .idle, .loading:
            HStack(spacing: 8) {
                ProgressView()
                Text("Translating…")
                    .foregroundStyle(.secondary)
            }
        case .loaded(let text):
            Text(text)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
        case .failed(let message, let actionLabel, let action):
            VStack(alignment: .leading, spacing: 8) {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if action == .downloadLanguage, let actionLabel {
                    Button(actionLabel) {
                        Task { await onDownloadLanguage() }
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }
}
