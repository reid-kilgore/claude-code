// M4
// Bottom sheet: streaming `PassageExplanation` card (docs/specs/M4-overlay-ui.md
// §8). Presented via `.sheet(item:)` from the root view; owns its own
// streaming/availability-polling state, scoped to its own `.task` so
// abandoning it (dismiss) cancels generation per M6's contract.
import SwiftUI
import LingoPodKit
import UIKit

struct ExplainSheetView: View {
    let passage: String
    let context: String
    let sourceLanguage: Locale.Language
    let targetLanguage: Locale.Language
    let explainService: any ExplainServiceProtocol
    let engine: any PlayerEngineProtocol

    @State private var snapshot: PassageExplanation.PartiallyGenerated?
    @State private var phase: Phase = .waitingForAvailability
    @State private var attempt = 0

    private enum Phase: Equatable {
        case waitingForAvailability
        case unavailable(String)
        case streaming
        case error(String)
    }

    /// Explicit init: the `private` `@State` properties above have default
    /// values, which would otherwise demote Swift's auto-synthesized
    /// memberwise initializer to `private` (Swift's documented
    /// access-control rule), making this type uncallable from
    /// `TranscriptOverlayView.swift`.
    init(
        passage: String,
        context: String,
        sourceLanguage: Locale.Language,
        targetLanguage: Locale.Language,
        explainService: any ExplainServiceProtocol,
        engine: any PlayerEngineProtocol
    ) {
        self.passage = passage
        self.context = context
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.explainService = explainService
        self.engine = engine
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                content
                    .padding()
            }
            .navigationTitle("Explain")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    pausePlayButton
                }
            }
        }
        // VERIFY(iOS26): `.task(id:)` restarting on `attempt` changes is how
        // the Retry button (§8's "re-invokes explain() with the same
        // passage/context from scratch") is implemented — confirm this
        // reliably cancels the prior in-flight stream before starting a new
        // one on the shipping SDK.
        .task(id: attempt) {
            await run()
        }
    }

    // MARK: - Orchestration

    private func run() async {
        // §14/architecture §11.14: poll availability (≤0.5 Hz) only while
        // showing `.modelNotReady`; stop as soon as the sheet closes (this
        // `.task` is cancelled automatically then) or availability changes.
        while true {
            if Task.isCancelled { return }
            switch explainService.availability {
            case .ready:
                phase = .streaming
                await stream()
                return
            case .modelNotReady:
                phase = .waitingForAvailability
                try? await Task.sleep(for: .seconds(2))
            case .unavailable(let reason):
                phase = .unavailable(reason)
                return
            }
        }
    }

    private func stream() async {
        let sequence = explainService.explain(
            passage: passage, context: context,
            sourceLanguage: sourceLanguage, targetLanguage: targetLanguage
        )
        do {
            for try await partial in sequence {
                withAnimation(.easeInOut(duration: 0.2)) {
                    snapshot = partial
                }
            }
            // Finished successfully — `phase` stays `.streaming`, card shows
            // its final populated state.
        } catch is CancellationError {
            // Sheet dismissed / task cancelled — nothing to surface.
        } catch {
            phase = .error(errorMessage(for: error))
        }
    }

    private func errorMessage(for error: Error) -> String {
        guard let explainError = error as? ExplainError else {
            return "Couldn't analyze this passage."
        }
        switch explainError {
        case .guardrailed:
            return "Couldn't analyze this passage."
        case .busy:
            return "Explain is briefly busy — try again in a moment."
        case .failed:
            return "Couldn't analyze this passage."
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .waitingForAvailability:
            availabilityBanner(text: ExplainAvailabilityCopy.modelNotReady, showSpinner: true, showSettingsButton: false)
        case .unavailable(let reason):
            availabilityBanner(text: reason, showSpinner: false, showSettingsButton: reason == ExplainAvailabilityCopy.appleIntelligenceNotEnabled)
        case .streaming:
            card
        case .error(let message):
            // §8: "keep partial content visible above the error, don't
            // discard it" — `snapshot` (whatever streamed before the
            // failure) is still rendered by `card`.
            VStack(alignment: .leading, spacing: 20) {
                card
                errorRow(message: message)
            }
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 20) {
            section(title: "Translation") {
                if let translation = snapshot?.translation {
                    Text(translation)
                } else {
                    skeleton(lines: 2)
                }
            }
            section(title: "Meaning") {
                if let meaning = snapshot?.meaning {
                    Text(meaning)
                } else {
                    skeleton(lines: 3)
                }
            }
            if let grammarNotes = snapshot?.grammarNotes, !grammarNotes.isEmpty {
                section(title: "Grammar notes") {
                    bulletList(grammarNotes)
                }
            }
            if let idiomNotes = snapshot?.idiomNotes, !idiomNotes.isEmpty {
                section(title: "Idioms & register") {
                    bulletList(idiomNotes)
                }
            }
            if snapshot != nil {
                Text(ExplainPrompting.disclosureFooterText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func skeleton(lines: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(0..<lines, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 6)
                    .fill(.secondary.opacity(0.15))
                    .frame(height: 14)
            }
        }
        .redacted(reason: .placeholder)
    }

    private func bulletList(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(items, id: \.self) { item in
                HStack(alignment: .top, spacing: 6) {
                    Text("•")
                    Text(item)
                }
            }
        }
    }

    private func availabilityBanner(text: String, showSpinner: Bool, showSettingsButton: Bool) -> some View {
        VStack(spacing: 12) {
            if showSpinner {
                ProgressView()
            }
            Text(text)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            if showSettingsButton {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 48)
    }

    private func errorRow(message: String) -> some View {
        VStack(spacing: 8) {
            Text(message)
                .foregroundStyle(.secondary)
            Button("Retry") {
                attempt += 1
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
    }

    private var pausePlayButton: some View {
        Button {
            engine.togglePlayPause()
        } label: {
            Image(systemName: engine.state == .playing ? "pause.fill" : "play.fill")
        }
        .accessibilityLabel(engine.state == .playing ? "Pause" : "Play")
    }
}
