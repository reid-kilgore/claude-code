// M1 — RSS/Podcasting-2.0 feed parser using Foundation.XMLParser
// Pure value types only; no SwiftData here (spec §4). `Foundation.XMLParser`
// works identically on Linux and Darwin, which is what lets `swift test`
// for `LingoPodKit` run in this repo's Linux authoring environment
// (architecture §1).
import Foundation

public enum FeedParserError: Error, Sendable, Equatable {
    case noChannelElement
    case xmlSyntaxError(String)
    case emptyData
}

public struct FeedParser: Sendable {
    public init() {}

    public func parse(data: Data) throws -> ParsedFeed {
        guard !data.isEmpty else { throw FeedParserError.emptyData }
        let delegate = FeedParserDelegate()
        let xmlParser = XMLParser(data: data)
        xmlParser.delegate = delegate
        // Namespace handling decision: prefix matching, not URI-aware
        // parsing. Real-world podcast feeds are inconsistent about
        // declaring `xmlns:itunes`/`xmlns:podcast` correctly, so
        // `shouldProcessNamespaces = true` makes namespace resolution
        // unreliable across feeds. With this set to `false`, `elementName`
        // in delegate callbacks is the raw tag as written (e.g.
        // "itunes:author", "podcast:transcript"), matched by plain string
        // comparison — simpler and more robust against the inconsistent-
        // declaration problem. Accepted downside: a feed using a
        // nonstandard prefix for the Podcasting 2.0 namespace (e.g.
        // `<pc:transcript>`) is missed; rare enough to accept for v1.
        xmlParser.shouldProcessNamespaces = false
        guard xmlParser.parse() else {
            if let error = xmlParser.parserError {
                throw FeedParserError.xmlSyntaxError(error.localizedDescription)
            }
            throw FeedParserError.xmlSyntaxError("unknown XMLParser failure")
        }
        guard let feed = delegate.result else { throw FeedParserError.noChannelElement }
        return feed
    }
}

/// Stateful/mutable XMLParser delegate. Created fresh per `parse(data:)`
/// call and never escapes that call, so it does not need to be `Sendable`
/// (and cannot be, given its mutable state) — this is why `FeedParser`
/// itself (the `Sendable` public type) is a stateless struct that merely
/// constructs one of these per call.
private final class FeedParserDelegate: NSObject, XMLParserDelegate {
    // Element-path stack, so `<title>` inside `<channel>` (feed title) is
    // distinguished from `<title>` inside `<item>` (episode title), and so
    // `<image><url>` can be recognized as nested under channel-level `<image>`.
    private var elementStack: [String] = []
    private var currentText = ""

    private var channelTitle = ""
    private var channelDescription: String?
    private var channelLanguage: String?
    private var channelAuthor: String?
    private var channelManagingEditor: String?
    private var channelImageURL: URL?
    private var items: [ParsedItem] = []

    private var insideItem = false
    private var currentGUID = ""
    private var currentItemTitle = ""
    private var currentItemDescription: String?
    private var currentItemSummary: String?
    private var currentPublishedAt: Date?
    private var currentDurationSeconds: TimeInterval?
    private var currentEnclosureURL: URL?
    private var currentEnclosureType: String?
    private var currentTranscripts: [ParsedTranscriptRef] = []

    private(set) var result: ParsedFeed?

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        currentText = ""
        elementStack.append(elementName)

