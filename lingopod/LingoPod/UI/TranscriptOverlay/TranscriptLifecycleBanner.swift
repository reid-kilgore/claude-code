// M4
// pending / partial-frontier / failed transcript-area states
// (docs/specs/M4-overlay-ui.md §9). `.complete` renders normal rows with no
// banner, so it has no case here.
import LingoPodKit
import SwiftUI

struct TranscriptPendingBanner: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .tint(.white)
            Text("Preparing transcript…")
                .foregroundStyle(.white.opacity(0.7))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Non-interactive row appended after the last real segment while
/// `state == .partial` (§9). Not a real segment: not tappable, not
/// selectable, removed the instant `state` becomes `.complete`/`.failed`.
struct TranscriptFrontierRow: View {
    let progress: Double
    @State private var pulse = false

    /// Explicit init: `pulse` is a `private` `@State` property with a
    /// default value, which would otherwise demote Swift's auto-synthesized
    /// memberwise initializer to `private` (Swift's documented
    /// access-control rule), making this type uncallable from
    /// `TranscriptOverlayView.swift`.
    init(progress: Double) {
        self.progress = progress
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(.white)
                        .frame(width: 8, height: 8)
                        .opacity(pulse ? 1.0 : 0.3)
                        .animation(
                            .easeInOut(duration: 0.6)
                                .repeatForever(autoreverses: true)
                                .delay(Double(index) * 0.15),
                            value: pulse
                        )
                }
            }
            ProgressView(value: progress)
                .tint(.white)
                .frame(maxWidth: 160)
            Text("\(Int((progress * 100).rounded()))% transcribed")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.6))
        }
        .padding(.horizontal, 24)
        .onAppear { pulse = true }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Transcribing, \(Int((progress * 100).rounded())) percent complete")
    }
}

struct TranscriptFailedBanner: View {
    let copy: TranscriptFailureCopy
    let isRetrying: Bool
    let onAction: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32))
                .foregroundStyle(.white.opacity(0.8))
            Text(copy.message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.8))
                .padding(.horizontal, 32)
            Button(action: onAction) {
                if isRetrying {
                    ProgressView()
                        .tint(.white)
                        .frame(minWidth: 100)
                } else {
                    Text(copy.buttonTitle)
                        .frame(minWidth: 100)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isRetrying)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
