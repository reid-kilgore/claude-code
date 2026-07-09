// M3
// Pure, static segmentation algorithm — the architecture §4 "segment a
// display line" rule owner (docs/specs/M3-transcripts.md §4). Converts raw
// feed cues *or* on-device word timings into canonical `NormalizedSegment`s.
// No SwiftData, no Speech import; fully unit-testable.
import Foundation

public enum SegmentNormalizer {

    // MARK: - Constants (§4.1)

    private static let maxSegmentChars = 90
    private static let targetMaxSeconds: TimeInterval = 8.0
    private static let silenceGapBreak: TimeInterval = 2.0

    /// Terminal punctuation set: Latin + common CJK full-width forms (§4.3).
    private static let terminalPunctuation: Set<Character> = [".", "!", "?", "…", "。", "！", "？"]
    /// Closing quote/bracket characters absorbed after a confirmed sentence
    /// boundary (§4.3 step 4).
    private static let closingBrackets: Set<Character> = ["\"", "'", "\u{201D}", "\u{2019}", ")"]

    // MARK: - Atoms (§4.2)

    private struct Atom: Sendable {
        var text: String
        var start: TimeInterval
        var end: TimeInterval
        var speaker: String?
        /// Non-nil only for word-path atoms (always exactly 1 element there).
        var words: [RawTranscriptWord]?
        /// True for word-path atoms (framework already embeds spacing);
        /// false for cue-path atoms (normalizer inserts " " when merging).
        var joinsWithoutSpace: Bool
    }

    /// Opaque streaming state carried by the caller across
    /// `normalizeIncremental` calls (§4, §6.8's `TranscriptionEngine` is
    /// that caller).
    public struct StreamState: Sendable {
        fileprivate var builder: [Atom] = []
        fileprivate var nextIndex: Int

        /// `nextIndex` defaults to 0 for a fresh stream. A caller resuming
        /// a previously-interrupted on-device transcription (architecture
        /// §11.15) seeds this to `1 + <last persisted segment's index>` so
        /// newly-produced segments continue the same stable ordering key
        /// rather than restarting from 0.
        public init(nextIndex: Int = 0) {
            self.nextIndex = nextIndex
        }
    }

    // MARK: - Public entry points (§4)

    /// One-shot: the whole feed transcript is known up front (§4.5).
    public static func normalize(cues: [RawTranscriptCue]) -> [NormalizedSegment] {
        var atoms: [Atom] = []
        for cue in cues {
            atoms.append(contentsOf: cueAtoms(from: cue))
        }
        // Cues are not guaranteed sorted (§3.2); sort the full atom stream.
        atoms.sort { $0.start < $1.start }

        var builder: [Atom] = []
        var segments: [NormalizedSegment] = []
        var nextIndex = 0
        runMergeCore(
            atoms: atoms,
            builder: &builder,
            segments: &segments,
            nextIndex: &nextIndex,
            forceBreakAtWordSentenceBoundary: false
        )
        // No "streaming tail" concern for the one-shot path: everything is
        // known up-front, so flush whatever's left after the loop.
        flush(&builder, into: &segments, nextIndex: &nextIndex)

        enforceMonotonicity(&segments)
        reindex(&segments)
        return segments
    }

    /// Streaming: on-device transcription arrives in batches (§4.6). Only
    /// returns newly *closed* segments; the open builder stays in `state`.
    public static func normalizeIncremental(
        newWords: [RawTranscriptWord],
        state: inout StreamState
    ) -> [NormalizedSegment] {
        var atoms: [Atom] = []
        for word in newWords {
            atoms.append(contentsOf: wordAtoms(from: word))
        }

        var builder = state.builder
        var segments: [NormalizedSegment] = []
        var nextIndex = state.nextIndex
        runMergeCore(
            atoms: atoms,
            builder: &builder,
            segments: &segments,
            nextIndex: &nextIndex,
            forceBreakAtWordSentenceBoundary: true
        )

        // Do NOT flush the trailing builder here — a sentence may continue
        // into the next batch (§4.6 step 3).
        state.builder = builder
        state.nextIndex = nextIndex
        return segments
    }

