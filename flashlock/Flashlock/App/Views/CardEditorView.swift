import FlashlockCore
import SwiftUI

/// Create/edit form for one card. Editing preserves the card's scheduling
/// state (phase, memory, due date) — only the content fields change.
struct CardEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var cardStore: CardStore

    let deckID: UUID
    let existingCard: Card?

    @State private var front = ""
    @State private var back = ""
    @State private var alternativesText = ""
    @State private var answerMode: AnswerMode = .multipleChoice
    @State private var loaded = false

    private var canSave: Bool {
        !front.trimmingCharacters(in: .whitespaces).isEmpty
            && !back.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Front") {
                    TextField("Question", text: $front, axis: .vertical)
                }
                Section("Back") {
                    TextField("Answer", text: $back, axis: .vertical)
                }
                Section("Also accept (comma-separated)") {
                    TextField("Alternative answers", text: $alternativesText)
                        .autocorrectionDisabled()
                }
                Section("Answer mode") {
                    Picker("Answer mode", selection: $answerMode) {
                        Text("Multiple choice").tag(AnswerMode.multipleChoice)
                        Text("Typed").tag(AnswerMode.typed)
                        Text("Self-graded").tag(AnswerMode.selfGraded)
                    }
                    .pickerStyle(.segmented)
                    if answerMode == .selfGraded {
                        Text("Self-graded cards are upgraded to multiple choice during unlock sessions.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(existingCard == nil ? "New card" : "Edit card")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!canSave)
                }
            }
            .onAppear { loadIfNeeded() }
        }
    }

    private func loadIfNeeded() {
        guard !loaded, let card = existingCard else { return }
        loaded = true
        front = card.front
        back = card.back
        alternativesText = card.alternativeAnswers.joined(separator: ", ")
        answerMode = card.answerMode
    }

    private func save() {
        let alternatives = alternativesText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var card = existingCard ?? Card(deckID: deckID, front: "", back: "")
        card.front = front.trimmingCharacters(in: .whitespaces)
        card.back = back.trimmingCharacters(in: .whitespaces)
        card.alternativeAnswers = alternatives
        card.answerMode = answerMode

        cardStore.upsert(card)
        dismiss()
    }
}
