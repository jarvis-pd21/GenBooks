import SwiftUI

struct LearningScoreSummaryView: View {
    @ObservedObject var model: LearningViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Physics check score").font(.headline)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                    .foregroundStyle(LRColor.secondaryText).accessibilityHidden(true)
            }
            Text(model.scoreSummary.completedSlotCount == 0 ? "Not checked yet" : "\(model.scoreSummary.score) / 100")
                .font(.title2.weight(.semibold).monospacedDigit())
                .foregroundStyle(LRColor.accent)
            Text("\(model.scoreSummary.completedSlotCount) of 10 questions have counted answers")
                .font(.caption).foregroundStyle(LRColor.secondaryText)
        }
        .foregroundStyle(LRColor.text)
        .frame(maxWidth: .infinity, alignment: .leading)
        .learningCard()
        .accessibilityElement(children: .combine)
    }
}

struct LearningScoreDetailView: View {
    @ObservedObject var model: LearningViewModel

    var body: some View {
        List {
            if model.canSave {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("\(model.scoreSummary.score) / 100")
                            .font(.largeTitle.weight(.semibold).monospacedDigit())
                            .foregroundStyle(LRColor.accent)
                        Text("Physics check score").font(.headline)
                        Text("\(model.scoreSummary.correctCount) correct · \(model.scoreSummary.completedSlotCount) of 10 with a counted answer")
                            .font(.subheadline).foregroundStyle(LRColor.secondaryText)
                        Text("A record of ten fixed question results, not a percentage of physics you know.")
                            .font(.subheadline)
                    }.padding(.vertical, 8)
                }.listRowBackground(LRColor.surface)
                Section {
                    ForEach(Array(model.scoreSummary.slots.enumerated()), id: \.element.id) { index, slot in
                        VStack(alignment: .leading, spacing: 6) {
                            Text("\(slot.title) · Check \(index % 2 + 1)").font(.headline)
                            Label(statusTitle(slot.status), systemImage: statusSymbol(slot.status))
                                .font(.subheadline)
                                .foregroundStyle(slot.status == .correct ? LRColor.accent : LRColor.secondaryText)
                            if let date = slot.date {
                                Text(date.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption).foregroundStyle(LRColor.secondaryText)
                            }
                            if slot.older {
                                Text("More than 14 days old · points are not automatically removed")
                                    .font(.caption).foregroundStyle(LRColor.secondaryText)
                            }
                        }
                        .padding(.vertical, 8)
                        .listRowBackground(LRColor.surface)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("learning.score.slot.\(slot.id)")
                    }
                } header: { Text("The ten questions") }
                footer: { Text("This list shows the latest counted answer for each question. Practice and earlier answers stay in your history.") }
                Section("How points work") {
                    Text("Each question contributes 10 points when its latest counted answer is correct. A slot with a counted incorrect result, or no counted result, contributes zero. A later counted answer can replace that result and lower the score.")
                    Text("Only designated review checks can count: without reported help and at least 24 hours after recorded teaching or feedback. If this question was shown before, seven days must pass since that display. At most one check for a concept counts within 24 hours. Existing progress without exposure dates waits seven days after this tracking begins.")
                    Text("Reading, self-reported learning and immediate practice do not add points. A multiple-choice answer does not prove free recall or mastery.")
                    NavigationLink("Foundations and full definitions") { FoundationsView() }
                }.listRowBackground(LRColor.surface)
            } else {
                ContentUnavailableView("Score unavailable", systemImage: "chart.bar",
                    description: Text("Your saved progress could not be opened. No score has been inferred."))
                    .listRowBackground(LRColor.surface)
            }
        }
        .scrollContentBackground(.hidden).background(LRColor.background)
        .foregroundStyle(LRColor.text).tint(LRColor.accent)
        .navigationTitle("Check score").navigationBarTitleDisplayMode(.inline)
        .learningPaperToolbar()
        .accessibilityIdentifier("learning.score.detail")
    }

    private func statusTitle(_ status: LearningScoreStatus) -> String {
        switch status {
        case .unknown: return "No counted answer"
        case .correct: return "Correct · 10 points"
        case .incorrect: return "Incorrect · 0 points"
        }
    }

    private func statusSymbol(_ status: LearningScoreStatus) -> String {
        switch status {
        case .unknown: return "minus.circle"
        case .correct: return "checkmark.circle"
        case .incorrect: return "xmark.circle"
        }
    }
}
