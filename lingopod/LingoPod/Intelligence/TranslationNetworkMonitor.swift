// M5
// Network framework, first-party, no third-party dependency introduced
// (architecture §1). docs/specs/M5-translation.md §5: "hold a single
// NWPathMonitor started at service init, and read its last-known
// currentPath.status == .satisfied" — lets `prepare(from:to:)` fail fast
// with `.downloadRequiresNetwork` without ever touching the Translation
// framework when the device is known offline.
import Foundation
import Network
import os

/// Seam so `TranslationService`'s offline-fast-fail path is unit-testable
/// without a real `NWPathMonitor` (architecture §9).
protocol NetworkReachabilityChecking: Sendable {
    var isSatisfied: Bool { get }
}

/// Thread-safe wrapper: `NWPathMonitor`'s `pathUpdateHandler` fires on an
/// arbitrary background queue, but `isSatisfied` is read synchronously from
/// the main actor (inside `TranslationService.prepare`), so the last-known
/// status is guarded by a lock rather than assumed to already be
/// main-actor-isolated.
final class TranslationNetworkMonitor: NetworkReachabilityChecking, Sendable {
    private let monitor = NWPathMonitor()
    private let lock = OSAllocatedUnfairLock(initialState: false)

    var isSatisfied: Bool {
        lock.withLock { $0 }
    }

    init() {
        let lock = lock
        monitor.pathUpdateHandler = { path in
            lock.withLock { $0 = path.status == .satisfied }
        }
        monitor.start(queue: DispatchQueue(label: "com.lingopod.app.translation.pathmonitor"))
    }

    deinit {
        monitor.cancel()
    }
}
