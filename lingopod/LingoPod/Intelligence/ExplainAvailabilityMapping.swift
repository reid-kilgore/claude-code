// M6
// Maps `SystemLanguageModel.Availability` (FoundationModels) onto the
// canonical `ExplainAvailability` enum. `ExplainAvailability` itself is
// declared once, in `LingoPod/App/Interfaces.swift` (M0-owned, cross-module
// contract — architecture §5.4) and is NOT redeclared here; this file only
// adds the FoundationModels-touching mapping function and user-facing copy,
// per docs/specs/M6-explain.md §0.1's file table ("`ExplainAvailability.swift`
// ... mapping from `SystemLanguageModel.Availability`, user-facing copy").
// Isolating the `FoundationModels` import to this file and
// `ExplainService.swift` keeps M6-explain.md §0.1's "framework calls live in
// one thin file" rule (there are two thin files, per the spec's own table).
//
// DEVIATION (naming only): the M6 spec's own sketch names the copy
// namespace `Copy`. Renamed to `ExplainAvailabilityCopy` here to avoid a
// same-module name collision — `LingoPod/Intelligence/` and
// `LingoPod/Services/` are being populated concurrently by other modules
// (M1/M2/M5), and a bare top-level `Copy` type is exactly the kind of name
// another module might also reach for. No behavioral change, same strings.
import Foundation
import FoundationModels
import os

private let logger = Logger(subsystem: "com.lingopod.app", category: "M6")

// VERIFY(iOS26): confirm exact type/case names —
// SystemLanguageModel.default.availability : SystemLanguageModel.Availability
// enum SystemLanguageModel.Availability {
//   case available
//   case unavailable(UnavailableReason)
// }
// enum SystemLanguageModel.Availability.UnavailableReason {
//   case deviceNotEligible
//   case appleIntelligenceNotEnabled
//   case modelNotReady
//   // possibly more cases in future OS updates
// }
func mapAvailability(_ availability: SystemLanguageModel.Availability) -> ExplainAvailability {
    switch availability {
    case .available:
        return .ready
    case .unavailable(let reason):
        switch reason {
        case .modelNotReady:
            return .modelNotReady
        case .deviceNotEligible:
            return .unavailable(reason: ExplainAvailabilityCopy.deviceNotEligible)
        case .appleIntelligenceNotEnabled:
            return .unavailable(reason: ExplainAvailabilityCopy.appleIntelligenceNotEnabled)
        @unknown default:
            // Log the raw case so we notice new cases show up; never crash
            // on an unrecognized reason (M6-explain.md §1.2).
            logger.warning("Unknown SystemLanguageModel.Availability.UnavailableReason case encountered")
            return .unavailable(reason: ExplainAvailabilityCopy.genericUnavailable)
        }
    }
}

/// User-facing copy for `ExplainAvailability` banners (M6-explain.md §1.3).
/// M4 renders these directly in the inline-banner pattern from architecture
/// §8. Never surfaces the words "source"/"target" (M6-explain.md §0.3).
enum ExplainAvailabilityCopy {
    /// Shown for `.modelNotReady` — no actionable button; expected to
    /// self-resolve.
    static let modelNotReady = "Apple Intelligence is getting ready on this device. Explanations will be available shortly."
    /// Shown for `.unavailable` / `deviceNotEligible` — no actionable button.
    static let deviceNotEligible = "Explain requires Apple Intelligence, which isn't supported on this device."
    /// Shown for `.unavailable` / `appleIntelligenceNotEnabled` — pair with
    /// an "Open Settings" button at the call site
    /// (`UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)`);
    /// M6 does not import UIKit, so the action itself is M4's
    /// responsibility.
    static let appleIntelligenceNotEnabled = "Explain requires Apple Intelligence. Turn it on in Settings to use this feature."
    /// Shown for `.unavailable` / any unknown/future reason — no
    /// actionable button.
    static let genericUnavailable = "Explain isn't available right now."
}
