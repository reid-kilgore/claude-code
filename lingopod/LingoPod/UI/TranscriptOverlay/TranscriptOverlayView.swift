// M4
// Root screen: composes background, top bar, transcript area, and playback
// bar (docs/specs/M4-overlay-ui.md §3). Presented via `.fullScreenCover`
// from `PlayerView` (M2) — M4 owns this destination view only, not the
// trigger. Initializer signature is pinned by that call site
// (`LingoPod/UI/Player/PlayerView.swift`); do not change it without
// updating the call site in the same commit.
import LingoPodKit
import SwiftData
import SwiftUI

struct TranscriptOverlayView: View {
    let episode: Episode
    let engine: any PlayerEngineProtocol
    let transcriptProvider: any TranscriptProviderProtocol

    @Environment(\.dismiss) private var dismiss
    @Environment(AppContainer.self) private var container
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var viewModel: TranscriptOverlayViewModel?

    init(episode: Episode, engine: any PlayerEngineProtocol, transcriptProvider: any TranscriptProviderProtocol) {
        self.episode = episode
        self.engine = engine
        self.transcriptProvider = transcriptProvider
    }

    var body: some View {
        Group {
            if let viewModel {
                overlay(viewModel: viewModel)
            } else {
                Color.black.ignoresSafeArea()
            }
        }
        .task {
            guard viewModel == nil else { return }
            let vm = TranscriptOverlayViewModel(
                episode: episode,
                transcriptProvider: transcriptProvider,
                translationService: container.translationService,
                translationDownloadPreparing: container.translationDownloadPreparing,
                explainService: container.explainService,
                catalogService: container.catalogService
            )
            vm.setReduceMotion(reduceMotion)
            viewModel = vm
            await vm.start()
        }
    }

    // MARK: - Root layout (§3)

