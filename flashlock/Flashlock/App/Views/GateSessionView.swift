import FlashlockCore
import SwiftUI

/// The earn-back gate: same question UI as free study, but with pile progress
/// (cleared/total), missed-card requeue feedback, and a completion screen
/// showing the minutes granted. Presented full-screen from the
/// shield/notification path.
struct GateSessionView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: GateViewModel

    init(cardStore: CardStore, sharedStore: SharedStore) {
        _model = StateObject(
            wrappedValue: GateViewModel(cardStore: cardStore, sharedStore: sharedStore)
        )
    }

    var body: some View {
        NavigationStack {
            Group {
                if let credit = model.earnedCredit {
                    completionView(credit)
                } else if let reason = model.blockedReason {
                    blockedView(reason)
                } else if let question = model.question {
                    questionScreen(question)
                }
            }
            .navigationTitle("Earn time back")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if model.earnedCredit == nil {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Give up") {
                            model.abandon()
                            dismiss()
                        }
                    }
                }
            }
        }
    }

    private func questionScreen(_ question: QuizQuestion) -> some View {
        VStack {
            ProgressView(value: model.session.progress)
                .padding(.horizontal)
            Text("\(model.session.clearedCount) of \(model.session.totalCards) cleared \u{00B7} \(model.session.remaining) to go")
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

    private func completionView(_ credit: TimeCredit) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.open.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)
            Text("+\(credit.minutes) minutes")
                .font(.largeTitle.bold())
            Text("Your apps are unlocked until \(credit.expiresAt.formatted(date: .omitted, time: .shortened)).")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    private func blockedView(_ reason: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "hourglass")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(reason)
                .multilineTextAlignment(.center)
            Button("Close") { dismiss() }
                .buttonStyle(.bordered)
        }
        .padding()
    }
}
