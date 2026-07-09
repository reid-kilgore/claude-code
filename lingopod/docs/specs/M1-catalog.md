# M1 — Catalog: search, RSS ingestion, subscriptions, downloads

Status: spec for implementation. Binding contract: `docs/00-product-overview.md`
and `docs/01-architecture.md` (hereafter "the architecture doc"). This spec
adds detail; it does not and may not contradict the architecture doc. Where
this spec makes a placement or naming decision the architecture doc left
open, that decision is called out explicitly in **§0 Decisions**.

Depends on: M0 (project scaffolding: `project.yml`, app target skeleton,
`AppContainer` DI, `LingoPod/App/Interfaces.swift` file existing). If M0 has
not created `LingoPod/App/Interfaces.swift` yet, create it with just the
`CatalogServiceProtocol` block from architecture §5.5 (copy verbatim) — do
not invent other protocols in that file.

---

## 0. Decisions (placement calls this spec is making)

The architecture doc's repository layout (§2) puts RSS/iTunes parsing in
`LingoPodKit/Sources/LingoPodKit/Feeds/` (pure logic, testable with
`swift test`, no SwiftData). It does **not** say where the SwiftData-touching
`CatalogService` (the type implementing `CatalogServiceProtocol`) lives.
Decision for M1:

- **`CatalogService` lives in the app target**, at
  `LingoPod/Services/CatalogService.swift`, as a SwiftData `ModelActor`.
  Rationale: architecture §7 says heavy work / SwiftData batch writes happen
  in `ModelActor`s, and §1 says `LingoPodKit` has "no UIKit/SwiftUI imports"
  — `ModelActor` itself is fine in a Kit package, but `CatalogService` also
  owns a background `URLSession` with a delegate that must update UI-observed
  `@Model` state and needs access to `AppContainer`-provided things (SwiftData
  `ModelContainer` instance configured by M0's app entry point). Keeping it in
  the app target avoids inventing a second DI path into the Kit package.
  `LingoPod/Services/` is a new directory not explicitly listed in
  architecture §2's tree; it is a sibling of `App/`, `Playback/`,
  `Transcription/`, `Intelligence/`, `UI/`. If a future spec needs a
  `Services/` directory too, it should reuse this one, not invent another.
- Parsing (iTunes search decode, RSS/XML decode) stays 100% in
  `LingoPodKit/Sources/LingoPodKit/Feeds/` per §2, and is plain value types
  only (`Sendable` structs), no `@Model` types, so it is usable from
  `swift test` with zero simulator/App dependency.
- SwiftData model files go in `LingoPodKit/Sources/LingoPodKit/Models/` per
  §2 and §4 — `LingoPodKit` **does** import SwiftData (SwiftData has no
  UIKit/SwiftUI dependency; this is consistent with "no UIKit/SwiftUI
  imports").
- UI goes in `LingoPod/UI/Library/` per §2's explicit `UI/Library/ # subscriptions, search, episode lists (M1 UI)` line.

If any implementer disagrees with the `Services/` placement, they must not
silently move it — flag it, because M2 (`PlayerEngineProtocol`) and later
modules will look for `CatalogService` at this path when wiring
`AppContainer`.

---

## 1. File manifest

Create exactly these files (paths relative to repo root
`/home/user/claude-code/lingopod/` unless noted as already existing from M0):

```
LingoPodKit/Sources/LingoPodKit/Models/Podcast.swift
LingoPodKit/Sources/LingoPodKit/Models/Episode.swift
LingoPodKit/Sources/LingoPodKit/Models/Transcript.swift
LingoPodKit/Sources/LingoPodKit/Models/TranscriptSegment.swift
LingoPodKit/Sources/LingoPodKit/Models/WordTiming.swift
LingoPodKit/Sources/LingoPodKit/Models/CacheEntries.swift
LingoPodKit/Sources/LingoPodKit/Models/Enums.swift

LingoPodKit/Sources/LingoPodKit/Feeds/ITunesSearchClient.swift
LingoPodKit/Sources/LingoPodKit/Feeds/PodcastSearchResult.swift
LingoPodKit/Sources/LingoPodKit/Feeds/FeedParser.swift
LingoPodKit/Sources/LingoPodKit/Feeds/ParsedFeed.swift
LingoPodKit/Sources/LingoPodKit/Feeds/HTMLStripper.swift
LingoPodKit/Sources/LingoPodKit/Feeds/RFC822DateParser.swift
LingoPodKit/Sources/LingoPodKit/Feeds/ITunesDurationParser.swift

LingoPodKit/Tests/LingoPodKitTests/Fixtures/feed_with_transcript.xml
LingoPodKit/Tests/LingoPodKitTests/Fixtures/feed_without_transcript.xml
LingoPodKit/Tests/LingoPodKitTests/Fixtures/feed_malformed_dates_and_encoding.xml
LingoPodKit/Tests/LingoPodKitTests/Fixtures/itunes_search_response.json
LingoPodKit/Tests/LingoPodKitTests/FeedParserTests.swift
LingoPodKit/Tests/LingoPodKitTests/ITunesSearchClientTests.swift
LingoPodKit/Tests/LingoPodKitTests/HTMLStripperTests.swift
LingoPodKit/Tests/LingoPodKitTests/ITunesDurationParserTests.swift
LingoPodKit/Tests/LingoPodKitTests/RFC822DateParserTests.swift

LingoPod/Services/CatalogService.swift
LingoPod/Services/DownloadCoordinator.swift

LingoPod/UI/Library/LibraryView.swift
LingoPod/UI/Library/PodcastDetailView.swift
LingoPod/UI/Library/SearchView.swift
LingoPod/UI/Library/PodcastGridItemView.swift
LingoPod/UI/Library/EpisodeRowView.swift
```

`LingoPodKit/Package.swift` and `LingoPod/App/Interfaces.swift` are owned by
M0; M1 only *edits* them (add `CatalogServiceProtocol` if missing from
Interfaces.swift; ensure `Package.swift` declares the
`LingoPodKitTests` test target with a `resources: [.copy("Fixtures")]`
entry so fixture files ship with the test bundle).

Every source file must start with a `// M1` header comment per architecture
§10, e.g. `// M1 — Podcast SwiftData model`.

---

## 2. SwiftData models — copy architecture §4 verbatim

The architecture doc is explicit: "Names below are canonical; specs must use
them verbatim." Implement the five `@Model` classes and the `WordTiming`
struct **exactly** as shown in architecture §4, split across files as below.
Do not rename, reorder, retype, or add properties beyond what's specified
(the enums referenced inline are defined in §2.1 of this spec).

### 2.1 `Enums.swift`

Define these as `Codable`, `Hashable`, `Sendable` enums with `String` raw
values (SwiftData stores enums with primitive `RawRepresentable` raw values
natively when the property type conforms to `Codable`; using `String` raw
values keeps them debuggable in the SwiftData store browser and is safe if a
case is appended later — **never reorder or delete existing cases**, only
append, since SwiftData needs stable storage and a stored raw string survives
schema evolution better than an `Int`).

```swift
// M1 — Shared enums for catalog + transcript models

import Foundation

public enum DownloadState: Codable, Hashable, Sendable {
    case none
    case inProgress(progress: Double)   // 0.0...1.0, coarse (rounded to nearest 0.01 before persisting)
    case downloaded
    case failed(reason: String)
}

public enum TranscriptSource: String, Codable, Hashable, Sendable {
    case feed
    case onDevice
}

public enum TranscriptState: Codable, Hashable, Sendable {
    case pending
    case partial
    case complete
    case failed(reason: String)
}
```

Important detail — `DownloadState` and `TranscriptState` are **not** simple
`RawRepresentable` string enums because they carry associated values
(`progress`, `reason`). SwiftData (as of iOS 26) supports storing an enum
with associated values as a model property **only if the enum is `Codable`**
and the property is declared normally (SwiftData will encode it via
`Codable` under the hood, same mechanism used for `[WordTiming]`). Implement
`Codable` conformance for both via the compiler-synthesized conformance
(works automatically for enums with `Codable` associated values in Swift 6 —
no manual `init(from:)`/`encode(to:)` needed as long as every associated
value type is itself `Codable`; `Double` and `String` are). Do not attempt to
make these `RawRepresentable` — a raw-value enum cannot carry an associated
value, and the architecture doc's inline comments (`inProgress(progress
persisted coarse)`, `failed(reason: String)`) require associated values.

If, when this is actually compiled in Xcode 26, `@Model` macro expansion
rejects an associated-value enum for a stored property, the fallback (mark
with `// VERIFY(iOS26):` per architecture §10, do not silently restructure
without leaving the note) is: keep the enum exactly as-is for all in-memory
and cross-module use, and add a **private** shadow stored property on the
`@Model` class that SwiftData persists, with a computed public property doing
the mapping, e.g. on `Episode`:

```swift
// VERIFY(iOS26): if @Model rejects associated-value enums directly, use this shadow-storage pattern instead of the plain `var downloadState: DownloadState` property.
private var downloadStateData: Data = try! JSONEncoder().encode(DownloadState.none)
var downloadState: DownloadState {
    get { (try? JSONDecoder().decode(DownloadState.self, from: downloadStateData)) ?? .none }
    set { downloadStateData = (try? JSONEncoder().encode(newValue)) ?? downloadStateData }
}
```

Write the model file with the plain property first (`var downloadState:
DownloadState`); only apply the shadow-storage fallback if a build actually
fails, and leave the `// VERIFY(iOS26):` comment either way so the reason is
traceable.

### 2.2 `Podcast.swift`, `Episode.swift`, `Transcript.swift`,
`TranscriptSegment.swift`, `WordTiming.swift`

