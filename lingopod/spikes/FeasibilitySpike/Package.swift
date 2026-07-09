// swift-tools-version: 6.0
// Feasibility spike for LingoPod's two riskiest bets (architecture §11.16):
// on-device timestamped transcription (SpeechAnalyzer/SpeechTranscriber) and
// on-device LLM explanations (FoundationModels). Both frameworks ship on
// macOS 26 too, so this standalone Mac CLI proves them before any iOS code
// in LingoPod/Transcription or LingoPod/Intelligence is trusted.
//
// No third-party dependencies by design (matches architecture §1's
// zero-fetches rule) — arg parsing is hand-rolled in
// Sources/spike/ArgParsing.swift.
import PackageDescription

let package = Package(
    name: "FeasibilitySpike",
    platforms: [
        .macOS("26.0")
    ],
    targets: [
        .executableTarget(
            name: "spike",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
