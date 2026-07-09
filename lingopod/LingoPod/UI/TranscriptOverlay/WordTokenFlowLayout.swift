// M4
// Word-token identity, frame publishing, custom wrapping layout, and the
// per-token tap/long-press-drag gesture (docs/specs/M4-overlay-ui.md §6.2).
//
// Decision (spec §6.2): SwiftUI's `Text` + `.textSelection(.enabled)` gives
// no hook to intercept a tap on a specific word or render a custom
// in-progress-selection highlight, so words are laid out as individual
// subviews through a custom `Layout` instead of one flowing `Text`.
import SwiftUI

/// Stable identity for one word token: `segmentIndex` is
/// `TranscriptSegmentSnapshot.index` (the data model's stable ordering
/// key), `tokenIndex` is the position in that segment's cached
/// `[WordToken]` array. Document order for two IDs is lexicographic
/// `(segmentIndex, tokenIndex)` — this is how selection anchor/extent get
/// normalized into start/end (§10.2).
struct WordTokenID: Hashable, Sendable, Comparable {
    let segmentIndex: Int
    let tokenIndex: Int

    static func < (lhs: WordTokenID, rhs: WordTokenID) -> Bool {
        (lhs.segmentIndex, lhs.tokenIndex) < (rhs.segmentIndex, rhs.tokenIndex)
    }
}

/// Published by every on-screen `WordTokenView` (in the `"transcriptScroll"`
/// named coordinate space) so the selection-drag handler can hit-test
/// "which token is at point P" without needing UIKit hit-testing. Because
/// rows live in a `LazyVStack`, only tokens whose row is currently laid out
/// publish a frame here — see `TranscriptOverlayViewModel.nearestToken`'s
/// doc comment for how the drag handler clamps to the furthest known token
/// instead of crashing/no-op'ing when the drag outruns laid-out rows.
struct WordTokenFramesPreferenceKey: PreferenceKey {
    static var defaultValue: [WordTokenID: CGRect] { [:] }
    static func reduce(value: inout [WordTokenID: CGRect], nextValue: () -> [WordTokenID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// Custom wrapping `Layout` (iOS 16+) arranging one subview per word token,
/// left-to-right, wrapping to a new line when a token would overflow the
/// available width. Inter-token spacing is a fixed-width gap; wrapping
/// measures each subview's natural size via `sizeThatFits(.unspecified)`.
struct WordTokenFlowLayout: Layout {
    var horizontalSpacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        guard !subviews.isEmpty else { return .zero }

        var rowWidths: [CGFloat] = [0]
        var rowHeights: [CGFloat] = [0]

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let isRowEmpty = rowWidths[rowWidths.count - 1] == 0
            let candidateWidth = isRowEmpty ? size.width : rowWidths[rowWidths.count - 1] + horizontalSpacing + size.width
            if candidateWidth > maxWidth, !isRowEmpty {
                rowWidths.append(size.width)
                rowHeights.append(size.height)
            } else {
                rowWidths[rowWidths.count - 1] = candidateWidth
                rowHeights[rowHeights.count - 1] = max(rowHeights[rowHeights.count - 1], size.height)
            }
        }

        let width = min(rowWidths.max() ?? 0, maxWidth)
        let height = rowHeights.reduce(0, +) + CGFloat(max(0, rowHeights.count - 1)) * lineSpacing
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }

        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        var isRowEmpty = true

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if !isRowEmpty, x + size.width > bounds.minX + bounds.width {
                x = bounds.minX
                y += rowHeight + lineSpacing
                rowHeight = 0
                isRowEmpty = true
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + horizontalSpacing
            rowHeight = max(rowHeight, size.height)
            isRowEmpty = false
        }
    }
}

/// One tappable word/phrase token. Inherits current/dimmed opacity and blur
/// from the parent row (tokens never independently dim, per §6.2) — this
/// view intentionally carries no "isCurrent"/"isHighlighted" state of its
/// own so it stays cheap to reconstruct; in-progress-selection highlighting
/// is rendered as a separate overlay layer above the transcript
/// (`TranscriptOverlayView`), driven by `tokenFrames` + the view model's
/// `selection`, rather than by mutating each token — this keeps
/// `TranscriptRowView`'s `Equatable` perf contract (§11, comparing only
/// `segment.id`/`isCurrent`) honest: a token's own view identity never
/// needs to change just because a selection is being dragged elsewhere.
struct WordTokenView: View {
    let id: WordTokenID
    let token: WordToken
    let font: Font
    let onTap: () -> Void
    let onLongPressBegan: () -> Void
    let onDragChanged: (CGPoint) -> Void
    let onDragEnded: () -> Void

    @State private var isDragging = false

    /// Explicit init: `isDragging` is a `private` stored property with a
    /// default value, which would otherwise demote Swift's auto-synthesized
    /// memberwise initializer to `private` (Swift's documented
    /// access-control rule) and make this type uncallable from
    /// `TranscriptRowView.swift`.
    init(
        id: WordTokenID,
        token: WordToken,
        font: Font,
        onTap: @escaping () -> Void,
        onLongPressBegan: @escaping () -> Void,
        onDragChanged: @escaping (CGPoint) -> Void,
        onDragEnded: @escaping () -> Void
    ) {
        self.id = id
        self.token = token
        self.font = font
        self.onTap = onTap
        self.onLongPressBegan = onLongPressBegan
        self.onDragChanged = onDragChanged
        self.onDragEnded = onDragEnded
    }

    var body: some View {
        Text(token.text)
            .font(font)
            .contentShape(Rectangle())
            .overlay(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: WordTokenFramesPreferenceKey.self,
                        value: [id: proxy.frame(in: .named("transcriptScroll"))]
                    )
                }
            )
            .gesture(combinedGesture)
    }

    // VERIFY(iOS26): gesture composition (`LongPressGesture.sequenced(before:)`
    // exclusively combined with a plain `TapGesture` so a quick release
    // resolves as a tap while a 0.35s hold resolves as the start of a
    // phrase-selection drag) matches the documented `Gesture` value shapes
    // as of this writing. Kept isolated to this one computed property per
    // spec §4.4's "adapt, don't restructure" guidance if the exact shapes
    // differ on the shipping SDK.
    private var combinedGesture: some Gesture {
        let longPressThenDrag = LongPressGesture(minimumDuration: 0.35)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named("transcriptScroll")))
        let tap = TapGesture()

        return longPressThenDrag.exclusively(before: tap)
            .onChanged { value in
                guard case .first(let sequenceValue) = value else { return }
                switch sequenceValue {
                case .first:
                    break // long-press still pending, hasn't reached the drag phase yet.
                case .second(true, let dragValue):
                    if !isDragging {
                        isDragging = true
                        onLongPressBegan()
                    }
                    if let dragValue {
                        onDragChanged(dragValue.location)
                    }
                case .second(false, _):
                    break
                }
            }
            .onEnded { value in
                switch value {
                case .first:
                    if isDragging {
                        isDragging = false
                        onDragEnded()
                    }
                case .second:
                    onTap()
                }
            }
    }
}
