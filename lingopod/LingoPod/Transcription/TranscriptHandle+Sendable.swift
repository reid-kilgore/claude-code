// M3
// `TranscriptHandle` (`LingoPod/App/Interfaces.swift`, canonical -- not
// edited by M3) is a `@MainActor` class with no declared `Sendable`
// conformance. `TranscriptProvider`/`TranscriptionEngine` are plain
// (non-`@MainActor`) actors per architecture §7 ("Transcription pipeline is
// an actor... posts snapshots to the TranscriptHandle on the main actor")
// that hold, return, and mutate `TranscriptHandle` references exclusively
// through `await`-hopped calls (construction, `.apply(...)`, and property
// reads all cross into its `@MainActor` isolation). Every actual mutation
// is therefore already serialized through the MainActor executor -- the
// real safety property `Sendable` exists to encode -- the compiler just
// can't infer that automatically for a manually-authored class it doesn't
// own. `@unchecked Sendable` documents that invariant explicitly in one
// place instead of every cross-actor call site fighting strict-concurrency
// checking individually. If `Interfaces.swift` is ever amended to declare
// `TranscriptHandle: Sendable` directly, this file becomes redundant and
// can be deleted.
import Foundation

extension TranscriptHandle: @unchecked Sendable {}
