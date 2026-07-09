// M4
// Root state machine for the transcript overlay (docs/specs/M4-overlay-ui.md
// §10): selection model, sync/scroll orchestration, translation + explain
// request plumbing, and transcript-lifecycle-failure retry actions. Kept as
// one `@MainActor @Observable` class per the spec's file manifest
// (`TranscriptOverlayViewModel.swift`); `TranscriptOverlayView` and its
// child views read/drive it, never `engine`/`transcriptHandle` internals
// directly for anything beyond simple property reads.
import Foundation
import SwiftData
import SwiftUI
import LingoPodKit
import UIKit
import os

// MARK: - Mode / selection model (§10)

enum OverlayMode: Equatable {
    case syncing
    case userScrolling
    case selecting
    case popoverOpen
    case sheetOpen
}

/// §10.2. A single word tap is represented the same way with `anchor == extent`.
struct TranscriptSelection: Equatable {
    var anchor: WordTokenID
    var extent: WordTokenID
}

enum TranslationRequestKey: Equatable {
    case token(WordTokenID)
    case selection
}

enum TranslationLookupState: Equatable {
    case idle
    case loading
    case loaded(String)
    case failed(message: String, actionLabel: String?, action: TranslationFailureAction)
}

enum TranslationFailureAction: Equatable {
    case downloadLanguage
    case none
}

/// `.sheet(item:)` payload — a fresh identity per explain request so
/// re-requesting (e.g. "Explain more" while already reading a different
/// explanation) reliably restarts the sheet's `.task`.
struct ExplainRequest: Identifiable, Equatable {
    let id = UUID()
    let passage: String
    let context: String
}

enum TranscriptFailureUIAction: Equatable {
    case retry
    case downloadLanguage
    case downloadEpisode
}

struct TranscriptFailureCopy {
    let message: String
    let buttonTitle: String
    let action: TranscriptFailureUIAction
}

@MainActor
@Observable
final class TranscriptOverlayViewModel {

    // MARK: Injected dependencies

    let episode: Episode
    let episodeID: PersistentIdentifier
    private let transcriptProvider: any TranscriptProviderProtocol
    private let translationService: any TranslationServiceProtocol
    private let translationDownloadPreparing: (any TranslationDownloadPreparing)?
    let explainService: any ExplainServiceProtocol
    private let catalogService: any CatalogServiceProtocol

    private let logger = Logger(subsystem: "com.lingopod.app", category: "Overlay")

    // MARK: Transcript state

    private(set) var transcriptHandle: TranscriptHandle?
    private(set) var initialLoadFailed = false
    private(set) var isRetryingTranscript = false

    // MARK: Sync

    let syncDriver = TranscriptSyncDriver()
    private(set) var startTimes: [TimeInterval] = []
    /// `ScrollViewReader`'s proxy, captured once by the root view so the
    /// view model can drive programmatic scrolling itself (§4.3, §4.4).
    var scrollProxy: ScrollViewProxy?

    // MARK: Mode / interruption tracking

    private(set) var mode: OverlayMode = .syncing
    /// Only ever `.syncing` or `.userScrolling` (§10.3's closing note): set
    /// when leaving one of those two into `.selecting`/`.popoverOpen`/
    /// `.sheetOpen`, consumed on the way back out.
    private var modeBeforeInterruption: OverlayMode = .syncing
    /// Set while `.selecting`/`.popoverOpen`/`.sheetOpen` is up and
    /// `currentIndex` moves underneath it; consumed to snap-scroll (no
    /// spring) once that state ends (§4.4).
    private var driftedWhileInterrupted = false

    private var idleTimerTask: Task<Void, Never>?
    private var lastKnownSegments: [TranscriptSegmentSnapshot] = []
    private var lastKnownReduceMotion = false

    // MARK: Selection

    private(set) var selection: TranscriptSelection?
    /// Frames of every currently-laid-out token, in the `"transcriptScroll"`
    /// named coordinate space (§6.2). Updated by the root view's
    /// `.onPreferenceChange(WordTokenFramesPreferenceKey.self)`.
    var tokenFrames: [WordTokenID: CGRect] = [:]
    private var selectionCapHapticFired = false

