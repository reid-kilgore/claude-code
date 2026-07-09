// M1
// Confidence tests for the pure-Swift SHA-256 used to derive stable
// download filenames (`Episode.localAudioRelativePath`, architecture
// §11.9). Not part of this module's own required fixture/test list (spec
// §10.2) -- added as extra insurance since this is hand-written crypto
// code authored without a Swift compiler available to verify it directly;
// the known FIPS 180-4 test vectors below are the actual correctness check.
import Testing
@testable import LingoPodKit

@Suite("EpisodeAudioHasher (SHA-256)")
struct EpisodeAudioHasherTests {
    @Test func knownVectorEmptyString() {
        #expect(EpisodeAudioHasher.sha256Hex("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    @Test func knownVectorAbc() {
        #expect(EpisodeAudioHasher.sha256Hex("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func stableForSameInput() {
        let guid = "https://example.com/feed/episode-123"
        #expect(EpisodeAudioHasher.sha256Hex(guid) == EpisodeAudioHasher.sha256Hex(guid))
    }

    @Test func differsForDifferentInput() {
        #expect(EpisodeAudioHasher.sha256Hex("a") != EpisodeAudioHasher.sha256Hex("b"))
    }

    @Test func producesLowercase64CharHex() {
        let hex = EpisodeAudioHasher.sha256Hex("guid/with slashes and spaces")
        #expect(hex.count == 64)
        #expect(hex.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }

    @Test func relativePathUsesEpisodesPrefixAndHashedGUID() {
        let guid = "tag:example.com,2021:ep1"
        let path = Episode.localAudioRelativePath(forGUID: guid)
        #expect(path == "Episodes/\(EpisodeAudioHasher.sha256Hex(guid))")
    }
}
