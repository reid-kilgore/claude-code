import FlashlockCore
import SwiftUI

/// Free-study flow for one deck. Unlike the gate, self-graded cards keep their
/// reveal-and-rate UI and answers never mint screen time.
struct StudySessionView: View {
    @StateObject private var model: StudyViewModel

    init(cardStore: CardStore, deck: Deck) {
        _model = StateObject(wrappedValue: StudyViewModel(cardStore: cardStore, deck: deck))
    }

    var body: some View {
        Group {
            if model.isFinished {
                finishedView
            } else if let question = model.question {
                VStack {
                    Text("\(model.remainingCount) to go")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                    QuestionView(
                        question: question,
                        feedback: model.feedback,
                        onSelfGrade: { model.submitSelfGraded($0) },
                        onChoice: { model.submitChoice($0) },
                        onTyped: { model.submitTyped($0) },
                        onContinue: { model.continueAfterFeedback() }
                    )
                    Spacer()
                }
                .padding(.vertical)
            }
        }
        .navigationTitle(model.deck.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var finishedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)
            Text(model.reviewedCount > 0 ? "Session complete" : "All caught up")
                .font(.title2)
            if model.reviewedCount > 0 {
                Text("You reviewed \(model.reviewedCount) cards.")
                    .foregroundStyle(.secondary)
            } else {
                Text("No cards are due right now.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
    }
}
