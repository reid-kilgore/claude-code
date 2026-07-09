// M2
// Unit tests for `PlayerEngine` per M2 spec §9.1: state machine, the
// rate-persistence/pause-resume quirk, seek clamping and completion
// bridging, the auto-download-on-play trigger, and the episode-switch
// notification. Uses an in-memory `ModelContainer` (no disk I/O) and the
// `AVPlayerWrapping` seam (`MockAVPlayerWrapping.swift`) so none of this
// touches real media, `AVAudioSession` output, or the simulator's audio
// hardware.
@testable import LingoPod
import Foundation
import LingoPodKit
import SwiftData
import Testing

private actor RecordingCatalogService: CatalogServiceProtocol {
    private(set) var downloadCallCount = 0
    private(set) var lastDownloadedEpisodeID: PersistentIdentifier?

    func search(term: String) async throws -> [PodcastSearchResult] { [] }
    func subscribe(feedURL: URL) async throws -> PersistentIdentifier {
        fatalError("not exercised by these tests")
    }
    func unsubscribe(podcastID: PersistentIdentifier) async throws {}
    func refresh(podcastID: PersistentIdentifier) async throws {}
    func download(episodeID: PersistentIdentifier) async throws {
        downloadCallCount += 1
        lastDownloadedEpisodeID = episodeID
    }
    func removeDownload(episodeID: PersistentIdentifier) async throws {}
}

@MainActor
private func makeInMemoryContext() throws -> ModelContext {
    let schema = Schema([
        Podcast.self,
        Episode.self,
        Transcript.self,
        TranscriptSegment.self,
        TranslationCacheEntry.self,
        ExplanationCacheEntry.self,
    ])
    let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    let container = try ModelContainer(for: schema, configurations: [configuration])
    return ModelContext(container)
}

@MainActor
private func makeEpisode(
    in context: ModelContext,
    title: String = "Episode",
    playbackPosition: TimeInterval = 0,
    playbackCompleted: Bool = false,
    downloadState: DownloadState = .none
) -> Episode {
    let podcast = Podcast(feedURL: URL(string: "https://example.com/feed-\(UUID())")!, title: "Podcast")
    context.insert(podcast)
    let episode = Episode(
        guid: UUID().uuidString,
        podcast: podcast,
        title: title,
        audioURL: URL(string: "https://example.com/audio-\(UUID()).mp3")!,
        downloadState: downloadState,
        playbackPosition: playbackPosition,
        playbackCompleted: playbackCompleted
    )
    context.insert(episode)
    try? context.save()
    return episode
}

@MainActor
private func makeEngine(
    context: ModelContext,
    catalogService: RecordingCatalogService = RecordingCatalogService()
) -> (engine: PlayerEngine, wrapper: MockAVPlayerWrapping) {
    let wrapper = MockAVPlayerWrapping()
    let defaults = UserDefaults(suiteName: "PlayerEngineTests-\(UUID())")!
    let engine = PlayerEngine(
        modelContext: context,
        positionStore: PlaybackPositionStore(modelContext: context),
        ratePreference: PlaybackRatePreference(defaults: defaults),
        catalogService: catalogService,
        playerFactory: { _ in wrapper }
    )
    return (engine, wrapper)
}

@MainActor
private func waitForDownloadCallCount(_ service: RecordingCatalogService, atLeast target: Int, timeoutMS: Int = 1000) async -> Int {
    var elapsed = 0
    while elapsed < timeoutMS {
        let count = await service.downloadCallCount
        if count >= target { return count }
        try? await Task.sleep(for: .milliseconds(10))
        elapsed += 10
    }
    return await service.downloadCallCount
}

// MARK: - State machine

@MainActor
@Test func loadWithAutoplayTransitionsToPlaying() async throws {
    let context = try makeInMemoryContext()
    let episode = makeEpisode(in: context)
    let (engine, wrapper) = makeEngine(context: context)

    #expect(engine.state == .idle)
    await engine.load(episode: episode, autoplay: true)

    #expect(engine.state == .playing)
    #expect(engine.currentEpisodeID == episode.persistentModelID)
    #expect(wrapper.playCallCount == 1)
}