        switch elementName {
        case "item":
            insideItem = true
            currentGUID = ""
            currentItemTitle = ""
            currentItemDescription = nil
            currentItemSummary = nil
            currentPublishedAt = nil
            currentDurationSeconds = nil
            currentEnclosureURL = nil
            currentEnclosureType = nil
            currentTranscripts = []

        case "itunes:image":
            // Self-closing, href attribute, no children. Higher priority
            // than <image><url> (usually higher-res) — only fill if unset.
            if channelImageURL == nil, let href = attributeDict["href"], let url = URL(string: href) {
                channelImageURL = url
            }

        case "enclosure":
            if insideItem {
                if let urlString = attributeDict["url"] {
                    currentEnclosureURL = URL(string: urlString)
                }
                currentEnclosureType = attributeDict["type"]
            }

        case "podcast:transcript":
            // Malformed entries (missing url or type) are silently skipped,
            // not fatal.
            if insideItem,
               let urlString = attributeDict["url"], let url = URL(string: urlString),
               let type = attributeDict["type"], !type.isEmpty {
                currentTranscripts.append(ParsedTranscriptRef(url: url, type: type))
            }

        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        // XMLParser can call this multiple times for one text node (e.g.
        // across CDATA boundaries or buffer splits) — always append, never
        // overwrite.
        currentText += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        // `<description><![CDATA[...]]></description>` is common in podcast
        // feeds; XMLParser calls this instead of/in addition to
        // `foundCharacters` for CDATA blocks.
        if let string = String(data: CDATABlock, encoding: .utf8) {
            currentText += string
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        defer {
            if !elementStack.isEmpty { elementStack.removeLast() }
        }

        switch elementName {
        case "title":
            if insideItem {
                currentItemTitle = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                channelTitle = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            }

        case "description":
            let stripped = HTMLStripper.strip(currentText)
            if insideItem {
                currentItemDescription = stripped.isEmpty ? nil : stripped
            } else {
                channelDescription = stripped.isEmpty ? nil : stripped
            }

        case "itunes:summary":
            if insideItem {
                let stripped = HTMLStripper.strip(currentText)
                currentItemSummary = stripped.isEmpty ? nil : stripped
            }

        case "language":
            if !insideItem {
                let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                channelLanguage = trimmed.isEmpty ? nil : trimmed
            }

        case "itunes:author":
            // First-write-wins: don't let a later, possibly-duplicate
            // element overwrite an already-set value.
            if !insideItem, channelAuthor == nil {
                let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { channelAuthor = trimmed }
            }

        case "managingEditor":
            if !insideItem, channelManagingEditor == nil {
                let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { channelManagingEditor = trimmed }
            }

        case "url":
            // Only meaningful when nested `<image><url>` at channel level.
            // At this point (before the `defer` pop) `elementStack.last`
            // is still "url"; its parent is one below that.
            if !insideItem, channelImageURL == nil,
               elementStack.count >= 2, elementStack[elementStack.count - 2] == "image" {
                let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { channelImageURL = URL(string: trimmed) }
            }

        case "guid":
            if insideItem {
                currentGUID = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            }

        case "pubDate":
            if insideItem {
                currentPublishedAt = RFC822DateParser.parse(currentText)
            }

        case "itunes:duration":
            if insideItem {
                currentDurationSeconds = ITunesDurationParser.parse(currentText)
            }

        case "item":
            let item = ParsedItem(
                guid: currentGUID,
                title: currentItemTitle,
                // Prefer <description>; <itunes:summary> is only a fallback
                // (spec §4.3's item table), applied here at item-end.
                description: currentItemDescription ?? currentItemSummary,
                publishedAt: currentPublishedAt,
                durationSeconds: currentDurationSeconds,
                enclosureURL: currentEnclosureURL,
                enclosureType: currentEnclosureType,
                transcripts: currentTranscripts
            )
            items.append(item)
            insideItem = false

        case "channel":
            // Set on </channel> close, since that's guaranteed present in
            // valid RSS (more robust than waiting for </rss>).
            result = ParsedFeed(
                title: channelTitle,
                description: channelDescription,
                languageCode: channelLanguage,
                // itunes:author wins; managingEditor is the fallback,
                // applied here rather than by overwriting during parsing.
                author: channelAuthor ?? channelManagingEditor,
                imageURL: channelImageURL,
                items: items
            )

        default:
            break
        }
    }
}
