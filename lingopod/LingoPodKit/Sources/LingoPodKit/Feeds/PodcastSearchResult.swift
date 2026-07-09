// M1 — Value type + wire-format decoding for the iTunes Search API.
//
// NOTE (deviation from this module's own spec §3.1, recorded here since it
// affects this file's public type name): the cross-module
// `CatalogServiceProtocol.search(term:)` return type is `PodcastSearchResult`,
// but that struct is canonically defined in the app target's
// `LingoPod/App/Interfaces.swift` (M0-owned, binding per architecture §5)
// with a different shape than this spec originally sketched — notably a
// *non-optional* `feedURL`, plus `id`/`title`/`author` field names instead
// of `collectionName`/`artistName`. `LingoPodKit` cannot import the app
// target's type (the module dependency only goes the other way: app ->
// Kit), so this file defines the Kit-side decode/filter value type under a
// different name, `ITunesSearchResult`, to avoid a name collision, while
// keeping this file at the path this spec's file manifest names.
// `CatalogService` (app target, `LingoPod/Services/CatalogService.swift`)
// maps `ITunesSearchResult` -> `PodcastSearchResult` at the protocol
// boundary, dropping any result with no usable `feedURL` (since the
// canonical, binding type cannot represent that case) rather than keeping
// it with a nil feedURL and a disabled Subscribe button as this spec
// originally described.
import Foundation

public struct ITunesSearchResult: Sendable, Hashable {
    public let collectionId: Int?
    /// Podcast title.
    public let collectionName: String
    /// Podcast author/publisher.
    public let artistName: String
    /// nil if iTunes omitted it (rare, but happens).
    public let feedURL: URL?
    /// `artworkUrl600`, falls back to `artworkUrl100`.
    public let artworkURL: URL?
    public let primaryGenreName: String?

    public init(
        collectionId: Int?,
        collectionName: String,
        artistName: String,
        feedURL: URL?,
        artworkURL: URL?,
        primaryGenreName: String?
    ) {
        self.collectionId = collectionId
        self.collectionName = collectionName
        self.artistName = artistName
        self.feedURL = feedURL
        self.artworkURL = artworkURL
        self.primaryGenreName = primaryGenreName
    }
}

// Wire-format types kept private-to-module (not the public API); mapping
// logic below is deliberately separate from `Decodable` on
// `ITunesSearchResult` itself, so client-side filtering stays testable in
// isolation from JSON decoding (spec §3.1).
struct ITunesSearchResponse: Decodable {
    let resultCount: Int
    let results: [ITunesResult]
}

struct ITunesResult: Decodable {
    let wrapperType: String?
    let kind: String?
    let collectionId: Int?
    let collectionName: String?
    let artistName: String?
    let feedUrl: String?
    let artworkUrl600: String?
    let artworkUrl100: String?
    let primaryGenreName: String?
}

enum ITunesResultMapper {
    /// Mapping rules (spec §3.1):
    /// - Keep only `wrapperType == "track" && kind == "podcast"`.
    /// - `collectionName`/`artistName` missing/empty -> drop the result.
    /// - `feedUrl` missing or fails `URL(string:)` -> keep the result with
    ///   `feedURL = nil` (the decision of whether a nil-feedURL result is
    ///   *usable* downstream is made at the `CatalogService` boundary — see
    ///   this file's header).
    /// - `artworkUrl600` preferred, falls back to `artworkUrl100`, else nil.
    static func map(_ response: ITunesSearchResponse) -> [ITunesSearchResult] {
        response.results.compactMap { result in
            guard result.wrapperType == "track", result.kind == "podcast" else { return nil }
            guard let collectionName = result.collectionName, !collectionName.isEmpty,
                  let artistName = result.artistName, !artistName.isEmpty else { return nil }

            let feedURL: URL? = result.feedUrl.flatMap { URL(string: $0) }
            let artworkURL: URL? = {
                if let url600 = result.artworkUrl600, !url600.isEmpty, let url = URL(string: url600) {
                    return url
                }
                if let url100 = result.artworkUrl100, !url100.isEmpty, let url = URL(string: url100) {
                    return url
                }
                return nil
            }()

            return ITunesSearchResult(
                collectionId: result.collectionId,
                collectionName: collectionName,
                artistName: artistName,
                feedURL: feedURL,
                artworkURL: artworkURL,
                primaryGenreName: result.primaryGenreName
            )
        }
    }
}
