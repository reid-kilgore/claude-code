// M1 — Value types produced by FeedParser; no SwiftData here.
// Pure, Sendable, Equatable value types so `FeedParser` stays a dumb
// "XML in, structured values out" function, testable with `swift test`
// on Linux with zero SwiftData/simulator dependency (architecture §1, §9).
import Foundation

public struct ParsedFeed: Sendable, Equatable {
    /// `<title>` at channel level.
    public var title: String
    /// `<description>` at channel level, HTML-stripped.
    public var description: String?
    /// `<language>`, lowercased+trimmed as given; nil if absent/empty.
    public var languageCode: String?
    /// `<itunes:author>`, falls back to `<managingEditor>` if absent.
    public var author: String?
    /// `<itunes:image href="">`, falls back to `<image><url>`.
    public var imageURL: URL?
    /// In feed (document) order — caller decides sort/cap.
    public var items: [ParsedItem]

    public init(
        title: String,
        description: String? = nil,
        languageCode: String? = nil,
        author: String? = nil,
        imageURL: URL? = nil,
        items: [ParsedItem] = []
    ) {
        self.title = title
        self.description = description
        self.languageCode = languageCode
        self.author = author
        self.imageURL = imageURL
        self.items = items
    }
}

public struct ParsedItem: Sendable, Equatable {
    /// `<guid>`; possibly empty string as found in the XML. `FeedParser`
    /// does NOT fall back to the enclosure URL itself — that policy
    /// decision belongs to `CatalogService` (spec §4.7).
    public var guid: String
    public var title: String
    /// `<description>` or `<itunes:summary>`, HTML-stripped.
    public var description: String?
    /// `<pubDate>`, parsed via `RFC822DateParser`; nil if absent/unparsable.
    public var publishedAt: Date?
    /// `<itunes:duration>`, parsed via `ITunesDurationParser`.
    public var durationSeconds: TimeInterval?
    /// `<enclosure url="">`; item is unusable as an episode if nil.
    public var enclosureURL: URL?
    /// `<enclosure type="">`, e.g. "audio/mpeg".
    public var enclosureType: String?
    /// `<podcast:transcript>` entries, in document order.
    public var transcripts: [ParsedTranscriptRef]

    public init(
        guid: String,
        title: String,
        description: String? = nil,
        publishedAt: Date? = nil,
        durationSeconds: TimeInterval? = nil,
        enclosureURL: URL? = nil,
        enclosureType: String? = nil,
        transcripts: [ParsedTranscriptRef] = []
    ) {
        self.guid = guid
        self.title = title
        self.description = description
        self.publishedAt = publishedAt
        self.durationSeconds = durationSeconds
        self.enclosureURL = enclosureURL
        self.enclosureType = enclosureType
        self.transcripts = transcripts
    }
}

public struct ParsedTranscriptRef: Sendable, Equatable {
    public var url: URL
    /// MIME type as given, e.g. "application/json", "text/vtt", "application/srt".
    public var type: String

    public init(url: URL, type: String) {
        self.url = url
        self.type = type
    }
}
