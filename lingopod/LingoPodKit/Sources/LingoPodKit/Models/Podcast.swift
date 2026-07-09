// M0
// SwiftData model (architecture §4, verbatim field set; §11.1 assigns
// implementation of this file to M0 rather than M1). `public` access and
// the memberwise `init` below are additions required for a SwiftPM
// library target consumed across the package boundary by the app target;
// architecture §4's sketch omits access modifiers entirely since it is
// illustrative pseudocode, not a literal file.
import Foundation
import SwiftData

@Model
public final class Podcast {
    @Attribute(.unique) public var feedURL: URL
    public var title: String
    public var author: String?
    public var artworkURL: URL?
    public var feedDescription: String?
    /// BCP-47 from `<language>`; nil if absent.
    public var languageCode: String?
    /// User-set BCP-47, wins over `languageCode`.
    public var languageOverride: String?
    public var subscribedAt: Date
    public var lastRefreshedAt: Date?

    @Relationship(deleteRule: .cascade, inverse: \Episode.podcast)
    public var episodes: [Episode] = []

    public init(
        feedURL: URL,
        title: String,
        author: String? = nil,
        artworkURL: URL? = nil,
        feedDescription: String? = nil,
        languageCode: String? = nil,
        languageOverride: String? = nil,
        subscribedAt: Date = .now,
        lastRefreshedAt: Date? = nil
    ) {
        self.feedURL = feedURL
        self.title = title
        self.author = author
        self.artworkURL = artworkURL
        self.feedDescription = feedDescription
        self.languageCode = languageCode
        self.languageOverride = languageOverride
        self.subscribedAt = subscribedAt
        self.lastRefreshedAt = lastRefreshedAt
    }
}
