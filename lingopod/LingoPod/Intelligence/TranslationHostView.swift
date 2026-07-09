// M5
// The only view M5 owns. A single, permanently-mounted, zero-size,
// invisible view that bridges SwiftUI's view-lifecycle-scoped
// `.translationTask` API to `TranslationService`'s async queue (spec §3.1).
// M0's RootView mounts exactly one instance of this for the lifetime of
// the app, not inside the transcript overlay — see the wiring note this
// module reports back for the exact modifier line.
import SwiftUI
import Translation

struct TranslationHostView: View {
    @Environment(AppContainer.self) private var container

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .translationTask(translationService?.pendingConfiguration) { session in
                await translationService?.run(session: session)
            }
    }

    /// `AppContainer.translationService` is `any TranslationServiceProtocol`
    /// (architecture §5.3's minimal surface, deliberately so M4 never needs
    /// more than the protocol). `pendingConfiguration`/`run(session:)` are
    /// not part of that protocol — they are `TranslationService`'s own
    /// plumbing for driving this exact view. Unlike M4 (which must always
    /// go through `TranslationServiceProtocol`/`TranslationDownloadPreparing`
    /// per spec §2.1's "no downcasts" decision), this downcast is confined
    /// to M5's own internal host view and never leaves this file, so it
    /// doesn't reintroduce the problem that decision was avoiding. If a
    /// non-`TranslationService` (e.g. a mock without the queue plumbing) is
    /// installed, this is simply `nil` and `.translationTask` never fires —
    /// harmless.
    private var translationService: TranslationService? {
        container.translationService as? TranslationService
    }
}
