// M0
// SwiftData model (architecture §4, verbatim field set; §11.1). See
// Podcast.swift for the note on why `public`/`init` are added beyond the
// architecture doc's pseudocode.
//
// `localAudioPath` is relative to `Application Support/Episodes/` (M0
// spec §8 pins this convention); resolving it to an absolute URL is M1's
// job (architecture §11.9, `Episode.resolvedLocalAudioURL`) — not added
// here.
import Foundation
import SwiftData

@Model
public final class Episode {
    /// RSS guid, falls back to enclosure URL.
    @Attribute(.unique) public var guid: String
    public var podcast: Podcast?
    public var title: String
    /// HTML-stripped.
    public var episodeDescription: String?
    public var publishedAt: Date?
    /// From `itunes:duration` if present.
    public var duration: TimeInterval?
    /// Enclosure URL.
    public var audioURL: URL
    /// `<podcast:transcript>` href.
    public var feedTranscriptURL: URL?
    /// Its MIME type.
    public var feedTranscriptType: String?
    /// Relative path under Application Support when downloaded.
    public var localAudioPath: String?
    public var downloadState: DownloadState
    public var playbackPosition: TimeInterval
    public var playbackCompleted: Bool

    @Relationship(deleteRule: .cascade, inverse: \Transcript.episode)
    public var transcript: Transcript?

    public init(
        guid: String,
        podcast: Podcast? = nil,
        title: String,
        episodeDescription: String? = nil,
        publishedAt: Date? = nil,
        duration: TimeInterval? = nil,
        audioURL: URL,
        feedTranscriptURL: URL? = nil,
        feedTranscriptType: String? = nil,
        localAudioPath: String? = nil,
        downloadState: DownloadState = .none,
        playbackPosition: TimeInterval = 0,
        playbackCompleted: Bool = false
    ) {
        self.guid = guid
        self.podcast = podcast
        self.title = title
        self.episodeDescription = episodeDescription
        self.publishedAt = publishedAt
        self.duration = duration
        self.audioURL = audioURL
        self.feedTranscriptURL = feedTranscriptURL
        self.feedTranscriptType = feedTranscriptType
        self.localAudioPath = localAudioPath
        self.downloadState = downloadState
        self.playbackPosition = playbackPosition
        self.playbackCompleted = playbackCompleted
    }
}
