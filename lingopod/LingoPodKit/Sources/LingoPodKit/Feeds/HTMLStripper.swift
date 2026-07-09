// M1 — Minimal HTML tag stripper for feed descriptions
// Descriptions in podcast feeds are frequently HTML (`<p>`, `<a href>`,
// `<br>`, entities). Deliberately not a full HTML parser and not
// `NSAttributedString(data:options:[.documentType: .html])` (UIKit/AppKit-
// adjacent, unavailable cleanly cross-platform) — this must compile and run
// under Linux `swift test` per architecture §1.
import Foundation

public enum HTMLStripper {
    /// Removes tags, decodes a small set of common HTML entities, collapses
    /// whitespace. Not a full HTML parser — good enough for podcast blurb
    /// text. Numeric entities (`&#233;` etc.) are intentionally not handled
    /// — rare enough in practice to accept as a v1 gap.
    public static func strip(_ input: String) -> String {
        var result = ""
        result.reserveCapacity(input.count)
        var inTag = false
        for char in input {
            if char == "<" { inTag = true; continue }
            if char == ">" { inTag = false; continue }
            if !inTag { result.append(char) }
        }
        result = decodeEntities(result)
        let collapsed = result
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed
    }

    private static func decodeEntities(_ s: String) -> String {
        let map: [String: String] = [
            "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
            "&#39;": "'", "&apos;": "'", "&nbsp;": " ",
        ]
        var out = s
        for (entity, replacement) in map {
            out = out.replacingOccurrences(of: entity, with: replacement)
        }
        return out
    }
}
