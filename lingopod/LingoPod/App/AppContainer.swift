// M0
// The app's only composition root (architecture §5, §11.10). Holds the
// SwiftData `ModelContainer` and one instance of each §5 service protocol.
// Every service below is a mock in M0; later modules replace exactly one
// `let`/assignment line each (see docs/specs/M0-scaffolding.md §6.6) —
// AppContainer's public shape does not change as mocks are swapped out.
import Foundation
import SwiftData
import Observation
import LingoPodKit

@MainActor
@Observable
final class AppContainer {
    let modelContainer: ModelContainer

    var catalogService: any CatalogServiceProtocol
    var translationService: any TranslationServiceProtocol
    var explainService: any ExplainServiceProtocol
    var transcriptProvider: any TranscriptProviderProtocol

    /// `PlayerEngine` is `@MainActor @Observable` and owned as a concrete
    /// reference type (not `any PlayerEngineProtocol`) because SwiftUI's
    /// `@Observable` protocol conformance can't be stored as an
    /// existential and still participate in view invalidation the way a
    /// concrete `@Observable` class can (architecture §11.10). Views that
    /// need protocol-only access can still type a parameter as
    /// `any PlayerEngineProtocol`.
    var playerEngine: PlayerEngine

    /// Optional-capability accessors (architecture §11.5): additive
    /// protocols aren't part of the base §5 service protocols, so they're
    /// exposed here as `as?` downcasts at the container boundary rather
    /// than widening `TranslationServiceProtocol`/`ExplainServiceProtocol`
    /// themselves. `nil` until a concrete service that conforms is wired
    /// in (M0's mocks conform trivially so the pattern is exercised from
    /// day one).
    var translationDownloadPreparing: (any TranslationDownloadPreparing)? {
        translationService as? TranslationDownloadPreparing
    }

    var translationFallbackProviding: (any TranslationFallbackProviding)? {
        explainService as? TranslationFallbackProviding
    }

    init() {
        do {
            let schema = Schema([
                Podcast.self,
                Episode.self,
                Transcript.self,
                TranscriptSegment.self,
                TranslationCacheEntry.self,
                ExplanationCacheEntry.self,
            ])
            let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
            self.modelContainer = try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }

        // M1
        let downloadCoordinator = DownloadCoordinator()
        let catalog = CatalogService(modelContainer: modelContainer, downloadCoordinator: downloadCoordinator)
        self.catalogService = catalog
        Task { await downloadCoordinator.attach(catalogService: catalog) }

        // Background-session relaunch handshake (M1 spec §8.5): register the
        // coordinator with AppDelegate and drain any handler that arrived
        // before this container existed.
        AppDelegate.downloadCoordinator = downloadCoordinator
        if let pending = AppDelegate.pendingBackgroundCompletionHandler {
            AppDelegate.pendingBackgroundCompletionHandler = nil
            Task { await downloadCoordinator.attach(backgroundCompletionHandler: pending) }
        }

        // M5
        self.translationService = TranslationService(
            cache: TranslationCacheStore(modelContainer: modelContainer)
        )

        // M6
        let explain = ExplainService(
            cacheStore: ExplanationCacheStore(modelContainer: modelContainer)
        )
        explain.refreshAvailability()
        self.explainService = explain

        // M3
        self.transcriptProvider = TranscriptProvider(modelContainer: modelContainer)

        // M2
        self.playerEngine = PlayerEngine(
            modelContext: modelContainer.mainContext,
            positionStore: PlaybackPositionStore(modelContext: modelContainer.mainContext),
            catalogService: catalog
        )
    }
}
