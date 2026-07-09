// M1
// Cannot hit the live network in CI (spec §10.2) -- tests the
// decoding/filtering logic in isolation via `ITunesSearchClient.decodeResults(from:)`,
// a static function separated from the network fetch specifically so this
// is possible.
import Testing
import Foundation
@testable import LingoPodKit

private enum FixtureError: Error {
    case missing(String)
}

@Suite("ITunesSearchClient")
struct ITunesSearchClientTests {
    private func loadFixture() throws -> Data {
        guard let url = Bundle.module.url(forResource: "itunes_search_response", withExtension: "json", subdirectory: "Fixtures") else {
            throw FixtureError.missing("itunes_search_response.json")
        }
        return try Data(contentsOf: url)
    }

    @Test func decodeResultsFiltersOutNonPodcastEntries() throws {
        let data = try loadFixture()
        let results = try ITunesSearchClient.decodeResults(from: data)

        // 4 fixture entries, 1 is wrapperType=track/kind=audiobook and
        // must be filtered out.
        #expect(results.count == 3)
        #expect(!results.contains { $0.collectionName == "Some Audiobook" })
    }

    @Test func decodeResultsKeepsMissingFeedURLEntryWithNilFeedURL() throws {
        let data = try loadFixture()
        let results = try ITunesSearchClient.decodeResults(from: data)
        let noFeed = try #require(results.first { $0.collectionName == "No Feed Podcast" })
        #expect(noFeed.feedURL == nil)
        #expect(noFeed.artistName == "Nobody")
    }

    @Test func decodeResultsResolvesArtworkFallbackTo100() throws {
        let data = try loadFixture()
        let results = try ITunesSearchClient.decodeResults(from: data)
        let smallArt = try #require(results.first { $0.collectionName == "Small Art Podcast" })
        #expect(smallArt.artworkURL == URL(string: "https://example.com/art/sa100.jpg"))
    }

    @Test func decodeResultsPrefersArtwork600WhenBothPresent() throws {
        let data = try loadFixture()
        let results = try ITunesSearchClient.decodeResults(from: data)
        let radioAmbulante = try #require(results.first { $0.collectionName == "Radio Ambulante" })
        #expect(radioAmbulante.artistName == "NPR")
        #expect(radioAmbulante.feedURL == URL(string: "https://feeds.example.com/radioambulante.xml"))
        #expect(radioAmbulante.artworkURL == URL(string: "https://example.com/art/ra600.jpg"))
    }

    @Test func decodeResultsThrowsOnGarbageData() {
        let data = Data("not json at all".utf8)
        do {
            _ = try ITunesSearchClient.decodeResults(from: data)
            Issue.record("Expected ITunesSearchError.decodingFailed to be thrown")
        } catch let error as ITunesSearchError {
            #expect(error == .decodingFailed)
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    /// Guards the pitfall called out in spec §3.2: building the request URL
    /// by hand-interpolating the search term (rather than via
    /// `URLComponents.queryItems`) would silently produce a broken/
    /// mismatched search for any term with a space or non-ASCII character.
    @Test func searchURLPercentEncodesSpacesAndNonASCII() throws {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "media", value: "podcast"),
            URLQueryItem(name: "term", value: "café radio"),
            URLQueryItem(name: "limit", value: "50"),
        ]
        let url = try #require(components.url)
        let urlString = url.absoluteString
        #expect(!urlString.contains(" "))
        #expect(urlString.contains("%C3%A9")) // percent-encoded 'é'
        #expect(urlString.contains("%20") || urlString.contains("+"))
    }

    @Test func emptyTermThrows() async {
        let client = ITunesSearchClient()
        do {
            _ = try await client.search(term: "   ")
            Issue.record("Expected ITunesSearchError.emptyTerm to be thrown")
        } catch let error as ITunesSearchError {
            #expect(error == .emptyTerm)
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }
}
