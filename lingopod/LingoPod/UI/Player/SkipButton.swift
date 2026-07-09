// M2
// Reusable transport skip control (±15s/±30s), numeral overlaid on
// `gobackward`/`goforward`-style SF Symbols (M2 spec §8.2). `gobackward.15`
// and `goforward.30` are real SF Symbols — the only two second-counts used
// in this app (§1.5's "+30s / −15s per Apple Podcasts convention").
import SwiftUI

struct SkipButton: View {
    enum Direction {
        case backward
        case forward
    }

    let direction: Direction
    let seconds: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbolName)
                .font(.system(size: 28))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    private var symbolName: String {
        switch direction {
        case .backward: "gobackward.\(seconds)"
        case .forward: "goforward.\(seconds)"
        }
    }

    private var accessibilityLabel: String {
        switch direction {
        case .backward: "Skip back \(seconds) seconds"
        case .forward: "Skip forward \(seconds) seconds"
        }
    }
}
