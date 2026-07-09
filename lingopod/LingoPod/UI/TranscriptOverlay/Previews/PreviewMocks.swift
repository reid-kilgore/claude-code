// M4
// Canned fakes + `#Preview` blocks so the whole overlay is exercisable in
// Xcode Previews with zero real audio, zero downloaded models, zero
// network (docs/specs/M4-overlay-ui.md §13). `MockTranscriptProvider`
// (`LingoPod/App/MockServices.swift`) always throws and
// `MockTranslationService` always throws too — neither is usable here, so
// this file provides its own fakes. `MockExplainService`
// (`LingoPod/Intelligence/MockExplainService.swift`, M6's own preview mock
// with canned streaming) is reused as-is rather than duplicated.
#if DEBUG
import Foundation
import LingoPodKit
import SwiftData
import SwiftUI

// MARK: - Fake PlayerEngine

@MainActor
@Observable
final class FakePlayerEngine: PlayerEngineProtocol {
    private(set) var currentEpisodeID: PersistentIdentifier?
    private(set) var state: PlaybackState
    private(set) var currentTime: TimeInterval
    private(set) var duration: TimeInterval?
    var rate: Float = 1.0

    private var loopTask: Task<Void, Never>?

    init(currentTime: TimeInterval = 0, duration: TimeInterval? = 900, state: PlaybackState = .playing) {
        self.currentTime = currentTime
        self.duration = duration
        self.state = state
        if state == .playing {
            startLoop()
        }
    }

    func load(episode: Episode, autoplay: Bool) async {
        currentEpisodeID = episode.persistentModelID
        if autoplay { play() }
    }

    func play() {
        state = .playing
        startLoop()
    }

    func pause() {
        state = .paused
    }

    func togglePlayPause() {
        if state == .playing { pause() } else { play() }
    }

    func seek(to time: TimeInterval) async {
        currentTime = time
        await Task.yield()
    }

    func skip(by seconds: TimeInterval) async {
        let upperBound = duration ?? .greatestFiniteMagnitude
        currentTime = min(max(0, currentTime + seconds), upperBound)
    }

    private func startLoop() {
        loopTask?.cancel()
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, self.state == .playing else { return }
                self.currentTime += 0.25 * Double(self.rate)
            }
        }
    }
}

// MARK: - Fake TranslationService

final class FakeTranslationService: TranslationServiceProtocol, TranslationDownloadPreparing {
    func translate(_ text: String, from source: Locale.Language, to target: Locale.Language) async throws -> String {
        try await Task.sleep(for: .milliseconds(400))
        return "[traducido] \(text)"
    }

    func availability(from source: Locale.Language, to target: Locale.Language) async -> TranslationAvailability {
        .ready
    }

    func prepare(from source: Locale.Language, to target: Locale.Language) async throws {
        try await Task.sleep(for: .milliseconds(300))
    }
}

// MARK: - Fake TranscriptProvider

/// Always returns the same pre-built `TranscriptHandle` regardless of which
/// episode is asked for — sufficient for previews, which only ever show one
/// episode at a time.
final class FakeTranscriptProvider: TranscriptProviderProtocol {
    private let handle: TranscriptHandle

    init(handle: TranscriptHandle) {
        self.handle = handle
    }

    func transcript(for episodeID: PersistentIdentifier) async throws -> TranscriptHandle {
        handle
    }

    func invalidateAndRetranscribe(episodeID: PersistentIdentifier) async throws -> TranscriptHandle {
        handle
    }
}

// MARK: - Canned Spanish transcript fixture

@MainActor
enum PreviewTranscriptFixture {
    private static let sentences = [
        "Hola a todos, bienvenidos de nuevo al programa.",
        "Hoy vamos a hablar de un tema muy interesante.",
        "La inteligencia artificial está cambiando el mundo rápidamente.",
        "Pero primero, quiero contarles una historia personal.",
        "Cuando era niño, mi abuela me enseñó a cocinar.",
        "Ella decía que la paciencia es la clave de todo.",
        "Ahora entiendo mucho mejor lo que quería decir.",
        "Volvamos al tema principal de hoy.",
        "Muchas empresas están invirtiendo en esta tecnología.",
        "Sin embargo, también hay riesgos que debemos considerar.",
        "Por ejemplo, la privacidad de los datos es fundamental.",
        "Los gobiernos están empezando a regular estas herramientas.",
        "Es un equilibrio difícil de encontrar, la verdad.",
        "Mis oyentes me preguntan mucho sobre este tema.",
        "Espero que este episodio les ayude a entenderlo mejor.",
        "Gracias por escuchar hasta el final, como siempre.",
        "Nos vemos la próxima semana con un nuevo episodio.",
        "Hasta pronto, y cuídense mucho.",
    ]

