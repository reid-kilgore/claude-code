import FlashlockCore
import SwiftUI

/// Renders one `QuizQuestion` in any of its three cases, plus the post-answer
/// feedback state. Shared by free study and the gate session so the two flows
/// stay visually identical.
struct QuestionView: View {
    let question: QuizQuestion
    let feedback: AnswerFeedback?
    /// Called with `.again` or `.good` — self-graded cards show exactly those
    /// two buttons, in free study and in the gate alike.
    var onSelfGrade: (Rating) -> Void = { _ in }
    let onChoice: (Int) -> Void
    let onTyped: (String) -> Void
    let onContinue: () -> Void

    @State private var typedInput = ""
    @State private var revealed = false

    var body: some View {
        VStack(spacing: 24) {
            switch question {
            case let .selfGraded(_, front, back):
                prompt(front)
                if let feedback {
                    // Gate-only: "Again" requeues the card and explains so.
                    feedbackView(feedback)
                } else if revealed {
                    Divider()
                    Text(back)
                        .font(.title3)
                        .multilineTextAlignment(.center)
                    gradeButtons
                } else {
                    Button("Show answer") { revealed = true }
                        .buttonStyle(.borderedProminent)
                }

            case let .multipleChoice(_, front, choices, _):
                prompt(front)
                if let feedback {
                    feedbackView(feedback)
                } else {
                    ForEach(choices.indices, id: \.self) { index in
                        Button {
                            onChoice(index)
                        } label: {
                            Text(choices[index])
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                }

            case let .typed(_, front):
                prompt(front)
                if let feedback {
                    feedbackView(feedback)
                } else {
                    TextField("Type your answer", text: $typedInput)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onSubmit { onTyped(typedInput) }
                    Button("Submit") { onTyped(typedInput) }
                        .buttonStyle(.borderedProminent)
                        .disabled(typedInput.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .padding()
        .onChange(of: question) { _, _ in
            typedInput = ""
            revealed = false
        }
    }

    private func prompt(_ front: String) -> some View {
        Text(front)
            .font(.title2)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
    }

    /// Two honesty buttons only; `Rating.hard`/`.easy` still exist in the
    /// model but are no longer offered in the UI.
    private var gradeButtons: some View {
        HStack(spacing: 12) {
            gradeButton("Again", .again, tint: .red)
            gradeButton("Good", .good, tint: .green)
        }
    }

    private func gradeButton(_ title: String, _ rating: Rating, tint: Color) -> some View {
        Button(title) { onSelfGrade(rating) }
            .buttonStyle(.bordered)
            .tint(tint)
    }

    private func feedbackView(_ feedback: AnswerFeedback) -> some View {
        VStack(spacing: 16) {
            switch feedback {
            case .correct:
                Label("Correct", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.title3)
            case let .fuzzy(correctAnswer):
                Label("Close!", systemImage: "checkmark.circle")
                    .foregroundStyle(.orange)
                    .font(.title3)
                Text("The exact answer is \u{201C}\(correctAnswer)\u{201D}")
                    .multilineTextAlignment(.center)
            case let .incorrect(correctAnswer):
                Label("Incorrect", systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
                    .font(.title3)
                Text("The answer is \u{201C}\(correctAnswer)\u{201D}")
                    .multilineTextAlignment(.center)
            case let .requeued(correctAnswer):
                Label("Back in the pile", systemImage: "arrow.uturn.backward.circle.fill")
                    .foregroundStyle(.red)
                    .font(.title3)
                Text("The answer is \u{201C}\(correctAnswer)\u{201D} — this card comes around again.")
                    .multilineTextAlignment(.center)
            }
            Button("Continue") { onContinue() }
                .buttonStyle(.borderedProminent)
        }
    }
}
