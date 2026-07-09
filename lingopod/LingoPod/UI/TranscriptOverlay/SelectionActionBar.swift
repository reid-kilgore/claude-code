// M4
// Floating "Translate | Explain" bar shown once a phrase selection is
// committed (docs/specs/M4-overlay-ui.md §7.2). Positioned centered
// horizontally at a fixed vertical offset above the playback bar — simpler
// than anchoring precisely to the selection's bounding box, which the spec
// explicitly says isn't worth the complexity for v1.
import SwiftUI

struct SelectionActionBar: View {
    let showTranslate: Bool
    let onTranslate: () -> Void
    let onExplain: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            if showTranslate {
                actionButton(title: "Translate", systemImage: "character.bubble", action: onTranslate)
                Divider()
                    .frame(height: 20)
                    .overlay(.white.opacity(0.3))
            }
            actionButton(title: "Explain", systemImage: "sparkles", action: onExplain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .shadow(radius: 8)
    }

    private func actionButton(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
    }
}
