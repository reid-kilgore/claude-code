// M2
// AVPlayer-backed implementation of `PlayerEngineProtocol`
// (`LingoPod/App/Interfaces.swift`, architecture §5.1). Constructed once in
// `AppContainer` and lives for the app's lifetime — not re-created per
// episode (M2 spec §1.2).
import AVFoundation
import Foundation
import LingoPodKit
import Observation
import SwiftData
import os

// MARK: - Episode-switch notification (M2 spec §7.3)
//
// M2 spec §7.3 calls for this to be declared in `LingoPod/App/Interfaces.swift`
// so M3 can see it without a direct M2→M3 import. This integration's
// constraints prohibit M2 from editing anything under `LingoPod/App/`, so
// it's declared here instead. Functionally equivalent: this is a plain
// `Notification.Name` extension with internal (default) access, visible
// anywhere in the `LingoPod` app target regardless of which file declares
// it — M3's `TranscriptProvider` can observe it the same way either way.
// Flagged in the M2 report; the integrator may relocate this declaration
// into `Interfaces.swift` for discoverability without changing its meaning.
extension Notification.Name {
    /// Posted by `PlayerEngine.load(episode:autoplay:)` immediately before
    /// switching to a different episode. `userInfo["episodeID"]` is the
    /// outgoing episode's `PersistentIdentifier` — M3's `TranscriptProvider`
    /// is expected to observe this (e.g. via
    /// `NotificationCenter.default.notifications(named:)`) and cancel any
    /// in-flight transcription task for that episode ID.
    static let playerEngineWillSwitchEpisode = Notification.Name("com.lingopod.playerEngineWillSwitchEpisode")
}

@MainActor
@Observable
final class PlayerEngine: PlayerEngineProtocol {
    private(set) var currentEpisodeID: PersistentIdentifier?
    private(set) var state: PlaybackState = .idle
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval?

    /// `@Observable`'s macro only instruments *stored* properties;
    /// `rate`'s getter reads through `ratePreference` (a plain, non-tracked
    /// reference), so a bare `get { ratePreference.currentRate }` would
    /// silently fail to notify SwiftUI observers on change. Reading this
    /// tracked-but-otherwise-unused counter inside the getter gives `rate`
    /// a real Observation dependency without changing its external
    /// get/set shape (M2 spec §1.1's declared shape is preserved exactly).
    private var rateObservationTick = 0
    var rate: Float {
        get {
            _ = rateObservationTick
            return ratePreference.currentRate
        }
        set { setRate(newValue) }
    }

    // Non-protocol, UI-facing extras (M2 spec §1.1/§5/§6):
    private(set) var isBuffering: Bool = false
    private(set) var currentEpisodeTitle: String = ""
    private(set) var currentPodcastTitle: String = ""
    private(set) var currentArtworkURL: URL?
    private(set) var isCurrentEpisodeDownloaded: Bool = false

    // MARK: Dependencies

    @ObservationIgnored private let modelContext: ModelContext
    @ObservationIgnored private let audioSession: AudioSessionManager
    @ObservationIgnored private let nowPlayingInfo: NowPlayingInfoManager
    @ObservationIgnored private let positionStore: PlaybackPositionStore
    @ObservationIgnored private let ratePreference: PlaybackRatePreference
    @ObservationIgnored private let catalogService: any CatalogServiceProtocol
    @ObservationIgnored private let playerFactory: (URL) -> any AVPlayerWrapping
    @ObservationIgnored private let logger = Logger(subsystem: "com.lingopod.app", category: "Playback")

    // MARK: Internal AVFoundation-adjacent state

    @ObservationIgnored private var playerWrapper: (any AVPlayerWrapping)?
    @ObservationIgnored private var timeObserverToken: Any?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    @ObservationIgnored private var durationObservation: NSKeyValueObservation?
    @ObservationIgnored private var bufferEmptyObservation: NSKeyValueObservation?
    @ObservationIgnored private var likelyToKeepUpObservation: NSKeyValueObservation?
    @ObservationIgnored private var bufferFullObservation: NSKeyValueObservation?
    @ObservationIgnored private var endTimeObserverToken: NSObjectProtocol?
    @ObservationIgnored private var nowPlayingElapsedTask: Task<Void, Never>?
    /// Monotonically increasing token guarding against a fast double-tap
    /// `load()` racing itself (M2 spec §1.3, "load supersedes in-flight load").
    @ObservationIgnored private var loadGeneration = 0