    /// Call once when the word stream ends (audio fully consumed) to flush
    /// whatever's left in the open builder as a final segment (§4.6).
    public static func finalizeStream(state: inout StreamState) -> [NormalizedSegment] {
        guard !state.builder.isEmpty else { return [] }
        var builder = state.builder
        var segments: [NormalizedSegment] = []
        var nextIndex = state.nextIndex
        flush(&builder, into: &segments, nextIndex: &nextIndex)
        state.builder = builder
        state.nextIndex = nextIndex
        return segments
    }

    // MARK: - Merge / force-break core (§4.4)

    private static func runMergeCore(
        atoms: [Atom],
        builder: inout [Atom],
        segments: inout [NormalizedSegment],
        nextIndex: inout Int,
        forceBreakAtWordSentenceBoundary: Bool
    ) {
        for atom in atoms {
            if builder.isEmpty {
                builder = [asSegmentInitial(atom)]
                flushIfSentenceBoundary(&builder, into: &segments, nextIndex: &nextIndex, atom: atom, enabled: forceBreakAtWordSentenceBoundary)
                continue
            }

            guard let last = builder.last, let firstInBuilder = builder.first else {
                // Unreachable (builder just failed the isEmpty check above),
                // but keeps this function free of force-unwraps.
                builder = [asSegmentInitial(atom)]
                continue
            }

            let gap = atom.start - last.end
            let speakerChanged = last.speaker != nil && atom.speaker != nil && last.speaker != atom.speaker
            let forcedBreak = speakerChanged || gap >= silenceGapBreak

            if forcedBreak {
                flush(&builder, into: &segments, nextIndex: &nextIndex)
                builder = [asSegmentInitial(atom)]
                flushIfSentenceBoundary(&builder, into: &segments, nextIndex: &nextIndex, atom: atom, enabled: forceBreakAtWordSentenceBoundary)
                continue
            }

            let candidate = builder + [atom]
            let candidateLen = candidateText(candidate).utf16.count
            let candidateDuration = atom.end - firstInBuilder.start

            if candidateLen <= maxSegmentChars && candidateDuration <= targetMaxSeconds {
                builder = candidate
            } else {
                flush(&builder, into: &segments, nextIndex: &nextIndex)
                builder = [asSegmentInitial(atom)]
            }

            flushIfSentenceBoundary(&builder, into: &segments, nextIndex: &nextIndex, atom: atom, enabled: forceBreakAtWordSentenceBoundary)
        }
    }

    /// A word-path atom's `text` naturally embeds a *leading* space (per
    /// §2's "never re-space" contract for `RawTranscriptWord`) whenever it
    /// isn't the very first word of the whole utterance. When such an atom
    /// becomes the first atom of a *new* segment (after a force-break —
    /// §4.8 Example C's segment 2 starts at `"It's"`, not `" It's"`), that
    /// leading space is stray: nothing precedes it in this segment to
    /// justify the separator. Strip it from both the atom's own `text` and
    /// (so `WordTiming.text`/`rangeInSegmentText` still round-trip exactly
    /// against the segment's displayed text) its single backing word.
    /// Cue-path atoms are already individually trimmed at construction
    /// (`cueAtoms`), so this is a no-op for them.
    private static func asSegmentInitial(_ atom: Atom) -> Atom {
        guard atom.joinsWithoutSpace, let firstChar = atom.text.first, firstChar.isWhitespace else {
            return atom
        }
        var adjusted = atom
        adjusted.text = String(atom.text.drop(while: { $0.isWhitespace }))
        if let words = atom.words, words.count == 1 {
            var word = words[0]
            word.text = adjusted.text
            adjusted.words = [word]
        }
        return adjusted
    }

