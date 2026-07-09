import FlashlockCore
import SwiftUI

/// Today's status plus entry points into study, the gate, decks, and settings.
struct HomeView: View {
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var cardStore: CardStore

    var body: some View {
        NavigationStack {
            List {
                Section("Today") {
                    statusRow
                    if appModel.isShielded {
                        Button {
                            appModel.requestGate()
                        } label: {
                            Label("Unlock apps", systemImage: "lock.open")
                        }
                    }
                }

                Section("Study now") {
                    ForEach(cardStore.decks) { deck in
                        NavigationLink {
                            StudySessionView(cardStore: cardStore, deck: deck)
                        } label: {
                            HStack {
                                Text(deck.name)
                                Spacer()
                                Text("\(cardStore.dueCount(in: deck)) due")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section {
                    NavigationLink("Decks") { DeckListView() }
                    NavigationLink("Settings") { SettingsView() }
                }
            }
            .navigationTitle("Flashlock")
            .onAppear { appModel.refreshStatus() }
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        let config = appModel.sharedStore.limitConfig
        if !config.isEnabled {
            Label("Daily limit is off", systemImage: "pause.circle")
                .foregroundStyle(.secondary)
        } else if let credit = appModel.activeCredit {
            Label {
                Text("Unlocked until \(credit.expiresAt.formatted(date: .omitted, time: .shortened))")
            } icon: {
                Image(systemName: "lock.open.fill")
                    .foregroundStyle(.green)
            }
        } else if appModel.isShielded {
            Label {
                Text("Limit reached — apps are blocked")
            } icon: {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.red)
            }
        } else {
            Label(
                "\(config.dailyLimitMinutes)-minute daily limit active",
                systemImage: "clock"
            )
        }
    }
}
