// `spike locales`
//
// Proves the locale-gating step M3's LocaleResolver.resolve(requested:
// supported:) depends on (docs/specs/M3-transcripts.md §5, §7.3 step 4) and
// the asset-already-installed check TranscriptionEngine.ensureAssetsInstalled
// needs (§6.3). All Speech-framework calls for this subcommand live in this
// one file, per the "framework calls stay in one thin file" convention this
// spike borrows from architecture §9.
import Foundation
import Speech

enum LocalesCommand {
    static func run(arguments: [String]) async {
        print("=== SpeechTranscriber.supportedLocales ===")
        // VERIFY(iOS26): confirm this is `static var supportedLocales: [Locale]`
        // (possibly `async`, possibly throwing). M3 spec §7.3 step 4 flags the
        // identical uncertainty verbatim ("static/async property — isolate
        // this one call in a tiny wrapper"). Written to the documented shape.
        let supported = await SpeechTranscriber.supportedLocales
        let supportedSorted = supported.sorted { $0.identifier(.bcp47) < $1.identifier(.bcp47) }
        for locale in supportedSorted {
            print(locale.identifier(.bcp47))
        }
        print("Total supported: \(supported.count)")

        print("")
        print("=== AssetInventory.installedLocales ===")
        // VERIFY(iOS26): M3 §6.3's ensureAssetsInstalled comment names two
        // candidate shapes for the "already installed" check:
        // `AssetInventory.installedLocales.contains(locale)` or
        // `AssetInventory.status(forModules:)`. This spike exercises the
        // former since it's the one that composes with `spike transcribe`'s
        // own asset-check (TranscribeCommand.swift); confirm the exact
        // static member name/async-ness against the SDK on device.
        let installed = await AssetInventory.installedLocales
        if installed.isEmpty {
            print("(none installed)")
        } else {
            for locale in installed.sorted(by: { $0.identifier(.bcp47) < $1.identifier(.bcp47) }) {
                print(locale.identifier(.bcp47))
            }
        }
        print("Total installed: \(installed.count)")

        print("")
        let esLocales = supportedSorted.filter { $0.identifier(.bcp47).hasPrefix("es") }
        print("es-* locales in supportedLocales (validates M3's locale-gating design): \(esLocales.map { $0.identifier(.bcp47) })")
        if esLocales.isEmpty {
            print("WARNING: no es-* locale found — M3's on-device path would report TranscriptFailureCode.unsupportedLocale for every Spanish podcast on this device/OS build.")
        }

        exit(0)
    }
}