    /// Word-path-only refinement (§4.8 Example C): after appending a word
    /// atom whose trimmed text ends in terminal punctuation, flush
    /// immediately rather than waiting for the char/duration cap. Does NOT
    /// apply to cue-path atoms (Example A explicitly merges multiple
    /// terminally-punctuated cues into one segment) — `enabled` is only
    /// `true` from `normalizeIncremental`.
    private static func flushIfSentenceBoundary(
        _ builder: inout [Atom],
        into segments: inout [NormalizedSegment],
        nextIndex: inout Int,
        atom: Atom,
        enabled: Bool
    ) {
        guard enabled, isWordSentenceBoundary(atom) else { return }
        flush(&builder, into: &segments, nextIndex: &nextIndex)
    }

    private static func isWordSentenceBoundary(_ atom: Atom) -> Bool {
        guard atom.words != nil else { return false }
        let trimmed = atom.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let lastChar = trimmed.last, terminalPunctuation.contains(lastChar) else { return false }
        if lastChar == ".", trimmed.count >= 2 {
            let beforeLastIndex = trimmed.index(trimmed.endIndex, offsetBy: -2)
            // Decimal-number heuristic (§4.3 step 2), one-sided: a per-atom
            // check has no visibility into the *next* atom's leading
            // character, unlike the full sentence splitter used for
            // cue-path atoms below. Documented simplification (M3 report).
            if trimmed[beforeLastIndex].isNumber {
                return false
            }
        }
        return true
    }

    private static func flush(_ builder: inout [Atom], into segments: inout [NormalizedSegment], nextIndex: inout Int) {
        guard !builder.isEmpty else { return }
        segments.append(makeSegment(from: builder, index: nextIndex))
        nextIndex += 1
        builder = []
    }

    private static func candidateText(_ atoms: [Atom]) -> String {
        var result = ""
        for (i, atom) in atoms.enumerated() {
            if i > 0, !atom.joinsWithoutSpace {
                result += " "
            }
            result += atom.text
        }
        return result
    }

    private static func makeSegment(from atoms: [Atom], index: Int) -> NormalizedSegment {
        guard let first = atoms.first, let last = atoms.last else {
            return NormalizedSegment(index: index, startTime: 0, endTime: 0, text: "", wordTimings: [])
        }
        let text = candidateText(atoms)

        var wordTimings: [WordTiming] = []
        var offset = 0
        for (i, atom) in atoms.enumerated() {
            if i > 0, !atom.joinsWithoutSpace {
                offset += 1 // matches the " " candidateText inserts above
            }
            if let words = atom.words {
                for word in words {
                    let wordUTF16Count = word.text.utf16.count
                    let range = offset..<(offset + wordUTF16Count)
                    wordTimings.append(WordTiming(text: word.text, start: word.start, end: word.end, rangeInSegmentText: range))
                    offset += wordUTF16Count
                }
            } else {
                offset += atom.text.utf16.count
            }
        }

        return NormalizedSegment(index: index, startTime: first.start, endTime: last.end, text: text, wordTimings: wordTimings)
    }

    // MARK: - Monotonicity / non-overlap pass (§4.7)

    private static func enforceMonotonicity(_ segments: inout [NormalizedSegment]) {
        guard segments.count > 1 else { return }
        for i in 1..<segments.count {
            if segments[i].startTime < segments[i - 1].endTime {
                segments[i].startTime = segments[i - 1].endTime
                if segments[i].startTime >= segments[i].endTime {
                    segments[i].endTime = segments[i].startTime + 0.01
                }
            }
        }
    }

    private static func reindex(_ segments: inout [NormalizedSegment]) {
        for i in segments.indices {
            segments[i].index = i
        }
    }

    // MARK: - Cue-path atom construction (§4.2, §4.3)

