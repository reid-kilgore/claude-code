import FlashlockCore
import SwiftUI
import UniformTypeIdentifiers

/// Minimal deck CRUD: list, create, delete, import/sync from a
/// flashlock-deck-v1 JSON file, and drill into a deck's cards.
struct DeckListView: View {
    @EnvironmentObject private var cardStore: CardStore

    @State private var newDeckAlertPresented = false
    @State private var newDeckName = ""
    @State private var importerPresented = false
    @State private var importResultMessage = ""
    @State private var importAlertPresented = false

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

            Section {
                Button {
                    importerPresented = true
                } label: {
                    Label("Import deck\u{2026}", systemImage: "square.and.arrow.down")
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
        .fileImporter(
            isPresented: $importerPresented,
            allowedContentTypes: [.json]
        ) { result in
            handleImport(result)
        }
        .alert("Deck import", isPresented: $importAlertPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importResultMessage)
        }
    }

    /// Reads the picked file and merges it via `CardStore.applyImport`.
    /// Re-importing the same (or an updated) export is the sync path:
    /// text updates in place, scheduling is preserved, nothing is deleted.
    private func handleImport(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            // Files-picker URLs are security-scoped; access must be bracketed
            // or reading throws a permission error.
            let accessing = url.startAccessingSecurityScopedResource()
            defer {
                if accessing { url.stopAccessingSecurityScopedResource() }
            }
            let data = try Data(contentsOf: url)
            let file = try DeckImportFile.decode(from: data)
            let outcome = cardStore.applyImport(file)
            importResultMessage = "Imported \u{201C}\(file.name)\u{201D}: "
                + "\(outcome.added) added, \(outcome.updated) updated, "
                + "\(outcome.unchanged) unchanged."
        } catch let error as DeckImportFile.ImportError {
            switch error {
            case let .unsupportedFormat(format):
                importResultMessage =
                    "This file isn't a Flashlock deck (format \u{201C}\(format)\u{201D})."
            case .emptyDeck:
                importResultMessage = "The deck file is empty."
            }
        } catch is DecodingError {
            importResultMessage = "This file isn't a Flashlock deck."
        } catch {
            importResultMessage = "Import failed: \(error.localizedDescription)"
        }
        importAlertPresented = true
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
