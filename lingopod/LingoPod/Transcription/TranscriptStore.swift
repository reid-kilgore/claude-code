// M3
// `ModelActor` wrapping all SwiftData CRUD for `Transcript`/`TranscriptSegment`
// (docs/specs/M3-transcripts.md §6.8, §8 -- there called `TranscriptWriter`;
// kept that type name since it's referenced throughout the spec's pseudocode,
// but the file lives at `TranscriptStore.swift` per this integration's brief
// to avoid colliding with the concurrently-running M1 agent's files under
// `LingoPod/Services/`). Callers never receive live `@Model` objects across
// the actor boundary -- only `Sendable` snapshots (architecture §7).
import Foundation
import SwiftData
import LingoPodKit

enum TranscriptStoreError: Error, Sendable, Equatable {
    case episodeNotFound
    case transcriptNotFound
}

/// Everything `TranscriptProvider`'s decision tree (M3 spec §7.1) needs to
/// know about an already-persisted `Transcript`, read in one shot.
struct ExistingTranscriptInfo: Sendable {
    var transcriptID: PersistentIdentifier
    var source: TranscriptSource
    var languageCode: String
    var state: TranscriptState
    /// Ordered by `index`. Empty for a transcript with no committed batches
    /// yet.
    var segments: [TranscriptSegmentSnapshot]
}

/// Everything `TranscriptProvider` needs to know about the owning `Episode`
/// / `Podcast` to run the feed-vs-on-device decision tree and the
/// download-wait watcher (M3 spec §7.3 step 3, architecture §11.8).
struct EpisodeTranscriptionContext: Sendable {
    var downloadState: DownloadState
    var resolvedLocalAudioURL: URL?
    var duration: TimeInterval?
    var feedTranscriptURL: URL?
    var feedTranscriptType: String?
    var podcastLanguageCode: String?
    var podcastLanguageOverride: String?
}

