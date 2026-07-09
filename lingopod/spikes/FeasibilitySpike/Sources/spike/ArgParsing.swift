// Deliberately dumb hand-rolled arg parsing — no third-party deps allowed
// (architecture §1), and this CLI's surface is tiny enough that a real
// argument-parsing library would be overkill.
//
// Supported shapes only:
//   - bare positional tokens: `spike transcribe foo.mp3`
//   - `--flag value` pairs: `spike transcribe foo.mp3 --locale es-ES`
//   - bare `--flag` (no following value, or value itself starts with `--`)
//     is recorded as `"true"`.
//
// Known limitation, intentionally not handled: a flag value that itself
// starts with `--` (e.g. `--context "--not actually a flag"`) will be
// mis-parsed as a new flag. Not worth solving for a feasibility spike; quote
// your context text without a leading `--` when invoking `spike explain`.
import Foundation

struct ParsedArguments {
    private(set) var positionals: [String] = []
    private var flags: [String: String] = [:]

    init(_ arguments: [String]) {
        var index = 0
        while index < arguments.count {
            let token = arguments[index]
            if token.hasPrefix("--") {
                let key = String(token.dropFirst(2))
                if index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") {
                    flags[key] = arguments[index + 1]
                    index += 2
                } else {
                    flags[key] = "true"
                    index += 1
                }
            } else {
                positionals.append(token)
                index += 1
            }
        }
    }

    func flag(_ name: String) -> String? {
        flags[name]
    }

    func requireFlag(_ name: String) -> String {
        guard let value = flags[name] else {
            FileHandle.standardError.write("Missing required --\(name)\n".data(using: .utf8)!)
            exit(64) // EX_USAGE
        }
        return value
    }
}
