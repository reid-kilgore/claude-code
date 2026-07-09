// M1 — SwiftData-backed implementation of CatalogServiceProtocol
// (docs/specs/M1-catalog.md §5; architecture §5.5, §11.2). Lives in the app
// target rather than LingoPodKit (spec §0's placement decision): it owns a
// background `URLSession` delegate that must update UI-observed `@Model`
// state and needs the app's real `ModelContainer`, which would otherwise
// require inventing a second DI path into the Kit package.
import Foundation
import SwiftData
import os
import LingoPodKit

public enum CatalogError: Error, Sendable {
    case podcastNotFound
    case episodeNotFound
    case feedFetchFailed(statusCode: Int)
    case feedParseFailed(underlying: String)
    case downloadFailed(underlying: String)
    case fileSystemError(underlying: String)
}

@ModelActor
public actor CatalogService: CatalogServiceProtocol {
    private let itunesClient: ITunesSearchClient
    private let feedParser: FeedParser
    private let urlSession: URLSession
    private let downloadCoordinator: DownloadCoordinator
    private let logger = Logger(subsystem: "com.lingopod.app", category: "Catalog")

    private static let episodeCapLimit = 200

    // VERIFY(iOS26): `@ModelActor` synthesizes `modelContext`/`modelContainer`
    // stored properties plus a `public init(modelContainer:)`. This custom
    // initializer sets those two synthesized properties directly (rather
    // than delegating to the synthesized init, which does not accept extra
    // parameters) so `CatalogService` can also take its collaborators at
    // construction time, per spec §5.2. If a real Xcode 26 SDK's generated
    // storage/init shape differs from this, update this initializer.
    public init(
        modelContainer: ModelContainer,
        downloadCoordinator: DownloadCoordinator,
        itunesClient: ITunesSearchClient = ITunesSearchClient(),
        feedParser: FeedParser = FeedParser(),
        urlSession: URLSession = .shared
    ) {
        self.modelContainer = modelContainer
        self.modelContext = ModelContext(modelContainer)
        self.itunesClient = itunesClient
        self.feedParser = feedParser
        self.urlSession = urlSession
        self.downloadCoordinator = downloadCoordinator
    }

    // MARK: - CatalogServiceProtocol

    public func search(term: String) async throws -> [PodcastSearchResult] {
        let raw = try await itunesClient.search(term: term)
        return raw.compactMap { result -> PodcastSearchResult? in
            guard let feedURL = result.feedURL else {
                // The canonical `PodcastSearchResult` (Interfaces.swift,
                // App-target, binding per architecture §5.5) declares
                // `feedURL` as non-optional — unlike this module's own spec
                // §3.1, which kept nil-feedURL results visible with a
                // disabled Subscribe button. Since the binding type cannot
                // represent that case, such results are dropped here
                // instead. See PodcastSearchResult.swift's file header.
                return nil
            }
            let id = result.collectionId.map(String.init) ?? feedURL.absoluteString
            let author = result.artistName.isEmpty ? nil : result.artistName
            return PodcastSearchResult(
                id: id,
                feedURL: feedURL,
                title: result.collectionName,
                author: author,
                artworkURL: result.artworkURL,
                // The iTunes Search API does not return a podcast-language
                // field in practice; always nil in v1.
                languageCode: nil
            )
        }
    }

    public func subscribe(feedURL: URL) async throws -> PersistentIdentifier {
        // Dedupe check first: subscribing to an already-subscribed feed is
        // idempotent success, not an error (spec §5.4 step 1).
        if let existing = try fetchPodcastByFeedURL(feedURL) {
            return existing.persistentModelID
        }

        let parsed = try await fetchAndParse(feedURL: feedURL)

        let trimmedTitle = parsed.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = trimmedTitle.isEmpty ? (feedURL.host ?? "Untitled Podcast") : trimmedTitle
        let resolvedArtwork = Self.resolveIfRelative(parsed.imageURL, against: feedURL)

        let podcast = Podcast(
            feedURL: feedURL,
            title: title,
            author: parsed.author,
            artworkURL: resolvedArtwork,
            feedDescription: parsed.description,
            languageCode: parsed.languageCode,
            languageOverride: nil,
            subscribedAt: .now,
            lastRefreshedAt: .now
        )
        modelContext.insert(podcast)

        // Cap applies only at initial subscribe, bounding how many `Episode`
        // rows a first-time backfill from a huge archive feed creates. See
        // `applyIngestion(...)`'s doc comment for why refresh never caps.
        applyIngestion(items: parsed.items, to: podcast, feedURL: feedURL, capToInitial200: true)

        do {
            try modelContext.save()
        } catch {
            throw CatalogError.fileSystemError(underlying: String(describing: error))
        }

        return podcast.persistentModelID
    }

    public func unsubscribe(podcastID: PersistentIdentifier) async throws {
        let podcast = try fetchPodcast(podcastID)

        for episode in podcast.episodes {
            if case .inProgress = episode.downloadState {
                await downloadCoordinator.cancelDownload(guid: episode.guid)
            }
            if let path = episode.localAudioPath {
                removeFileIfExists(relativePath: path)
            }
        }

        // `@Relationship(deleteRule: .cascade, ...)` on `Podcast.episodes`
        // cascades to `Episode`, which cascades to `Episode.transcript` and
        // its segments — do not manually delete episodes one by one.
        modelContext.delete(podcast)

        do {
            try modelContext.save()
        } catch {
            throw CatalogError.fileSystemError(underlying: String(describing: error))
        }
    }

    public func refresh(podcastID: PersistentIdentifier) async throws {
        let podcast = try fetchPodcast(podcastID)
        let feedURL = podcast.feedURL

        // A failed refresh must be a complete no-op on stored data (spec
        // §7.9) — `fetchAndParse` throwing here means we return before
        // touching `podcast` or `lastRefreshedAt` at all.
        let parsed = try await fetchAndParse(feedURL: feedURL)

        // Never cap/evict on refresh: architecture §11.11 ("deletion
        // happens only via unsubscribe/removeDownload") is binding and
        // overrides this module's own spec §5.5 step 3 / §7.4, which
        // described evicting existing `Episode` rows past the 200 cap on
        // refresh (exempting downloaded/played ones). Since architecture
        // forbids any deletion path outside unsubscribe/removeDownload,
        // this cap is enforced only at initial subscribe (see `subscribe`
        // above), where there is nothing yet to delete. A refresh may
        // therefore leave a podcast with more than 200 episodes if the
        // feed keeps publishing — accepted, matches architecture's
        // "never delete on refresh" rule to the letter.
        applyIngestion(items: parsed.items, to: podcast, feedURL: feedURL, capToInitial200: false)

        podcast.lastRefreshedAt = .now

        do {
            try modelContext.save()
        } catch {
            throw CatalogError.fileSystemError(underlying: String(describing: error))
        }
    }

    public func download(episodeID: PersistentIdentifier) async throws {
        let episode = try fetchEpisode(episodeID)

        switch episode.downloadState {
        case .downloaded, .inProgress:
            return // idempotent no-op — already downloaded or downloading
        case .none, .failed:
            break
        }

        episode.downloadState = .inProgress(progress: 0)
        do {
            try modelContext.save()
        } catch {
            throw CatalogError.fileSystemError(underlying: String(describing: error))
        }

        do {
            try await downloadCoordinator.startDownload(guid: episode.guid, url: episode.audioURL)
        } catch {
            episode.downloadState = .failed(reason: "enqueueFailed")
            try? modelContext.save()
            throw CatalogError.downloadFailed(underlying: String(describing: error))
        }
    }

    public func removeDownload(episodeID: PersistentIdentifier) async throws {
        let episode = try fetchEpisode(episodeID)

        if case .inProgress = episode.downloadState {
            await downloadCoordinator.cancelDownload(guid: episode.guid)
        }
        if let path = episode.localAudioPath {
            removeFileIfExists(relativePath: path)
        }

        episode.localAudioPath = nil
        episode.downloadState = .none
        // Deliberately NOT touching playbackPosition/playbackCompleted —
        // removing a download is a storage decision, not a "forget my
        // progress" action (spec §5.10 step 4).

        do {
            try modelContext.save()
        } catch {
            throw CatalogError.fileSystemError(underlying: String(describing: error))
        }
    }

    // MARK: - Internal (non-protocol) hooks for DownloadCoordinator (spec §8.3)
    //
    // `URLSessionDownloadDelegate` callbacks arrive on an arbitrary
    // system-owned queue, independent of this actor's isolation;
    // `DownloadCoordinator` hops back with `Task { await self... }` and
    // calls these to persist progress/results. Not part of
    // `CatalogServiceProtocol` (architecture §5.5 pins that exactly) — this
    // is app-target-only surface between these two collaborators.

    func applyDownloadProgress(guid: String, progress: Double) {
        guard let episode = fetchEpisode(guid: guid) else { return }
        if case .inProgress = episode.downloadState {
            let rounded = (progress * 100).rounded() / 100
            episode.downloadState = .inProgress(progress: rounded)
            try? modelContext.save()
        }
    }

    func applyDownloadSuccess(guid: String, tempFileURL: URL) async {
        guard let episode = fetchEpisode(guid: guid) else {
            try? FileManager.default.removeItem(at: tempFileURL)
            return
        }
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            episode.downloadState = .failed(reason: "fileSystemUnavailable")
            try? modelContext.save()
            try? FileManager.default.removeItem(at: tempFileURL)
            return
        }

        let episodesDir = base.appendingPathComponent("Episodes", isDirectory: true)
        do {
            if !FileManager.default.fileExists(atPath: episodesDir.path) {
                try FileManager.default.createDirectory(at: episodesDir, withIntermediateDirectories: true)
                var dirURL = episodesDir
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                try dirURL.setResourceValues(values)
            }

            let relativePath = episode.localAudioRelativePath
            let destination = base.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: tempFileURL, to: destination)

            episode.localAudioPath = relativePath
            episode.downloadState = .downloaded
            try modelContext.save()
        } catch {
            logger.error("Failed to finalize download for \(guid, privacy: .public): \(error.localizedDescription, privacy: .public)")
            episode.downloadState = .failed(reason: "fileMoveFailed")
            try? modelContext.save()
            try? FileManager.default.removeItem(at: tempFileURL)
        }
    }

    func applyDownloadFailure(guid: String, reason: String) {
        guard let episode = fetchEpisode(guid: guid) else { return }
        episode.downloadState = .failed(reason: reason)
        try? modelContext.save()
    }

    // MARK: - Feed fetch + parse

    private func fetchAndParse(feedURL: URL) async throws -> ParsedFeed {
        let data: Data
        let response: URLResponse
        do {
            // Default redirect policy handles 30x redirects (feed moved to
            // a new host) with zero extra code (spec §7.5) — the *stored*
            // `Podcast.feedURL` always stays the originally-subscribed URL,
            // never rewritten to a redirect target.
            (data, response) = try await urlSession.data(from: feedURL)
        } catch {
            throw CatalogError.feedFetchFailed(statusCode: -1)
        }
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw CatalogError.feedFetchFailed(statusCode: code)
        }

        do {
            // Pass raw `Data` straight into `FeedParser` — `XMLParser`
            // honors the XML prolog's declared encoding itself (spec §7.6).
            // Never pre-convert to `String` with a guessed encoding first.
            return try feedParser.parse(data: data)
        } catch {
            throw CatalogError.feedParseFailed(underlying: String(describing: error))
        }
    }

    // MARK: - Shared episode ingestion routine (spec §5.6)

    /// Given parsed feed items and a target `Podcast`, upserts by guid:
    /// existing episodes have their feed-derived fields refreshed (title,
    /// description, publishedAt, duration, audioURL, transcript ref) while
    /// download/playback state is left untouched; new items become new
    /// `Episode` rows; episodes missing from the incoming feed are left in
    /// place, untouched (never deleted here — spec §5.5 step 3 / architecture
    /// §11.11).
    ///
    /// `capToInitial200`: when true (subscribe only), the *candidate new*
    /// items are truncated to the 200 most-recent by `publishedAt` (nil
    /// sorts last) before any `Episode` rows are created. See the
    /// `refresh(podcastID:)` doc comment above for why this never applies
    /// (and no row is ever evicted) on refresh.
    private func applyIngestion(items: [ParsedItem], to podcast: Podcast, feedURL: URL, capToInitial200: Bool) {
        var resolved = resolveAndDedupe(items: items)
        if capToInitial200 {
            resolved = Self.capForInitialSubscribe(resolved, limit: Self.episodeCapLimit)
        }

        var existingByGUID: [String: Episode] = [:]
        for episode in podcast.episodes {
            existingByGUID[episode.guid] = episode
        }

        for (guid, item) in resolved {
            guard let rawEnclosureURL = item.enclosureURL else { continue } // guaranteed non-nil by resolveAndDedupe
            let enclosureURL = Self.resolveIfRelative(rawEnclosureURL, against: feedURL) ?? rawEnclosureURL
            let (transcriptURL, transcriptType) = Self.selectTranscript(from: item.transcripts, feedURL: feedURL)

            if let existing = existingByGUID[guid] {
                existing.title = item.title
                existing.episodeDescription = item.description
                existing.publishedAt = item.publishedAt
                existing.duration = item.durationSeconds
                existing.audioURL = enclosureURL
                existing.feedTranscriptURL = transcriptURL
                existing.feedTranscriptType = transcriptType
                // NOT touched: downloadState, localAudioPath,
                // playbackPosition, playbackCompleted, transcript.
            } else {
                let episode = Episode(
                    guid: guid,
                    podcast: podcast,
                    title: item.title,
                    episodeDescription: item.description,
                    publishedAt: item.publishedAt,
                    duration: item.durationSeconds,
                    audioURL: enclosureURL,
                    feedTranscriptURL: transcriptURL,
                    feedTranscriptType: transcriptType
                )
                modelContext.insert(episode)
                podcast.episodes.append(episode)
            }
        }
    }

    /// Resolves guid (falling back to enclosure URL) and drops/dedupes
    /// items per spec §5.6 steps 1-3.
    private func resolveAndDedupe(items: [ParsedItem]) -> [(guid: String, item: ParsedItem)] {
        var seen = Set<String>()
        var resolved: [(guid: String, item: ParsedItem)] = []
        for item in items {
            guard let enclosureURL = item.enclosureURL else {
                logger.info("Dropping feed item with no enclosure URL: \(item.title, privacy: .public)")
                continue
            }
            let guid = item.guid.isEmpty ? enclosureURL.absoluteString : item.guid
            guard !guid.isEmpty else {
                logger.info("Dropping feed item with no guid and no enclosure URL")
                continue
            }
            if seen.contains(guid) {
                logger.info("Dropping duplicate-guid feed item: \(guid, privacy: .public)")
                continue
            }
            seen.insert(guid)
            resolved.append((guid, item))
        }
        return resolved
    }

    private static func capForInitialSubscribe(
        _ resolved: [(guid: String, item: ParsedItem)],
        limit: Int
    ) -> [(guid: String, item: ParsedItem)] {
        guard resolved.count > limit else { return resolved }
        let sorted = resolved.sorted { lhs, rhs in
            switch (lhs.item.publishedAt, rhs.item.publishedAt) {
            case let (l?, r?): return l > r
            case (nil, .some): return false // nil sorts last
            case (.some, nil): return true
            case (nil, nil): return false
            }
        }
        return Array(sorted.prefix(limit))
    }

    /// Transcript type preference order (spec §5.6 step 4):
    /// application/json, then text/vtt, then application/srt or text/srt
    /// (equal preference; first encountered in document order wins).
    private static func selectTranscript(from refs: [ParsedTranscriptRef], feedURL: URL) -> (URL?, String?) {
        func firstMatching(_ types: Set<String>) -> ParsedTranscriptRef? {
            refs.first { types.contains($0.type.lowercased()) }
        }
        if let match = firstMatching(["application/json"]) {
            return (resolveIfRelative(match.url, against: feedURL), match.type)
        }
        if let match = firstMatching(["text/vtt"]) {
            return (resolveIfRelative(match.url, against: feedURL), match.type)
        }
        if let match = firstMatching(["application/srt", "text/srt"]) {
            return (resolveIfRelative(match.url, against: feedURL), match.type)
        }
        return (nil, nil)
    }

    /// Resolves a URL that may be relative to the feed's own host (spec
    /// §7.7) — e.g. `<itunes:image href="/art.jpg">`.
    private static func resolveIfRelative(_ url: URL?, against base: URL) -> URL? {
        guard let url else { return nil }
        if url.scheme != nil { return url }
        return URL(string: url.absoluteString, relativeTo: base)?.absoluteURL
    }

    // MARK: - Fetch helpers

    // VERIFY(iOS26): `ModelContext.model(for:)` is the documented way to
    // resolve a `PersistentIdentifier` back to a model instance; downcast +
    // nil-check here guards against a stale/deleted identifier (e.g. a
    // podcast unsubscribed concurrently) without crashing, per spec §5.5
    // step 1 / §5.8 step 1.
    private func fetchPodcast(_ id: PersistentIdentifier) throws -> Podcast {
        guard let podcast = modelContext.model(for: id) as? Podcast else {
            throw CatalogError.podcastNotFound
        }
        return podcast
    }

    private func fetchEpisode(_ id: PersistentIdentifier) throws -> Episode {
        guard let episode = modelContext.model(for: id) as? Episode else {
            throw CatalogError.episodeNotFound
        }
        return episode
    }

    private func fetchPodcastByFeedURL(_ feedURL: URL) throws -> Podcast? {
        var descriptor = FetchDescriptor<Podcast>(predicate: #Predicate { $0.feedURL == feedURL })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    /// Guid-keyed lookup used by `DownloadCoordinator`'s callbacks (spec
    /// §8.5: tasks are correlated to episodes by RSS `guid`, not
    /// `PersistentIdentifier`, since the latter isn't reliably
    /// string-convertible across a process relaunch).
    private func fetchEpisode(guid: String) -> Episode? {
        var descriptor = FetchDescriptor<Episode>(predicate: #Predicate { $0.guid == guid })
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    // MARK: - File removal

    private func removeFileIfExists(relativePath: String) {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return
        }
        let url = base.appendingPathComponent(relativePath)
        do {
            try FileManager.default.removeItem(at: url)
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            // A missing file must not block unsubscribe/removeDownload
            // (spec §5.8 step 2) — the DB record and the file can drift.
        } catch {
            logger.error("Failed to remove file at \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}