    // MARK: Token / segment caches (§6.1, §11: never recomputed per-tick)

    private(set) var tokensBySegmentIndex: [Int: [WordToken]] = [:]
    private var segmentsByIndex: [Int: TranscriptSegmentSnapshot] = [:]
    private var flattenedTokenIDs: [WordTokenID] = []
    private var lastCachedSegmentCount = -1

    // MARK: Translation popover

    private(set) var translationLookup: TranslationLookupState = .idle
    private var inFlightTranslationKey: TranslationRequestKey?
    private var lastTranslationRequest: (text: String, key: TranslationRequestKey)?
    /// The token a single-word popover is anchored to; `nil` when the
    /// popover instead reflects a multi-word selection (anchored to the
    /// action bar). Read by the root view to decide which token's
    /// `.popover` binding to flip.
    var popoverTokenID: WordTokenID? {
        guard mode == .popoverOpen, let selection, selection.anchor == selection.extent else { return nil }
        return selection.anchor
    }

    // MARK: Explain

    private(set) var explainRequest: ExplainRequest?
    private var didPrewarmExplain = false

    // MARK: Init

    init(
        episode: Episode,
        transcriptProvider: any TranscriptProviderProtocol,
        translationService: any TranslationServiceProtocol,
        translationDownloadPreparing: (any TranslationDownloadPreparing)?,
        explainService: any ExplainServiceProtocol,
        catalogService: any CatalogServiceProtocol
    ) {
        self.episode = episode
        self.episodeID = episode.persistentModelID
        self.transcriptProvider = transcriptProvider
        self.translationService = translationService
        self.translationDownloadPreparing = translationDownloadPreparing
        self.explainService = explainService
        self.catalogService = catalogService
    }

    // MARK: - Language resolution (architecture §11.3)

    /// Order: `TranscriptHandle.languageCode` first (treating M3's "und"
    /// not-yet-resolved placeholder as absent), else
    /// `Podcast.languageOverride ?? Podcast.languageCode`. M4 has direct
    /// access to `episode.podcast` (unlike the spec's own §2 ASSUMPTION,
    /// written before the initializer's `episode: Episode` parameter was
    /// pinned by M2's placeholder), so the Podcast fallback is reachable.
    func resolvedSourceLanguage() -> Locale.Language {
        if let handle = transcriptHandle,
           handle.languageCode != "und",
           let language = LocaleResolver.normalizeBCP47(handle.languageCode) {
            return language
        }
        if let podcast = episode.podcast,
           let language = LocaleResolver.normalizeBCP47(podcast.languageOverride ?? podcast.languageCode) {
            return language
        }
        return Locale.Language(identifier: "und")
    }

    /// Architecture §11.3: the learner's native language, `Locale.current.language`.
    var targetLanguage: Locale.Language {
        Locale.current.language
    }

    /// Architecture §11.3: hide the translate affordance when source and
    /// target resolve to the same language.
    var shouldShowTranslateAffordance: Bool {
        resolvedSourceLanguage().languageCode?.identifier != targetLanguage.languageCode?.identifier
    }

    // MARK: - Load

    func start() async {
        do {
            let handle = try await transcriptProvider.transcript(for: episodeID)
            transcriptHandle = handle
            initialLoadFailed = false
            refreshCaches(segments: handle.segments)
            prewarmExplainIfNeeded()
        } catch {
            logger.error("transcript(for:) failed: \(String(describing: error), privacy: .public)")
            initialLoadFailed = true
        }
    }

    func retryInitialLoad() async {
        await start()
    }

    private func prewarmExplainIfNeeded() {
        guard !didPrewarmExplain else { return }
        let source = resolvedSourceLanguage()
        guard source.languageCode?.identifier != "und" else { return }
        didPrewarmExplain = true
        (explainService as? ExplainService)?.prewarm(sourceLanguage: source, targetLanguage: targetLanguage)
    }

