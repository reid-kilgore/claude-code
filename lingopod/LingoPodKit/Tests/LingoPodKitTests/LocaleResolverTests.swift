// M3
// Covers LocaleResolver.normalizeBCP47/resolve (docs/specs/M3-transcripts.md
// §10). Not called out by name in the M3 integration brief's abbreviated
// test-file list, but LocaleResolver.swift is explicitly in the module's
// file map (§1) and its own acceptance criteria (§12) -- included for full
// coverage; doesn't collide with M1's concurrent work (Feeds/, Services/).
import Testing
import Foundation
@testable import LingoPodKit

@Suite("LocaleResolver")
struct LocaleResolverTests {
    @Test func normalizeBCP47Cases() {
        #expect(LocaleResolver.normalizeBCP47("es")?.languageCode?.identifier == "es")
        #expect(LocaleResolver.normalizeBCP47("es-MX")?.languageCode?.identifier == "es")
        #expect(LocaleResolver.normalizeBCP47("es-MX")?.region?.identifier == "MX")
        #expect(LocaleResolver.normalizeBCP47("ES")?.languageCode?.identifier.lowercased() == "es")
        #expect(LocaleResolver.normalizeBCP47("en_US")?.languageCode?.identifier == "en")
        #expect(LocaleResolver.normalizeBCP47("en_US")?.region?.identifier == "US")
        #expect(LocaleResolver.normalizeBCP47("en-us")?.languageCode?.identifier == "en")
        #expect(LocaleResolver.normalizeBCP47("es-419")?.languageCode?.identifier == "es")
        #expect(LocaleResolver.normalizeBCP47("es-419")?.region?.identifier == "419")
        #expect(LocaleResolver.normalizeBCP47("") == nil)
        #expect(LocaleResolver.normalizeBCP47(nil) == nil)
        #expect(LocaleResolver.normalizeBCP47("Spanish") == nil)
    }

    @Test func resolveExactRegionMatchPreferred() {
        let supported = [Locale(identifier: "es-ES"), Locale(identifier: "es-MX"), Locale(identifier: "en-US")]
        let requested = Locale.Language(identifier: "es-MX")
        let resolved = LocaleResolver.resolve(requested: requested, supported: supported)
        #expect(resolved?.language.languageCode?.identifier == "es")
        #expect(resolved?.language.region?.identifier == "MX")
    }

    @Test func resolveFallsBackToLanguageCodeOnlyMatch() {
        let supported = [Locale(identifier: "es-ES"), Locale(identifier: "en-US")]
        // Requested region ("MX") isn't in the supported list, but the
        // language ("es") is -- falls back to the first es-* match.
        let requested = Locale.Language(identifier: "es-MX")
        let resolved = LocaleResolver.resolve(requested: requested, supported: supported)
        #expect(resolved?.language.languageCode?.identifier == "es")
    }

    @Test func resolveReturnsNilWhenNoLanguageCodeMatchExists() {
        let supported = [Locale(identifier: "en-US"), Locale(identifier: "fr-FR")]
        let requested = Locale.Language(identifier: "es")
        #expect(LocaleResolver.resolve(requested: requested, supported: supported) == nil)
    }

    @Test func resolveNoRegionRequestedMatchesFirstLanguageCodeHit() {
        let supported = [Locale(identifier: "es-ES"), Locale(identifier: "es-MX")]
        let requested = Locale.Language(identifier: "es")
        let resolved = LocaleResolver.resolve(requested: requested, supported: supported)
        #expect(resolved?.language.languageCode?.identifier == "es")
    }
}
