// M2
// `MPNowPlayingInfoCenter` + `MPRemoteCommandCenter` wiring (M2 spec §5).
// This is also how CarPlay, AirPods, lock-screen, and Control Center remote
// controls are supported — there is no separate CarPlay code path; every
// remote surface routes exclusively through `MPRemoteCommandCenter`/
// `MPNowPlayingInfoCenter` (§5.2).
import Foundation
import MediaPlayer
import UIKit
import os

@MainActor
final class NowPlayingInfoManager {
    private let logger = Logger(subsystem: "com.lingopod.app", category: "Playback")
    private var isRemoteCommandsConfigured = false

    private var artworkCache: [URL: MPMediaItemArtwork] = [:]
    private var inFlightArtworkURL: URL?
    private var artworkFetchTask: Task<Void, Never>?

    /// Rebuilds the full `MPNowPlayingInfoCenter` dictionary. Callers are
    /// responsible for throttling: `PlayerEngine` calls this on load
    /// completion, state transitions, rate changes, duration becoming
    /// known, and from a dedicated ~1 Hz loop for elapsed-time — never from
    /// the 0.25s time observer (§5.1's "do not rebuild the whole dictionary
    /// 4x/second").
    func update(from engine: PlayerEngine) {
        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = engine.currentEpisodeTitle
        info[MPMediaItemPropertyArtist] = engine.currentPodcastTitle
        if let duration = engine.duration {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = engine.currentTime
        // "Native" configured rate vs. actual motion — set both per
        // MediaPlayer convention (§5.1).
        info[MPNowPlayingInfoPropertyPlaybackRate] = engine.state == .playing ? engine.rate : 0
        info[MPMediaItemPropertyPlaybackRate] = engine.rate

        if let url = engine.currentArtworkURL {
            if let cached = artworkCache[url] {
                info[MPMediaItemPropertyArtwork] = cached
            } else {
                fetchArtworkIfNeeded(url: url, engine: engine)
            }
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// Fires the artwork fetch once per episode load; merges it in via a
    /// follow-up `update(from:)` call when it arrives, without blocking the
    /// synchronous `update(from:)` above (§5.1).
    private func fetchArtworkIfNeeded(url: URL, engine: PlayerEngine) {
        guard inFlightArtworkURL != url else { return }
        inFlightArtworkURL = url
        artworkFetchTask?.cancel()
        artworkFetchTask = Task { [weak self, weak engine] in
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard !Task.isCancelled, let image = UIImage(data: data) else { return }
                guard let self else { return }
                let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                self.artworkCache[url] = artwork
                if self.inFlightArtworkURL == url {
                    self.inFlightArtworkURL = nil
                }
                if let engine, engine.currentArtworkURL == url {
                    self.update(from: engine)
                }
            } catch {
                self?.logger.error("Now Playing artwork fetch failed: \(String(describing: error), privacy: .public)")
                if self?.inFlightArtworkURL == url {
                    self?.inFlightArtworkURL = nil
                }
            }
        }
    }

    /// One-time, idempotent command handler wiring (§5.2). Handlers hop
    /// through `Task { @MainActor in ... }` since
    /// `MPRemoteCommandCenter`'s handler closure type is not statically
    /// actor-isolated; they still return `.success` synchronously so the
    /// system doesn't see a stalled response (§1.4's "commands must respond
    /// synchronously").
    func configureRemoteCommands(engine: PlayerEngine) {
        guard !isRemoteCommandsConfigured else { return }
        isRemoteCommandsConfigured = true

        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { [weak engine] _ in
            Task { @MainActor in engine?.play() }
            return .success
        }
        center.pauseCommand.addTarget { [weak engine] _ in
            Task { @MainActor in engine?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak engine] _ in
            Task { @MainActor in engine?.togglePlayPause() }
            return .success
        }

        center.skipForwardCommand.preferredIntervals = [30]
        center.skipForwardCommand.addTarget { [weak engine] _ in
            Task { @MainActor in await engine?.skip(by: 30) }
            return .success
        }

        center.skipBackwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.addTarget { [weak engine] _ in
            Task { @MainActor in await engine?.skip(by: -15) }
            return .success
        }

        center.changePlaybackPositionCommand.addTarget { [weak engine] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in await engine?.seek(to: event.positionTime) }
            return .success
        }

        center.changePlaybackRateCommand.supportedPlaybackRates = PlaybackRatePreference.allowedSteps.map { NSNumber(value: $0) }
        center.changePlaybackRateCommand.addTarget { [weak engine] event in
            guard let event = event as? MPChangePlaybackRateCommandEvent else { return .commandFailed }
            Task { @MainActor in engine?.rate = event.playbackRate }
            return .success
        }

        // No queue/playlist concept in v1 (§5.2) — leave disabled rather
        // than wiring to a no-op.
        center.nextTrackCommand.isEnabled = false
        center.previousTrackCommand.isEnabled = false
    }
}