    private static func cueAtoms(from cue: RawTranscriptCue) -> [Atom] {
        let collapsed = TranscriptTextNormalization.collapseWhitespace(cue.text)
        guard !collapsed.isEmpty else { return [] }
        let totalUTF16 = collapsed.utf16.count
        guard totalUTF16 > 0 else { return [] }

        var atoms: [Atom] = []
        for fragment in sentenceFragmentRanges(in: collapsed) {
            let trimmedText = fragment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedText.isEmpty else { continue }
            let fragmentStart = interpolate(cue.start, cue.end, fraction: Double(fragment.range.lowerBound) / Double(totalUTF16))
            let fragmentEnd = interpolate(cue.start, cue.end, fraction: Double(fragment.range.upperBound) / Double(totalUTF16))
            let atom = Atom(text: trimmedText, start: fragmentStart, end: fragmentEnd, speaker: cue.speaker, words: nil, joinsWithoutSpace: false)
            atoms.append(contentsOf: applyLongAtomSplitIfNeeded(atom))
        }
        return atoms
    }

    private static func wordAtoms(from word: RawTranscriptWord) -> [Atom] {
        let atom = Atom(text: word.text, start: word.start, end: word.end, speaker: nil, words: [word], joinsWithoutSpace: true)
        return applyLongAtomSplitIfNeeded(atom)
    }

    private static func interpolate(_ start: TimeInterval, _ end: TimeInterval, fraction: Double) -> TimeInterval {
        start + (end - start) * fraction
    }

    /// Splits `text` into sentence-boundary fragments (§4.3). Returns each
    /// fragment's UTF-16 offset range *within the original, untrimmed
    /// `text`* (needed for §4.2's character-proportional time
    /// interpolation) alongside its raw (untrimmed) substring.
    private static func sentenceFragmentRanges(in text: String) -> [(range: Range<Int>, text: String)] {
        guard !text.isEmpty else { return [] }
        let chars = Array(text)
        var utf16Offsets: [Int] = []
        var running = 0
        for c in chars {
            utf16Offsets.append(running)
            running += String(c).utf16.count
        }
        let totalUTF16 = running

        var boundaryCharIndices: [Int] = []
        var idx = 0
        while idx < chars.count {
            let c = chars[idx]
            guard terminalPunctuation.contains(c) else {
                idx += 1
                continue
            }

            // Collapse a run of consecutive terminal-punctuation chars
            // (e.g. "..." or "?!") into one boundary point (§4.3 step 3).
            var runEnd = idx
            while runEnd + 1 < chars.count, terminalPunctuation.contains(chars[runEnd + 1]) {
                runEnd += 1
            }

            var isBoundaryCandidate = true
            if runEnd == idx, c == "." {
                // Decimal-number heuristic (§4.3 step 2): "3.14" is not a
                // sentence boundary.
                let prevIsDigit = idx > 0 && chars[idx - 1].isNumber
                let nextIsDigit = idx + 1 < chars.count && chars[idx + 1].isNumber
                if prevIsDigit, nextIsDigit {
                    isBoundaryCandidate = false
                }
            }

            if isBoundaryCandidate {
                // Absorb immediately-following closing quote/bracket chars
                // (§4.3 step 4) into the split point.
                var afterIdx = runEnd + 1
                while afterIdx < chars.count, closingBrackets.contains(chars[afterIdx]) {
                    afterIdx += 1
                }
                boundaryCharIndices.append(afterIdx)
                idx = afterIdx
            } else {
                idx = runEnd + 1
            }
        }

        var fragments: [(range: Range<Int>, text: String)] = []
        var startChar = 0
        for boundary in boundaryCharIndices {
            guard boundary > startChar else { continue }
            let fragmentChars = chars[startChar..<boundary]
            let utf16Start = utf16Offsets[startChar]
            let utf16End = boundary < utf16Offsets.count ? utf16Offsets[boundary] : totalUTF16
            fragments.append((utf16Start..<utf16End, String(fragmentChars)))
            startChar = boundary
        }
        if startChar < chars.count {
            let fragmentChars = chars[startChar...]
            let utf16Start = utf16Offsets[startChar]
            fragments.append((utf16Start..<totalUTF16, String(fragmentChars)))
        }

        if fragments.isEmpty {
            fragments.append((0..<totalUTF16, text))
        }
        return fragments
    }

