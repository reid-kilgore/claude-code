// `spike translate-check [--from es --to en]`
//
// Best-effort only. Mirrors the one piece of the Translation framework M5's
// TranslationServiceProtocol.availability(from:to:) (architecture §5.3) can
// reach without a SwiftUI host: `LanguageAvailability.status(from:to:)`.
//
// What this subcommand deliberately does NOT attempt: an actual translation.
// Apple's `TranslationSession` (the type that would run the translation
// itself, or drive an on-device language-pack download) is only obtainable
// through the SwiftUI `.translationTask(_:_:)` view modifier — there is no
// documented headless/programmatic initializer. A macOS CLI with no SwiftUI
// view hierarchy has nothing to attach `.translationTask` to, so the actual
// `translate(_:from:to:)` half of M5's protocol is NOT exercised by this
// spike. See README.md's "translate-check is status-only" section for what
// this means for M5's host-view pattern (architecture §5.3's note that "M5's
// spec defines a host-view pattern that adapts this to the async protocol").
import Foundation
import Translation

enum TranslateCheckCommand {
    static func run(arguments: [String]) async {
        let parsed = ParsedArguments(arguments)
        let fromCode = parsed.flag("from") ?? "es"
        let toCode = parsed.flag("to") ?? "en"

        print("spike translate-check: STATUS-ONLY. This does not perform a translation.")
        print("See README.md for why TranslationSession itself needs a SwiftUI host and")
        print("cannot be driven headlessly from this CLI, and what that implies for M5.")
        print("")
        print("Checking LanguageAvailability.status(from: \(fromCode), to: \(toCode))...")

        let source = Locale.Language(identifier: fromCode)
        let target = Locale.Language(identifier: toCode)

        // VERIFY(iOS26): LanguageAvailability itself is not new in macOS/iOS
        // 26 (available since iOS 17.4 / macOS 14.4) — lower uncertainty
        // than the Speech/FoundationModels calls elsewhere in this spike.
        // Still worth confirming the exact `.status` case names here since
        // M5's spec (not read by this spike) presumably switches over them.
        let availability = LanguageAvailability()
        let status = await availability.status(from: source, to: target)

        switch status {
        case .installed:
            print("status: installed — language pack already on device, ready to translate with no download.")
        case .supported:
            print("status: supported — pair is supported but needs a language-pack download (would happen via .translationTask in a real SwiftUI host).")
        case .unsupported:
            print("status: unsupported — pair not supported at all. This is the trigger condition for M6's translateFallback (architecture §6.2 / M6-explain.md §6).")
        @unknown default:
            print("status: unknown case (@unknown default) — log and treat conservatively as unsupported, matching the pattern M6 §1.2 uses for SystemLanguageModel.Availability's own @unknown default.")
        }

        exit(0)
    }
}
