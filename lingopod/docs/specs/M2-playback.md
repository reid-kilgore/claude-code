# M2 — Playback Engine + Now-Playing UI

Status: ready for implementation
Depends on: M0 (DI container, app entry, background modes, Info.plist), M1
(`Episode` SwiftData model — read-only from M2's perspective except for
position/completion writes described in §4)
Consumed by: M3 (uses `currentTime` for transcription scheduling), M4 (uses
`PlayerEngineProtocol` for playhead sync + seek), AppContainer (constructs
and injects `PlayerEngine`)

This spec adds detail to `docs/01-architecture.md` (the contract). It does
not and may not contradict it. Where this document says "MUST", treat it as
a hard requirement; "SHOULD" is a strong default you may deviate from only
with a code comment explaining why.

---

## 0. File map

```
LingoPod/
  Playback/
    PlayerEngine.swift          // @MainActor @Observable final class PlayerEngine: PlayerEngineProtocol
    AudioSessionManager.swift   // AVAudioSession category/activation/interruption/route-change handling
    NowPlayingInfoManager.swift // MPNowPlayingInfoCenter + MPRemoteCommandCenter wiring
    PlaybackPositionStore.swift // periodic + lifecycle persistence of Episode.playbackPosition/playbackCompleted
    PlaybackRatePreference.swift// UserDefaults-backed persisted playback rate
    AVPlayerWrapping.swift      // thin protocol wrapping AVPlayer for testability (see §9)
  UI/
    Player/
      MiniPlayerView.swift
      PlayerView.swift
      PlaybackRateMenu.swift
      SkipButton.swift
```

`LingoPod/App/Interfaces.swift` already declares `PlayerEngineProtocol`
(architecture §5.1) verbatim — M2 MUST NOT redeclare or modify it there;
`PlayerEngine` conforms to it as-is. If you believe the protocol needs to
change, stop and flag it rather than diverging silently (§10 of the
architecture doc).

Every file starts with `// M2` per architecture §10.

---

## 1. `PlayerEngine`

### 1.1 Declaration

```swift
// M2
import AVFoundation
import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class PlayerEngine: PlayerEngineProtocol {
    private(set) var currentEpisodeID: PersistentIdentifier?
    private(set) var state: PlaybackState = .idle
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval?
    var rate: Float {
        get { ratePreference.currentRate }
        set { setRate(newValue) }
    }

    // Non-protocol, UI-facing extras (see §5/§6):
    private(set) var isBuffering: Bool = false
    private(set) var currentEpisodeTitle: String = ""
    private(set) var currentPodcastTitle: String = ""
    private(set) var currentArtworkURL: URL?
    private(set) var isCurrentEpisodeDownloaded: Bool = false

    // dependencies injected via init — see §1.2
}
```

`PlaybackState` is defined exactly as architecture §5.1 lists it:
`idle, loading, playing, paused, failed(Error)`. Put this enum in
`LingoPod/App/Interfaces.swift` alongside the protocol if it is not already
there (M2 owns this type since only M2 produces it); it MUST be `Sendable`
so `state` can be read where needed, and `Error` inside `.failed` MUST be a
concrete `Sendable`, `Equatable`-if-practical type — define:

```swift
enum PlaybackState: Equatable {
    case idle
    case loading
    case playing
    case paused
    case failed(PlaybackError)
}

enum PlaybackError: Error, Equatable, LocalizedError {
    case assetLoadFailed
    case noPlayableSource       // no localAudioPath and no reachable audioURL
    case avPlayerError(String)  // message extracted from AVPlayer/AVPlayerItem .error
    var errorDescription: String? { /* human-readable string per case */ }
}
```

(`Error` itself is not `Equatable`, hence the dedicated `PlaybackError`
type — architecture §5.1's `failed(Error)` is realized as
`failed(PlaybackError)`.)

### 1.2 Dependencies (constructor injection)

```swift
init(
    modelContext: ModelContext,
    audioSession: AudioSessionManager = AudioSessionManager(),
    nowPlayingInfo: NowPlayingInfoManager = NowPlayingInfoManager(),
    positionStore: PlaybackPositionStore,
    ratePreference: PlaybackRatePreference = PlaybackRatePreference(),
    catalogService: CatalogServiceProtocol,
    playerFactory: @escaping (URL) -> any AVPlayerWrapping = { AVPlayer(url: $0) }
)
```

- `modelContext` is the app's main-actor `ModelContext` (from
  `AppContainer`), used to read/write the `Episode` for position/completion
  persistence (§4).
- `catalogService` is M1's `CatalogServiceProtocol`, used only to trigger
  auto-download-on-play (§6). `PlayerEngine` MUST NOT depend on any other
  M1 type beyond `Episode` and `CatalogServiceProtocol`.
- `playerFactory` exists purely for testability (§9); production code uses
  the default, which wraps a real `AVPlayer`.

`PlayerEngine` is constructed once in `AppContainer` (M0) and lives for the
app's lifetime; it is not re-created per episode.

### 1.3 `load(episode:autoplay:)`

```swift
func load(episode: Episode, autoplay: Bool) async
```

Sequence:
1. If `currentEpisodeID` is set and differs from `episode.persistentModelID`,
   treat this as an episode switch:
   - Persist the outgoing episode's position immediately (§4.2) before
     detaching.
   - Post `Notification.Name.playerEngineWillSwitchEpisode` with the
     outgoing `PersistentIdentifier` in `userInfo["episodeID"]` — this is
     the cancellation seam M3's `TranscriptProvider` listens to so it stops
     transcribing the episode you're leaving (see §7.3; the notification is
     declared by M2 since M2 is the trigger, even though M3 is the
     consumer — declare it in `LingoPod/App/Interfaces.swift` near the
     protocols so both modules can see it without a direct M2→M3 import).
   - Tear down the existing time observer and `AVPlayerItem` KVO/NotificationCenter
     observers before building the new player item (avoid duplicate
     callbacks firing against stale state).