Copy the corresponding `@Model` class / struct body from architecture §4
verbatim into its own file, `import Foundation` and `import SwiftData` at
the top, `public` access level on the class and every stored property (Kit
types must be usable from the app target), and a `public init(...)` with all
stored properties as parameters (SwiftData `@Model` macro does not
auto-synthesize a memberwise initializer usable outside the file once
`public` is involved — write one explicitly per model, in declaration order,
matching architecture §4's property order). Defaults:

- `Podcast.init`: `subscribedAt: Date = .now`, `lastRefreshedAt: Date? = nil`,
  `episodes: [Episode] = []`.
- `Episode.init`: `downloadState: DownloadState = .none`,
  `playbackPosition: TimeInterval = 0`, `playbackCompleted: Bool = false`,
  `transcript: Transcript? = nil`, `podcast: Podcast? = nil`.
- `Transcript.init`: `state: TranscriptState = .pending`,
  `generatedAt: Date = .now`, `segments: [TranscriptSegment] = []`,
  `episode: Episode? = nil`.
- `TranscriptSegment.init`: `wordTimings: [WordTiming] = []`,
  `transcript: Transcript? = nil`.
- `WordTiming` is a plain `Codable, Hashable, Sendable` struct (not a
  `@Model`) exactly as shown; give it a public memberwise `init`.

M1 only *writes* `Transcript`/`TranscriptSegment`/`WordTiming` — M1 never
*populates* them (that's M3). M1 must still define them here because
`Episode.transcript` references `Transcript` and the whole schema must be
registered together in one `ModelContainer` (see §2.4).

### 2.3 `CacheEntries.swift`

Copy `TranslationCacheEntry` and `ExplanationCacheEntry` verbatim from
architecture §4 into this one file (they are cache tables M1 does not
populate, but the schema must include them from the start — SwiftData
migrations are painful to bolt on later, and other modules assume the whole
schema exists after M1 ships). Give both a public memberwise `init`.

### 2.4 Schema registration

Add a small public helper so app code (M0's `@main`) and tests can build a
consistent `ModelContainer`:

```swift
// M1 — Central SwiftData schema list
import SwiftData

public enum LingoPodSchema {
    public static var models: [any PersistentModel.Type] {
        [Podcast.self, Episode.self, Transcript.self, TranscriptSegment.self,
         TranslationCacheEntry.self, ExplanationCacheEntry.self]
    }
}
```

Put this at the bottom of `CacheEntries.swift` (no new file needed). M0's app
entry constructs `ModelContainer(for: Schema(LingoPodSchema.models), ...)`;
if M0 hasn't done so yet, this spec's implementer should add it to whatever
file M0 created for the `ModelContainer` (search the app target for
`ModelContainer(` before creating a new one).

---

## 3. iTunes Search API client

### 3.1 `PodcastSearchResult.swift`

```swift
// M1 — Value type returned by iTunes Search API, pre-subscribe
import Foundation

public struct PodcastSearchResult: Sendable, Hashable, Identifiable, Decodable {
    public var id: String { feedURL?.absoluteString ?? collectionName + artistName }
    public let collectionName: String      // podcast title
    public let artistName: String          // podcast author/publisher
    public let feedURL: URL?               // nil if iTunes omitted it (rare, but happens) — UI must hide "Subscribe" if nil
    public let artworkURL: URL?            // artworkUrl600, falls back to artworkUrl100
    public let primaryGenreName: String?
}
```

Do not make this `Decodable` by matching JSON keys 1:1 on the struct itself
— the iTunes JSON uses `feedUrl`, `artworkUrl600`, etc. Define a private
wire-format struct and map it, so `PodcastSearchResult`'s field names stay
Swift-idiomatic and stable regardless of iTunes's wire format:

```swift
private struct ITunesSearchResponse: Decodable {
    let resultCount: Int
    let results: [ITunesResult]
}

private struct ITunesResult: Decodable {
    let wrapperType: String?
    let kind: String?
    let collectionName: String?
    let artistName: String?
    let feedUrl: String?
    let artworkUrl600: String?
    let artworkUrl100: String?
    let primaryGenreName: String?
}
```

Mapping rules (in `ITunesSearchClient`, not in the struct's own decoder,
so client-side filtering logic is testable in isolation):

- Only keep results where `wrapperType == "track"` **and** `kind ==
  "podcast"`. iTunes's `/search?media=podcast` endpoint can still return
  non-podcast entries (audiobooks, or `wrapperType == "collection"` items) —
  filter them out.
- `collectionName` and `artistName` missing/empty → drop the result (can't
  display it meaningfully).
- `feedUrl` missing or fails `URL(string:)` → keep the result but with
  `feedURL = nil` (still shown in UI, but Subscribe button disabled — see
  §6.3). Do not drop the whole result just because the feed URL is bad;
  users may still want to see it exists.
- `artworkUrl600` preferred; if absent/empty, fall back to `artworkUrl100`;
  if both absent, `artworkURL = nil`.
- `primaryGenreName` passthrough, nil-safe.

### 3.2 `ITunesSearchClient.swift`

```swift
// M1 — iTunes Search API client
import Foundation

public enum ITunesSearchError: Error, Sendable, Equatable {
    case emptyTerm
    case invalidResponse(statusCode: Int)
    case decodingFailed
    case network(String)   // URLError description, string so the error stays Equatable/Sendable without wrapping URLError
}

public actor ITunesSearchClient {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func search(term: String) async throws -> [PodcastSearchResult] {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ITunesSearchError.emptyTerm }

        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "media", value: "podcast"),
            URLQueryItem(name: "term", value: trimmed),
            URLQueryItem(name: "limit", value: "50"),
        ]
        guard let url = components.url else { throw ITunesSearchError.decodingFailed }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(from: url)
        } catch {
            throw ITunesSearchError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw ITunesSearchError.invalidResponse(statusCode: code)
        }

        // decode wire format, map + filter, see §3.1
    }
}
```

Notes / pitfalls to get right:

- **Use `URLComponents` with `queryItems`, never hand-build the query
  string with string interpolation.** `URLQueryItem` percent-encodes the
  `term` value correctly, including spaces (as `%20`, not iTunes's
  documented-but-legacy `+`), ampersands, non-Latin scripts (target-language
  podcast names — Korean, Japanese, Arabic, etc. — are the primary use case
  here per the product doc's "podcast in their target language"), and
  quote characters. A hand-built `"...term=\(term)"` string will silently
  produce a broken/mismatched search for any term with a space or
  non-ASCII character.
  - Known `URLComponents` pitfall: `percentEncodedQueryItems` vs
    `queryItems` — always use `.queryItems` (plain, unencoded strings) and
    let `URLComponents` do the percent-encoding when you read `.url`; do not
    pre-encode values yourself and assign to `.queryItems`, or you'll get
    double-encoding (e.g. a literal space in the term becomes `%2520`
    instead of `%20`).
- `ITunesSearchClient` is an `actor` (not `@MainActor`) — it does network
  I/O only, no UI state; `Sendable` result types let callers hop back to
  `@MainActor` cheaply.
- No API key / auth needed (public endpoint). Do not add one.
- iTunes Search API is rate-limited (~20 calls/minute per the well-known
  informal limit) and unversioned/undocumented officially — do not add
  retry-with-backoff logic in M1 (out of scope); a plain failure surfaced to
  `SearchView` as an inline error is enough, per architecture §8's "typed
  availability/state enum ... UI renders inline, never alerts" pattern,
  even though this protocol method is a plain `throws` (search failures are
  transient/user-triggered-retry, not "predictable degraded state" — using
  `throws` here matches `CatalogServiceProtocol`'s signature in architecture
  §5.5, which is authoritative and not to be changed by this spec).
- `limit=50` is not in the architecture doc's interface — it's a reasonable
  default this spec is choosing to bound response size / UI list length; not
  user-configurable in v1.

---

## 4. RSS feed parser (`LingoPodKit/Sources/LingoPodKit/Feeds/`)

Pure value types, `Foundation.XMLParser` only (works on Linux and Darwin, no
platform-specific API — this matters because `swift test` for `LingoPodKit`
must run in this repo's Linux authoring environment per architecture §1).
**No SwiftData imports in this file** — `FeedParser` returns `ParsedFeed`;
`CatalogService` (app target) is responsible for turning a `ParsedFeed` into
`Podcast`/`Episode` `@Model` instances.

### 4.1 `ParsedFeed.swift` — output value types

```swift
// M1 — Value types produced by FeedParser; no SwiftData here.
import Foundation

public struct ParsedFeed: Sendable, Equatable {
    public var title: String
    public var description: String?      // <description>, HTML-stripped
    public var languageCode: String?     // <language>, BCP-47/RFC 1766 as given, lowercased+trimmed, nil if absent/empty
    public var author: String?           // <itunes:author>, falls back to <managingEditor> if absent
    public var imageURL: URL?            // <itunes:image href="">, falls back to <image><url>
    public var items: [ParsedItem]       // in feed (document) order — caller decides sort/cap
}

public struct ParsedItem: Sendable, Equatable {
    public var guid: String              // <guid>; if absent/empty, caller must fall back to enclosureURL.absoluteString (FeedParser does NOT do this fallback itself — see §4.6)
    public var title: String
    public var description: String?      // <description> or <itunes:summary>, HTML-stripped
    public var publishedAt: Date?        // <pubDate>, parsed via RFC822DateParser; nil if absent or unparsable
    public var durationSeconds: TimeInterval?  // <itunes:duration>, parsed via ITunesDurationParser
    public var enclosureURL: URL?        // <enclosure url="">; item is unusable as an episode if nil (caller filters these out)
    public var enclosureType: String?    // <enclosure type="">, e.g. "audio/mpeg"
    public var transcripts: [ParsedTranscriptRef]  // <podcast:transcript> entries, in document order
}

public struct ParsedTranscriptRef: Sendable, Equatable {
    public var url: URL
    public var type: String              // MIME type as given, e.g. "application/json", "text/vtt", "application/srt"
}
```

### 4.2 `FeedParser.swift` — parsing approach

```swift
// M1 — RSS/Podcasting-2.0 feed parser using Foundation.XMLParser
import Foundation

public enum FeedParserError: Error, Sendable, Equatable {
    case noChannelElement
    case xmlSyntaxError(String)   // XMLParser's parserError localizedDescription
    case emptyData
}

public struct FeedParser: Sendable {
    public init() {}

    public func parse(data: Data) throws -> ParsedFeed {
        guard !data.isEmpty else { throw FeedParserError.emptyData }
        let delegate = FeedParserDelegate()
        let xmlParser = XMLParser(data: data)
        xmlParser.delegate = delegate
        // shouldProcessNamespaces = false — see namespace handling note below
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
```

**Namespace handling decision: `shouldProcessNamespaces = false` (prefix
matching).** Do not set it to `true`. Reasons:

1. Real-world podcast RSS feeds are inconsistent about declaring namespace
   URIs correctly, and some generators emit `itunes:` / `podcast:` prefixed
   elements without a well-formed `xmlns:itunes="http://www.itunes.com/..."`
   declaration on the root, or declare it with a trailing slash mismatch.
   Namespace-aware parsing (`shouldProcessNamespaces = true`) then fails to
   recognize the element's namespace URI and `didStartElement`'s
   `namespaceURI`/`qualifiedName` split becomes unreliable across feeds.
2. With `shouldProcessNamespaces = false`, `XMLParser` calls
   `parser(_:didStartElement:namespaceURI:qualifiedName:attributes:)` with
   `elementName` equal to the **raw tag as written**, e.g. `"itunes:author"`
   or `"podcast:transcript"` — a plain string. The delegate matches on this
   string directly (`switch elementName { case "itunes:author": ... case
   "podcast:transcript": ... }`). This is simpler and more robust against
   the inconsistent-namespace-declaration problem than resolving URIs.
3. Downside (accepted): a feed that uses a nonstandard prefix for the
   Podcasting 2.0 namespace (e.g. `<pc:transcript>` instead of
   `<podcast:transcript>`) would be missed. This is rare enough in practice
   (the `podcast:` prefix is the documented convention) to accept for v1;
   note it as a known limitation in a code comment, do not build a
   namespace-URI resolution system for it.

### 4.3 `FeedParserDelegate` — element handling (implement as a private class
in `FeedParser.swift`, conforming to `NSObject, XMLParserDelegate`; it is
inherently stateful/mutable so it cannot be the `Sendable` `FeedParser`
struct itself — it's created fresh per `parse(data:)` call and never escapes
that call, so it does not need to be `Sendable`):

State to track:
- `channelDepth: Int` / a simple element-path stack (array of element
  names) so `<title>` inside `<channel>` (feed title) is distinguished from
  `<title>` inside `<item>` (episode title), and `<image><url>` inside
  `<channel>` vs `<itunes:image>` (self-closing, `href` attribute, no
  children) — both feed-level image variants.
- `currentText: String` accumulator, reset in `didStartElement`, appended to
  in `foundCharacters(_:)`, consumed in `didEndElement`.
- `currentItem: ParsedItem?` under construction when inside `<item>`.
- `channelTitle`, `channelDescription`, `channelLanguage`, `channelAuthor`,
  `channelImageURL`, `items: [ParsedItem]` accumulated as channel-level vars.
- `insideItem: Bool` flag.
- `result: ParsedFeed?` set in `didEndElement` for `"channel"` (or
  `"rss"`/document end, whichever is more robust — set it when `</channel>`
  closes, since that's guaranteed present in valid RSS).

Element-by-element behavior:

| Element | Where | Behavior |
|---|---|---|
| `title` | channel-level (not inside `item`) | `channelTitle = currentText` on end |
| `description` | channel-level | `channelDescription = currentText`, HTML-stripped |
| `language` | channel-level | `channelLanguage = currentText.trimmed.lowercased()`, empty→nil |
| `itunes:author` | channel-level | `channelAuthor = currentText` |
| `managingEditor` | channel-level | fallback for `channelAuthor` if `itunes:author` never set (apply fallback at end-of-document, not by overwriting — first-write-wins for itunes:author) |
| `itunes:image` | channel-level, self-closing | in `didStartElement`, read `attributes["href"]`, `channelImageURL = URL(string:)` if not already set from `<image><url>` |
| `image` → `url` | channel-level, nested | on end of inner `url`, `channelImageURL = URL(string: currentText)` if not already set by `itunes:image` (itunes:image takes priority since it's usually higher-res; only fill if nil) |
| `item` | — | `didStartElement`: push new blank `ParsedItem` (empty guid/title, nil others, `transcripts: []`), set `insideItem = true`. `didEndElement`: append to `items`, clear `currentItem`, `insideItem = false` |
| `guid` | inside item | `currentItem.guid = currentText.trimmed` |
| `title` | inside item | `currentItem.title = currentText.trimmed` |
| `description` | inside item | `currentItem.description = HTMLStripper.strip(currentText)`, empty→nil |
| `itunes:summary` | inside item | only use if `description` was empty/absent (apply at item-end, same first-write-wins idea, prefer `description`) |
| `pubDate` | inside item | `currentItem.publishedAt = RFC822DateParser.parse(currentText.trimmed)` |
| `itunes:duration` | inside item | `currentItem.durationSeconds = ITunesDurationParser.parse(currentText.trimmed)` |
| `enclosure` | inside item, self-closing | in `didStartElement`: `currentItem.enclosureURL = URL(string: attributes["url"] ?? "")`, `currentItem.enclosureType = attributes["type"]` |
| `podcast:transcript` | inside item, self-closing | in `didStartElement`: if `attributes["url"]` parses as a `URL` and `attributes["type"]` is non-nil/non-empty, append `ParsedTranscriptRef(url:type:)` to `currentItem.transcripts`. Malformed entries (missing url or type) are silently skipped, not fatal. |

`foundCharacters(_:)` appends to `currentText` unconditionally; because
`XMLParser` can call this multiple times for one text node (e.g. across
CDATA boundaries or buffer splits), always **append**, never overwrite.
`didStartElement` resets `currentText = ""` for every element (harmless for
container elements whose text we never read, like `<channel>` or `<item>`
themselves — they don't reach a matching case in the switch anyway).

CDATA: `<description><![CDATA[...]]></description>` is common in podcast
feeds. `XMLParser` calls `foundCDATA(_:)` (with `Data`, not `String`) instead
of/in addition to `foundCharacters` for CDATA blocks — implement
`parser(_:foundCDATA:)` to decode the `Data` as UTF-8 and append it to
`currentText` the same way, or CDATA-wrapped descriptions will come back
empty.

### 4.4 `HTMLStripper.swift`

Descriptions in podcast feeds are frequently HTML (`<p>`, `<a href>`, `<br>`,
entities). The architecture doc's model comment says `episodeDescription`
is "HTML-stripped" — implement a small, dependency-free stripper (no
`NSAttributedString(data:options:[.documentType: .html])` — that's
UIKit/AppKit-adjacent and slow/unavailable cleanly cross-platform; keep this
pure-Swift so it's usable from Linux `swift test` per architecture §1):

```swift
// M1 — Minimal HTML tag stripper for feed descriptions
import Foundation

public enum HTMLStripper {
    /// Removes tags, decodes a small set of common HTML entities, collapses
    /// whitespace. Not a full HTML parser — good enough for podcast blurb text.
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
        // collapse runs of whitespace/newlines into single spaces, trim ends
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
```

Note: numeric entities (`&#233;` etc.) are **not** handled by this minimal
stripper — acceptable v1 gap (rare in podcast description HTML, which is
almost always simple `<p>`/`<a>`/`<br>` from a CMS). Do not scope-creep into
a full entity table.

Edge case: if `strip` is called on text that was never HTML (plain text
description, no tags), it must be a no-op modulo whitespace collapsing —
verify this in `HTMLStripperTests`.

### 4.5 `RFC822DateParser.swift`

```swift
// M1 — Lenient RFC 822 (and common variant) date parsing for <pubDate>
import Foundation

public enum RFC822DateParser {
    /// Tries RFC 822 first (the RSS spec's mandated format), then a small
    /// set of fallback formats real-world feeds actually emit. Returns nil
    /// (never throws) if nothing matches — pubDate is optional in the model.
    public static func parse(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        for formatter in formatters {
            if let date = formatter.date(from: trimmed) { return date }
        }
        return nil
    }

    private static let formatters: [DateFormatter] = {
        let formats = [
            "EEE, dd MMM yyyy HH:mm:ss zzz",   // RFC 822 with named/numeric TZ, e.g. "Mon, 06 Sep 2021 08:00:00 GMT" or "+0000"
            "EEE, dd MMM yyyy HH:mm:ss Z",     // numeric offset variant, explicit
            "dd MMM yyyy HH:mm:ss zzz",        // missing weekday (some generators omit it)
            "EEE, dd MMM yyyy HH:mm zzz",      // missing seconds
            "yyyy-MM-dd'T'HH:mm:ssZZZZZ",      // ISO 8601 (a few feeds put ISO in pubDate despite the spec)
            "yyyy-MM-dd'T'HH:mm:ss",           // ISO without offset
        ]
        return formats.map { fmt in
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")   // required: weekday/month names are English regardless of device locale
            df.dateFormat = fmt
            df.timeZone = TimeZone(identifier: "UTC")        // used only when the format has no zzz/Z; ignored otherwise since parsed offset wins
            return df
        }
    }()
}
```

Critical detail: `Locale(identifier: "en_US_POSIX")` on every `DateFormatter`
instance — without it, parsing `"Mon, 06 Sep 2021 08:00:00 GMT"` on a device
whose system locale isn't English will fail to match `EEE`/`MMM` symbolic
names. This is a well-known Apple platform gotcha; get it right the first
time.

`ISO8601DateFormatter` is a valid alternative for the ISO fallback formats
specifically (it's faster and handles more offset variants than a
`DateFormatter` pattern) — implementers may add it as an additional fallback
entry, but the primary RFC822 formats must remain `DateFormatter`-based
since `ISO8601DateFormatter` cannot parse RFC 822 weekday/month-name dates.

### 4.6 `ITunesDurationParser.swift`

```swift
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
            return TimeInterval(trimmed)   // bare seconds, integer or decimal; nil if not numeric
        }

        let parts = trimmed.split(separator: ":").map(String.init)
        guard parts.count == 2 || parts.count == 3 else { return nil }
        let numbers = parts.compactMap { Double($0) }
        guard numbers.count == parts.count else { return nil }   // every component must be numeric

        switch numbers.count {
        case 2: // MM:SS
            let (m, s) = (numbers[0], numbers[1])
            guard s < 60 else { return nil }
            return m * 60 + s
        case 3: // HH:MM:SS
            let (h, m, s) = (numbers[0], numbers[1], numbers[2])
            guard m < 60, s < 60 else { return nil }
            return h * 3600 + m * 60 + s
        default:
            return nil
        }
    }
}
```

Edge cases to test: `"00:45"` → 45, `"1:05:00"` (single-digit hour) → 3900,
`"3661"` → 3661, `""` → nil, `"invalid"` → nil, `"25:99"` (invalid seconds
≥60) → nil per the guard, `"1:2:3:4"` (too many components) → nil.

### 4.7 Item-level fallback rules FeedParser does NOT implement itself

Deliberately keep `FeedParser` a dumb, faithful transcription of the XML —
push the *policy* decisions (guid fallback, episode cap, dedup) into
`CatalogService`, so the parser stays a pure "XML in, structured values out"
function with no knowledge of the SwiftData store or business rules. This
also makes `FeedParser` trivially testable against fixtures without a
database. Concretely, `ParsedItem.guid` is emitted **as found in the XML,
possibly empty string** — `FeedParser` does not substitute the enclosure URL
itself. `CatalogService` (§5) is responsible for: guid-empty → enclosure URL
fallback, duplicate-guid handling, 200-episode cap, and dropping items with
no enclosure URL at all (those can't become playable `Episode` rows).

---

## 5. `CatalogService` (app target, `LingoPod/Services/CatalogService.swift`)

### 5.1 Shape

```swift
// M1 — SwiftData-backed implementation of CatalogServiceProtocol
import Foundation
import SwiftData
import LingoPodKit

@ModelActor
public actor CatalogService: CatalogServiceProtocol {
    private let itunesClient: ITunesSearchClient
    private let feedParser: FeedParser
    private let urlSession: URLSession               // plain session for feed fetch (not background)
    private let downloadCoordinator: DownloadCoordinator

    // `@ModelActor` macro synthesizes `modelContext: ModelContext` and an
    // initializer taking `ModelContainer`; extend that initializer to also
    // accept/construct the collaborators above. See §5.2.
}
```

`@ModelActor` (SwiftData) generates an actor-isolated `ModelContext` bound to
a `ModelContainer` passed at init — this is the mechanism architecture §6.5
references ("our write volume ... is fine with batched inserts in a
`ModelActor`"). All SwiftData reads/writes for catalog operations happen on
`self.modelContext` inside this actor; never pass live `@Model` instances
back across the actor boundary (architecture §7) — return `PersistentIdentifier`
or plain value types instead, exactly matching `CatalogServiceProtocol`'s
signatures.

### 5.2 Initialization

```swift
public init(modelContainer: ModelContainer,
            itunesClient: ITunesSearchClient = ITunesSearchClient(),
            feedParser: FeedParser = FeedParser(),
            urlSession: URLSession = .shared,
            downloadCoordinator: DownloadCoordinator) {
    self.modelContainer = modelContainer
    self.modelContext = ModelContext(modelContainer)
    self.itunesClient = itunesClient
    self.feedParser = feedParser
    self.urlSession = urlSession
    self.downloadCoordinator = downloadCoordinator
}
```

(Exact `@ModelActor`-synthesized init signature may differ slightly by SDK
version — if the macro's generated initializer doesn't accept extra
parameters directly, write the memberwise fields manually and call
`self.modelContext = ModelContext(modelContainer)` in a plain (non-macro)
actor conforming to `ModelActor` manually; either approach is acceptable as
long as the actor ends up owning one `ModelContext` created from the
injected `ModelContainer`, per SwiftData's documented pattern. Mark whichever
you pick with `// VERIFY(iOS26):` if the macro's exact generated signature
was guessed rather than confirmed against the SDK.)

`AppContainer` (M0) constructs one `CatalogService` at app launch with the
app's real `ModelContainer` and a real `DownloadCoordinator`, and exposes it
through the environment per architecture §5's "injected via a lightweight
`AppContainer`". M1 does not build `AppContainer` (M0 does) but must expose
`CatalogService`'s initializer in a way M0's container code can call
directly.

### 5.3 `search(term:) async throws -> [PodcastSearchResult]`

Thin passthrough to `itunesClient.search(term:)`. No caching in v1 (search
results are transient UI state). Empty/whitespace-only `term` — let
`ITunesSearchClient` throw `.emptyTerm`; `SearchView` should avoid calling
this for empty input anyway (see §6.3) but the service must not crash if it
does.

### 5.4 `subscribe(feedURL:) async throws -> PersistentIdentifier`

1. **Dedupe check first**: query `modelContext` for an existing `Podcast`
   where `feedURL == feedURL` (fetch with a `#Predicate<Podcast> { $0.feedURL
   == feedURL }`, limit 1). If found, return its `PersistentIdentifier`
   immediately — **do not** re-fetch/re-parse/create a duplicate, and do not
   throw (subscribing to an already-subscribed feed is idempotent success,
   not an error — important because "add by URL" (§6.3) and search-result
   "Subscribe" can race or be tapped twice).
2. Fetch feed bytes: `URLSession.shared.data(from: feedURL)` (or the
   injected `urlSession`). Let `URLSession` follow the default redirect
   policy for up to Foundation's default redirect chain — this handles 30x
   redirects (a common case: feed moved to a new host, e.g. a
   Feedburner/Podbean migration) with zero extra code; do not disable
   redirects. If the final response status is not 2xx, throw
   `CatalogError.feedFetchFailed(statusCode:)` (define `CatalogError` per
   §5.7).
3. **Non-UTF8 encodings**: RSS feeds declare their encoding in the XML
   prolog (`<?xml version="1.0" encoding="ISO-8859-1"?>` etc.), and
   `Foundation.XMLParser` handles this **automatically** when given raw
   `Data` (it reads the prolog itself and transcodes internally) — do
   **not** pre-convert `data` to a `String` with a guessed encoding before
   handing it to `XMLParser`; pass the raw `Data` straight from
   `URLSession` into `FeedParser.parse(data:)`. Converting to `String` first
   and back is the actual pitfall to avoid (it forces a UTF-8 assumption
   before `XMLParser` gets a chance to honor the real declared encoding).
4. `let parsed = try feedParser.parse(data: data)` — propagate
   `FeedParserError` wrapped as `CatalogError.feedParseFailed`.
5. Build the `Podcast`:
   - `feedURL`: the **input** `feedURL` parameter (not a URL derived from
     the final redirected response URL — keep subscribing idempotent/stable
     even if the host later redirects again; refresh (§5.5) always refetches
     from the originally-subscribed `feedURL`).
   - `title`: `parsed.title`, trimmed; if empty, fall back to the feed URL's
     host as a last-resort display string (`feedURL.host ?? "Untitled
     Podcast"`) rather than leaving it blank.
   - `author`: `parsed.author`.
   - `artworkURL`: `parsed.imageURL` — see §7.5 for relative-URL handling.
   - `feedDescription`: `parsed.description`.
   - `languageCode`: `parsed.languageCode`.
   - `languageOverride`: `nil` (user sets this later via podcast settings —
     out of M1 UI scope beyond leaving the field in the model; no UI in M1
     writes it, but the field must exist per architecture §4).
   - `subscribedAt`: `.now`.
   - `lastRefreshedAt`: `.now` (subscribing counts as the first refresh).
6. Build `Episode` rows from `parsed.items` using the **shared episode
   ingestion routine** (§5.6) — subscribe and refresh both funnel through
   the same item→Episode logic so guid-fallback/cap/dedupe rules live in one
   place.
7. Insert `Podcast` (with its `episodes` relationship populated) into
   `modelContext`, `try modelContext.save()`.
8. Return `podcast.persistentModelID`.

### 5.5 `refresh(podcastID:) async throws`

1. Fetch the `Podcast` by `PersistentIdentifier` (`modelContext.model(for:)`
   — if the model no longer exists, e.g. user unsubscribed concurrently,
   throw `CatalogError.podcastNotFound` and return; do not crash).
2. Fetch + parse `podcast.feedURL` exactly as in subscribe steps 2–4.
3. Run the shared episode ingestion routine (§5.6) against
   `podcast.episodes` (existing) and `parsed.items` (incoming) — this is an
   **upsert by guid**, not a wipe-and-reinsert:
   - Existing `Episode` whose `guid` matches an incoming item: update
     `title`, `episodeDescription`, `publishedAt`, `duration`, `audioURL`,
     `feedTranscriptURL`/`feedTranscriptType` (using the transcript-type
     preference order in §5.6) from the incoming data — **do not touch**
     `downloadState`, `localAudioPath`, `playbackPosition`,
     `playbackCompleted`, or `transcript` (playback/download state survives
     a refresh; this is the "keep playback state" requirement).
   - Incoming item whose guid has no existing match: create a new `Episode`
     exactly as in subscribe, insert into `podcast.episodes`.
   - Existing `Episode` whose guid is **not** present in the incoming feed
     at all (episode removed from feed, or fell off the publisher's window):
     **leave it in place, untouched.** Do not delete episodes on refresh —
     a user may have downloaded/be mid-playback on an episode the publisher
     later removed from the feed; deleting local library rows out from under
     active downloads/playback would be destructive and unexpected. (This is
     a deliberate M1 policy choice; record it — see §9 gap list.)
   - Apply the 200-episode cap (§7.3) to the **union** after upsert, by
     `publishedAt` descending (nil `publishedAt` sorts last / least-recent
     for cap purposes) — but never cap-evict an episode that has
     `downloadState != .none` or `playbackPosition > 0` (partially/fully
     played or downloaded episodes are exempt from the cap, since evicting
     them would silently orphan a download or lose progress the user cares
     about). This means the true stored count can exceed 200 when the user
     has many downloaded/in-progress episodes — that's intended.
4. `podcast.lastRefreshedAt = .now`.
5. `try modelContext.save()`.

### 5.6 Shared episode ingestion routine (private helper, not on the
protocol — call it `applyIngestion(items:to:in:)` or similar)

Given `[ParsedItem]` and a target `Podcast`, for each item:

1. **Resolve guid**: `let guid = item.guid.isEmpty ? item.enclosureURL?.absoluteString : item.guid`.
   If **both** are empty/nil (no guid AND no enclosure URL), **drop the
   item entirely** — it cannot be uniquely identified or played. Log via
   `os.Logger` (category matching this module, subsystem
   `com.lingopod.app` per architecture §8) at `.info`, don't throw.
2. If `item.enclosureURL == nil`, drop the item (no audio to play), even if
   guid resolved from something else (shouldn't happen given step 1's logic,
   but guard it explicitly — an item could theoretically have a non-empty
   `<guid>` and no `<enclosure>`, e.g. a text-only blog-post-as-RSS-item
   mixed into a podcast feed by a sloppy generator).
3. **Duplicate guids within the same parse**: if two items in `parsed.items`
   resolve to the same guid (malformed feed), **keep the first occurrence in
   document order, drop subsequent ones** — document order in RSS is
   normally newest-first, so "first" is usually also "newest," which is the
   more useful of two entries to keep; log a `.info` message noting the
   collision.
4. **Transcript URL/type selection** from `item.transcripts`
   (`[ParsedTranscriptRef]`), preference order exactly as specified in scope
   item 3: `application/json` first, then `text/vtt`, then `application/srt`
   or `text/srt` (treat those two as equal preference — pick the first
   matching one encountered in document order), else nil/nil if
   `item.transcripts` is empty or none match a known type. Store only the
   **single** winning `(url, type)` pair into `Episode.feedTranscriptURL` /
   `Episode.feedTranscriptType` — the model has room for exactly one, per
   architecture §4. (M3 owns actually fetching/parsing this URL; M1 only
   selects and stores it.)
5. Build/update the `Episode` fields as described in §5.4 step 6 / §5.5
   step 3.

### 5.7 `CatalogError`

Define in `CatalogService.swift`:

```swift
public enum CatalogError: Error, Sendable {
    case podcastNotFound
    case episodeNotFound
    case feedFetchFailed(statusCode: Int)
    case feedParseFailed(underlying: String)   // FeedParserError description, stringified for Sendable simplicity
    case downloadFailed(underlying: String)
    case fileSystemError(underlying: String)
}
```

### 5.8 `unsubscribe(podcastID:) async throws`

1. Fetch `Podcast` by id; if missing, throw `.podcastNotFound`.
2. For every `episode` in `podcast.episodes` with `localAudioPath != nil`:
   delete the file at that path (§7.1 for path resolution) via
   `FileManager.default.removeItem(at:)`, **swallow (log, don't throw) file-
   not-found errors** — the DB record and the file can drift (e.g. a prior
   failed cleanup); a missing file must not block unsubscribe. Also cancel
   any in-flight download task for that episode via
   `downloadCoordinator.cancelDownload(episodeID:)` (§8.2) before deleting.
3. `modelContext.delete(podcast)` — the `@Relationship(deleteRule: .cascade,
   inverse: \Episode.podcast)` on `Podcast.episodes` (architecture §4)
   cascades to delete all `Episode` rows, which in turn cascade-deletes each
   `Episode.transcript` (and its segments) via the analogous cascade rule.
   Do not manually delete episodes/transcripts one by one — trust the
   cascade, it's specified exactly for this.
4. `try modelContext.save()`.

### 5.9 `download(episodeID:) async throws`

Thin delegate to `DownloadCoordinator` (§8) — `CatalogService` resolves the
`Episode`'s `audioURL` and hands off:

1. Fetch `Episode` by id; if missing, throw `.episodeNotFound`.
2. If `episode.downloadState` is already `.downloaded` or
   `.inProgress`, return early (idempotent no-op) — do not start a second
   download.
3. Set `episode.downloadState = .inProgress(progress: 0)`, save.
4. `try await downloadCoordinator.startDownload(episodeID: episodeID, url: episode.audioURL)`
   — see §8 for the background `URLSession` mechanics. `CatalogService`
   does not block on completion; `startDownload` returns once the task is
   enqueued with the OS. Progress/completion updates flow back into
   `Episode.downloadState` via `DownloadCoordinator`'s callback into this
   actor (§8.3), not via this method's return value.

### 5.10 `removeDownload(episodeID:) async throws`

1. Fetch `Episode`; if missing, throw `.episodeNotFound`.
2. If a download is `.inProgress`, cancel it first
   (`downloadCoordinator.cancelDownload(episodeID:)`).
3. If `episode.localAudioPath != nil`, delete the file (§7.1), swallow
   not-found errors as in unsubscribe.
4. `episode.localAudioPath = nil`, `episode.downloadState = .none`.
   **Do not** reset `playbackPosition`/`playbackCompleted` — removing a
   download is a storage decision, not a "forget my progress" action.
5. `try modelContext.save()`.

---

## 6. UI (`LingoPod/UI/Library/`)

All views `@MainActor` (implicit for SwiftUI `View`s). Read `CatalogService`
from the environment via `AppContainer` (M0's mechanism — assume
`@Environment(AppContainer.self) private var container` or equivalent; if
M0's exact environment-injection pattern differs, follow M0's actual
convention, not a guess — check `LingoPod/App/` for how `AppContainer` is
exposed before writing these views). Use `@Query` for SwiftData reads
wherever the view just needs a live list/object (per this scope item's
instruction) — reserve explicit `CatalogService` calls for actions
(subscribe, refresh, download) and one-shot fetches the protocol doesn't
otherwise expose.

### 6.1 `LibraryView.swift`

- Root tab/screen showing subscribed podcasts as a grid.
- `@Query(sort: \Podcast.subscribedAt, order: .reverse) private var podcasts: [Podcast]`.
- `LazyVGrid` of `PodcastGridItemView` (2 or 3 columns adaptive via
  `GridItem(.adaptive(minimum: 110))`), each navigating to
  `PodcastDetailView(podcast:)` on tap.
- Empty state (`podcasts.isEmpty`): centered message + "Search Podcasts"
  button pushing `SearchView`.
- Pull-to-refresh (`.refreshable { ... }`): iterate all `podcasts`, call
  `await container.catalogService.refresh(podcastID: podcast.persistentModelID)`
  for each, **concurrently** (`withThrowingTaskGroup` or `async let` fan-out,
  bounded — e.g. process in the loop with a `TaskGroup` and no explicit
  bound is fine for realistic library sizes of a few dozen podcasts), and
  collect/log individual failures without aborting the others (one dead feed
  must not block refreshing the rest of the library).
- **Foreground refresh** (scope item 6): this view (or a container above it)
  observes `Scene.scenePhase` (`@Environment(\.scenePhase)`) and triggers the
  same all-podcasts refresh fan-out when phase transitions to `.active` from
  `.background`/`.inactive` — implement with an `.onChange(of: scenePhase)`
  that checks `newValue == .active && oldValue != .active`. Debounce/guard so
  this doesn't also double-fire immediately after a manual pull-to-refresh
  (track a `lastAutoRefreshAt` and skip if < 60s since last refresh of any
  kind — simple in-memory `@State` timestamp is sufficient, no persistence
  needed). No `BGAppRefreshTask`/background-mode refresh in v1, per scope
  item 6 — do not register background tasks in `Info.plist` for this;
  that's explicitly out of scope.
- Toolbar button (magnifying glass) pushing `SearchView`.

### 6.2 `PodcastDetailView.swift`

- Takes a `Podcast` (or its `PersistentIdentifier` + a `@Query` filtered to
  it — prefer passing the live `@Model Podcast` directly from
  `LibraryView`'s `@Query` result, simplest and avoids a redundant fetch).
- Header: artwork (`AsyncImage(url: podcast.artworkURL)` with a placeholder
  `ProgressView` and a fallback SF Symbol like `"waveform"` on failure —
  `AsyncImage`'s phase-based initializer, not the simple URL-only one, so
  failures render something other than a blank box), title, author,
  description (collapsible/truncated with "more" — simple `Text` with
  `.lineLimit(3)` + tap-to-expand `@State` bool is enough for v1, no need
  for a fancy component).
- Episode list: `List` over `podcast.episodes.sorted(by: { ($0.publishedAt
  ?? .distantPast) > ($1.publishedAt ?? .distantPast) })` — `@Model`
  relationship arrays aren't automatically sorted, sort at render time; each
  row is `EpisodeRowView`.
- Row tap (not on the download button) → calls into
  `PlayerEngineProtocol.load(episode:autoplay:)` (M2's protocol, injected via
  `AppContainer` — M1 only needs to call it, not implement it; if M2 isn't
  built yet, guard the call site behind the protocol so it compiles once M2
  lands — do not stub a fake player in M1). Per architecture's
  "auto-download-on-play is M1 behavior" (§6.1), before calling `load`, if
  `episode.downloadState != .downloaded`, trigger
  `catalogService.download(episodeID:)` first (fire-and-forget is fine —
  M2's `load` should be able to stream from `audioURL` directly while a
  parallel download proceeds; M1 does not need to block play on download
  completion — streaming playback of the enclosure URL directly, independent
  of the local download, is a M2-owned concern per architecture §5.1's
  `load(episode:autoplay:)`; M1's job here is just to *also* kick off the
  background download so it's available offline next time, not to gate
  playback on it).
- Toolbar/menu "Unsubscribe" action → confirmation alert → `await
  catalogService.unsubscribe(podcastID:)`, then pop navigation.

### 6.3 `SearchView.swift`

- `@State private var query: String = ""`, bound to a `.searchable(text:)`
  modifier (preferred over a manual `TextField` — gets the standard iOS
  search UX, cancel button, keyboard type for free) or a manual `TextField`
  with a search-styled background if `.searchable` doesn't fit the
  navigation structure chosen by M0 — implementer's call, but debounce
  either way.
- **Debounce**: do not call `catalogService.search(term:)` on every
  keystroke. Use a `Task` cancellation pattern: on each `query` change,
  cancel the previous search `Task`, start a new one that does `try? await
  Task.sleep(for: .milliseconds(400))` then checks
  `Task.isCancelled` before calling `search`. (`.searchable` +
  `.onChange(of: query)` driving this is the simplest wiring; a
  `.task(id: query)` modifier on the results list is an equally valid,
  slightly more idiomatic SwiftUI alternative — either is acceptable, pick
  one.)
- Results: `[PodcastSearchResult]` in `@State`, rendered as a `List` of rows
  (title, author, artwork thumbnail via `AsyncImage`, genre caption). Each
  row has a "Subscribe" button/trailing icon; disabled (grayed, non-
  interactive) when `result.feedURL == nil` (§3.1 case). Tapping Subscribe:
  `let id = try await catalogService.subscribe(feedURL: result.feedURL!)`,
  show a brief inline "Subscribed" state on that row (e.g. swap button for a
  checkmark), do not auto-navigate away (user may want to subscribe to
  several results from one search).
- **Add-by-URL affordance**: a persistent row/section (e.g. above results, or
  a `Section("Add by RSS URL")` with a `TextField` + "Add" button) accepting
  a raw feed URL. On submit: validate with `URL(string:)` (also check
  `url.scheme == "http" || url.scheme == "https"` — reject `file://` and
  friends), then call `catalogService.subscribe(feedURL:)` the same as a
  search-result Subscribe tap. Show an inline error (`Text` in red, not an
  alert per architecture §8's "never alerts" convention) if the URL is
  malformed or `subscribe` throws.
- Loading state while a search is in-flight: `ProgressView` in place of/above
  results. Error state (search threw): inline banner with the error
  description and a manual "Retry" button (re-runs the last query) — again,
  no `.alert`.
- Empty results (search succeeded, zero matches): simple "No podcasts found
  for '<term>'" text.

### 6.4 `PodcastGridItemView.swift` / `EpisodeRowView.swift`

Small presentational subviews:

- `PodcastGridItemView(podcast:)`: `AsyncImage` artwork (square, rounded
  corners, phase-based with placeholder), title (`.lineLimit(2)`) beneath.
  Episode-count/unread badges are explicitly **cut from v1** per scope item
  5 ("optional-cut") — do not implement an unread-tracking mechanism (there
  is no "read/unread" concept anywhere in the architecture §4 model; adding
  one would be inventing schema not in the contract).
- `EpisodeRowView(episode:)`: title, formatted `publishedAt` (relative or
  short date — `Text(date, style: .date)` is sufficient), formatted
  `duration` (`m:ss`/`h:mm:ss` via a small local helper, not
  `ITunesDurationParser` which is Kit-side parse-only), and a trailing
  download-state indicator:
  - `.none` → SF Symbol `"arrow.down.circle"` button, tap triggers
    `catalogService.download(episodeID:)`.
  - `.inProgress(let progress)` → `ProgressView(value: progress)` (small
    circular or linear), tap-to-cancel calls
    `catalogService.removeDownload(episodeID:)` (removeDownload already
    cancels in-flight per §5.10 step 2 — reuse it rather than adding a
    separate cancel-only path).
  - `.downloaded` → filled SF Symbol `"checkmark.circle.fill"`, tap triggers
    `catalogService.removeDownload(episodeID:)` (with a confirmation if you
    want to be safe, not required for v1).
  - `.failed(let reason)` → SF Symbol `"exclamationmark.circle"` in a
    warning color; tap retries (`download(episodeID:)` again); reason
    available as an accessibility label / long-press tooltip, not shown
    inline (keep row compact).

---

## 7. Edge cases (explicit handling required, referenced from sections above)

7.1 **Download file path.** `localAudioPath` is stored as a path **relative
    to** `FileManager.default.urls(for: .applicationSupportDirectory,
    in: .userDomainMask).first!`, under an `Episodes/` subdirectory, filename
    = `"\(episode.guid.hashedFilenameSafe).mp3"` (or the extension implied by
    `enclosureType`/URL path extension when not clearly MP3 — fall back to no
    extension if genuinely unknown, `AVPlayer`/`AVAudioFile` don't strictly
    require one). Guid is not filesystem-safe as-is (may contain `/`, spaces,
    etc.) — hash it (e.g. a stable simple hash, or percent-encode and
    truncate) into a safe filename; store the **relative** path (not
    absolute) in `localAudioPath` because the app's container path changes
    between installs/updates on-device — an absolute path baked in at
    download time would break after an app update. Reconstruct the absolute
    path at read time by joining the stored relative path onto the
    then-current Application Support URL. `Episodes/` directory must be
    created (`FileManager.default.createDirectory(at:withIntermediateDirectories:
    true)`) before first write if it doesn't exist. Set
    `URLResourceValues.isExcludedFromBackup = true` on the `Episodes/`
    directory itself (once, after creating it) — this is enough to exclude
    all files under it from iCloud/iTunes backup; do not set it per-file
    (works but is redundant/wasteful — set once on the directory).

7.2 **Feeds without guid.** Covered in §5.6 step 1 — fall back to
    `enclosureURL.absoluteString`; drop the item if neither is present.

7.3 **Duplicate guids** — within one parse: §5.6 step 3 (first occurrence
    wins). Across subscribe→refresh calls: the upsert-by-guid logic (§5.5)
    naturally treats a repeated guid as "update existing," which is correct
    and is not a duplicate-handling bug, it's the intended upsert semantics.

7.4 **Huge feeds — cap at 200 most-recent episodes.** Apply the cap (§5.5
    step 3) by `publishedAt` descending, exempting downloaded/in-progress/
    played episodes from eviction. On **initial subscribe** (§5.4), the same
    cap applies but there's no existing state to exempt yet — simply take
    the 200 most-recent by `publishedAt` (items with nil `publishedAt` sort
    last, i.e. are the first candidates dropped if the feed has more than
    200 items). If the feed has ≤200 items, no capping occurs, obviously.

7.5 **30x redirects.** Handled for free by `URLSession`'s default
    `HTTPRedirectionHandling` (both for the feed-fetch in §5.4/§5.5 and for
    the background download session in §8) — do not implement custom
    redirect logic. One nuance: `Podcast.feedURL` (the stored, unique key)
    remains the **originally subscribed** URL even if the server responds
    with a redirect on every fetch; do not silently rewrite the stored
    `feedURL` to the redirect target, or a re-subscribe attempt using the
    original URL a user copied from the podcast's website would create a
    second `Podcast` row with the canonical URL as key, defeating the dedupe
    check in §5.4 step 1. (If this is later judged wrong, it's a decision to
    revisit explicitly, not silently patch — see §9.)

7.6 **Non-UTF8 encodings.** Covered in §5.4 step 3 — pass raw `Data` into
    `XMLParser`, never pre-convert to `String`.

7.7 **Relative artwork URLs.** Some feeds emit `<itunes:image href="/art.jpg">`
    or a channel `<image><url>art.jpg</url></image>` relative to the feed's
    own host. `FeedParser` uses plain `URL(string:)` on whatever string is in
    the XML (per §4, it's a dumb transcriber) — this produces a `URL` whose
    `.scheme` is nil for a relative string, which is *not itself an error*
    (`URL(string: "/art.jpg")` succeeds and produces a valid but relative
    `URL` value) but is useless for `AsyncImage`. Resolution happens in
    `CatalogService.subscribe`/`refresh` (§5.4/§5.5), not in `FeedParser`:
    after parsing, if `parsed.imageURL?.scheme == nil`, re-resolve it against
    the feed's URL: `URL(string: parsed.imageURL!.absoluteString, relativeTo: feedURL)?.absoluteURL`.
    Apply the same relative-resolution rule to each `ParsedTranscriptRef.url`
    and to `enclosureURL` for completeness, even though enclosure/transcript
    URLs being relative is rarer than artwork — one shared private helper
    `resolveIfRelative(_ url: URL?, against base: URL) -> URL?` used for all
    three.

7.8 **Malformed dates.** `RFC822DateParser.parse` returns `nil` rather than
    throwing (§4.5) — `ParsedItem.publishedAt` ends up `nil`, which is a
    valid, modeled state (`Episode.publishedAt: Date?` per architecture §4).
    UI (`EpisodeRowView`) must handle a nil `publishedAt` gracefully (e.g.
    omit the date, don't show "Invalid Date" or crash a formatter). Sorting
    (§6.2, §5.5 step 3 cap) treats nil as "oldest"/lowest-priority
    consistently everywhere it's compared, as specified in those sections.

7.9 **Non-2xx / network failure fetching a feed during refresh** (as opposed
    to initial subscribe): do not clear `lastRefreshedAt` or mutate any
    existing episodes — a failed refresh must be a complete no-op on stored
    data other than surfacing the error to the caller (`LibraryView`'s
    fan-out logs/collects it per §6.1). `podcast.lastRefreshedAt` is only
    updated on a *successful* refresh (§5.5 step 4 runs only after steps 1–3
    succeed).

7.10 **Download resume / app termination mid-download.** Covered in §8
     (background `URLSession` with resume-data handling) — not a v1 gap, but
     called out here because it's easy to under-scope: a download must
     survive the app being suspended/terminated by the OS while in progress,
     per "background URLSession" being explicitly named in the protocol's
     comment (architecture §5.5: `download(episodeID:) async throws //
     background URLSession`).

---

## 8. `DownloadCoordinator.swift` (`LingoPod/Services/`)

A separate type from `CatalogService` (not folded into the actor) because
`URLSessionDownloadDelegate` callbacks arrive on an arbitrary background
queue from the system, independent of `CatalogService`'s actor isolation,
and because a background `URLSessionConfiguration` needs a stable, unique
`identifier` string that the app must be able to reconnect to from
`application(_:handleEventsForBackgroundURLSession:completionHandler:)` in
the app delegate/scene delegate (M0 territory) — `DownloadCoordinator` is the
one object that owns that session end-to-end.

### 8.1 Shape

```swift
// M1 — Background URLSession-backed episode download manager
import Foundation
import os

public actor DownloadCoordinator: NSObject {
    public static let backgroundSessionIdentifier = "com.lingopod.app.downloads"

    private var session: URLSession!
    private var activeTasks: [PersistentIdentifier: URLSessionDownloadTask] = [:]
    private var resumeData: [PersistentIdentifier: Data] = [:]
    private weak var catalogService: CatalogService?   // set post-init to break init cycle; see §8.4
    private let logger = Logger(subsystem: "com.lingopod.app", category: "Downloads")

    public override init() {
        super.init()
        let config = URLSessionConfiguration.background(withIdentifier: Self.backgroundSessionIdentifier)
        config.isDiscretionary = false          // user explicitly tapped download; start promptly, don't defer to system-chosen time
        config.sessionSendsLaunchEvents = true
        self.session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    public func attach(catalogService: CatalogService) {
        self.catalogService = catalogService
    }
    // ... see §8.2/§8.3
}
```

Note: `URLSessionDownloadDelegate` methods are declared `nonisolated` on the
actor (required — delegate callbacks aren't actor-isolated by the system;
inside each callback, hop back with `Task { await self.handle...(...) }` to
touch actor state). `DownloadCoordinator: NSObject` is necessary because
`URLSessionDelegate` requires `NSObjectProtocol` conformance — this is one of
the rare, framework-mandated non-SwiftUI Foundation/ObjC-bridging spots
allowed by architecture §1's "SwiftUI only... except where a framework
demands."

### 8.2 `startDownload(episodeID:url:) async throws` / `cancelDownload(episodeID:) async`

- `startDownload`: if `activeTasks[episodeID]` already exists, no-op
  (already downloading). Else: `let task = session.downloadTask(with: url)`,
  `task.taskDescription = episodeID.storableString` (need a stable
  string encoding of `PersistentIdentifier` to correlate a resumed/relaunched
  session's tasks back to episodes after process death — see §8.5),
  `activeTasks[episodeID] = task`, `task.resume()`.
- `cancelDownload`: if there's resumable progress
  (`URLSessionDownloadTask.cancel(byProducingResumeData:)`), store the
  resulting `Data` in `resumeData[episodeID]` for a possible future resume
  (not required to auto-resume in v1 — storing it is low-cost insurance;
  actually offering a "resume" UI action is out of scope, plain re-tap of
  the download button starting a fresh `startDownload` is sufficient for
  v1). Remove from `activeTasks`.

### 8.3 Delegate callbacks → `CatalogService` state updates

```swift
nonisolated public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                                    totalBytesExpectedToWrite: Int64) {
    guard totalBytesExpectedToWrite > 0 else { return }   // -1 when server omits Content-Length; skip progress updates, still fine, final completion still fires
    let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
    Task { await self.reportProgress(taskDescription: downloadTask.taskDescription, progress: progress) }
}

nonisolated public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                    didFinishDownloadingTo location: URL) {
    // location is a temp file that is DELETED as soon as this method returns —
    // must synchronously move it (FileManager, same-thread, before returning)
    // to a stable temp location this delegate owns, THEN hop to the actor to
    // do the final move into Application Support (§7.1) + DB update.
    let interim = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try? FileManager.default.moveItem(at: location, to: interim)
    Task { await self.finishDownload(taskDescription: downloadTask.taskDescription, tempFile: interim) }
}

nonisolated public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    guard let error else { return }   // success path already handled by didFinishDownloadingTo
    Task { await self.failDownload(taskDescription: task.taskDescription, error: error) }
}
```

**Critical, easy-to-miss detail**: `didFinishDownloadingTo location:` hands
you a file at a temporary URL that the system deletes the moment the
delegate method returns — any move off of it must happen synchronously,
inline, in that delegate call, not inside an `await`-suspended `Task` (the
`Task {}` closure runs *later*, asynchronously, by which point `location` is
already gone). The code above handles this correctly by doing the
`FileManager.default.moveItem` call synchronously first, to a self-owned
temp path, and only then dispatching a `Task` for the rest of the (SwiftData-
touching, actor-isolated) work. Get this ordering right — it's the single
most common bug in background-download implementations.

`reportProgress`/`finishDownload`/`failDownload` are `private func`s
isolated to the `DownloadCoordinator` actor that: look up the episode by
decoding `taskDescription` back to a `PersistentIdentifier` (§8.5), then call
into `catalogService` to mutate `Episode.downloadState` (and, for
`finishDownload`, move the file from the interim temp path to its final
`Episodes/` location per §7.1, set `localAudioPath`, set `.downloaded`, save)
— `CatalogService` needs a small internal (non-protocol) method for this,
e.g. `func applyDownloadResult(episodeID:, tempFileURL: URL?, error: String?)
async` — add it to `CatalogService` as an `internal`/non-protocol method
callable by `DownloadCoordinator` within the app target (not part of
`CatalogServiceProtocol`, which architecture §5.5 pins exactly — do not add
to that protocol).

### 8.4 Init-order note

`DownloadCoordinator` and `CatalogService` reference each other
(`CatalogService` holds a `DownloadCoordinator` to start/cancel downloads;
`DownloadCoordinator` needs to call back into `CatalogService` to persist
results) — a `weak var catalogService` set via a post-init `attach(...)` call
(§8.1) breaks the reference cycle / init-ordering chicken-and-egg. `AppContainer`
(M0) is responsible for constructing both and calling `attach` once, at app
launch, before either is used.

### 8.5 Correlating tasks to episodes across process relaunch

`PersistentIdentifier` isn't trivially `String`-convertible out of the box in
a way guaranteed stable across encodes — use a wrapper: store
`episode.guid` (the RSS guid, already unique per architecture §4's
`@Attribute(.unique) var guid: String`) as `task.taskDescription` instead of
trying to serialize `PersistentIdentifier` — it's simpler, stable, and
`CatalogService` can look an `Episode` up by guid via a `#Predicate` fetch
just as easily as by `PersistentIdentifier`. Update §8.2/§8.3 accordingly:
`activeTasks` keyed by `String` (guid), `taskDescription = episode.guid`. On
app relaunch, `application(_:handleEventsForBackgroundURLSession:...)` (M0)
recreates a `URLSession` with the same background identifier, which
automatically reattaches to any still-running/completed background tasks;
`DownloadCoordinator` should implement
`urlSessionDidFinishEvents(forBackgroundURLSession:)` to call the stored
system completion handler (handed to it by M0) so the OS knows the app is
done processing background events — wire this handoff through `attach`-style
injection from M0's app/scene delegate, exact mechanism is M0's call.

---

## 9. Contradictions / gaps in the architecture doc (relevant to M1 — do not
"fix" silently; flagged here per the instruction in this doc's own header
that deviations get recorded, and duplicated in this spec's return summary)

- Architecture §2 does not list a `LingoPod/Services/` directory; this spec
  introduces it to hold `CatalogService`/`DownloadCoordinator` since §2's
  tree has no obvious slot for "app-target service implementing a §5
  protocol, SwiftData-backed." See §0 of this spec for the reasoning.
- Architecture §5.5's `refresh` and `unsubscribe` say nothing about what
  happens to episodes removed from the upstream feed, or to downloaded files
  belonging to episodes that are refreshed-away. This spec chooses
  "never delete an episode on refresh, ever" (§5.5) and "delete downloaded
  files + DB rows only on explicit `unsubscribe`/`removeDownload`" (§5.8,
  §5.10) as the safe default. Flagged as a policy choice this spec is making
  on the architecture doc's behalf, not a verbatim requirement from it.
- Architecture §4's `DownloadState` and `TranscriptState` are enums with
  associated values (`inProgress(progress: Double)`, `failed(reason:
  String)`) stored directly as `@Model` properties; SwiftData's support for
  enums-with-associated-values as stored properties is asserted here to work
  via its `Codable` fallback path, but this spec could not verify this
  against the actual iOS 26 SDK (not available in this authoring
  environment). Flagged with a `// VERIFY(iOS26):` fallback pattern in §2.1.
- Architecture §5.5's `download(episodeID:)` signature is `async throws` but
  conceptually kicks off background work that outlives the call — this spec
  interprets "returns once the download is durably enqueued with the OS,"
  not "returns when the download completes." This reading seems obviously
  intended given "background URLSession" in the same line, but the protocol
  signature alone doesn't make it explicit.

---

## 10. Unit tests (`LingoPodKit/Tests/LingoPodKitTests/`)

### 10.1 Fixtures

- **`feed_with_transcript.xml`** — a well-formed podcast RSS feed, `<channel>`
  with title/description/language(`"en-US"`)/`itunes:author`/`itunes:image`,
  3 `<item>`s. Item 1 has **two** `<podcast:transcript>` tags (one
  `text/vtt`, one `application/json`) to exercise the preference order
  (`application/json` must win). Item 2 has exactly one `<podcast:transcript
  type="application/srt">`. Item 3 has none. All items have `<guid>`,
  `<enclosure url= type="audio/mpeg">`, `<itunes:duration>` in three
  *different* formats across the three items (`"HH:MM:SS"`, `"MM:SS"`, bare
  seconds) to also exercise `ITunesDurationParser` via the full pipeline.
- **`feed_without_transcript.xml`** — well-formed feed, no `podcast:`
  namespace usage anywhere (not even a namespace declaration on `<rss>`),
  5 items, one item **missing** `<guid>` entirely (exercises enclosure-URL
  guid fallback — done at the `CatalogService` level, but the fixture must
  produce a `ParsedItem` with empty `guid` for that test to be meaningful),
  one item with a CDATA-wrapped HTML `<description>` (exercises
  `foundCDATA` + `HTMLStripper` together), one item using `<itunes:summary>`
  instead of `<description>`.
- **`feed_malformed_dates_and_encoding.xml`** — encoding declared as
  `ISO-8859-1` in the XML prolog with at least one non-ASCII Latin-1
  byte in the channel description (e.g. an accented character in raw
  Latin-1, not pre-converted to UTF-8) to exercise §5.4-step-3's non-UTF8
  handling; items with `<pubDate>` values in at least 3 different shapes:
  one valid RFC 822 (`"Mon, 06 Sep 2021 08:00:00 GMT"`), one missing weekday
  (`"06 Sep 2021 08:00:00 GMT"`), one flat-out garbage string (`"not a
  date"`, must parse to `nil` without throwing), one ISO-8601-in-pubDate
  (`"2021-09-06T08:00:00Z"`). Also include one item whose `<itunes:duration>`
  is an invalid shape (`"1:2:3:4"`) to confirm the pipeline tolerates a
  parser returning nil for duration too.
- **`itunes_search_response.json`** — a captured/hand-written iTunes Search
  API JSON response shape with `resultCount` and `results`: include at least
  one `wrapperType: "track", kind: "podcast"` valid entry, one entry with
  `wrapperType: "track", kind: "audiobook"` (must be filtered out), one
  entry missing `feedUrl` (must survive filtering with `feedURL: nil`, not be
  dropped), one entry with only `artworkUrl100` and no `artworkUrl600`
  (exercises the artwork fallback).

### 10.2 Test files

- **`FeedParserTests.swift`**: load each XML fixture (bundle resource via
  `Bundle.module`), call `FeedParser().parse(data:)`, assert on every field
  described above per-fixture (channel-level fields, item count, guid
  presence/absence, transcript preference-order winner per item, duration
  values, CDATA description decoded and HTML-stripped, malformed dates
  resulting in nil not a thrown error, non-UTF8 channel description decoded
  correctly e.g. compare against the expected Swift string literal with the
  accented character). Also a synthetic-`Data` test for
  `FeedParserError.emptyData` (empty `Data()`) and `.xmlSyntaxError`
  (deliberately truncated/invalid XML bytes, e.g. `Data("<rss><channel>".utf8)`
  with no closing tags).
- **`ITunesSearchClientTests.swift`**: cannot hit the live network in CI —
  test the **decoding/filtering logic** in isolation by extracting it into a
  method/free function that takes already-fetched `Data` (or restructure
  `ITunesSearchClient.search` so the HTTP fetch and the decode-and-filter
  step are separately testable — e.g. an internal `static func
  decodeResults(from data: Data) throws -> [PodcastSearchResult]` that
  `search(term:)` calls after fetching; tests call the static function
  directly against `itunes_search_response.json`). Assert: audiobook entry
  filtered out, missing-feedUrl entry present with `feedURL == nil`,
  artwork-100-only entry resolves `artworkURL` to the 100 variant. Also a
  `URLComponents` percent-encoding unit test (no network): build the request
  URL for a term containing a space and a non-ASCII character (e.g. `"café
  radio"`), assert the resulting `URL.absoluteString`'s query contains
  properly percent-encoded output (e.g. contains `%20` or `+`-per-spec and
  `%C3%A9`, not a literal space or raw UTF-8 byte) — this directly guards
  the pitfall called out in §3.2.
- **`HTMLStripperTests.swift`**: plain text passthrough (no tags) is a
  no-op modulo whitespace; `<p>...</p>` paragraphs collapse to
  space-joined text; `<a href="...">text</a>` keeps just `text`; common
  entities (`&amp;`, `&quot;`, `&#39;`, `&nbsp;`) decode correctly; nested/
  malformed tags (`<p><b>bold</p>` unclosed `<b>`) don't crash and produce
  reasonable output (exact reasonable output, not literally correct HTML
  semantics, is fine — assert it doesn't include `<`/`>` characters and
  doesn't throw).
- **`ITunesDurationParserTests.swift`**: table-driven test over the cases
  listed in §4.6 (`"00:45"` → 45, `"1:05:00"` → 3900, `"3661"` → 3661,
  `"3661.5"` → 3661.5, `""` → nil, `"invalid"` → nil, `"25:99"` → nil,
  `"1:2:3:4"` → nil).
- **`RFC822DateParserTests.swift`**: table-driven over the pubDate shapes
  from §10.1's third fixture (all four shapes), plus a round-trip sanity
  check (parse a known RFC822 string, assert the resulting `Date`'s UTC
  components match expected year/month/day/hour/minute/second exactly, not
  just "non-nil") — this guards the `en_US_POSIX` locale requirement (a
  wrong-locale bug would produce `nil`, not a wrong-but-non-nil date, given
  `DateFormatter`'s all-or-nothing symbolic matching, so a non-nil-with-
  correct-components assertion is the meaningful check).

`CatalogService`, `DownloadCoordinator`, and the UI views are **not** unit
tested in `LingoPodKit` (they live in the app target, touch SwiftData
`@Model`/`ModelActor`, `URLSession` background sessions, and SwiftUI — per
architecture §9, these are "constructor-injected... framework-touching seams
... left for on-device verification," covered by the manual script in §11,
not automated tests). If the implementer wants extra confidence, app-target
XCTest/Swift Testing tests using an in-memory `ModelContainer`
(`ModelConfiguration(isStoredInMemoryOnly: true)`) exercising
`CatalogService.subscribe`/`refresh`/`unsubscribe` against the same XML
fixtures (copied or referenced) are a reasonable bonus, but are not required
by this spec and are not part of M1's acceptance bar.

---

## 11. Acceptance criteria

1. `swift test` in `LingoPodKit/` passes with zero failures, including every
   test enumerated in §10.2, runnable on Linux (no Darwin-only API used in
   `Sources/LingoPodKit/Feeds/` or `Models/` — `SwiftData` itself requires
   Darwin for actual persistence, but the parser/value-type code under test
   must not require a live `ModelContainer` to compile or run its tests; if
   `SwiftData` import alone breaks Linux `swift test`, keep parser tests
   isolated from any SwiftData-touching code so the parser test target still
   runs — flag this if it turns out to be a real conflict, since architecture
   §1 promises Linux-runnable `swift test` for "feed parsing").
2. `xcodegen generate` (on a Mac) + build succeeds with `LingoPodKit` and
   `LingoPod` targets both compiling, given M0's `project.yml` includes the
   files listed in §1.
3. Given a real, publicly reachable target-language podcast RSS URL, calling
   `CatalogService.subscribe(feedURL:)` produces exactly one `Podcast` with
   its episodes populated, capped at 200, sorted-recent-first when queried.
4. Calling `subscribe` twice with the same `feedURL` does not create a
   second `Podcast` row (dedupe, §5.4 step 1).
5. `refresh` on a podcast whose feed has new episodes since subscribe adds
   only the new ones and leaves `downloadState`/`playbackPosition` on
   existing episodes untouched (verify by manually setting
   `playbackPosition` on an episode, refreshing, and checking it's
   unchanged).
6. `download(episodeID:)` on a real episode results, eventually, in
   `Episode.downloadState == .downloaded`, `localAudioPath` pointing at a
   file that exists on disk under Application Support/Episodes/, and that
   file surviving app relaunch (simulated by killing/relaunching the app
   during or after the download).
7. `removeDownload` deletes the file and resets state to `.none` without
   touching `playbackPosition`.
8. `unsubscribe` removes the `Podcast`, all its `Episode`/`Transcript`/
   `TranscriptSegment` rows (verify via a fetch returning zero results), and
   all downloaded files for that podcast's episodes from disk.
9. `SearchView` returns results for a plausible search term within a few
   seconds, debounces (verify via a network-call counter/log while typing
   a multi-character term quickly — should not fire once per keystroke),
   and the "Subscribe" flow round-trips into `LibraryView` (subscribed
   podcast appears in the grid without a manual app relaunch — `@Query`
   should update the view automatically since it's SwiftData-observed).
10. Add-by-URL accepts a valid feed URL and rejects (inline error, no crash,
    no alert) a non-URL string and a non-http(s) URL.

## 12. Manual verification script (device/simulator, per architecture §9)

Run on a real device or simulator with network access, after M0 + M1 are
both integrated into a buildable app with at least a minimal shell around
`LibraryView`/`SearchView` (M0's navigation shell hosts these).

1. Launch app cold. Confirm `LibraryView` shows the empty state with a
   "Search Podcasts" button (no prior subscriptions).
2. Tap Search. Type a target-language podcast search term (e.g. "NHK
   ニュース" or "Radio Ambulante" — anything non-trivial/non-ASCII to
   exercise encoding) slowly, letter by letter. Confirm results don't
   flicker/refire on every keystroke (debounce working) and results appear
   within a couple seconds of pausing.
3. Subscribe to one result. Confirm the row shows a subscribed indicator
   without navigating away. Go back to Library — confirm the podcast now
   appears in the grid with artwork loaded.
4. Also use "Add by RSS URL" with a second, different feed's raw URL (find
   one from a podcast's website "RSS" link). Confirm it also lands in the
   Library.
5. Try the URL field with garbage text ("hello") — confirm an inline error,
   not a crash or system alert.
6. Open a subscribed podcast's detail view. Confirm episodes list, sorted
   newest first, with correct-looking titles/durations/dates.
7. Tap the download icon on one episode. Watch the icon transition to a
   progress indicator, then to a checkmark. Force-quit the app mid-download
   on a second episode (before it completes) — relaunch — confirm the
   download either resumes or is left in a sane retryable `.failed`/`.none`
   state (not stuck forever showing progress with no activity).
8. Put the device in Airplane Mode. Relaunch the app. Confirm the downloaded
   episode's row still shows "downloaded" and the file is presumably
   playable (full playback verification is M2's script, but confirm the
   Library/Detail UI doesn't error out or show blank state offline — all
   this data is local SwiftData + local file).
9. Turn Airplane Mode off. Pull-to-refresh the Library. Confirm no crash,
   `lastRefreshedAt`-driven UI (if any) updates, and no duplicate episodes
   appear.
10. Background the app (press home / swipe away without force-quitting),
    wait a few seconds, foreground it again. Confirm a refresh fires
    automatically (check via a breakpoint/log line in the foreground-refresh
    handler, or by having a feed with a genuinely new episode published
    between steps).
11. Unsubscribe from one podcast (with a downloaded episode). Confirm it
    disappears from the Library grid immediately, and — if you have file
    system access (e.g. via Xcode's device file browser on a simulator) —
    confirm the episode's audio file is actually gone from
    Application Support/Episodes/.
12. Subscribe to a podcast with an unusual/older feed (if you can find one)
    that uses relative artwork URLs or non-UTF8 encoding, to spot-check
    §7.6/§7.7 don't produce broken images or garbled text in the UI.
