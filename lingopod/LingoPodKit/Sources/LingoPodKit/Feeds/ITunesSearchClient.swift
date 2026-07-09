// M1 — iTunes Search API client
import Foundation

public enum ITunesSearchError: Error, Sendable, Equatable {
    case emptyTerm
    case invalidResponse(statusCode: Int)
    case decodingFailed
    /// `URLError` description, stringified so the error stays
    /// `Equatable`/`Sendable` without wrapping `URLError`.
    case network(String)
}

public actor ITunesSearchClient {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func search(term: String) async throws -> [ITunesSearchResult] {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ITunesSearchError.emptyTerm }

        // Always build the URL via URLComponents + queryItems, never by
        // hand-interpolating the term into a string: URLQueryItem
        // percent-encodes spaces/ampersands/non-Latin scripts correctly
        // (target-language podcast names — Korean, Japanese, Arabic, etc. —
        // are the primary use case here). Do not pre-encode values and
        // assign to `.queryItems`, or double-encoding results.
        guard var components = URLComponents(string: "https://itunes.apple.com/search") else {
            throw ITunesSearchError.decodingFailed
        }
        components.queryItems = [
            URLQueryItem(name: "media", value: "podcast"),
            URLQueryItem(name: "term", value: trimmed),
            URLQueryItem(name: "limit", value: "50"),
        ]
        guard let url = components.url else { throw ITunesSearchError.decodingFailed }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(from: url)
        } catch {
            throw ITunesSearchError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw ITunesSearchError.invalidResponse(statusCode: code)
        }

        return try Self.decodeResults(from: data)
    }

    /// Decode+filter step, split out as a `static` function (touches
    /// neither `self` nor the network) so it is independently unit-testable
    /// against a captured JSON fixture without hitting the network
    /// (spec §10.2).
    public static func decodeResults(from data: Data) throws -> [ITunesSearchResult] {
        let decoded: ITunesSearchResponse
        do {
            decoded = try JSONDecoder().decode(ITunesSearchResponse.self, from: data)
        } catch {
            throw ITunesSearchError.decodingFailed
        }
        return ITunesResultMapper.map(decoded)
    }
}
