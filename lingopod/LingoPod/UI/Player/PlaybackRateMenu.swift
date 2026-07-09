// M2
// Rate menu listing exactly the seven steps from M2 spec §1.6/§8.3.
import SwiftUI

struct PlaybackRateMenu: View {
    let engine: PlayerEngine

    var body: some View {
        Menu {
            ForEach(PlaybackRatePreference.allowedSteps, id: \.self) { step in
                Button {
                    engine.rate = step
                } label: {
                    HStack {
                        Text(Self.formatted(step))
                        if isActive(step) {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            Text(Self.formatted(engine.rate))
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(.secondary.opacity(0.15)))
        }
        .accessibilityLabel("Playback speed")
    }

    /// `Float` equality is unsafe — compare with a small epsilon (§8.3).
    private func isActive(_ step: Float) -> Bool {
        abs(engine.rate - step) < 0.01
    }

    private static func formatted(_ value: Float) -> String {
        let rounded = (value * 100).rounded() / 100
        if rounded == rounded.rounded() {
            return String(format: "%.1fx", rounded) // e.g. "1.0x", "2.0x"
        }
        let hasHundredths = (rounded * 100).truncatingRemainder(dividingBy: 10) != 0
        return hasHundredths ? String(format: "%.2fx", rounded) : String(format: "%.1fx", rounded)
    }
}