    // MARK: - Long-atom split (§4.4)

    /// If a single incoming atom's own text exceeds `maxSegmentChars`, split
    /// it *before* it ever enters the merge loop, snapping split points to
    /// the nearest whitespace so words are never cut mid-word.
    private static func applyLongAtomSplitIfNeeded(_ atom: Atom) -> [Atom] {
        guard atom.words == nil else {
            // Word-path atoms are always exactly one already-tokenized
            // speech run; a single run being >90 UTF-16 units in practice
            // never happens. Splitting one would also break makeSegment's
            // offset invariant (which assumes atom.text == word.text for
            // word-path atoms), which the spec's §4.4 step 5 "inherits
            // words/joinsWithoutSpace" instruction doesn't actually resolve
            // for the `words` field. Left unsplit; see M3 report deviations.
            return [atom]
        }

        let text = atom.text
        let utf16Count = text.utf16.count
        guard utf16Count > maxSegmentChars else { return [atom] }
        let n = Int((Double(utf16Count) / Double(maxSegmentChars)).rounded(.up))
        guard n > 1 else { return [atom] }

        var offsetToIndex: [Int: String.Index] = [:]
        var positions: [(utf16Offset: Int, isWhitespace: Bool)] = []
        var offset = 0
        var idx = text.startIndex
        while idx < text.endIndex {
            offsetToIndex[offset] = idx
            positions.append((offset, text[idx].isWhitespace))
            offset += String(text[idx]).utf16.count
            idx = text.index(after: idx)
        }
        let total = offset
        offsetToIndex[total] = text.endIndex

        guard total > 0 else { return [atom] }

        var splitPoints: Set<Int> = []
        for k in 1..<n {
            let target = total * k / n
            let snapped = nearestUTF16Offset(among: positions, target: target, whitespaceOnly: true)
                ?? nearestUTF16Offset(among: positions, target: target, whitespaceOnly: false)
                ?? target
            if snapped > 0, snapped < total {
                splitPoints.insert(snapped)
            }
        }

        let boundaries = [0] + splitPoints.sorted() + [total]
        guard boundaries.count > 2 else { return [atom] }

        var subAtoms: [Atom] = []
        for i in 0..<(boundaries.count - 1) {
            let c0 = boundaries[i]
            let c1 = boundaries[i + 1]
            guard c1 > c0, let startIndex = offsetToIndex[c0], let endIndex = offsetToIndex[c1] else { continue }
            let rawFragment = text[startIndex..<endIndex]
            let fragmentText = rawFragment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !fragmentText.isEmpty else { continue }

            // Time math uses the RAW (untrimmed) c0/c1 offsets against the
            // original atom's full duration — same character-proportional
            // interpolation as §4.2, applied to this atom's own span.
            let fractionStart = Double(c0) / Double(total)
            let fractionEnd = Double(c1) / Double(total)
            let subStart = interpolate(atom.start, atom.end, fraction: fractionStart)
            let subEnd = interpolate(atom.start, atom.end, fraction: fractionEnd)

            subAtoms.append(Atom(text: fragmentText, start: subStart, end: subEnd, speaker: atom.speaker, words: nil, joinsWithoutSpace: atom.joinsWithoutSpace))
        }
        return subAtoms.isEmpty ? [atom] : subAtoms
    }

    private static func nearestUTF16Offset(
        among positions: [(utf16Offset: Int, isWhitespace: Bool)],
        target: Int,
        whitespaceOnly: Bool
    ) -> Int? {
        var bestOffset: Int?
        var bestDistance = Int.max
        for p in positions where !whitespaceOnly || p.isWhitespace {
            let distance = abs(p.utf16Offset - target)
            if distance < bestDistance {
                bestDistance = distance
                bestOffset = p.utf16Offset
            } else if distance == bestDistance, let currentBest = bestOffset, p.utf16Offset < currentBest {
                bestOffset = p.utf16Offset
            }
        }
        return bestOffset
    }
}