2. Set `state = .loading`, `currentTime = 0`, `duration = nil`,
   `isBuffering = false`. Set `currentEpisodeID = episode.persistentModelID`,
   and the UI-facing fields (`currentEpisodeTitle = episode.title`,
   `currentPodcastTitle = episode.podcast?.title ?? ""`,
   `currentArtworkURL = episode.podcast?.artworkURL`,
   `isCurrentEpisodeDownloaded = episode.downloadState == .downloaded`).
3. Resolve the source URL: if `episode.localAudioPath` is non-nil, resolve
   it to an absolute file URL under
   `FileManager.default.urls(for: .applicationSupportDirectory, ...)`
   (same base path convention M1 uses for downloads — read it, do not
   invent a new one; if M1's spec/interfaces expose a helper for this
   resolution, use it instead of hand-rolling the join) and use
   `URL(fileURLWithPath:)`. Else use `episode.audioURL` directly (streaming).
   If neither resolves to a usable URL, set
   `state = .failed(.noPlayableSource)` and return.
4. Build the `AVPlayerItem`/`AVPlayer` via `playerFactory(url)`. Wire:
   - A periodic time observer at **0.25s interval**
     (`CMTime(seconds: 0.25, preferredTimescale: 600)`) that updates
     `currentTime` on the main actor (the closure is already called on the
     main queue since we pass `queue: .main`, but since `PlayerEngine` is
     `@MainActor`, hop explicitly only if the underlying wrapper's callback
     isn't guaranteed main-queue — see §9 wrapper contract).
   - KVO/observation on the item's `status` to detect `.failed` →
     `state = .failed(.avPlayerError(...))`.
   - Observation of `timeControlStatus` / buffering signals
     (`playbackBufferEmpty`, `playbackLikelyToKeepUp`) to drive
     `isBuffering` (§7.2).
   - `AVPlayerItemDidPlayToEndTime` notification → on fire, mark
     `episode.playbackCompleted = true`, `episode.playbackPosition = 0`,
     save context, set `state = .paused`, `currentTime = 0`, seek player to
     zero. (Do not auto-advance to a "next episode" — no such feature in
     v1 per product overview's scope.)
5. `await` the asset's duration: `try await item.asset.load(.duration)`,
   convert to `TimeInterval` via `CMTimeGetSeconds`; if it's `.indefinite`
   or non-finite (can happen mid-download for a live/partial file), leave
   `duration = nil` and rely on `AVPlayerItem.duration` updating later via
   KVO — add an observer for `item.duration` that fills in `duration` once
   it becomes a finite value. If the load throws, set
   `state = .failed(.assetLoadFailed)` and return.
6. Determine resume position: if `episode.playbackCompleted == false` and
   `episode.playbackPosition > 0` (and less than duration, with a small
   epsilon), seek to `episode.playbackPosition` before starting playback
   (zero tolerance, per §1.5). If `playbackCompleted == true`, start from 0
   regardless of stored position.
7. Apply the persisted rate preference to the player (`player.rate` is only
   meaningfully set once playback starts — see §1.6 for the pause/resume
   rate quirk).
8. If `autoplay`, call `play()` (§1.4); else set `state = .paused`.
9. Trigger the auto-download-on-play hook (§6) regardless of autoplay,
   based on `episode.downloadState`.

If `load` is called again before a prior `load` finishes (fast double-tap
on episode list), the new call MUST supersede the old one: guard with a
monotonically increasing "load generation" token captured at the start of
`load`, and check it after every `await` point before mutating state; if
stale, return early without touching `state`/`currentTime`/etc.

### 1.4 `play()` / `pause()` / `togglePlayPause()`

```swift
func play() {
    guard state != .loading else { return }  // no-op while an item is still resolving
    audioSession.activate()  // idempotent; see §2
    applyPersistedRateOnPlay()  // §1.6
    playerWrapper?.play()
    state = .playing
    nowPlayingInfo.update(from: self)
    positionStore.startPeriodicSave(engine: self)
}

func pause() {
    playerWrapper?.pause()
    state = .paused
    nowPlayingInfo.update(from: self)
    positionStore.saveNow(engine: self)  // immediate persist, not just periodic (§4.1)
}

func togglePlayPause() {
    switch state {
    case .playing: pause()
    case .paused, .idle: play()
    default: break  // no-op during .loading / .failed
    }
}
```

`play()`/`pause()` are synchronous per the protocol (architecture §5.1) —
they issue the command and update local state immediately; they do not
await AVPlayer's actual `timeControlStatus` transition. UI reflects
`state` optimistically, which matches how MPRemoteCommandCenter commands
must respond (synchronously, returning `.success`).

### 1.5 `seek(to:)` and `skip(by:)`

```swift
func seek(to time: TimeInterval) async {
    let clamped = max(0, min(time, duration ?? time))
    let cmTime = CMTime(seconds: clamped, preferredTimescale: 600)
    await playerWrapper?.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
    currentTime = clamped
}

func skip(by seconds: TimeInterval) async {
    let target = currentTime + seconds
    await seek(to: target)
}
```

- Zero tolerance is REQUIRED (not merely preferred) because transcript
  tap-to-seek (M4) must land within ~1s of the spoken line per product
  overview §"Product principles" #4 ("Honest timestamps"); default AVPlayer
  tolerance can silently snap to the nearest keyframe, which for typical
  podcast AAC/MP3 encodes can be several seconds off.
- `seek(to:)` is `async` and its awaiter resumes only once AVPlayer's
  completion handler fires (`true` = landed, `false` = superseded by a
  newer seek) — bridge the completion-handler API with
  `withCheckedContinuation`. If a second `seek` arrives before the first's
  completion handler fires, that is fine: AVPlayer cancels the earlier one
  and calls its handler with `finished: false`; do not treat `false` as an
  error, just resume the (now-stale) continuation so it doesn't leak.
- After seeking, immediately persist position (§4.1) if the player is
  paused (so a seek-then-background doesn't lose the new position before
  the next periodic tick).
- `skip(by:)` values used by the UI are **+30s / −15s** per Apple Podcasts
  convention and product overview UX; the protocol itself is
  direction-agnostic (positive seconds = forward, negative = backward), so
  the UI passes `-15` for rewind.

### 1.6 Rate handling

- `PlaybackRatePreference` (a small `@Observable` or plain class wrapping
  `UserDefaults.standard`) persists the user's chosen rate under key
  `"playbackRate"` (Float, default `1.0`), independent of any specific
  episode — the rate preference is global, matching Apple Podcasts
  behavior and avoiding surprise speed changes per episode.
- Setting `PlayerEngine.rate = x` MUST clamp `x` to `0.5...2.0`, write it to
  `PlaybackRatePreference`, and apply it live:
  - If `state == .playing`: set `playerWrapper.rate = x` directly (setting
    `.rate` on a playing `AVPlayer` both changes speed and keeps it
    playing).
  - If not playing: only persist the preference; do NOT set
    `playerWrapper.rate` while paused/idle, because **setting a non-zero
    rate on an `AVPlayer` that is not currently playing starts playback**
    (a well-known AVPlayer quirk). Apply the stored rate at the moment
    `play()` is next called instead (`applyPersistedRateOnPlay()` in §1.4
    sets `playerWrapper.rate = ratePreference.currentRate` right before/at
    the same time as calling `.play()`).
  - This is the "pause/play must restore rate" requirement from the task
    brief: because pausing an `AVPlayer` does not reset its `.rate`
    property by itself, but resuming via `.play()` on some AVFoundation
    versions can reset effective rate to 1.0 unless `.rate` is explicitly
    re-applied — always re-set `.rate` explicitly in `play()`, never rely
    on it having "stuck" from before pause.
- Update `MPNowPlayingInfoCenter`'s `MPNowPlayingInfoPropertyPlaybackRate`
  and `MPMediaItemPropertyPlaybackRate` whenever rate changes (§5).
- Allowed rate steps exposed in the UI are exactly:
  `[0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]` (§5.3), but the underlying
  protocol/property accepts any `Float` in `0.5...2.0` — the engine itself
  does not enforce the step list, only the UI menu does.

---

## 2. `AudioSessionManager`

```swift
// M2
import AVFoundation

@MainActor
final class AudioSessionManager {
    func activate() { /* category .playback, mode .spokenAudio, activate */ }
    func deactivate() { /* deactivate with .notifyOthersOnDeactivation, best-effort */ }
}
```

- Configure once (can be done at `activate()` time, idempotently — calling
  `setCategory` repeatedly with the same category is cheap and safe):
  `try session.setCategory(.playback, mode: .spokenAudio, options: [])`.
  `.playback` category is what enables background audio + lock-screen
  controls; `.spokenAudio` mode optimizes voice-processing/loudness for
  podcast content and is the documented mode for this content type.
- Call `try session.setActive(true)` in `activate()`, invoked from
  `PlayerEngine.play()` (§1.4) — not at app launch, to avoid holding the
  audio session before the user actually plays anything (matches App
  Store review guidance / good citizenship for background modes).
- **Interruptions** (phone call, Siri, alarm): register for
  `AVAudioSession.interruptionNotification`. On `.began`: call
  `PlayerEngine.pause()` (through a weak back-reference or a closure
  callback injected at construction — `AudioSessionManager` should not
  import `PlayerEngine` to avoid a circular dependency; instead expose
  `var onInterruptionBegan: (() -> Void)?` and `var onInterruptionEnded:
  ((_ shouldResume: Bool) -> Void)?`, set by `PlayerEngine` at init). On
  `.ended`, check `AVAudioSessionInterruptionOptions` for
  `.shouldResume`; if present, call the engine's `play()` again (this
  re-activates the session and re-applies rate per §1.6); if absent, stay
  paused and let the user resume manually.
- **Route changes** (headphones unplugged, AirPods disconnected, output
  device switch away from what was in use): register for
  `AVAudioSession.routeChangeNotification`. When
  `reason == .oldDeviceUnavailable` (the standard "unplugged" signal),
  call the engine's `pause()` via the same callback pattern. Do not act on
  other reasons (`.newDeviceAvailable`, `.categoryChange`, etc.) —
  auto-pause is specifically the "don't blast audio through the speaker
  when headphones come out" behavior users expect.
- `PlayerEngine` MUST wire `onInterruptionBegan`/`onInterruptionEnded`/
  route-change callback to its own `pause()`/`play()` at construction time,
  and MUST start observing notifications as soon as `AudioSessionManager`
  is constructed (not deferred to first playback) so an interruption that
  begins before any playback doesn't crash/misbehave — though in practice
  there's nothing to pause if nothing is playing; the callback should be a
  no-op if `state` isn't `.playing`.

---

## 3. Info.plist / background modes

This is normally M0's job (architecture §3, M0 owns Info.plist keys and
background modes), but M2 depends on it being correct, so verify — do not
silently re-add if already present, but flag in your PR/commit notes if
missing:
- `UIBackgroundModes` includes `audio`.
- If M0 has not already added it, add it and note the deviation from "M0
  owns this" in your commit message rather than silently expanding scope.

