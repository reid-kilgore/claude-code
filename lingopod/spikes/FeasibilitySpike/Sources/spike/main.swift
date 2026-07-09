// Feasibility spike — entry point / subcommand dispatch.
//
// This CLI exists to prove, on real macOS 26 hardware, the same API surface
// LingoPod's M3 (Transcription) and M6 (Explain) modules will use — see
// docs/01-architecture.md §11.16 and docs/specs/M3-transcripts.md §6 for the
// shapes this mirrors. Each subcommand's framework calls live in exactly one
// file (spike's own version of architecture §9's "framework-touching seams
// stay in one thin file" rule):
//
//   locales           -> LocalesCommand.swift      (Speech)
//   transcribe         -> TranscribeCommand.swift    (Speech, AVFoundation)
//   explain            -> ExplainCommand.swift       (FoundationModels)
//   translate-check    -> TranslateCheckCommand.swift (Translation)
//
// Swift 6 strict concurrency (see Package.swift). Top-level code in
// main.swift is an implicit async context (SE-0343), so subcommands can be
// awaited directly here.
import Foundation

func printUsage() {
    let usage = """
    FeasibilitySpike — LingoPod on-device framework spike (macOS 26)

    USAGE:
      spike locales
      spike transcribe <audio-file> --locale <bcp47> [--start <seconds>]
      spike explain --passage <text> --context <text> [--source es] [--target en]
      spike translate-check [--from es] [--to en]

    See spikes/FeasibilitySpike/README.md for prerequisites, example
    commands, expected output, and the PASS/FAIL rubric mapping each check
    to an app design decision.
    """
    print(usage)
}

let allArguments = Array(CommandLine.arguments.dropFirst())

guard let subcommand = allArguments.first else {
    printUsage()
    exit(64) // EX_USAGE
}

let commandArguments = Array(allArguments.dropFirst())

switch subcommand {
case "locales":
    await LocalesCommand.run(arguments: commandArguments)
case "transcribe":
    await TranscribeCommand.run(arguments: commandArguments)
case "explain":
    await ExplainCommand.run(arguments: commandArguments)
case "translate-check":
    await TranslateCheckCommand.run(arguments: commandArguments)
case "-h", "--help", "help":
    printUsage()
default:
    FileHandle.standardError.write("Unknown subcommand: \(subcommand)\n\n".data(using: .utf8)!)
    printUsage()
    exit(64)
}
