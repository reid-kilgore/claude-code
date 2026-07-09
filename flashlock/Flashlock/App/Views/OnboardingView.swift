import FamilyControls
import FlashlockCore
import SwiftUI
import UserNotifications

/// First-run setup: Screen Time authorization, app selection, the daily
/// limit, and the unlock policy (pile size, minutes earned, recall minimum,
/// daily unlock cap). All of it is editable later in Settings.
struct OnboardingView: View {
    /// Undocumented ManagedSettings ceiling: shields with more than 50 tokens
    /// silently shield nothing, so enforce at selection time.
    private static let maxShieldedApps = 50

    @EnvironmentObject private var appModel: AppModel

    @State private var authorized = false
    @State private var authErrorMessage: String?
    @State private var selection = FamilyActivitySelection()
    @State private var pickerPresented = false
    @State private var limitMinutes = 60
    @State private var cardCount = 5
    @State private var minutesGranted = 15
    @State private var minimumRecallCards = 2
    /// 0 means unlimited (`UnlockPolicy.maxUnlocksPerDay == nil`).
    @State private var maxUnlocksPerDay = 0

    private var tooManyApps: Bool {
        selection.applicationTokens.count > Self.maxShieldedApps
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Flashlock blocks your chosen apps after a daily limit. Earn time back by clearing a pile of flashcards.")
                        .font(.callout)
                }

                Section("1. Allow Screen Time access") {
                    if authorized {
                        Label("Access granted", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Button("Grant Screen Time access") {
                            Task { await requestAuthorization() }
                        }
                        if let authErrorMessage {
                            Text(authErrorMessage)
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                    }
                }

                Section("2. Choose apps to limit") {
                    Button("Select apps") { pickerPresented = true }
                        .disabled(!authorized)
                    Text("\(selection.applicationTokens.count) apps selected")
                        .foregroundStyle(.secondary)
                    if tooManyApps {
                        Text("Pick at most \(Self.maxShieldedApps) apps — iOS shields nothing beyond that.")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                Section("3. Daily limit") {
                    Stepper(
                        "\(limitMinutes) minutes per day",
                        value: $limitMinutes,
                        in: 5...240,
                        step: 5
                    )
                }

                Section("4. Earning time back") {
                    Stepper(
                        "Cards in the pile: \(cardCount)",
                        value: $cardCount,
                        in: 1...50
                    )
                    Stepper(
                        "Earns \(minutesGranted) minutes",
                        value: $minutesGranted,
                        in: 1...60
                    )
                    Stepper(
                        "Recall cards required: \(min(minimumRecallCards, cardCount))",
                        value: $minimumRecallCards,
                        in: 0...cardCount
                    )
                    Stepper(
                        maxUnlocksPerDay == 0
                            ? "Unlimited unlocks per day"
                            : "\(maxUnlocksPerDay) unlocks per day",
                        value: $maxUnlocksPerDay,
                        in: 0...20
                    )
                    Text("Clear a pile of \(cardCount) cards to earn \(minutesGranted) minutes. Missed cards go to the back of the pile.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button("Start") { finish() }
                        .disabled(
                            !authorized
                                || selection.applicationTokens.isEmpty
                                || tooManyApps
                        )
                }
            }
            .navigationTitle("Welcome")
            // NOTE: iOS 18.4+ has a reported bug where a FamilyActivityPicker
            // inside a sheet dismisses the presenting sheet on "Done"; the
            // picker is attached to this root form to sidestep it.
            .familyActivityPicker(isPresented: $pickerPresented, selection: $selection)
        }
    }

    private func requestAuthorization() async {
        do {
            try await appModel.requestScreenTimeAuthorization()
            authorized = true
            authErrorMessage = nil
        } catch {
            // NOTE: fails on Simulator (FamilyControlsError code 3) — Screen
            // Time features require a physical device.
            authErrorMessage = "Authorization failed: \(error.localizedDescription)"
        }
    }

    private func finish() {
        let store = appModel.sharedStore
        let config = LimitConfig(dailyLimitMinutes: limitMinutes, isEnabled: true)
        store.selection = selection
        store.limitConfig = config
        store.unlockPolicy = UnlockPolicy(
            cardCount: cardCount,
            minutesGranted: minutesGranted,
            minimumRecallCards: min(minimumRecallCards, cardCount),
            maxUnlocksPerDay: maxUnlocksPerDay == 0 ? nil : maxUnlocksPerDay
        )

        try? DailyLimitScheduler.schedule(selection: selection, config: config)

        // Needed for the shield-action extension's "notification dance" on
        // iOS ≤ 26.4; request it up front so the unlock path works later.
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound]
        ) { _, _ in }

        appModel.completeOnboarding()
    }
}