@MainActor
@Test func loadWithoutAutoplaySetsPaused() async throws {
    let context = try makeInMemoryContext()
    let episode = makeEpisode(in: context)
    let (engine, wrapper) = makeEngine(context: context)

    await engine.load(episode: episode, autoplay: false)

    #expect(engine.state == .paused)
    #expect(wrapper.playCallCount == 0)
}

@MainActor
@Test func togglePlayPauseFlipsStateAndUnderlyingWrapper() async throws {
    let context = try makeInMemoryContext()
    let episode = makeEpisode(in: context)
    let (engine, wrapper) = makeEngine(context: context)
    await engine.load(episode: episode, autoplay: false)

    engine.togglePlayPause()
    #expect(engine.state == .playing)
    #expect(wrapper.playCallCount == 1)

    engine.togglePlayPause()
    #expect(engine.state == .paused)
    #expect(wrapper.pauseCallCount == 1)
}

// MARK: - Rate persistence + pause/resume quirk (§1.6)

@MainActor
@Test func settingRateWhilePausedPersistsButDoesNotTouchPlayerRateUntilPlay() async throws {
    let context = try makeInMemoryContext()
    let episode = makeEpisode(in: context)
    let (engine, wrapper) = makeEngine(context: context)
    await engine.load(episode: episode, autoplay: false)
    wrapper.rate = 0

    engine.rate = 1.5

    #expect(wrapper.rate == 0, "must not touch AVPlayer.rate while paused — that would start playback")
    #expect(engine.rate == 1.5, "preference must still be updated")

    engine.play()

    #expect(wrapper.rate == 1.5, "persisted rate must be explicitly re-applied on play(), not assumed to have stuck")
}

@MainActor
@Test func rateIsClampedToAllowedRange() async throws {
    let context = try makeInMemoryContext()
    let episode = makeEpisode(in: context)
    let (engine, _) = makeEngine(context: context)
    await engine.load(episode: episode, autoplay: false)

    engine.rate = 10
    #expect(engine.rate == 2.0)

    engine.rate = 0.1
    #expect(engine.rate == 0.5)
}

@MainActor
@Test func rateWhilePlayingIsAppliedToWrapperImmediately() async throws {
    let context = try makeInMemoryContext()
    let episode = makeEpisode(in: context)
    let (engine, wrapper) = makeEngine(context: context)
    await engine.load(episode: episode, autoplay: true)

    engine.rate = 1.75

    #expect(wrapper.rate == 1.75)
}

// MARK: - Seek clamping and completion bridging (§1.5)

@MainActor
@Test func seekNeverGoesNegative() async throws {
    let context = try makeInMemoryContext()
    let episode = makeEpisode(in: context)
    let (engine, _) = makeEngine(context: context)
    await engine.load(episode: episode, autoplay: false)

    await engine.seek(to: -50)

    #expect(engine.currentTime == 0)
}

@MainActor
@Test func seekDoesNotHangWhenUnderlyingSeekIsSuperseded() async throws {
    let context = try makeInMemoryContext()
    let episode = makeEpisode(in: context)
    let (engine, wrapper) = makeEngine(context: context)
    await engine.load(episode: episode, autoplay: false)

    wrapper.seekResult = false // simulates AVPlayer canceling an earlier, in-flight seek
    await engine.seek(to: 42)

    #expect(engine.currentTime == 42, "a `finished: false` completion is not an error — the stale continuation just resumes")
    #expect(wrapper.seekCalls.count == 1)
}

@MainActor
@Test func skipAddsDeltaToCurrentTime() async throws {
    let context = try makeInMemoryContext()
    let episode = makeEpisode(in: context)
    let (engine, _) = makeEngine(context: context)
    await engine.load(episode: episode, autoplay: false)

    await engine.seek(to: 100)
    await engine.skip(by: 30)
    #expect(engine.currentTime == 130)

    await engine.skip(by: -15)
    #expect(engine.currentTime == 115)
}