    init(
        modelContext: ModelContext,
        audioSession: AudioSessionManager = AudioSessionManager(),
        nowPlayingInfo: NowPlayingInfoManager = NowPlayingInfoManager(),
        positionStore: PlaybackPositionStore,
        ratePreference: PlaybackRatePreference = PlaybackRatePreference(),
        catalogService: any CatalogServiceProtocol,
        playerFactory: @escaping (URL) -> any AVPlayerWrapping = { AVPlayer(url: $0) }
    ) {
        self.modelContext = modelContext
        self.audioSession = audioSession
        self.nowPlayingInfo = nowPlayingInfo
        self.positionStore = positionStore
        self.ratePreference = ratePreference
        self.catalogService = catalogService
        self.playerFactory = playerFactory

        // Wired at construction time, not deferred to first playback, so an
        // interruption/route change that begins before any playback
        // doesn't misbehave (M2 spec §2). Each callback is a no-op unless
        // actually playing.
        audioSession.onInterruptionBegan = { [weak self] in
            guard let self, self.state == .playing else { return }
            self.pause()
        }
        audioSession.onInterruptionEnded = { [weak self] shouldResume in
            guard let self, shouldResume else { return }
            self.play()
        }
        audioSession.onRouteChangeShouldPause = { [weak self] in
            guard let self, self.state == .playing else { return }
            self.pause()
        }

        nowPlayingInfo.configureRemoteCommands(engine: self)
    }

    // MARK: - Load

    func load(episode: Episode, autoplay: Bool) async {
        loadGeneration += 1
        let generation = loadGeneration

        if let outgoingID = currentEpisodeID, outgoingID != episode.persistentModelID {
            // Persist the outgoing episode's position before detaching, and
            // announce the switch so M3's TranscriptProvider can cancel
            // in-flight transcription for it (§1.3 step 1, §7.3).
            positionStore.saveNow(engine: self)
            NotificationCenter.default.post(
                name: .playerEngineWillSwitchEpisode,
                object: nil,
                userInfo: ["episodeID": outgoingID]
            )
        }

        tearDownObservers()

        state = .loading
        currentTime = 0
        duration = nil
        isBuffering = false
        currentEpisodeID = episode.persistentModelID
        currentEpisodeTitle = episode.title
        currentPodcastTitle = episode.podcast?.title ?? ""
        currentArtworkURL = episode.podcast?.artworkURL
        isCurrentEpisodeDownloaded = episode.downloadState == .downloaded

        guard let sourceURL = resolveSourceURL(for: episode) else {
            state = .failed(PlaybackError(code: "noPlayableSource", message: "Episode has no local file and no reachable audio URL."))
            return
        }

        let wrapper = playerFactory(sourceURL)
        guard generation == loadGeneration else { return }
        playerWrapper = wrapper
        wireObservers(on: wrapper)

        if let item = wrapper.currentItem {
            do {
                let cmDuration = try await item.asset.load(.duration)
                guard generation == loadGeneration else { return }
                let seconds = CMTimeGetSeconds(cmDuration)
                // §1.3 step 5: `.indefinite`/non-finite durations (can
                // happen mid-download for a partial file) leave `duration`
                // nil; the KVO observer in `wireObservers` fills it in once
                // `AVPlayerItem.duration` becomes finite.
                if seconds.isFinite, seconds > 0 {
                    duration = seconds
                }
            } catch {
                guard generation == loadGeneration else { return }
                logger.error("Failed to load asset duration: \(String(describing: error), privacy: .public)")
                state = .failed(PlaybackError(code: "assetLoadFailed", message: String(describing: error)))
                return
            }
        }

        guard generation == loadGeneration else { return }

        if let target = PlaybackTimeMath.resumeTarget(
            storedPosition: episode.playbackPosition,
            duration: duration,
            playbackCompleted: episode.playbackCompleted
        ) {
            await seek(to: target)
            guard generation == loadGeneration else { return }
        }

        // player.rate is only meaningfully set once playback starts (§1.6);
        // `play()` applies the persisted rate itself via
        // `applyPersistedRateOnPlay()`.
        if autoplay {
            play()
        } else {
            state = .paused
        }

        guard generation == loadGeneration else { return }
        nowPlayingInfo.update(from: self)
        triggerAutoDownloadIfNeeded(episode: episode)
    }