---

## 4. Playback position persistence

Owned by `PlaybackPositionStore`:

```swift
// M2
import Foundation
import SwiftData

@MainActor
final class PlaybackPositionStore {
    private var periodicTask: Task<Void, Never>?

    func startPeriodicSave(engine: PlayerEngine) { /* cancel existing, start a new 5s-interval Task loop */ }
    func stopPeriodicSave() { periodicTask?.cancel() }
    func saveNow(engine: PlayerEngine) { /* immediate synchronous-ish write */ }
}
```

### 4.1 When to write

- **Periodic**: while `state == .playing`, write `episode.playbackPosition
  = currentTime` every **5 seconds** via a `Task` loop
  (`Task { while !Task.isCancelled { try? await Task.sleep(for: .seconds(5));
  saveNow(engine:) } }`), started in `play()` and cancelled in `pause()`
  (§1.4 already calls `positionStore.startPeriodicSave`/implicitly stops
  via the pause path calling `saveNow` once — `pause()` MUST also call
  `positionStore.stopPeriodicSave()` before or after `saveNow`, since there's
  no more periodic saving to do while paused).
- **On pause**: immediate `saveNow` (already specified in §1.4).
- **On backgrounding**: `AppContainer`/root App struct (M0) observes
  `scenePhase` and, on transition to `.background`, MUST call
  `playerEngine.persistPositionForBackgrounding()` — add this method to
  `PlayerEngine` (non-protocol, app-internal) that just calls
  `positionStore.saveNow(engine: self)`. Document this as a required call
  site for M0's `App` struct; if M0 was implemented first without it,
  add the call when integrating M2 (cross-module wiring like this is
  expected to land in `App/LingoPodApp.swift`, which M2 may touch for this
  one line — do not restructure the rest of that file).