    /// Called whenever `transcriptHandle?.segments.count` or `.languageCode`
    /// changes (the root view drives this via `.onChange`). Cheap: only
    /// tokenizes segments not already cached (§6.1, §11).
    func refreshCaches(segments: [TranscriptSegmentSnapshot]) {
        lastKnownSegments = segments
        guard segments.count != lastCachedSegmentCount else {
            prewarmExplainIfNeeded()
            return
        }
        lastCachedSegmentCount = segments.count
        startTimes = segments.map(\.startTime)

        let language = resolvedSourceLanguage()
        for segment in segments where tokensBySegmentIndex[segment.index] == nil {
            tokensBySegmentIndex[segment.index] = WordTokenizer.tokenize(segment.text, language: language)
        }
        segmentsByIndex = Dictionary(uniqueKeysWithValues: segments.map { ($0.index, $0) })
        flattenedTokenIDs = tokensBySegmentIndex.keys.sorted().flatMap { segIndex in
            (0..<(tokensBySegmentIndex[segIndex]?.count ?? 0)).map { WordTokenID(segmentIndex: segIndex, tokenIndex: $0) }
        }
        prewarmExplainIfNeeded()
    }

    func setReduceMotion(_ value: Bool) {
        lastKnownReduceMotion = value
    }

    // MARK: - Sync tick (§4.2)

    func syncTick(currentTime: TimeInterval) {
        syncDriver.update(time: currentTime, startTimes: startTimes)
    }

    /// Driven by `.onChange(of: syncDriver.currentIndex)` in the root view
    /// (§4.3: "driven by currentIndex changes, not by currentTime").
    func currentIndexChanged(segments: [TranscriptSegmentSnapshot], reduceMotion: Bool) {
        lastKnownSegments = segments
        lastKnownReduceMotion = reduceMotion
        guard let index = syncDriver.currentIndex, segments.indices.contains(index) else { return }
        switch mode {
        case .syncing:
            performScroll(to: segments[index].id, style: autoScrollStyle(reduceMotion: reduceMotion))
        case .selecting, .popoverOpen, .sheetOpen:
            driftedWhileInterrupted = true
        case .userScrolling:
            break
        }
    }

    // MARK: - Scroll (§4.3, §4.4)

    private enum ScrollStyle { case spring, shortEase, instant }

    private func autoScrollStyle(reduceMotion: Bool) -> ScrollStyle {
        reduceMotion ? .shortEase : .spring
    }