    /// Inserts real `TranscriptSegment` models into `context` (SwiftData
    /// doesn't offer a public arbitrary-value `PersistentIdentifier`
    /// initializer, so a real inserted model is the only way to get a
    /// legitimate one for a `TranscriptSegmentSnapshot`) and returns the
    /// snapshots, 2-6s apart.
    static func segments(count: Int = 18, in context: ModelContext) -> [TranscriptSegmentSnapshot] {
        var result: [TranscriptSegmentSnapshot] = []
        var time: TimeInterval = 2
        for (index, sentence) in sentences.prefix(count).enumerated() {
            let duration = TimeInterval(2 + (index % 4))
            let start = time
            let end = start + duration
            let model = TranscriptSegment(index: index, startTime: start, endTime: end, text: sentence, wordTimings: [])
            context.insert(model)
            result.append(
                TranscriptSegmentSnapshot(
                    id: model.persistentModelID,
                    index: index,
                    startTime: start,
                    endTime: end,
                    text: sentence,
                    wordTimings: []
                )
            )
            time = end + 0.6
        }
        return result
    }
}

// MARK: - Preview environment factory

@MainActor
enum PreviewEnvironment {
    struct Built {
        let container: AppContainer
        let episode: Episode
        let engine: FakePlayerEngine
    }

    /// Builds a real (in-process) `AppContainer` — required since
    /// `TranscriptOverlayView` reads `@Environment(AppContainer.self)` —
    /// then swaps its M4-relevant service `var`s for fakes. `AppContainer`
    /// itself is read-only for M4 (architecture: "AppContainer needs no new
    /// wiring for M4, pure consumer"); this only reassigns its already-`var`
    /// properties from the outside, the same optional-capability seam
    /// AppContainer's own doc comments describe.
    static func build(
        transcriptState: TranscriptState,
        segmentCount: Int = 18,
        progress: Double = 1,
        currentTime: TimeInterval = 30,
        explainScenario: MockExplainService.Scenario = .normalStream
    ) -> Built {
        let container = AppContainer()
        let context = container.modelContainer.mainContext

        let podcast = Podcast(
            feedURL: URL(string: "https://example.com/feed.xml") ?? URL(fileURLWithPath: "/"),
            title: "Café con Leche",
            author: "Radio Ejemplo",
            languageCode: "es"
        )
        context.insert(podcast)
        let episode = Episode(
            guid: "preview-episode-\(UUID().uuidString)",
            podcast: podcast,
            title: "Un episodio de muestra",
            audioURL: URL(string: "https://example.com/audio.mp3") ?? URL(fileURLWithPath: "/"),
            downloadState: .downloaded
        )
        context.insert(episode)

        let segments: [TranscriptSegmentSnapshot]
        switch transcriptState {
        case .pending:
            segments = []
        case .partial:
            segments = PreviewTranscriptFixture.segments(count: min(8, segmentCount), in: context)
        default:
            segments = PreviewTranscriptFixture.segments(count: segmentCount, in: context)
        }

        let handle = TranscriptHandle(
            previewLanguageCode: "es",
            previewSegments: segments,
            previewState: transcriptState,
            previewProgress: progress
        )

        container.transcriptProvider = FakeTranscriptProvider(handle: handle)
        container.translationService = FakeTranslationService()
        container.explainService = MockExplainService(availability: .ready, scenario: explainScenario)
        container.catalogService = MockCatalogService()

        let engine = FakePlayerEngine(currentTime: currentTime, duration: 900, state: .playing)

        return Built(container: container, episode: episode, engine: engine)
    }
}

// MARK: - #Preview blocks

#Preview("Complete, mid-playback") {
    let built = PreviewEnvironment.build(transcriptState: .complete, currentTime: 22)
    TranscriptOverlayView(episode: built.episode, engine: built.engine, transcriptProvider: built.container.transcriptProvider)
        .environment(built.container)
}

#Preview("Partial (frontier row + progress)") {
    let built = PreviewEnvironment.build(transcriptState: .partial, progress: 0.4, currentTime: 10)
    TranscriptOverlayView(episode: built.episode, engine: built.engine, transcriptProvider: built.container.transcriptProvider)
        .environment(built.container)
}

#Preview("Pending") {
    let built = PreviewEnvironment.build(transcriptState: .pending, currentTime: 0)
    TranscriptOverlayView(episode: built.episode, engine: built.engine, transcriptProvider: built.container.transcriptProvider)
        .environment(built.container)
}

#Preview("Failed (needsDownload)") {
    let built = PreviewEnvironment.build(transcriptState: .failed(reason: TranscriptFailureCode.needsDownload.rawValue), currentTime: 0)
    TranscriptOverlayView(episode: built.episode, engine: built.engine, transcriptProvider: built.container.transcriptProvider)
        .environment(built.container)
}

#Preview("Explain sheet (skeleton -> populated)") {
    let built = PreviewEnvironment.build(transcriptState: .complete, currentTime: 22, explainScenario: .normalStream)
    TranscriptOverlayView(episode: built.episode, engine: built.engine, transcriptProvider: built.container.transcriptProvider)
        .environment(built.container)
}

#Preview("Accessibility: accessibility5 + Reduce Motion") {
    let built = PreviewEnvironment.build(transcriptState: .complete, currentTime: 22)
    TranscriptOverlayView(episode: built.episode, engine: built.engine, transcriptProvider: built.container.transcriptProvider)
        .environment(built.container)
        .environment(\.dynamicTypeSize, .accessibility5)
        .environment(\.accessibilityReduceMotion, true)
}
#endif