- **On seek** (paused only): see §1.5, already covered.
- **On episode switch / new `load()`**: outgoing episode's position is
  saved before detaching (§1.3 step 1).

### 4.2 What `saveNow` writes

```swift
func saveNow(engine: PlayerEngine) {
    guard let id = engine.currentEpisodeID,
          let episode = try? modelContext.model(for: id) as? Episode else { return }
    episode.playbackPosition = engine.currentTime
    if let duration = engine.duration, duration > 0,
       engine.currentTime / duration > 0.95 {
        episode.playbackCompleted = true
    }
    try? modelContext.save()
}
```

- The **95%** threshold is the "mark completed" rule from the task brief.
  Once `playbackCompleted` is true, do not un-set it here (only
  `AVPlayerItemDidPlayToEndTime`'s reset-to-zero path or a future explicit
  "mark unplayed" user action, out of scope for M2, changes it back).
- `modelContext.save()` failures are logged via `os.Logger` (subsystem
  `com.lingopod.app`, category `"Playback"`) and otherwise swallowed —
  losing one position tick is not worth crashing or surfacing an alert.

### 4.3 Resume-on-load

Already specified in §1.3 step 6: `load(episode:autoplay:)` seeks to the
stored `playbackPosition` (unless already `playbackCompleted`) before
playback begins, with **zero seek tolerance** for consistency with §1.5
(the resume point should be exact, not "close enough").

---

## 5. Now Playing integration

Owned by `NowPlayingInfoManager`:

```swift
// M2
import MediaPlayer

@MainActor
final class NowPlayingInfoManager {
    func update(from engine: PlayerEngine) { /* rebuild MPNowPlayingInfoCenter.default().nowPlayingInfo */ }
    func configureRemoteCommands(engine: PlayerEngine) { /* one-time command handler wiring */ }
}
```

### 5.1 `MPNowPlayingInfoCenter`

Call `update(from:)` whenever any of the following change: episode load
completes, `state` transitions, `rate` changes, `duration` becomes known,
and additionally on every periodic time-observer tick **at a throttled
rate** — do not rebuild the whole dictionary 4x/second; instead update
`MPNowPlayingInfoPropertyElapsedPlaybackTime` at a **coarser cadence
(~once per second)** by driving `NowPlayingInfoManager` from a separate 1s
`Task` loop (started alongside `startPeriodicSave`, or reusing the same
loop cadence family) rather than the 0.25s time observer, to avoid
needless `MPNowPlayingInfoCenter` churn — the system interpolates elapsed
time between updates using the playback rate, so 1 Hz is sufficient and is
Apple's documented guidance.