    private func performScroll(to id: PersistentIdentifier, style: ScrollStyle) {
        guard let scrollProxy else { return }
        switch style {
        case .spring:
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                scrollProxy.scrollTo(id, anchor: .center)
            }
        case .shortEase:
            withAnimation(.easeInOut(duration: 0.2)) {
                scrollProxy.scrollTo(id, anchor: .center)
            }
        case .instant:
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                scrollProxy.scrollTo(id, anchor: .center)
            }
        }
    }

    // VERIFY(iOS26): assumes `View.onScrollPhaseChange { old, new in }` is
    // available on `ScrollView` with a `ScrollPhase` enum carrying
    // `.interacting`/`.decelerating`/`.idle` cases, per spec §4.4. Kept
    // isolated to this method and the root view's call site.
    func scrollPhaseChanged(old: ScrollPhase, new: ScrollPhase) {
        if new == .interacting {
            cancelIdleTimer()
            if mode == .syncing {
                mode = .userScrolling
            }
            // Any other mode ignores scroll-phase changes defensively
            // (§10.3's closing note) — the popover/sheet/selection surface
            // captures gestures enough in practice that this is mostly moot.
        } else if (old == .interacting || old == .decelerating), new == .idle {
            guard mode == .userScrolling else { return }
            startIdleTimer()
        }
    }

    private func startIdleTimer() {
        idleTimerTask?.cancel()
        idleTimerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.resumeSyncAfterIdle()
        }
    }

    private func cancelIdleTimer() {
        idleTimerTask?.cancel()
        idleTimerTask = nil
    }

    private func resumeSyncAfterIdle() {
        guard mode == .userScrolling else { return }
        mode = .syncing
        if let index = syncDriver.currentIndex, lastKnownSegments.indices.contains(index) {
            performScroll(to: lastKnownSegments[index].id, style: autoScrollStyle(reduceMotion: lastKnownReduceMotion))
        }
    }

    /// `ResumeSyncPill` tap (§3.2): immediate transition, cancels the idle timer.
    func resumeSyncNow() {
        cancelIdleTimer()
        mode = .syncing
        if let index = syncDriver.currentIndex, lastKnownSegments.indices.contains(index) {
            performScroll(to: lastKnownSegments[index].id, style: autoScrollStyle(reduceMotion: lastKnownReduceMotion))
        }
    }

    /// Shared exit path for `.selecting`/`.popoverOpen`/`.sheetOpen` back to
    /// `modeBeforeInterruption` (§7.1, §7.2, §8, §10.3). Every table row
    /// that returns to `modeBeforeInterruption` funnels through here.
    private func returnFromInterruption() {
        mode = modeBeforeInterruption
        selection = nil
        translationLookup = .idle
        inFlightTranslationKey = nil
        if driftedWhileInterrupted {
            driftedWhileInterrupted = false
            if let index = syncDriver.currentIndex, lastKnownSegments.indices.contains(index) {
                performScroll(to: lastKnownSegments[index].id, style: .instant)
            }
        }
    }

    // MARK: - Interaction 1: tap segment -> seek (§5)

    func tapSegment(_ segment: TranscriptSegmentSnapshot, engine: any PlayerEngineProtocol) {
        hapticImpact(.light)
        syncDriver.forceIndex(segment.index)
        Task { await engine.seek(to: segment.startTime) }

        if mode == .userScrolling {
            cancelIdleTimer()
            mode = .syncing
        }
        if mode == .syncing {
            performScroll(to: segment.id, style: autoScrollStyle(reduceMotion: lastKnownReduceMotion))
        }
    }

    /// VoiceOver's "Translate line" custom action (§12): treats the whole
    /// line as a single-token-equivalent selection anchored to its first
    /// token, opening the popover the same way a word tap would.
    func translateLine(_ segment: TranscriptSegmentSnapshot) {
        guard let tokens = tokensBySegmentIndex[segment.index], !tokens.isEmpty else { return }
        let first = WordTokenID(segmentIndex: segment.index, tokenIndex: 0)
        let last = WordTokenID(segmentIndex: segment.index, tokenIndex: tokens.count - 1)
        if mode == .syncing || mode == .userScrolling {
            modeBeforeInterruption = mode
        }
        selection = TranscriptSelection(anchor: first, extent: last)
        mode = .popoverOpen
        beginTranslation(for: segment.text, requestKey: .selection)
    }

    // MARK: - Interaction 2: word tap & phrase selection -> translation (§7)

    func tapToken(_ id: WordTokenID, token: WordToken) {
        guard mode == .syncing || mode == .userScrolling else { return }
        modeBeforeInterruption = mode
        selection = TranscriptSelection(anchor: id, extent: id)
        mode = .popoverOpen
        beginTranslation(for: token.text, requestKey: .token(id))
    }

    func longPressBegan(on id: WordTokenID) {
        guard mode == .syncing || mode == .userScrolling else { return }
        hapticImpact(.medium)
        modeBeforeInterruption = mode
        selection = TranscriptSelection(anchor: id, extent: id)
        mode = .selecting
        selectionCapHapticFired = false
    }

    func dragUpdated(to point: CGPoint) {
        guard mode == .selecting, let current = selection else { return }
        guard let nearest = nearestToken(to: point) else { return }
        guard nearest != current.extent else { return }

        let candidate = TranscriptSelection(anchor: current.anchor, extent: nearest)
        if selectionText(candidate).utf16.count > 280 {
            if !selectionCapHapticFired {
                hapticWarning()
                selectionCapHapticFired = true
            }
            let clamped = clampExtent(anchor: current.anchor, towards: nearest)
            if clamped != current.extent {
                selection = TranscriptSelection(anchor: current.anchor, extent: clamped)
            }
            return
        }
        selection = candidate
    }

    func dragEnded() {
        // Mode stays `.selecting` — this is the "committed" sub-state where
        // `SelectionActionBar` shows (§7.2). Nothing else to do here.
    }

    func tapElsewhereInTranscript() {
        guard mode == .selecting else { return }
        returnFromInterruption()
    }

    func requestTranslateSelection() {
        guard let selection else { return }
        mode = .popoverOpen
        beginTranslation(for: selectionText(selection), requestKey: .selection)
    }

    func requestExplainFromSelection() {
        guard let selection else { return }
        let text = selectionText(selection)
        let range = orderedSegmentRange(selection)
        let context = buildExplainContext(segmentRange: range)
        mode = .sheetOpen
        explainRequest = ExplainRequest(passage: text, context: context)
    }

    func dismissPopover() {
        guard mode == .popoverOpen else { return }
        returnFromInterruption()
    }

    func dismissExplainSheet() {
        explainRequest = nil
        guard mode == .sheetOpen else { return }
        returnFromInterruption()
    }

    // MARK: - Translation lookup (§7.1)

    private func beginTranslation(for text: String, requestKey: TranslationRequestKey) {
        lastTranslationRequest = (text, requestKey)
        guard inFlightTranslationKey != requestKey else { return }
        inFlightTranslationKey = requestKey
        translationLookup = .loading

        let source = resolvedSourceLanguage()
        let target = targetLanguage
        Task { [weak self] in
            guard let self else { return }
            do {
                let translated = try await self.translationService.translate(text, from: source, to: target)
                guard self.inFlightTranslationKey == requestKey else { return }
                self.translationLookup = .loaded(translated)
                self.inFlightTranslationKey = nil
            } catch {
                guard self.inFlightTranslationKey == requestKey else { return }
                self.translationLookup = self.translationFailureState(for: error)
                self.inFlightTranslationKey = nil
            }
        }
    }

    private func translationFailureState(for error: Error) -> TranslationLookupState {
        guard let translationError = error as? TranslationError else {
            return .failed(message: "Couldn't translate. Try again.", actionLabel: nil, action: .none)
        }
        switch translationError {
        case .sameLanguage, .sessionUnavailable, .cancelled:
            return .failed(message: "Couldn't translate. Try again.", actionLabel: nil, action: .none)
        case .unsupportedLanguagePair:
            return .failed(message: "Translation isn't available for this language pair.", actionLabel: nil, action: .none)
        case .languagePackNeedsDownload:
            return .failed(message: "This language needs to be downloaded before translating.", actionLabel: "Download language", action: .downloadLanguage)
        case .downloadRequiresNetwork:
            return .failed(message: "Connect to the internet to download this language.", actionLabel: nil, action: .none)
        }
    }

    func downloadLanguagePackAndRetryTranslation() async {
        guard let translationDownloadPreparing else { return }
        translationLookup = .loading
        do {
            try await translationDownloadPreparing.prepare(from: resolvedSourceLanguage(), to: targetLanguage)
            if let last = lastTranslationRequest {
                inFlightTranslationKey = nil
                beginTranslation(for: last.text, requestKey: last.key)
            }
        } catch {
            translationLookup = translationFailureState(for: error)
        }
    }

    /// "Explain more" from the translation popover (§7.1): promotes the
    /// popover's current word/selection to the explain sheet with the same
    /// passage.
    func explainMoreFromPopover() {
        requestExplainFromSelection()
    }

    // MARK: - Selection derivation (§10.2)

    private func orderedPair(_ selection: TranscriptSelection) -> (WordTokenID, WordTokenID) {
        selection.anchor <= selection.extent ? (selection.anchor, selection.extent) : (selection.extent, selection.anchor)
    }

    func selectionText(_ selection: TranscriptSelection) -> String {
        let (lower, upper) = orderedPair(selection)
        guard lower.segmentIndex <= upper.segmentIndex else { return "" }
        var parts: [String] = []
        for segmentIndex in lower.segmentIndex...upper.segmentIndex {
            guard let tokens = tokensBySegmentIndex[segmentIndex], !tokens.isEmpty else { continue }
            let startToken = segmentIndex == lower.segmentIndex ? min(lower.tokenIndex, tokens.count - 1) : 0
            let endToken = segmentIndex == upper.segmentIndex ? min(upper.tokenIndex, tokens.count - 1) : tokens.count - 1
            guard startToken <= endToken else { continue }
            parts.append(tokens[startToken...endToken].map(\.text).joined(separator: " "))
        }
        return parts.joined(separator: " ")
    }

    private func orderedSegmentRange(_ selection: TranscriptSelection) -> ClosedRange<Int> {
        let (lower, upper) = orderedPair(selection)
        return lower.segmentIndex...upper.segmentIndex
    }

    /// Every token ID covered by the current selection, in document order —
    /// used by the root view to draw the in-progress-selection highlight
    /// (a coordinate-space overlay driven by `tokenFrames`, see
    /// `WordTokenFlowLayout.swift`'s doc comment on `WordTokenView` for why
    /// highlighting lives outside the `Equatable`-guarded row subtree).
    func selectedTokenIDs() -> [WordTokenID] {
        guard let selection else { return [] }
        let (lower, upper) = orderedPair(selection)
        guard lower.segmentIndex <= upper.segmentIndex else { return [] }
        var ids: [WordTokenID] = []
        for segmentIndex in lower.segmentIndex...upper.segmentIndex {
            guard let tokens = tokensBySegmentIndex[segmentIndex], !tokens.isEmpty else { continue }
            let startToken = segmentIndex == lower.segmentIndex ? min(lower.tokenIndex, tokens.count - 1) : 0
            let endToken = segmentIndex == upper.segmentIndex ? min(upper.tokenIndex, tokens.count - 1) : tokens.count - 1
            guard startToken <= endToken else { continue }
            for tokenIndex in startToken...endToken {
                ids.append(WordTokenID(segmentIndex: segmentIndex, tokenIndex: tokenIndex))
            }
        }
        return ids
    }

    /// §8's context rule: passage's segment(s) plus one segment of padding
    /// on each side, joined with a single space. M4 does not additionally
    /// truncate to ~600 characters here — `ExplainPrompting.trimContext`
    /// (LingoPodKit), which `ExplainService` already calls internally on
    /// every prompt it builds, performs exactly the "keep the passage
    /// intact, trim padding symmetrically" truncation the spec describes;
    /// duplicating that algorithm in the app target would be pure
    /// repetition for no behavioral difference (see M4 report's deviations).
    private func buildExplainContext(segmentRange: ClosedRange<Int>) -> String {
        let lower = max(0, segmentRange.lowerBound - 1)
        let upper = min((segmentsByIndex.keys.max() ?? segmentRange.upperBound), segmentRange.upperBound + 1)
        guard lower <= upper else { return "" }
        var parts: [String] = []
        for index in lower...upper {
            if let segment = segmentsByIndex[index] {
                parts.append(segment.text)
            }
        }
        return parts.joined(separator: " ")
    }

    // MARK: - Drag hit-testing (§6.2)

    /// Finds the token whose published frame contains `point`; if none
    /// contains it exactly (finger between/past tokens), clamps to the
    /// nearest known token by center distance rather than extending
    /// unboundedly into not-yet-laid-out rows (§6.2's documented caveat:
    /// only tokens whose row is currently laid out in the `LazyVStack`
    /// publish a frame at all).
    private func nearestToken(to point: CGPoint) -> WordTokenID? {
        guard !tokenFrames.isEmpty else { return nil }
        if let containing = tokenFrames.first(where: { $0.value.contains(point) }) {
            return containing.key
        }
        return tokenFrames.min(by: { distance(point, $0.value) < distance(point, $1.value) })?.key
    }

    private func distance(_ point: CGPoint, _ rect: CGRect) -> CGFloat {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        return hypot(point.x - center.x, point.y - center.y)
    }

    /// Walks the flattened, document-ordered token list one token at a time
    /// from `anchor` toward `candidate`, returning the furthest token that
    /// keeps the derived selection text at or under the 280-character cap
    /// (§7.2). Token counts on screen are small (a handful of visible
    /// rows), so this linear walk is cheap relative to a drag gesture's
    /// natural update rate.
    private func clampExtent(anchor: WordTokenID, towards candidate: WordTokenID) -> WordTokenID {
        guard let anchorPos = flattenedTokenIDs.firstIndex(of: anchor),
              let candidatePos = flattenedTokenIDs.firstIndex(of: candidate) else {
            return anchor
        }
        let step = candidatePos >= anchorPos ? 1 : -1
        var lastValid = anchor
        var pos = anchorPos
        while pos != candidatePos {
            let nextPos = pos + step
            guard flattenedTokenIDs.indices.contains(nextPos) else { break }
            let testSelection = TranscriptSelection(anchor: anchor, extent: flattenedTokenIDs[nextPos])
            if selectionText(testSelection).utf16.count > 280 { break }
            lastValid = flattenedTokenIDs[nextPos]
            pos = nextPos
        }
        return lastValid
    }

    // MARK: - Transcript lifecycle failure actions (§9, architecture §11.4)

    /// Exact match against `TranscriptFailureCode` (LingoPodKit) rather than
    /// the spec's own heuristic substring match — see M4 report's
    /// deviations for why: the spec's heuristic was explicitly hedged
    /// ("Gap: reason is a raw String, not a typed enum") pending a real
    /// code; `TranscriptFailureCode` now exists and `reason` is documented
    /// (architecture §11.4) to store its exact `rawValue`, so exact
    /// matching is strictly more correct.
    func failureCopy(for reason: String) -> TranscriptFailureCopy {
        guard let code = TranscriptFailureCode(rawValue: reason) else {
            return TranscriptFailureCopy(message: "Something went wrong preparing this transcript.", buttonTitle: "Retry", action: .retry)
        }
        switch code {
        case .noLanguageSpecified:
            return TranscriptFailureCopy(message: "This podcast doesn't specify a language, so it can't be transcribed automatically.", buttonTitle: "Retry", action: .retry)
        case .unsupportedLocale:
            return TranscriptFailureCopy(message: "This language isn't supported for on-device transcription yet.", buttonTitle: "Retry", action: .retry)
        case .assetDownloadFailed:
            return TranscriptFailureCopy(message: "Downloading the on-device language model failed.", buttonTitle: "Download language", action: .downloadLanguage)
        case .assetDownloadNoNetwork:
            return TranscriptFailureCopy(message: "Connect to the internet to download the on-device language model.", buttonTitle: "Download language", action: .downloadLanguage)
        case .audioFileUnreadable:
            return TranscriptFailureCopy(message: "The downloaded episode audio couldn't be read.", buttonTitle: "Download episode", action: .downloadEpisode)
        case .analyzerError:
            return TranscriptFailureCopy(message: "Transcription failed unexpectedly.", buttonTitle: "Retry", action: .retry)
        case .needsDownload:
            return TranscriptFailureCopy(message: "This episode needs to finish downloading before it can be transcribed.", buttonTitle: "Download episode", action: .downloadEpisode)
        case .feedFetchFailed:
            return TranscriptFailureCopy(message: "Couldn't fetch the transcript included with this podcast.", buttonTitle: "Retry", action: .retry)
        case .feedUnsupportedFormat:
            return TranscriptFailureCopy(message: "This podcast's transcript is in a format LingoPod doesn't support yet.", buttonTitle: "Retry", action: .retry)
        case .feedParseError:
            return TranscriptFailureCopy(message: "Couldn't read the transcript included with this podcast.", buttonTitle: "Retry", action: .retry)
        }
    }

    /// `.downloadEpisode`/`.downloadLanguage` both end by calling
    /// `invalidateAndRetranscribe` — a bare `catalogService.download(...)`
    /// only *enqueues* the download (architecture §11.11: "returns once the
    /// download is durably enqueued, not on completion") and would leave
    /// the transcript stuck in `.failed` with no automatic re-trigger.
    /// Chaining the retranscribe call is what actually completes the
    /// retry: `TranscriptProvider`'s on-device path internally waits for
    /// the download to finish (architecture §11.8) before transcribing.
    func executeFailureAction(_ action: TranscriptFailureUIAction) async {
        guard !isRetryingTranscript else { return }
        isRetryingTranscript = true
        defer { isRetryingTranscript = false }

        if action == .downloadEpisode {
            do {
                try await catalogService.download(episodeID: episodeID)
            } catch {
                logger.error("catalogService.download failed during transcript-failure retry: \(String(describing: error), privacy: .public)")
            }
        }

        do {
            let newHandle = try await transcriptProvider.invalidateAndRetranscribe(episodeID: episodeID)
            transcriptHandle = newHandle
            refreshCaches(segments: newHandle.segments)
        } catch {
            logger.error("invalidateAndRetranscribe failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Haptics

    private func hapticImpact(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }

    private func hapticWarning() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }
}
