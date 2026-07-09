// M5
// Thin seam around Apple's `LanguageAvailability` API (architecture §9)
// so `TranslationService.availability(from:to:)` is unit-testable without
// the real Translation framework. docs/specs/M5-translation.md §5.
import Foundation
import Translation

protocol LanguageAvailabilityChecking: Sendable {
    func status(from source: Locale.Language, to target: Locale.Language) async -> LanguageAvailabilityCheckStatus
}

enum LanguageAvailabilityCheckStatus: Sendable {
    case installed
    case supported
    case unsupported
}

struct LiveLanguageAvailability: LanguageAvailabilityChecking {
    func status(from source: Locale.Language, to target: Locale.Language) async -> LanguageAvailabilityCheckStatus {
        // VERIFY(iOS26): confirm exact type/method name. Documented shape:
        // LanguageAvailability().status(from:to:) async ->
        // LanguageAvailability.Status with cases .installed, .supported,
        // .unsupported.
        let status = await LanguageAvailability().status(from: source, to: target)
        switch status {
        case .installed: return .installed
        case .supported: return .supported
        case .unsupported: return .unsupported
        @unknown default: return .unsupported
        }
    }
}
