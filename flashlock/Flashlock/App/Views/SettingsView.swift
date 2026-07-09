import FamilyControls
import FlashlockCore
import SwiftUI

/// Edits the daily limit, unlock policy, and shielded-app selection. Saving
/// re-registers the daily DeviceActivity schedule and reconciles shields.
struct SettingsView: View {
    @EnvironmentObject private var appModel: AppModel

    @State private var isEnabled = true
    @State private var limitMinutes = 60
    @State private var cardCount = 5
    @State private var minutesGranted = 15
    @State private var minimumRecallCards = 2
    /// 0 means unlimited (`UnlockPolicy.maxUnlocksPerDay == nil`).
    @State private var maxUnlocksPerDay = 0
    @State private var selection = FamilyActivitySelection()
    @State private var pickerPresented = false
    @State private var loaded = false
    @State private var saved = false

    var body: some View {
        Form {
            Section("Daily limit") {
                Toggle("Limit enabled", isOn: $isEnabled)
                Stepper(
                    "\(limitMinutes) minutes per day",
                    value: $limitMinutes,
                    in: 5...240,
                    step: 5
                )
            }

            Section("Blocked apps") {
                Button("Reselect apps") { pickerPresented = true }
                Text("\(selection.applicationTokens.count) apps selected")
                    .foregroundStyle(.secondary)
                if selection.applicationTokens.count > 50 {
                    Text("Pick at most 50 apps — iOS shields nothing beyond that.")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            Section("Unlock policy") {
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
                Button("Save") { save() }
                    .disabled(selection.applicationTokens.count > 50)
                if saved {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
        }
        .navigationTitle("Settings")
        .familyActivityPicker(isPresented: $pickerPresented, selection: $selection)
        .onAppear { loadIfNeeded() }
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        let store = appModel.sharedStore
        let config = store.limitConfig
        let policy = store.unlockPolicy
        isEnabled = config.isEnabled
        limitMinutes = config.dailyLimitMinutes
        cardCount = policy.cardCount
        minutesGranted = policy.minutesGranted
        minimumRecallCards = policy.minimumRecallCards
        maxUnlocksPerDay = policy.maxUnlocksPerDay ?? 0
        selection = store.selection ?? FamilyActivitySelection()
    }

    private func save() {
        let store = appModel.sharedStore
        let config = LimitConfig(dailyLimitMinutes: limitMinutes, isEnabled: isEnabled)
        store.limitConfig = config
        store.selection = selection
        store.unlockPolicy = UnlockPolicy(
            cardCount: cardCount,
            minutesGranted: minutesGranted,
            minimumRecallCards: min(minimumRecallCards, cardCount),
            maxUnlocksPerDay: maxUnlocksPerDay == 0 ? nil : maxUnlocksPerDay
        )

        // Re-register (stopMonitoring happens inside) and re-assert shields so
        // disabling the limit takes effect immediately.
        try? DailyLimitScheduler.schedule(selection: selection, config: config)
        appModel.refreshStatus()
        saved = true
    }
}
