// M1 — Lenient RFC 822 (and common variant) date parsing for <pubDate>
import Foundation

public enum RFC822DateParser {
    /// Tries RFC 822 first (the RSS spec's mandated format), then a small
    /// set of fallback formats real-world feeds actually emit. Returns nil
    /// (never throws) if nothing matches — `pubDate` is optional in the model.
    public static func parse(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        for formatter in formatters {
            if let date = formatter.date(from: trimmed) { return date }
        }
        if let date = iso8601Formatter.date(from: trimmed) { return date }
        return nil
    }

    // `Locale(identifier: "en_US_POSIX")` on every formatter is required:
    // without it, parsing "Mon, 06 Sep 2021 08:00:00 GMT" on a device whose
    // system locale isn't English fails to match EEE/MMM symbolic names.
    private static let formatters: [DateFormatter] = {
        let formats = [
            "EEE, dd MMM yyyy HH:mm:ss zzz",
            "EEE, dd MMM yyyy HH:mm:ss Z",
            "dd MMM yyyy HH:mm:ss zzz",
            "EEE, dd MMM yyyy HH:mm zzz",
            "yyyy-MM-dd'T'HH:mm:ssZZZZZ",
            "yyyy-MM-dd'T'HH:mm:ss",
        ]
        return formats.map { fmt in
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.dateFormat = fmt
            df.timeZone = TimeZone(identifier: "UTC")
            return df
        }
    }()

    // Additional ISO 8601 fallback (faster / handles more offset variants
    // than the DateFormatter pattern versions above); the RFC822 formats
    // above remain DateFormatter-based since ISO8601DateFormatter cannot
    // parse weekday/month-name dates.
    private static let iso8601Formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
