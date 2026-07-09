// M1 — Episode extension: local audio file path resolution
// (architecture §11.9). SwiftData model files themselves are M0-owned
// (architecture §11.1) and not edited here; this is an *extension* in a
// new file, as directed.
//
// Path convention (architecture §11.9, binding): `<Application Support>/
// Episodes/<sha256(guid)>`, no file extension — `AVPlayer`/`AVAudioFile`
// don't strictly require one, and the enclosure's declared MIME type is
// too unreliable across feeds to build a trustworthy extension from.
// `localAudioPath` on the model is the *relative* path (`Episodes/<hash>`)
// because the app's container path changes between installs/updates on
// device; resolving to an absolute URL happens here, at read time, against
// the *current* Application Support directory.
//
// Excluding the `Episodes/` directory from iCloud/Time Machine backup
// (`URLResourceValues.isExcludedFromBackup`) is done once, when the
// directory is created, by the writer (`LingoPod/Services/
// CatalogService.swift`'s download-completion handling) — this file only
// resolves paths, it never creates directories or writes files.
import Foundation

public extension Episode {
    /// Absolute file URL for this episode's downloaded audio, or `nil` if
    /// `localAudioPath` is unset. Does not check whether the file actually
    /// exists on disk — callers that need that should stat it themselves.
    var resolvedLocalAudioURL: URL? {
        guard let localAudioPath else { return nil }
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return base.appendingPathComponent(localAudioPath)
    }

    /// The relative path (`Episodes/<sha256(guid)>`) this episode's audio
    /// file lives at (or would live at once downloaded) — stable for a
    /// given `guid` regardless of enclosure MIME type. Callers that write
    /// the file (`CatalogService`) are responsible for creating the
    /// `Episodes/` directory and excluding it from backup.
    var localAudioRelativePath: String {
        Episode.localAudioRelativePath(forGUID: guid)
    }

    static func localAudioRelativePath(forGUID guid: String) -> String {
        "Episodes/\(EpisodeAudioHasher.sha256Hex(guid))"
    }
}

/// Minimal, dependency-free SHA-256. Architecture §1 forbids third-party
/// dependencies (ruling out the `swift-crypto` package's `Crypto` target),
/// and Apple's `CryptoKit` is Darwin-only while `LingoPodKit` must compile
/// under Linux `swift test` (architecture §1) — so a small pure-Swift
/// implementation lives here instead. Used only to derive a stable,
/// filesystem-safe filename from an arbitrary RSS `guid` string (which may
/// contain `/`, spaces, etc.); not used for anything security-sensitive.
enum EpisodeAudioHasher {
    static func sha256Hex(_ string: String) -> String {
        let digest = sha256(Array(string.utf8))
        return digest.map { byte in
            let hex = String(byte, radix: 16)
            return hex.count == 1 ? "0" + hex : hex
        }.joined()
    }

    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    private static func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 {
        (x >> n) | (x << (32 - n))
    }

    private static func sha256(_ message: [UInt8]) -> [UInt8] {
        var h: [UInt32] = [
            0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
            0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
        ]

        var msg = message
        let bitLength = UInt64(message.count) * 8
        msg.append(0x80)
        while msg.count % 64 != 56 {
            msg.append(0)
        }
        for i in stride(from: 56, through: 0, by: -8) {
            msg.append(UInt8((bitLength >> UInt64(i)) & 0xff))
        }

        for chunkStart in stride(from: 0, to: msg.count, by: 64) {
            var w = [UInt32](repeating: 0, count: 64)
            for i in 0..<16 {
                let base = chunkStart + i * 4
                w[i] = (UInt32(msg[base]) << 24) | (UInt32(msg[base + 1]) << 16)
                    | (UInt32(msg[base + 2]) << 8) | UInt32(msg[base + 3])
            }
            for i in 16..<64 {
                let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }

            var a = h[0], b = h[1], c = h[2], d = h[3]
            var e = h[4], f = h[5], g = h[6], hh = h[7]

            for i in 0..<64 {
                let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch = (e & f) ^ (~e & g)
                let temp1 = hh &+ s1 &+ ch &+ k[i] &+ w[i]
                let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let temp2 = s0 &+ maj

                hh = g
                g = f
                f = e
                e = d &+ temp1
                d = c
                c = b
                b = a
                a = temp1 &+ temp2
            }

            h[0] = h[0] &+ a
            h[1] = h[1] &+ b
            h[2] = h[2] &+ c
            h[3] = h[3] &+ d
            h[4] = h[4] &+ e
            h[5] = h[5] &+ f
            h[6] = h[6] &+ g
            h[7] = h[7] &+ hh
        }

        var digest = [UInt8]()
        digest.reserveCapacity(32)
        for value in h {
            digest.append(UInt8((value >> 24) & 0xff))
            digest.append(UInt8((value >> 16) & 0xff))
            digest.append(UInt8((value >> 8) & 0xff))
            digest.append(UInt8(value & 0xff))
        }
        return digest
    }
}