@ModelActor
actor TranscriptWriter {

    // MARK: - Reads

    func fetchEpisodeContext(episodeID: PersistentIdentifier) throws -> EpisodeTranscriptionContext? {
        guard let episode = modelContext.model(for: episodeID) as? Episode else {
            return nil
        }
        return EpisodeTranscriptionContext(
            downloadState: episode.downloadState,
            resolvedLocalAudioURL: episode.resolvedLocalAudioURL,
            duration: episode.duration,
            feedTranscriptURL: episode.feedTranscriptURL,
            feedTranscriptType: episode.feedTranscriptType,
            podcastLanguageCode: episode.podcast?.languageCode,
            podcastLanguageOverride: episode.podcast?.languageOverride
        )
    }

    func fetchExistingTranscript(episodeID: PersistentIdentifier) throws -> ExistingTranscriptInfo? {
        guard let episode = modelContext.model(for: episodeID) as? Episode, let transcript = episode.transcript else {
            return nil
        }
        let sorted = transcript.segments.sorted { $0.index < $1.index }
        let snapshots = sorted.map(Self.snapshot(of:))
        return ExistingTranscriptInfo(
            transcriptID: transcript.persistentModelID,
            source: transcript.source,
            languageCode: transcript.languageCode,
            state: transcript.state,
            segments: snapshots
        )
    }

    // MARK: - Writes

    /// Used by both the feed path's one-shot pending row and the on-device
    /// path (M3 spec §7.2 step 1, §7.3 step 2). Replaces any prior
    /// transcript relationship on the episode (cascade-deletes its
    /// segments) -- callers that want to *resume* a prior on-device run
    /// must pass its existing `transcriptID` straight through to
    /// `appendSegments` instead of calling this again (architecture §11.15).
    func createPendingTranscript(episodeID: PersistentIdentifier, source: TranscriptSource, languageCode: String) throws -> PersistentIdentifier {
        guard let episode = modelContext.model(for: episodeID) as? Episode else {
            throw TranscriptStoreError.episodeNotFound
        }
        if let existing = episode.transcript {
            modelContext.delete(existing)
        }
        let transcript = Transcript(episode: episode, source: source, languageCode: languageCode, state: .pending)
        modelContext.insert(transcript)
        episode.transcript = transcript
        try modelContext.save()
        return transcript.persistentModelID
    }

    /// §5's `LocaleResolver.resolve` contract: "whichever [locale] is
    /// chosen gets written into `Transcript.languageCode` as the actual
    /// locale used" -- called once, after `SpeechTranscriber.supportedLocales`
    /// matching completes (M3 spec §7.3 step 4), to correct the best-guess
    /// string `createPendingTranscript` was seeded with in step 2.
    func updateLanguageCode(_ languageCode: String, transcriptID: PersistentIdentifier) throws {
        guard let transcript = modelContext.model(for: transcriptID) as? Transcript else {
            throw TranscriptStoreError.transcriptNotFound
        }
        transcript.languageCode = languageCode
        try modelContext.save()
    }

    /// Inserts `TranscriptSegment` rows for `segments`, updates
    /// `Transcript.state` to `newState`, saves, and returns snapshots of
    /// exactly the rows just inserted (M3 spec §6.8).
    @discardableResult
    func appendSegments(_ segments: [NormalizedSegment], transcriptID: PersistentIdentifier, newState: TranscriptState) throws -> [TranscriptSegmentSnapshot] {
        guard let transcript = modelContext.model(for: transcriptID) as? Transcript else {
            throw TranscriptStoreError.transcriptNotFound
        }
        var snapshots: [TranscriptSegmentSnapshot] = []
        snapshots.reserveCapacity(segments.count)
        for segment in segments {
            let row = TranscriptSegment(
                transcript: transcript,
                index: segment.index,
                startTime: segment.startTime,
                endTime: segment.endTime,
                text: segment.text,
                wordTimings: segment.wordTimings
            )
            modelContext.insert(row)
            transcript.segments.append(row)
            snapshots.append(Self.snapshot(of: row))
        }
        transcript.state = newState
        try modelContext.save()
        return snapshots
    }

    /// One-shot replace: used by the feed path (§7.2) and by
    /// `invalidateAndRetranscribe` resetting a transcript before a fresh
    /// on-device run (§7.4).
    @discardableResult
    func replaceAllSegments(_ segments: [NormalizedSegment], transcriptID: PersistentIdentifier, newState: TranscriptState) throws -> [TranscriptSegmentSnapshot] {
        guard let transcript = modelContext.model(for: transcriptID) as? Transcript else {
            throw TranscriptStoreError.transcriptNotFound
        }
        for existing in transcript.segments {
            modelContext.delete(existing)
        }
        transcript.segments = []

        var snapshots: [TranscriptSegmentSnapshot] = []
        snapshots.reserveCapacity(segments.count)
        for segment in segments {
            let row = TranscriptSegment(
                transcript: transcript,
                index: segment.index,
                startTime: segment.startTime,
                endTime: segment.endTime,
                text: segment.text,
                wordTimings: segment.wordTimings
            )
            modelContext.insert(row)
            transcript.segments.append(row)
            snapshots.append(Self.snapshot(of: row))
        }
        transcript.state = newState
        try modelContext.save()
        return snapshots
    }

    func setState(_ state: TranscriptState, transcriptID: PersistentIdentifier) throws {
        guard let transcript = modelContext.model(for: transcriptID) as? Transcript else {
            throw TranscriptStoreError.transcriptNotFound
        }
        transcript.state = state
        try modelContext.save()
    }

    /// Cascade-deletes segments via `Transcript.segments`'s
    /// `@Relationship(deleteRule: .cascade)` (architecture §4). No-op if
    /// the episode has no transcript.
    func deleteTranscript(episodeID: PersistentIdentifier) throws {
        guard let episode = modelContext.model(for: episodeID) as? Episode, let transcript = episode.transcript else {
            return
        }
        modelContext.delete(transcript)
        episode.transcript = nil
        try modelContext.save()
    }

    // MARK: - Snapshot mapping

    private static func snapshot(of segment: TranscriptSegment) -> TranscriptSegmentSnapshot {
        TranscriptSegmentSnapshot(
            id: segment.persistentModelID,
            index: segment.index,
            startTime: segment.startTime,
            endTime: segment.endTime,
            text: segment.text,
            wordTimings: segment.wordTimings
        )
    }
}
