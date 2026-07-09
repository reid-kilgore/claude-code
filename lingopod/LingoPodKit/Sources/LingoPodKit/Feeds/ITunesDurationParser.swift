// M1 — Parses <itunes:duration>, which is inconsistently formatted across feeds
import Foundation

public enum ITunesDurationParser {
    /// Accepts "HH:MM:SS", "MM:SS", or a bare integer/decimal seconds count
    /// (both "3661" and "3661.5" appear in the wild). Returns nil if the
    /// string doesn't match any of these shapes.
    public static func parse(_ raw: String) -> TimeInterval? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if !trimmed.contains(":") {
            return TimeInterval(trimmed)
        }

        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 || parts.count == 3 else { return nil }
        let numbers = parts.compactMap { Double($0) }
        guard numbers.count == parts.count else { return nil }

        switch numbers.count {
        case 2:
            let (m, s) = (numbers[0], numbers[1])
            guard s < 60, m >= 0 else { return nil }
            return m * 60 + s
        case 3:
            let (h, m, s) = (numbers[0], numbers[1], numbers[2])
            guard m < 60, s < 60, h >= 0 else { return nil }
            return h * 3600 + m * 60 + s
        default:
            return nil
        }
    }
}