Populate:
- `MPMediaItemPropertyTitle` = episode title
- `MPMediaItemPropertyArtist` = podcast title
- `MPMediaItemPropertyPlaybackDuration` = `duration` (omit key if unknown yet)
- `MPNowPlayingInfoPropertyElapsedPlaybackTime` = `currentTime`
- `MPNowPlayingInfoPropertyPlaybackRate` = `state == .playing ? rate : 0`
- `MPMediaItemPropertyPlaybackRate` = `rate` (the "native" rate, separate from the above which reflects actual motion — set both per MediaPlayer convention)
- `MPMediaItemPropertyArtwork`: build an `MPMediaItemArtwork` asynchronously
  from `currentArtworkURL` (download via `URLSession`, decode to `UIImage`,
  cache in-memory keyed by URL so repeated updates don't re-fetch). Do not
  block `update(from:)` on the network fetch — fire the fetch once per
  episode load, and merge the artwork into the dictionary when it arrives
  (re-set `nowPlayingInfo` at that point).

### 5.2 `MPRemoteCommandCenter`

Configure once (idempotent — guard against double-registration, e.g. with a
`private var isConfigured = false` flag), from `AppContainer`/`PlayerEngine`
init:

| Command | Handler |
|---|---|
| `playCommand` | `engine.play(); return .success` |
| `pauseCommand` | `engine.pause(); return .success` |
| `togglePlayPauseCommand` | `engine.togglePlayPause(); return .success` |
| `skipForwardCommand` (preferredIntervals = `[30]`) | `Task { await engine.skip(by: 30) }; return .success` |
| `skipBackwardCommand` (preferredIntervals = `[15]`) | `Task { await engine.skip(by: -15) }; return .success` |
| `changePlaybackPositionCommand` | cast event to `MPChangePlaybackPositionCommandEvent`, `Task { await engine.seek(to: event.positionTime) }; return .success` |
| `changePlaybackRateCommand` (`supportedPlaybackRates` = the 7 steps from §1.6 as `NSNumber`) | cast to `MPChangePlaybackRateCommandEvent`, `engine.rate = event.playbackRate; return .success` |

Disable (`isEnabled = false`) commands that don't apply, e.g.
`nextTrackCommand`/`previousTrackCommand` — there is no queue/playlist
concept in v1 (product overview explicitly scopes out anything beyond
single-episode playback), so leave those commands disabled/unregistered
rather than wiring them to a no-op.

This is also how **CarPlay and AirPods remote controls** are supported
(task item #7's requirement) — per architecture, all remote-surface
interaction goes exclusively through this command center; M2 does not add
any CarPlay-specific scene/template code (out of scope — v1 has no CarPlay
app extension, only the implicit Now Playing template every app gets for
free from `MPRemoteCommandCenter` + `MPNowPlayingInfoCenter`).

---

## 6. Auto-download-on-play hook

Per architecture §6.1: on-device transcription requires the audio to be
downloaded first, and "auto-download-on-play is M1 behavior" — M2's job is
only to **trigger** it, not implement download logic.

In `load(episode:autoplay:)` step 9: if `episode.downloadState` is `.none`
or `.failed`, call:

```swift
Task.detached { [catalogService] in
    try? await catalogService.download(episodeID: episodeID)
}
```

- Fire-and-forget from `PlayerEngine`'s perspective — do not await it in
  `load`, do not block playback on it (playback proceeds by streaming
  `episode.audioURL` regardless, per §1.3 step 3's local-else-stream
  fallback). This satisfies product principle "Never block playback."
- Do not re-trigger if `downloadState == .inProgress` already (M1 owns
  dedup/coalescing of concurrent download requests, but avoid an obviously
  redundant call from the same `load()`).
- **UI hint**: `PlayerView` (§ below) shows a small caption under the
  transcript button when `isCurrentEpisodeDownloaded == false`, e.g.
  *"Downloading for transcript…"* — exact copy is a placeholder; use
  `Localizable.xcstrings` per architecture's SwiftUI-only/first-party
  convention if M0 has already established a localization pattern,
  otherwise a plain `Text` literal is acceptable for v1. This hint
  disappears once `episode.downloadState == .downloaded` (poll via
  `@Query`/`@Observable` on the `Episode` model from the view, or re-check
  `isCurrentEpisodeDownloaded` after a short delay — `PlayerEngine` does
  not need to actively watch `downloadState` itself; simplest correct
  approach is for `PlayerView` to hold its own `@Query` or fetch on the
  `Episode` and read `downloadState` directly rather than mirroring it
  through the engine).

---

## 7. Edge cases

### 7.1 Loading failures

- No local file and unreachable/invalid `audioURL`, or the asset fails to
  load (`asset.load(.duration)` throws, or item `.status == .failed`):
  `state = .failed(.assetLoadFailed)` or `.failed(.avPlayerError(message))`
  as appropriate (§1.1). `PlayerView`/`MiniPlayerView` render a failed
  state with a short message and, where sensible, a retry affordance that
  simply re-calls `load(episode:autoplay:)`.
- Per architecture §8, this is a genuine unexpected-error case (not a
  predictable availability enum) since AVPlayer failures aren't really
  "expected" the way e.g. missing Apple Intelligence is — still, render it
  as an inline state rather than a modal alert, consistent with the rest
  of the app's error UX, and log via `os.Logger`.

### 7.2 Stalls / buffering

- Observe `AVPlayerItem.playbackBufferEmpty` (KVO or `.publisher` in newer
  AVFoundation) → `isBuffering = true`; observe
  `playbackLikelyToKeepUp` (true) or `playbackBufferFull` → `isBuffering =
  false`. Also treat `player.timeControlStatus ==
  .waitingToPlayAtSpecifiedRate` while `state == .playing` as a buffering
  signal.
- `isBuffering` is a UI-only flag (not part of `PlaybackState` per the
  protocol's fixed enum in architecture §5.1) — `PlayerView` shows a small
  spinner overlay on the artwork when `isBuffering == true` while
  `state == .playing`. Do not transition `state` itself to anything
  buffering-related; the protocol has no such case, and downstream
  consumers (M3, M4) key off `state`/`currentTime` only.

### 7.3 Switching episodes mid-transcription

- Already covered mechanically in §1.3 step 1: `load()` posts
  `.playerEngineWillSwitchEpisode` before mutating engine state. Declare it as:

  ```swift
  extension Notification.Name {
      static let playerEngineWillSwitchEpisode = Notification.Name("com.lingopod.playerEngineWillSwitchEpisode")
  }
  ```

  in `LingoPod/App/Interfaces.swift`, with a doc comment: `userInfo["episodeID"]`
  is the outgoing episode's `PersistentIdentifier`. M3's
  `TranscriptProvider`/transcription actor is expected to observe this (via
  `NotificationCenter.default.notifications(named:)` async sequence or a
  block observer) and cancel any in-flight transcription `Task` for that
  episode ID — this is the seam the task brief asks M2 to define; M2 does
  not call into M3 directly (no reverse dependency), it only posts the
  notification. This keeps with architecture §7's cancellation rule
  ("switching episodes cancels the previous episode's transcription") while
  respecting the module boundary (M2 has no compile-time dependency on M3).

### 7.4 App termination persistence

- Handled by the combination of: periodic 5s save while playing (§4.1),
  immediate save on pause (§1.4), and immediate save on backgrounding
  (§4.1's `scenePhase` hook). iOS gives backgrounded apps some execution
  time and a `.background` scenePhase transition fires reliably before
  suspension/termination in the vast majority of cases (force-quit from
  the app switcher is the one case nothing can intercept — accepted data
  loss window is "up to 5 seconds of playback," which is fine for a
  resume-position feature).
- No `applicationWillTerminate`-based last-ditch save is required beyond
  the above; `UIApplication` termination hooks are unreliable in modern iOS
  and the architecture doc does not ask for anything beyond best-effort.

### 7.5 Remote control surfaces

- CarPlay and AirPods (and lock screen, and Control Center) all route
  through `MPRemoteCommandCenter` exclusively (§5.2) — there is no
  separate code path to build or test differently per surface. Manual
  verification (§9) covers exercising this.

---

## 8. UI

### 8.1 `MiniPlayerView`

`LingoPod/UI/Player/MiniPlayerView.swift`. Docked persistently above the
tab bar (wired into the root navigation shell by M0; M2 supplies the view,
M0's root layout places it — if M0 hasn't already reserved this slot, add
the minimal necessary container wiring but do not redesign M0's navigation
shell).

- Reads `PlayerEngine` from the environment (`AppContainer`).
- Hidden entirely when `currentEpisodeID == nil` (nothing has ever been
  loaded this session) — do not show an empty mini player.
- Contents: small artwork thumbnail (from `currentArtworkURL`,
  `AsyncImage` or a shared cached-image helper if one already exists in
  M1's UI layer — reuse rather than duplicate if so), episode title
  (single line, truncated), a play/pause button bound to
  `engine.togglePlayPause()`, and a hairline progress bar
  (`currentTime / (duration ?? 1)`, clamped `0...1`) along the bottom edge.
- Tapping anywhere on the mini player except the play/pause button
  presents `PlayerView` full-screen (`.fullScreenCover` from the root, or a
  sheet with `.presentationDetents([.large])` — prefer `.fullScreenCover`
  to match the "Now Playing" full-screen convention from Apple Podcasts/
  Music, and because `PlayerView` itself further presents
  `TranscriptOverlayView` full-screen, avoiding sheet-over-sheet).
- The play/pause button itself does not trigger the full-screen
  presentation (tap target must not conflict — use `.buttonStyle(.plain)`
  plus `.contentShape` scoping, or a `Button` for play/pause nested inside
  an outer `.onTapGesture`/`Button` for navigation, being careful with
  SwiftUI hit-testing precedence: give the play/pause button explicit
  bounds and rely on SwiftUI's default "inner tappable view wins" behavior
  rather than fighting it).

### 8.2 `PlayerView`

`LingoPod/UI/Player/PlayerView.swift`. The full-screen Now Playing surface.

Layout (top to bottom, roughly):
1. Large artwork (`currentArtworkURL`), with the `isBuffering` spinner
   overlay (§7.2) when applicable.
2. Episode title + podcast title.
3. Scrubber: a `Slider` bound to `currentTime`, range `0...(duration ?? 1)`.
   **Seek-on-release pattern** (required to avoid fighting the 0.25s time
   observer, per task brief): the slider must not directly bind to
   `engine.currentTime` in a way that both reads and writes it live, or
   every observer tick will yank the thumb out from under an in-progress
   drag. Implement with local `@State`:

   ```swift
   @State private var isScrubbing = false
   @State private var scrubTime: TimeInterval = 0

   Slider(
       value: Binding(
           get: { isScrubbing ? scrubTime : engine.currentTime },
           set: { scrubTime = $0 }
       ),
       in: 0...(engine.duration ?? 1),
       onEditingChanged: { editing in
           isScrubbing = editing
           if !editing {
               Task { await engine.seek(to: scrubTime) }
           }
       }
   )
   ```

   While `isScrubbing == true`, the slider's displayed value is driven only
   by local drag state, immune to the engine's live `currentTime` updates;
   on release (`editing == false`), fire exactly one `seek(to:)` with the
   final dragged value. Show elapsed/remaining time labels next to the
   scrubber, computed from `scrubTime` while scrubbing and `currentTime`
   otherwise (so the numeric readout tracks the thumb during drag, not the
   real playhead).
4. Transport row: skip-back-15 button, play/pause (large), skip-forward-30
   button. Skip buttons call `Task { await engine.skip(by: -15) }` /
   `Task { await engine.skip(by: 30) }`; label with the numeral overlaid on
   a `gobackward`/`goforward`-style SF Symbol if available
   (`gobackward.15`, `goforward.30` are real SF Symbols — use them).
5. Rate control: a menu/button showing the current rate (e.g. "1.0x") that
   opens `PlaybackRateMenu` (§8.3).
6. **"Transcript" button**: prominent, presents the M4 overlay full-screen
   (§8.4).
7. Auto-download hint text (§6) shown conditionally under the transcript
   button.

### 8.3 `PlaybackRateMenu`

A `Menu` (or custom picker) listing exactly the seven steps from §1.6:
`0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0`, each formatted as `"0.5x"` etc.
Selecting one sets `engine.rate = step`. Highlight/check the currently
active step (compare `engine.rate` to each step with a small epsilon,
e.g. `abs(engine.rate - step) < 0.01`, since `Float` equality is unsafe).

### 8.4 Transcript overlay presentation seam (for M4)

`PlayerView` presents the overlay via:

```swift
.fullScreenCover(isPresented: $showTranscript) {
    TranscriptOverlayView(
        episode: currentEpisode,
        engine: engine,
        transcriptProvider: appContainer.transcriptProvider
    )
}
```

M2 MUST define a placeholder `TranscriptOverlayView` now (in
`LingoPod/UI/TranscriptOverlay/TranscriptOverlayView.swift` — that
directory is M4's per architecture §2, but the placeholder file must exist
there so M4 can replace it in place rather than M2 owning a stray file
elsewhere) with exactly this initializer shape, so M4 can implement against
it without touching `PlayerView`:

```swift
// M2 (placeholder — M4 replaces this file's contents; keep the initializer
// signature stable or update this doc + PlayerView's call site together)
import SwiftUI
import SwiftData

struct TranscriptOverlayView: View {
    let episode: Episode
    let engine: any PlayerEngineProtocol
    let transcriptProvider: any TranscriptProviderProtocol

    init(episode: Episode, engine: any PlayerEngineProtocol, transcriptProvider: any TranscriptProviderProtocol) {
        self.episode = episode
        self.engine = engine
        self.transcriptProvider = transcriptProvider
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text("Transcript overlay coming soon")
                    .font(.headline)
                Text(episode.title)
                    .foregroundStyle(.secondary)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { /* dismiss via presentationMode/dismiss env */ }
                }
            }
        }
    }
}
```

- `transcriptProvider` comes from `AppContainer.transcriptProvider`
  (`any TranscriptProviderProtocol`, M3's interface, architecture §5.2) —
  `AppContainer` must expose this property; if M3/AppContainer wiring
  doesn't exist yet at M2 implementation time, still write
  `TranscriptOverlayView`'s initializer to accept it (per architecture's
  "code against these exactly" rule) and use a throwaway/unused parameter
  in the placeholder body — do not simplify the signature to make the
  placeholder compile easier, since M4 depends on the signature being
  stable.
- `PlayerView` passes `engine` as `any PlayerEngineProtocol`, i.e. the same
  `PlayerEngine` instance from the environment, not a copy — this is how
  M4's overlay stays in sync with the same playhead (architecture:
  "`currentTime` at ~4 Hz is the single sync source for the overlay").
- Dismissal: the placeholder is a real, functioning close button (using
  `@Environment(\.dismiss)`); M4 must preserve some equivalent dismiss
  affordance in its final implementation, but the exact chrome is M4's call.

---

## 9. Testing

### 9.1 Unit-testable (in `LingoPodKit` or app-target test target with mocks)

To make this practical, `PlayerEngine` depends on `AVPlayerWrapping`, a
thin protocol wrapping only the surface it needs from `AVPlayer`:

```swift
// M2
import AVFoundation

@MainActor
protocol AVPlayerWrapping: AnyObject {
    var rate: Float { get set }
    var currentItem: AVPlayerItem? { get }
    func play()
    func pause()
    func seek(to time: CMTime, toleranceBefore: CMTime, toleranceAfter: CMTime) async -> Bool
    func addPeriodicTimeObserver(forInterval interval: CMTime, queue: DispatchQueue?, using: @escaping (CMTime) -> Void) -> Any
    func removeTimeObserver(_ observer: Any)
}
```

A production `AVPlayer` subclass or extension conforms trivially (`AVPlayer`
already has all these members with compatible signatures modulo the
completion-handler-vs-async `seek` — wrap that one method). A
`MockAVPlayerWrapping` test double drives `PlayerEngine` deterministically
without touching real media files or the simulator's audio hardware.

With that seam, unit-test (XCTest in the app-target test bundle, or a
logic-only slice pulled into `LingoPodKit` if it can be made fully
platform-agnostic — most of this cannot, since it's AVFoundation/SwiftData-
adjacent, so app-target `XCTest` is the expected home per architecture §9
"App-target services: constructor-injected dependencies so logic is
testable"):

- **State machine**: `.idle → .loading → .playing/.paused/.failed`
  transitions for `load`/`play`/`pause`/`togglePlayPause`, including the
  "load supersedes in-flight load" generation-token behavior (§1.3).
- **Rate persistence and the pause/resume-restores-rate quirk** (§1.6):
  set rate while paused → verify `playerWrapper.rate` is untouched but
  `PlaybackRatePreference` is updated; call `play()` → verify
  `playerWrapper.rate` is now set to the persisted value.
- **Position persistence math** (§4.2): given a fake `currentTime`/
  `duration`, verify `playbackCompleted` flips at the 95% boundary and not
  before; verify periodic-save start/stop is tied correctly to
  play/pause.
- **Seek clamping and completion bridging** (§1.5): seek values outside
  `0...duration` get clamped; a mock wrapper that calls its completion
  handler with `finished: false` doesn't hang or throw.
- **Auto-download trigger** (§6): given an episode with
  `downloadState == .none`, verify `catalogService.download(episodeID:)`
  is called exactly once from `load()`, and not called again for
  `.downloaded`/`.inProgress`.
- **Episode-switch notification** (§7.3): verify
  `.playerEngineWillSwitchEpisode` posts with the correct outgoing episode
  ID when `load()` is called a second time with a different episode.
- Use an in-memory `ModelContainer`/`ModelContext` (SwiftData supports this
  for tests) so position-persistence tests don't touch disk.

### 9.2 Manual verification script (framework-touching, per architecture §9)

Run on a real device (simulator can't exercise lock screen / CarPlay / real
interruptions reliably):

1. **Basic playback**: play a streamed episode, confirm audio, scrubber
   moves, elapsed/remaining time correct, pause/resume works.
2. **Downloaded playback**: download an episode, force airplane mode,
   confirm it plays from local file with no network.
3. **Background audio**: start playback, background the app (home
   button/swipe), confirm audio continues; lock the device, confirm audio
   continues.
4. **Lock screen controls**: with audio playing and device locked, confirm
   Now Playing shows correct title/artwork/artist, and that play/pause,
   skip ±15/30, and the scrub bar on the lock screen all work and stay in
   sync with the app when unlocked again.
5. **Control Center**: same checks as #4 via Control Center's audio card.
6. **Interruption — phone call**: while playing, receive (or simulate via
   another device) an incoming call; confirm playback pauses; end the
   call; confirm playback auto-resumes (per `.shouldResume`).
7. **Interruption — timer/alarm**: same as #6 using the Clock app's timer
   ringing.
8. **Route change — unplug**: play via wired/Bluetooth headphones,
   disconnect them; confirm playback pauses and does not start blasting
   from the speaker.
9. **AirPods remote**: play via AirPods, use the stem/force-sensor
   play-pause gesture; confirm it toggles correctly.
10. **CarPlay**: connect to CarPlay (real hardware or CarPlay Simulator via
    Xcode), confirm Now Playing template shows correct info and transport
    controls work.
11. **Speed persistence**: set rate to 1.5x, force-quit the app, relaunch,
    play the same or a different episode, confirm rate is still 1.5x.
12. **Resume position**: play partway through an episode, background/quit,
    relaunch, re-open the episode, confirm it resumes near the last
    position (allow a few seconds of drift given the 5s save interval).
13. **Completion marking**: play an episode to the end (or seek to >95%
    and let it finish), confirm `playbackCompleted` behavior — re-opening
    the episode starts from 0, not from the near-end position.
14. **Stall/buffering**: on a throttled network (Network Link Conditioner
    or similar), start a stream and confirm the buffering indicator
    appears and clears appropriately.
15. **Episode switch mid-download-triggered-transcription**: start playing
    a non-downloaded episode (triggers auto-download), quickly switch to a
    different episode before the first finishes downloading/transcribing;
    confirm no crash and (once M3 exists) that the notification-based
    cancellation seam fires — this step is only fully checkable after M3
    lands, but the notification-posting half is independently verifiable
    now (e.g. temporary log statement / test observer).

---

## 10. Acceptance criteria

- [ ] `PlayerEngine` conforms to `PlayerEngineProtocol` exactly as declared
      in architecture §5.1, with no signature deviations.
- [ ] `PlaybackState` and `PlaybackError` types exist, `Equatable`, and
      `.failed` carries a concrete `Sendable` error.
- [ ] `load(episode:autoplay:)` prefers `localAudioPath` over `audioURL`,
      resolves the resume position, applies persisted rate, and triggers
      auto-download for non-downloaded episodes.
- [ ] Periodic time observer runs at 0.25s and drives `currentTime`.
- [ ] `duration` is populated via async `asset.load(.duration)` and
      corrected later via KVO if unknown at load time.
- [ ] `seek(to:)` uses zero tolerance on both sides and is awaitable,
      resuming only when the underlying AVPlayer seek completes (including
      the superseded/`finished: false` case not hanging).
- [ ] `rate` is clamped to `0.5...2.0`, persists across launches via
      `UserDefaults`, and is correctly re-applied on `play()` after a
      `pause()` (does not silently reset to 1.0).
- [ ] `AVAudioSession` is `.playback` / `.spokenAudio`, activated on
      `play()`, and interruption/route-change handling pauses (and
      resumes on `.shouldResume`) via callback wiring, not a hard
      dependency from `AudioSessionManager` back onto `PlayerEngine`.
- [ ] `Episode.playbackPosition` is written every ~5s while playing, and
      immediately on pause, seek (while paused), episode switch, and app
      backgrounding.
- [ ] `Episode.playbackCompleted` is set at >95% progress and reset to a
      from-zero state on natural end-of-item.
- [ ] `MPNowPlayingInfoCenter` reflects title/podcast/artwork/duration/
      elapsed/rate, throttled to ~1 Hz for elapsed-time updates.
- [ ] `MPRemoteCommandCenter` wires play/pause/toggle, skip +30/-15,
      `changePlaybackPositionCommand`, and `changePlaybackRateCommand`;
      unused commands (next/previous track) are disabled.
- [ ] `MiniPlayerView` is docked above the tab bar, hidden when nothing has
      been loaded, and taps (excluding the play/pause button) present
      `PlayerView` full-screen.
- [ ] `PlayerView`'s scrubber uses the seek-on-release local-state pattern
      and does not visibly fight the live time observer during a drag.
- [ ] `PlaybackRateMenu` exposes exactly the seven documented steps.
- [ ] `TranscriptOverlayView` placeholder exists at
      `LingoPod/UI/TranscriptOverlay/TranscriptOverlayView.swift` with the
      exact `episode`/`engine`/`transcriptProvider` initializer, and
      `PlayerView`'s "Transcript" button presents it via `fullScreenCover`.
- [ ] `.playerEngineWillSwitchEpisode` notification is declared and posted
      on every episode switch, carrying the outgoing episode's
      `PersistentIdentifier`.
- [ ] `AVPlayerWrapping` protocol exists and `PlayerEngine` is
      constructor-injectable with a mock for unit tests; the unit tests in
      §9.1 exist and pass.
- [ ] Buffering/stall states surface as a UI-only `isBuffering` flag, never
      mutate `PlaybackState` outside the four+failed protocol cases.
- [ ] Manual verification script (§9.2) has been run at least once on a
      physical device and any failures noted/fixed.
