import FlashlockCore
import SwiftUI

/// Minimal deck CRUD: list, create, delete, and drill into a deck's cards.
struct DeckListView: View {
    @EnvironmentObject private var cardStore: CardStore

    @State private var newDeckAlertPresented = false
    @State private var newDeckName = ""

    var body: some View {
        List {
            ForEach(cardStore.decks) { deck in
                NavigationLink {
                    DeckDetailView(deck: deck)
                } label: {
                    HStack {
                        Text(deck.name)
                        Spacer()
                        Text("\(cardStore.cards(in: deck).count) cards")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .onDelete { offsets in
                for index in offsets {
                    cardStore.delete(cardStore.decks[index])
                }
            }
        }
        .navigationTitle("Decks")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    newDeckName = ""
                    newDeckAlertPresented = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .alert("New deck", isPresented: $newDeckAlertPresented) {
            TextField("Name", text: $newDeckName)
            Button("Create") {
                let name = newDeckName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty {
                    cardStore.addDeck(named: name)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

/// One deck's cards, with add/edit via CardEditorView and swipe-to-delete.
struct DeckDetailView: View {
    @EnvironmentObject private var cardStore: CardStore
    let deck: Deck

    @State private var editingCard: Card?
    @State private var addingCard = false

    var body: some View {
        List {
            ForEach(cardStore.cards(in: deck)) { card in
                Button {
                    editingCard = card
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(card.front)
                        Text(card.back)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .tint(.primary)
            }
            .onDelete { offsets in
                let deckCards = cardStore.cards(in: deck)
                for index in offsets {
                    cardStore.delete(deckCards[index])
                }
            }
        }
        .navigationTitle(deck.name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    addingCard = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $addingCard) {
            CardEditorView(deckID: deck.id, existingCard: nil)
        }
        .sheet(item: $editingCard) { card in
            CardEditorView(deckID: deck.id, existingCard: card)
        }
    }
}
