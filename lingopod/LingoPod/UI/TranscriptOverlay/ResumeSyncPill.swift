// M4
// Small capsule shown bottom-center of the transcript area during
// `.userScrolling` (docs/specs/M4-overlay-ui.md §3.2). Tapping it
// transitions immediately back to `.syncing`.
import SwiftUI

struct ResumeSyncPill: View {
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Label("Resume sync", systemImage: "chevron.down.circle")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .background(.ultraThinMaterial, in: Capsule())
        .transition(.opacity)
    }
}
