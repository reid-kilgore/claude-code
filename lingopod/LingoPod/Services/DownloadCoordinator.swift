// M1 — Background URLSession-backed episode download manager
// (docs/specs/M1-catalog.md §8). A separate type from `CatalogService`
// (not folded into that actor) because `URLSessionDownloadDelegate`
// callbacks arrive on an arbitrary system queue, independent of
// `CatalogService`'s actor isolation, and because a background
// `URLSessionConfiguration` needs a stable identifier the app must be able
// to reconnect to from `application(_:handleEventsForBackgroundURLSession:
// completionHandler:)` (M0's app/scene delegate territory) —
// `DownloadCoordinator` is the one object that owns that session end-to-end.
//
// `DownloadCoordinator: NSObject` is required because `URLSessionDelegate`
// requires `NSObjectProtocol` conformance; an `actor` subclassing `NSObject`
// and implementing `nonisolated` delegate callback methods that hop back
// via `Task { await self... }` is a documented, Apple-sanctioned pattern
// for actor + URLSession integration (one of the rare, framework-mandated
// non-SwiftUI spots architecture §1 allows).
import Foundation
import os

public actor DownloadCoordinator: NSObject {
    public static let backgroundSessionIdentifier = "com.lingopod.app.downloads"

    private var session: URLSession!
    /// Keyed by `Episode.guid` (spec §8.5) rather than `PersistentIdentifier`
    /// — a `PersistentIdentifier` isn't reliably string-convertible across
    /// a process relaunch, while `guid` is already the model's
    /// `@Attribute(.unique)` key and trivially usable as `taskDescription`.
    private var activeTasks: [String: URLSessionDownloadTask] = [:]
    private var resumeData: [String: Data] = [:]
    /// Weak to break the CatalogService <-> DownloadCoordinator init-order
    /// cycle (spec §8.4); set once via `attach(catalogService:)` by
    /// `AppContainer` (M0) at app launch, before either is used.
    private weak var catalogService: CatalogService?
    private let logger = Logger(subsystem: "com.lingopod.app", category: "Downloads")
    /// Stashed by M0's app/scene delegate via
    /// `attach(backgroundCompletionHandler:)` when the OS relaunches the
    /// app to finish delivering background session events
    /// (`application(_:handleEventsForBackgroundURLSession:completionHandler:)`).
    private var backgroundCompletionHandler: (() -> Void)?

    public override init() {
        super.init()
        let config = URLSessionConfiguration.background(withIdentifier: Self.backgroundSessionIdentifier)
        config.isDiscretionary = false // user explicitly tapped download; start promptly
        config.sessionSendsLaunchEvents = true
        self.session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    public func attach(catalogService: CatalogService) {
        self.catalogService = catalogService
    }

    /// M0's scene/app delegate calls this from
    /// `application(_:handleEventsForBackgroundURLSession:completionHandler:)`;
    /// `urlSessionDidFinishEvents(forBackgroundURLSession:)` invokes the
    /// stored handler once the reattached session has delivered all its
    /// queued delegate callbacks, so the OS knows the app is done
    /// processing background events.
    public func attach(backgroundCompletionHandler: @escaping () -> Void) {
        self.backgroundCompletionHandler = backgroundCompletionHandler
    }

    // MARK: - Start/cancel

    public func startDownload(guid: String, url: URL) async throws {
        if activeTasks[guid] != nil { return } // already downloading, no-op
        let task = session.downloadTask(with: url)
        task.taskDescription = guid
        activeTasks[guid] = task
        task.resume()
    }

    public func cancelDownload(guid: String) async {
        guard let task = activeTasks[guid] else { return }
        activeTasks[guid] = nil
        task.cancel(byProducingResumeData: { [weak self] data in
            guard let data else { return }
            Task { await self?.storeResumeData(guid: guid, data: data) }
        })
    }

    private func storeResumeData(guid: String, data: Data) {
        // Stored as low-cost insurance for a possible future "resume"
        // feature; not required to auto-resume in v1 (spec §8.2) — a plain
        // re-tap of the download button starting a fresh `startDownload`
        // is sufficient.
        resumeData[guid] = data
    }

    // MARK: - Delegate -> CatalogService bridging

    private func reportProgress(taskDescription: String?, progress: Double) async {
        guard let guid = taskDescription else { return }
        await catalogService?.applyDownloadProgress(guid: guid, progress: progress)
    }

    private func finishDownload(taskDescription: String?, tempFile: URL) async {
        guard let guid = taskDescription else {
            try? FileManager.default.removeItem(at: tempFile)
            return
        }
        activeTasks[guid] = nil
        await catalogService?.applyDownloadSuccess(guid: guid, tempFileURL: tempFile)
    }

    private func failDownload(taskDescription: String?, error: Error) async {
        guard let guid = taskDescription else { return }
        activeTasks[guid] = nil
        if let urlError = error as? URLError, urlError.code == .cancelled {
            // Explicit cancellation (removeDownload) already updated state;
            // don't overwrite it with a spurious `.failed`.
            return
        }
        logger.error("Download failed for \(guid, privacy: .public): \(error.localizedDescription, privacy: .public)")
        await catalogService?.applyDownloadFailure(guid: guid, reason: "downloadFailed")
    }

    private func callBackgroundCompletionHandler() {
        backgroundCompletionHandler?()
        backgroundCompletionHandler = nil
    }
}

extension DownloadCoordinator: URLSessionDownloadDelegate {
    nonisolated public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return } // -1 when server omits Content-Length
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        Task { await self.reportProgress(taskDescription: downloadTask.taskDescription, progress: progress) }
    }

    nonisolated public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // CRITICAL: `location` is a temp file the system deletes the
        // instant this method returns. The move off of it must happen
        // synchronously, inline, here — not inside an `await`-suspended
        // `Task` (that closure runs later, by which point `location` is
        // already gone).
        let interim = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.moveItem(at: location, to: interim)
        } catch {
            Task { await self.failDownload(taskDescription: downloadTask.taskDescription, error: error) }
            return
        }
        Task { await self.finishDownload(taskDescription: downloadTask.taskDescription, tempFile: interim) }
    }

    nonisolated public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return } // success path already handled by didFinishDownloadingTo
        Task { await self.failDownload(taskDescription: task.taskDescription, error: error) }
    }
}

extension DownloadCoordinator: URLSessionDelegate {
    nonisolated public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { await self.callBackgroundCompletionHandler() }
    }
}
