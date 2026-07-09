import FamilyControls
import FlashlockCore
import SwiftUI
import UserNotifications

@main
struct FlashlockApp: App {
    @StateObject private var appModel = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appModel)
                .environmentObject(appModel.cardStore)
                .onOpenURL { appModel.handleDeepLink($0) }
        }
    }
}

/// App-level state: shared-store access, shield status for the UI, and routing
/// into the gate flow from deep links, notifications, and pending requests.
@MainActor
final class AppModel: ObservableObject {
    let sharedStore: SharedStore
    let cardStore: CardStore

    @Published var isOnboarded: Bool
    /// Presents the gate (earn-back) session full-screen when true.
    @Published var gateRequested = false
    @Published private(set) var isShielded = false
    @Published private(set) var activeCredit: TimeCredit?

    private let notificationDelegate = GateNotificationDelegate()

    init() {
        let store = SharedStore()
        sharedStore = store
        cardStore = CardStore()
        isOnboarded = store.isOnboarded

        notificationDelegate.onGateRequested = { [weak self] in
            Task { @MainActor in self?.requestGate() }
        }
        UNUserNotificationCenter.current().delegate = notificationDelegate
    }

    func didBecomeActive() {
        refreshStatus()
        // Shield-action extension wrote a gate request (whether or not the
        // user tapped the notification): route straight into the gate.
        if sharedStore.pendingGateRequest != nil {
            sharedStore.pendingGateRequest = nil
            if isShielded {
                requestGate()
            }
        }
    }

    /// Re-runs the reconciler and refreshes the status shown on HomeView.
    func refreshStatus(now: Date = Date()) {
        isShielded = ShieldStateReconciler.reconcile(now: now, store: sharedStore)
        activeCredit = sharedStore.ledger.activeCredit(at: now)
    }

    func handleDeepLink(_ url: URL) {
        if url.scheme == "flashlock", url.host == "gate" {
            requestGate()
        }
    }

    func requestGate() {
        guard isOnboarded else { return }
        gateRequested = true
    }

    func completeOnboarding() {
        sharedStore.isOnboarded = true
        isOnboarded = true
        refreshStatus()
    }

    /// First-run Screen Time authorization (`.individual`: self-managed, and
    /// self-revocable in Settings by design — Flashlock is a commitment
    /// device, not a parental control).
    func requestScreenTimeAuthorization() async throws {
        try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
    }
}

/// Routes taps on the shield-action extension's local notification into the
/// gate flow. Registered as the UNUserNotificationCenter delegate at launch.
final class GateNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    var onGateRequested: (() -> Void)?

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        if userInfo["url"] as? String == "flashlock://gate" {
            onGateRequested?()
        }
        completionHandler()
    }
}

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        Group {
            if appModel.isOnboarded {
                HomeView()
            } else {
                OnboardingView()
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Reconcile on every foreground: the DeviceActivity callbacks are
            // flaky, so a missed unlock or re-lock is repaired here.
            if newPhase == .active {
                appModel.didBecomeActive()
            }
        }
        .fullScreenCover(
            isPresented: $appModel.gateRequested,
            onDismiss: { appModel.refreshStatus() }
        ) {
            GateSessionView(
                cardStore: appModel.cardStore,
                sharedStore: appModel.sharedStore
            )
        }
    }
}
