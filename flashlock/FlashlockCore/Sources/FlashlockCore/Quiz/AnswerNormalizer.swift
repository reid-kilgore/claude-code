import Foundation

/// Normalization applied to both the expected answer and the user's input
/// before typed-answer comparison.
public enum AnswerNormalizer {
    /// Lowercases, strips diacritics, collapses whitespace, and removes
    /// punctuation at word boundaries ("São Paulo!" == "sao paulo").
    public static func normalize(_ text: String) -> String {
        let folded = text
            .folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
        let allowed = folded.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) { return Character(scalar) }
            return " "
        }
        return String(allowed)
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }

    /// Damerau-Levenshtein distance (optimal string alignment variant:
    /// insertions, deletions, substitutions, and adjacent transpositions).
    public static func editDistance(_ a: String, _ b: String) -> Int {
        let s = Array(a), t = Array(b)
        if s.isEmpty { return t.count }
        if t.isEmpty { return s.count }

        var prev2 = [Int](repeating: 0, count: t.count + 1)
        var prev = Array(0...t.count)
        var current = [Int](repeating: 0, count: t.count + 1)

        for i in 1...s.count {
            current[0] = i
            for j in 1...t.count {
                let cost = s[i - 1] == t[j - 1] ? 0 : 1
                current[j] = Swift.min(
                    prev[j] + 1,          // deletion
                    current[j - 1] + 1,   // insertion
                    prev[j - 1] + cost    // substitution
                )
                if i > 1, j > 1, s[i - 1] == t[j - 2], s[i - 2] == t[j - 1] {
                    current[j] = Swift.min(current[j], prev2[j - 2] + cost) // transposition
                }
            }
            (prev2, prev, current) = (prev, current, prev2)
        }
        return prev[t.count]
    }
}