// MARK: - Auto-download-on-play (§6)

@MainActor
@Test func autoDownloadTriggersForUndownloadedEpisode() async throws {
    let context = try makeInMemoryContext()
    let episode = makeEpisode(in: context, downloadState: .none)
    let recording = RecordingCatalogService()
    let (engine, _) = makeEngine(context: context, catalogService: recording)

    await engine.load(episode: episode, autoplay: false)

    let count = await waitForDownloadCallCount(recording, atLeast: 1)
    #expect(count == 1)
    let recordedID = await recording.lastDownloadedEpisodeID
    #expect(recordedID == episode.persistentModelID)
}

@MainActor
@Test func autoDownloadTriggersForPreviouslyFailedEpisode() async throws {
    let context = try makeInMemoryContext()
    let episode = makeEpisode(in: context, downloadState: .failed(reason: "network"))
    let recording = RecordingCatalogService()
    let (engine, _) = makeEngine(context: context, catalogService: recording)

    await engine.load(episode: episode, autoplay: false)

    let count = await waitForDownloadCallCount(recording, atLeast: 1)
    #expect(count == 1)
}

@MainActor
@Test func autoDownloadDoesNotTriggerForAlreadyDownloadedEpisode() async throws {
    let context = try makeInMemoryContext()
    let episode = makeEpisode(in: context, downloadState: .downloaded)
    let recording = RecordingCatalogService()
    let (engine, _) = makeEngine(context: context, catalogService: recording)

    await engine.load(episode: episode, autoplay: false)
    try? await Task.sleep(for: .milliseconds(50))

    #expect(await recording.downloadCallCount == 0)
}

@MainActor
@Test func autoDownloadDoesNotTriggerForInProgressEpisode() async throws {
    let context = try makeInMemoryContext()
    let episode = makeEpisode(in: context, downloadState: .inProgress(progress: 0.4))
    let recording = RecordingCatalogService()
    let (engine, _) = makeEngine(context: context, catalogService: recording)

    await engine.load(episode: episode, autoplay: false)
    try? await Task.sleep(for: .milliseconds(50))

    #expect(await recording.downloadCallCount == 0)
}

// MARK: - Episode-switch notification (§7.3)

@MainActor
@Test func loadingDifferentEpisodePostsSwitchNotificationWithOutgoingID() async throws {
    let context = try makeInMemoryContext()
    let episodeA = makeEpisode(in: context, title: "A")
    let episodeB = makeEpisode(in: context, title: "B")
    let (engine, _) = makeEngine(context: context)

    await engine.load(episode: episodeA, autoplay: false)

    var capturedID: PersistentIdentifier?
    let observer = NotificationCenter.default.addObserver(
        forName: .playerEngineWillSwitchEpisode,
        object: nil,
        queue: nil
    ) { notification in
        capturedID = notification.userInfo?["episodeID"] as? PersistentIdentifier
    }
    defer { NotificationCenter.default.removeObserver(observer) }

    await engine.load(episode: episodeB, autoplay: false)

    #expect(capturedID == episodeA.persistentModelID)
    #expect(engine.currentEpisodeID == episodeB.persistentModelID)
}

@MainActor
@Test func loadingSameEpisodeAgainDoesNotPostSwitchNotification() async throws {
    let context = try makeInMemoryContext()
    let episode = makeEpisode(in: context)
    let (engine, _) = makeEngine(context: context)

    await engine.load(episode: episode, autoplay: false)

    var notified = false
    let observer = NotificationCenter.default.addObserver(
        forName: .playerEngineWillSwitchEpisode,
        object: nil,
        queue: nil
    ) { _ in notified = true }
    defer { NotificationCenter.default.removeObserver(observer) }

    await engine.load(episode: episode, autoplay: false)

    #expect(notified == false)
}