    /// Resolves the source URL, preferring the downloaded local file over
    /// streaming (§1.3 step 3).
    ///
    /// Base-path convention pinned by `docs/specs/M0-scaffolding.md` §8 /
    /// architecture §11.9 (`Application Support/Episodes/`, relative
    /// `localAudioPath`). Architecture §11.9 assigns the canonical
    /// `Episode.resolvedLocalAudioURL` helper to M1, but that helper does
    /// not exist in the repo yet at M2 implementation time (M1's
    /// `LingoPod/Services/` is still just a placeholder directory) — this
    /// duplicates the same documented convention locally rather than
    /// inventing a new one. When M1 lands the real helper, replace this
    /// with a call to it and delete `episodesDirectory` below (flagged in
    /// the M2 report).
    private func resolveSourceURL(for episode: Episode) -> URL? {
        if let relativePath = episode.localAudioPath {
            return Self.episodesDirectory.appendingPathComponent(relativePath)
        }
        return episode.audioURL
    }

    private static var episodesDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Episodes", isDirectory: true)
    }

    // MARK: - Transport

    func play() {
        guard state != .loading else { return }
        audioSession.activate()
        applyPersistedRateOnPlay()
        playerWrapper?.play()
        state = .playing
        nowPlayingInfo.update(from: self)
        positionStore.startPeriodicSave(engine: self)
        startNowPlayingElapsedTimeLoop()
    }

    func pause() {
        playerWrapper?.pause()
        state = .paused
        nowPlayingInfo.update(from: self)
        positionStore.stopPeriodicSave()
        positionStore.saveNow(engine: self)
        stopNowPlayingElapsedTimeLoop()
    }

    func togglePlayPause() {
        switch state {
        case .playing: pause()
        case .paused, .idle: play()
        default: break // no-op during .loading / .failed
        }
    }

    func seek(to time: TimeInterval) async {
        let clamped = PlaybackTimeMath.clampedSeekTarget(time, duration: duration)
        let cmTime = CMTime(seconds: clamped, preferredTimescale: 600)
        // Zero tolerance is required, not merely preferred (§1.5): default
        // AVPlayer tolerance can snap to the nearest keyframe, which for
        // typical podcast encodes can be several seconds off — unacceptable
        // for tap-to-seek from the transcript overlay.
        _ = await playerWrapper?.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = clamped
        if state == .paused {
            // A seek-then-background must not lose the new position before
            // the next periodic tick (§1.5).
            positionStore.saveNow(engine: self)
        }
        nowPlayingInfo.update(from: self)
    }

    func skip(by seconds: TimeInterval) async {
        await seek(to: currentTime + seconds)
    }

    // MARK: - Rate

    private func setRate(_ newValue: Float) {
        let clamped = PlaybackTimeMath.clampedRate(newValue)
        ratePreference.currentRate = clamped
        if state == .playing {
            // Setting `.rate` on a playing AVPlayer both changes speed and
            // keeps it playing (§1.6).
            playerWrapper?.rate = clamped
        }
        // If not playing: only persist. Setting a non-zero rate on an
        // AVPlayer that is not currently playing starts playback (a
        // well-known AVPlayer quirk, §1.6) — applied instead at the moment
        // `play()` is next called, via `applyPersistedRateOnPlay()`.
        rateObservationTick += 1
        nowPlayingInfo.update(from: self)
    }

    /// Always re-set `.rate` explicitly in `play()`, never rely on it
    /// having "stuck" from before a pause (§1.6).
    private func applyPersistedRateOnPlay() {
        playerWrapper?.rate = ratePreference.currentRate
    }

    // MARK: - Background-save integration point (§4.1)

    /// Non-protocol, app-internal. `AppContainer`/the root `App` struct (M0)
    /// is expected to observe `scenePhase` and call this on transition to
    /// `.background`. M2's constraints for this integration prohibit
    /// editing `LingoPod/App/LingoPodApp.swift`/`RootView.swift`, so this
    /// method exists but its call site is not wired here — see the M2
    /// report for the exact one-line call to add at integration time.
    func persistPositionForBackgrounding() {
        positionStore.saveNow(engine: self)
    }

    // MARK: - Auto-download-on-play (§6)

    /// M2's job is only to *trigger* the download, not implement it — M1's
    /// `CatalogServiceProtocol.download(episodeID:)` owns dedup/coalescing
    /// of concurrent requests and returns once durably enqueued, not on
    /// completion (architecture §11.11). Fire-and-forget: playback proceeds
    /// by streaming `episode.audioURL` regardless ("never block playback").
    private func triggerAutoDownloadIfNeeded(episode: Episode) {
        switch episode.downloadState {
        case .none, .failed:
            let episodeID = episode.persistentModelID
            let catalogService = catalogService
            Task.detached {
                try? await catalogService.download(episodeID: episodeID)
            }
        case .inProgress, .downloaded:
            break
        }
    }

    // MARK: - AVPlayerItem observation wiring (§1.3 step 4, §7.2)

    private func wireObservers(on wrapper: any AVPlayerWrapping) {
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserverToken = wrapper.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                self?.currentTime = CMTimeGetSeconds(time)
            }
        }

        guard let item = wrapper.currentItem else { return }

        statusObservation = item.observe(\.status, options: [.new]) { [weak self] observedItem, _ in
            Task { @MainActor [weak self] in
                guard let self, observedItem.status == .failed else { return }
                let message = observedItem.error.map { String(describing: $0) } ?? "Unknown AVPlayerItem failure"
                self.state = .failed(PlaybackError(code: "avPlayerError", message: message))
            }
        }

        durationObservation = item.observe(\.duration, options: [.new]) { [weak self] observedItem, _ in
            Task { @MainActor [weak self] in
                guard let self, self.duration == nil else { return }
                let seconds = CMTimeGetSeconds(observedItem.duration)
                if seconds.isFinite, seconds > 0 {
                    self.duration = seconds
                }
            }
        }

        // Buffering (§7.2): UI-only flag, never mutates `PlaybackState`
        // itself — the protocol has no buffering case.
        bufferEmptyObservation = item.observe(\.isPlaybackBufferEmpty, options: [.new]) { [weak self] observedItem, _ in
            Task { @MainActor [weak self] in
                if observedItem.isPlaybackBufferEmpty { self?.isBuffering = true }
            }
        }
        likelyToKeepUpObservation = item.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { [weak self] observedItem, _ in
            Task { @MainActor [weak self] in
                if observedItem.isPlaybackLikelyToKeepUp { self?.isBuffering = false }
            }
        }
        bufferFullObservation = item.observe(\.isPlaybackBufferFull, options: [.new]) { [weak self] observedItem, _ in
            Task { @MainActor [weak self] in
                if observedItem.isPlaybackBufferFull { self?.isBuffering = false }
            }
        }

        endTimeObserverToken = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleDidPlayToEnd()
            }
        }
    }

    private func handleDidPlayToEnd() {
        if let id = currentEpisodeID, let episode = try? modelContext.model(for: id) as? Episode {
            episode.playbackCompleted = true
            episode.playbackPosition = 0
            do {
                try modelContext.save()
            } catch {
                logger.error("Failed to save completion state: \(String(describing: error), privacy: .public)")
            }
        }
        // No auto-advance to a "next episode" — no such feature in v1
        // (§1.3 step 4).
        state = .paused
        currentTime = 0
        Task { await self.seek(to: 0) }
        nowPlayingInfo.update(from: self)
        positionStore.stopPeriodicSave()
        stopNowPlayingElapsedTimeLoop()
    }

    private func tearDownObservers() {
        if let token = timeObserverToken {
            playerWrapper?.removeTimeObserver(token)
            timeObserverToken = nil
        }
        statusObservation = nil
        durationObservation = nil
        bufferEmptyObservation = nil
        likelyToKeepUpObservation = nil
        bufferFullObservation = nil
        if let token = endTimeObserverToken {
            NotificationCenter.default.removeObserver(token)
            endTimeObserverToken = nil
        }
        playerWrapper = nil
    }

    // MARK: - Now Playing elapsed-time cadence (§5.1: ~1 Hz, not the 0.25s observer)

    private func startNowPlayingElapsedTimeLoop() {
        nowPlayingElapsedTask?.cancel()
        nowPlayingElapsedTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { break }
                self.nowPlayingInfo.update(from: self)
            }
        }
    }

    private func stopNowPlayingElapsedTimeLoop() {
        nowPlayingElapsedTask?.cancel()
        nowPlayingElapsedTask = nil
    }
}
