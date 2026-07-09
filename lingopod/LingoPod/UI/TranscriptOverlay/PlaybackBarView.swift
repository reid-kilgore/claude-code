// M4
// Compact bottom playback controls (docs/specs/M4-overlay-ui.md §3.3).
// Reads `engine` (an `any PlayerEngineProtocol` existential, per the pinned
// `TranscriptOverlayView` initializer signature) directly for display —
// see the M4 report's integration-mismatch note on whether existential
// `@Observable` reads reliably drive SwiftUI invalidation here; the
// sync-critical 4 Hz path itself does not depend on this (see
// `TranscriptOverlayView`'s polling `.task`).
import SwiftUI

struct PlaybackBarView: View {
    let engine: any PlayerEngineProtocol

    var body: some View {
        VStack(spacing: 12) {
            progressRow
            controlsRow
        }
        .frame(height: 96)
    }

    private var progressRow: some View {
        VStack(spacing: 4) {
            Capsule()
                .fill(.white.opacity(0.25))
                .frame(height: 4)
                .overlay(alignment: .leading) {
                    GeometryReader { proxy in
                        Capsule()
                            .fill(.white)
                            .frame(width: proxy.size.width * progressFraction)
                    }
                }

            HStack {
                Text(formattedTime(engine.currentTime))
                Spacer()
                Text(remainingTimeLabel)
            }
            .font(.caption)
            .foregroundStyle(.white.opacity(0.7))
            .monospacedDigit()
        }
    }

    private var controlsRow: some View {
        HStack(spacing: 32) {
            Button {
                Task { await engine.skip(by: -15) }
            } label: {
                Image(systemName: "gobackward.15")
                    .font(.title2)
            }

            Button {
                engine.togglePlayPause()
            } label: {
                Image(systemName: engine.state == .playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 32))
                    .frame(width: 44, height: 44)
            }

            Button {
                Task { await engine.skip(by: 30) }
            } label: {
                Image(systemName: "goforward.30")
                    .font(.title2)
            }

            rateMenu
        }
        .foregroundStyle(.white)
        .buttonStyle(.plain)
    }

    private var rateMenu: some View {
        Menu {
            ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0], id: \.self) { step in
                Button {
                    engine.rate = Float(step)
                } label: {
                    if isActiveRate(step) {
                        Label(rateLabel(step), systemImage: "checkmark")
                    } else {
                        Text(rateLabel(step))
                    }
                }
            }
        } label: {
            Text(rateLabel(Double(engine.rate)))
                .font(.subheadline.weight(.semibold))
        }
        .accessibilityLabel("Playback speed")
    }

    private func isActiveRate(_ step: Double) -> Bool {
        abs(Double(engine.rate) - step) < 0.01
    }

    private func rateLabel(_ value: Double) -> String {
        String(format: "%g×", value)
    }

    private var progressFraction: Double {
        guard let duration = engine.duration, duration > 0 else { return 0 }
        return min(max(engine.currentTime / duration, 0), 1)
    }

    private var remainingTimeLabel: String {
        guard let duration = engine.duration else { return "--:--" }
        return "-" + formattedTime(max(0, duration - engine.currentTime))
    }

    private func formattedTime(_ time: TimeInterval) -> String {
        let clamped = max(0, Int(time.rounded()))
        return String(format: "%d:%02d", clamped / 60, clamped % 60)
    }
}