    @ViewBuilder
    private func overlay(viewModel: TranscriptOverlayViewModel) -> some View {
        ZStack {
            BlurredArtworkBackground(artworkURL: episode.podcast?.artworkURL)

            VStack(spacing: 0) {
                topBar
                transcriptArea(viewModel: viewModel)
                    .frame(maxHeight: .infinity)
                PlaybackBarView(engine: engine)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
        }
        // §4.2: polling fallback rather than `.onChange(of: engine.currentTime)`
        // — `engine` here is `any PlayerEngineProtocol` (an existential),
        // and architecture §11.10 explicitly notes `@Observable`
        // existentials don't reliably drive SwiftUI invalidation the way a
        // concrete `@Observable` class does. A 250ms polling loop sidesteps
        // that uncertainty entirely (it only ever reads a value, never
        // depends on Observation tracking through the existential) and is
        // the spec's own sanctioned fallback. See the M4 report's
        // integration-mismatch note.
        .task {
            while !Task.isCancelled {
                viewModel.syncTick(currentTime: engine.currentTime)
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        .onChange(of: viewModel.syncDriver.currentIndex) { _, _ in
            guard let handle = viewModel.transcriptHandle else { return }
            viewModel.currentIndexChanged(segments: handle.segments, reduceMotion: reduceMotion)
        }
        .onChange(of: viewModel.transcriptHandle?.segments.count) { _, _ in
            guard let handle = viewModel.transcriptHandle else { return }
            viewModel.refreshCaches(segments: handle.segments)
        }
        .onChange(of: viewModel.transcriptHandle?.languageCode) { _, _ in
            guard let handle = viewModel.transcriptHandle else { return }
            viewModel.refreshCaches(segments: handle.segments)
        }
        .onChange(of: reduceMotion) { _, newValue in
            viewModel.setReduceMotion(newValue)
        }
        .sheet(item: explainSheetBinding(viewModel: viewModel)) { request in
            ExplainSheetView(
                passage: request.passage,
                context: request.context,
                sourceLanguage: viewModel.resolvedSourceLanguage(),
                targetLanguage: viewModel.targetLanguage,
                explainService: viewModel.explainService,
                engine: engine
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    private var topBar: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel("Close transcript")
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private func explainSheetBinding(viewModel: TranscriptOverlayViewModel) -> Binding<ExplainRequest?> {
        Binding(
            get: { viewModel.explainRequest },
            set: { newValue in
                if newValue == nil {
                    viewModel.dismissExplainSheet()
                }
            }
        )
    }

    // MARK: - Transcript area (§9)

    @ViewBuilder
    private func transcriptArea(viewModel: TranscriptOverlayViewModel) -> some View {
        if viewModel.initialLoadFailed {
            TranscriptFailedBanner(
                copy: TranscriptFailureCopy(message: "Couldn't load this transcript.", buttonTitle: "Retry", action: .retry),
                isRetrying: viewModel.isRetryingTranscript,
                onAction: { Task { await viewModel.retryInitialLoad() } }
            )
        } else if let handle = viewModel.transcriptHandle {
            switch handle.state {
            case .pending:
                TranscriptPendingBanner()
            case .partial, .complete:
                scrollArea(viewModel: viewModel, handle: handle)
            case .failed(let reason):
                let copy = viewModel.failureCopy(for: reason)
                TranscriptFailedBanner(
                    copy: copy,
                    isRetrying: viewModel.isRetryingTranscript,
                    onAction: { Task { await viewModel.executeFailureAction(copy.action) } }
                )
            }
        } else {
            TranscriptPendingBanner()
        }
    }

    // MARK: - Scroll area (§3.1, §4, §6, §7)

    private func scrollArea(viewModel: TranscriptOverlayViewModel, handle: TranscriptHandle) -> some View {
        GeometryReader { containerProxy in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: rowSpacing) {
                        Color.clear.frame(height: containerProxy.size.height * 0.4)

                        ForEach(handle.segments) { segment in
                            TranscriptRowView(
                                segment: segment,
                                isCurrent: segment.index == viewModel.syncDriver.currentIndex,
                                tokens: viewModel.tokensBySegmentIndex[segment.index] ?? [],
                                dynamicTypeSize: dynamicTypeSize,
                                reduceMotion: reduceMotion,
                                reduceTransparency: reduceTransparency,
                                onTapRow: { viewModel.tapSegment(segment, engine: engine) },
                                onTapToken: { id, token in viewModel.tapToken(id, token: token) },
                                onLongPressToken: { id in viewModel.longPressBegan(on: id) },
                                onDragToken: { point in viewModel.dragUpdated(to: point) },
                                onDragEndedToken: { viewModel.dragEnded() },
                                onTranslateLine: { viewModel.translateLine(segment) }
                            )
                            .equatable()
                            .id(segment.id)
                        }

                        if handle.state == .partial {
                            TranscriptFrontierRow(progress: handle.progress)
                        }

                        Color.clear.frame(height: containerProxy.size.height * 0.4)
                    }
                    .padding(.horizontal, 24)
                }
                .coordinateSpace(name: "transcriptScroll")
                .onPreferenceChange(WordTokenFramesPreferenceKey.self) { frames in
                    viewModel.tokenFrames = frames
                }
                // VERIFY(iOS26): assumes `.onScrollPhaseChange { old, new in }`
                // exists on `ScrollView` with a `ScrollPhase` enum (§4.4).
                .onScrollPhaseChange { oldPhase, newPhase in
                    viewModel.scrollPhaseChanged(old: oldPhase, new: newPhase)
                }
                .onAppear {
                    viewModel.scrollProxy = proxy
                }
                .onTapGesture {
                    viewModel.tapElsewhereInTranscript()
                }
                .overlay {
                    selectionHighlightOverlay(viewModel: viewModel)
                        .allowsHitTesting(false)
                }
                .overlay {
                    popoverAnchor(viewModel: viewModel, containerSize: containerProxy.size)
                }
                .overlay(alignment: .bottom) {
                    if viewModel.mode == .userScrolling {
                        ResumeSyncPill(onTap: { viewModel.resumeSyncNow() })
                            .padding(.bottom, 12)
                            .transition(.opacity)
                    }
                }
                .overlay(alignment: .bottom) {
                    if viewModel.mode == .selecting, viewModel.selection != nil {
                        SelectionActionBar(
                            showTranslate: viewModel.shouldShowTranslateAffordance,
                            onTranslate: { viewModel.requestTranslateSelection() },
                            onExplain: { viewModel.requestExplainFromSelection() }
                        )
                        .padding(.bottom, 12)
                        .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.15), value: viewModel.mode)
            }
        }
    }

    private var rowSpacing: CGFloat {
        dynamicTypeSize >= .accessibility3 ? 16 : 28
    }

    /// In-progress-selection highlight, rendered above the transcript as a
    /// set of capsules positioned from the already-collected `tokenFrames`
    /// map — see `WordTokenView`'s doc comment for why this lives outside
    /// each row's `Equatable`-guarded subtree.
    @ViewBuilder
    private func selectionHighlightOverlay(viewModel: TranscriptOverlayViewModel) -> some View {
        if viewModel.mode == .selecting {
            let rects = viewModel.selectedTokenIDs().compactMap { viewModel.tokenFrames[$0] }
            ForEach(Array(rects.enumerated()), id: \.offset) { _, rect in
                Capsule()
                    .fill(.white.opacity(0.25))
                    .frame(width: rect.width + 6, height: rect.height + 4)
                    .position(x: rect.midX, y: rect.midY)
            }
        }
    }

    /// A single invisible anchor view driving `WordTranslationPopover`'s
    /// presentation. For a single-word/whole-line popover, anchored to that
    /// token's known frame; for a multi-word-selection translate, anchored
    /// to a fixed point near the bottom of the transcript area (§7.2:
    /// precise anchoring to a selection's bounding box is explicitly not
    /// worth the complexity for v1 — the same allowance is extended here to
    /// the popover's anchor).
    private func popoverAnchor(viewModel: TranscriptOverlayViewModel, containerSize: CGSize) -> some View {
        let rect = popoverAnchorRect(viewModel: viewModel, containerSize: containerSize)
        return Color.clear
            .frame(width: max(rect.width, 1), height: max(rect.height, 1))
            .position(x: rect.midX, y: rect.midY)
            .popover(isPresented: popoverPresentedBinding(viewModel: viewModel), attachmentAnchor: .rect(.bounds)) {
                WordTranslationPopover(
                    originalText: viewModel.selection.map(viewModel.selectionText) ?? "",
                    lookup: viewModel.translationLookup,
                    onDownloadLanguage: { await viewModel.downloadLanguagePackAndRetryTranslation() },
                    onExplainMore: { viewModel.explainMoreFromPopover() }
                )
                .presentationCompactAdaptation(.popover)
            }
            .allowsHitTesting(false)
    }

    private func popoverAnchorRect(viewModel: TranscriptOverlayViewModel, containerSize: CGSize) -> CGRect {
        if let tokenID = viewModel.popoverTokenID, let rect = viewModel.tokenFrames[tokenID] {
            return rect
        }
        return CGRect(x: containerSize.width / 2 - 1, y: max(0, containerSize.height - 96), width: 2, height: 2)
    }

    private func popoverPresentedBinding(viewModel: TranscriptOverlayViewModel) -> Binding<Bool> {
        Binding(
            get: { viewModel.mode == .popoverOpen },
            set: { presented in
                if !presented {
                    viewModel.dismissPopover()
                }
            }
        )
    }
}
