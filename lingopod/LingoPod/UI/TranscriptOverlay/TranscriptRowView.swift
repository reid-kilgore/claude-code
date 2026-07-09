// M4
// One transcript line (docs/specs/M4-overlay-ui.md §3.1, §6.2, §12).
// `Equatable` on `(segment.id, isCurrent)` only, per §11's performance
// contract — see that conformance below for why closures/tokens are
// intentionally excluded from `==`.
import LingoPodKit
import SwiftUI

struct TranscriptRowView: View, Equatable {
    let segment: TranscriptSegmentSnapshot
    let isCurrent: Bool
    let tokens: [WordToken]
    let dynamicTypeSize: DynamicTypeSize
    let reduceMotion: Bool
    let reduceTransparency: Bool
    let onTapRow: () -> Void
    let onTapToken: (WordTokenID, WordToken) -> Void
    let onLongPressToken: (WordTokenID) -> Void
    let onDragToken: (CGPoint) -> Void
    let onDragEndedToken: () -> Void
    let onTranslateLine: () -> Void

    /// §12: base 28pt, scaled via Dynamic Type, anchored to `.title`.
    @ScaledMetric(relativeTo: .title) private var baseFontSize: CGFloat = 28

    /// Explicit init: a `private` stored property (`baseFontSize`) with a
    /// default value would otherwise demote Swift's auto-synthesized
    /// memberwise initializer to `private` too (Swift's documented access-
    /// control rule for memberwise inits), which would make this type
    /// uncallable from `TranscriptOverlayView.swift`. Writing the init
    /// explicitly sidesteps that entirely; `baseFontSize` still gets its
    /// `= 28` default via the property wrapper's own declaration.
    init(
        segment: TranscriptSegmentSnapshot,
        isCurrent: Bool,
        tokens: [WordToken],
        dynamicTypeSize: DynamicTypeSize,
        reduceMotion: Bool,
        reduceTransparency: Bool,
        onTapRow: @escaping () -> Void,
        onTapToken: @escaping (WordTokenID, WordToken) -> Void,
        onLongPressToken: @escaping (WordTokenID) -> Void,
        onDragToken: @escaping (CGPoint) -> Void,
        onDragEndedToken: @escaping () -> Void,
        onTranslateLine: @escaping () -> Void
    ) {
        self.segment = segment
        self.isCurrent = isCurrent
        self.tokens = tokens
        self.dynamicTypeSize = dynamicTypeSize
        self.reduceMotion = reduceMotion
        self.reduceTransparency = reduceTransparency
        self.onTapRow = onTapRow
        self.onTapToken = onTapToken
        self.onLongPressToken = onLongPressToken
        self.onDragToken = onDragToken
        self.onDragEndedToken = onDragEndedToken
        self.onTranslateLine = onTranslateLine
    }

    /// §11: rows read only an `isCurrent` flag computed once by the parent;
    /// this is what makes `.equatable()` effective — SwiftUI's diffing
    /// skips re-invoking `body` for every row except the (at most two)
    /// whose `isCurrent` actually flipped. Closures are stable references
    /// (freshly-constructed each call, but never meaningfully different)
    /// and deliberately excluded from `==`, per spec §11's own text.
    /// `tokens` is likewise excluded: it's computed once per segment and
    /// cached by the view model, so for a stable `segment.id` its value
    /// never changes across the row's lifetime.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.segment.id == rhs.segment.id && lhs.isCurrent == rhs.isCurrent
    }

    /// §12: one accessibility step of normal spacing before tightening.
    private var isTightened: Bool {
        dynamicTypeSize >= .accessibility3
    }

    var body: some View {
        WordTokenFlowLayout(horizontalSpacing: 6, lineSpacing: isTightened ? 2 : 6) {
            ForEach(Array(tokens.enumerated()), id: \.offset) { offset, token in
                let id = WordTokenID(segmentIndex: segment.index, tokenIndex: offset)
                WordTokenView(
                    id: id,
                    token: token,
                    font: .system(size: baseFontSize, weight: .bold, design: .rounded),
                    onTap: { onTapToken(id, token) },
                    onLongPressBegan: { onLongPressToken(id) },
                    onDragChanged: onDragToken,
                    onDragEnded: onDragEndedToken
                )
            }
        }
        .foregroundStyle(.white)
        .lineSpacing(isTightened ? 2 : 6)
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(isCurrent ? 1.0 : 0.35)
        .blur(radius: shouldBlur ? 1.2 : 0)
        .animation(.easeInOut(duration: 0.25), value: isCurrent)
        .contentShape(Rectangle())
        .onTapGesture { onTapRow() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onTapRow() }
        .accessibilityAction(named: Text("Translate line")) { onTranslateLine() }
    }

    /// §3.1: blur on non-current rows is skipped entirely under Reduce
    /// Motion or Reduce Transparency (§12: "the optional non-current-row
    /// blur is skipped entirely" under Reduce Motion).
    private var shouldBlur: Bool {
        !isCurrent && !reduceMotion && !reduceTransparency
    }

    /// §12: VoiceOver label with a spelled-out timestamp
    /// ("3 minutes 5 seconds"), not "3:05", for clarity when spoken.
    private var accessibilityLabel: String {
        let position = "Line \(segment.index + 1)"
        let playing = isCurrent ? ", currently playing" : ""
        let timestamp = Self.spokenTimestamp(segment.startTime)
        return "\(position)\(playing), tap to play from \(timestamp)"
    }

    private static func spokenTimestamp(_ time: TimeInterval) -> String {
        let clamped = max(0, Int(time.rounded()))
        let minutes = clamped / 60
        let seconds = clamped % 60
        var parts: [String] = []
        if minutes > 0 {
            parts.append("\(minutes) minute\(minutes == 1 ? "" : "s")")
        }
        parts.append("\(seconds) second\(seconds == 1 ? "" : "s")")
        return parts.joined(separator: " ")
    }
}
