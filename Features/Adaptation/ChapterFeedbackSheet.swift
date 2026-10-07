import SwiftUI

struct ChapterFeedbackSheet: View {
    let chapterTitle: String
    @Binding var overall: FeedbackOverallRating
    @Binding var moreOf: Set<FeedbackMoreTopic>
    @Binding var lessOf: Set<FeedbackLessTopic>
    @Binding var freeText: String
    var isSubmitting: Bool
    var onSubmit: () -> Void
    var onClose: () -> Void
    var onBundledExample: (() -> Void)? = nil
    var errorMessage: String? = nil

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("You finished “\(chapterTitle)”. How was it?")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("feedback.intro")
                }

                Section("Overall") {
                    Picker("Overall", selection: $overall) {
                        ForEach(FeedbackOverallRating.allCases) { rating in
                            Text(rating.displayName).tag(rating)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("feedback.overall")
                }

                Section("More of") {
                    ForEach(FeedbackMoreTopic.allCases) { topic in
                        Toggle(isOn: Binding(
                            get: { moreOf.contains(topic) },
                            set: { on in
                                if on { moreOf.insert(topic) } else { moreOf.remove(topic) }
                            }
                        )) {
                            Text(topic.displayName)
                        }
                        .accessibilityIdentifier("feedback.more.\(topic.rawValue)")
                    }
                }

                Section("Less of") {
                    ForEach(FeedbackLessTopic.allCases) { topic in
                        Toggle(isOn: Binding(
                            get: { lessOf.contains(topic) },
                            set: { on in
                                if on { lessOf.insert(topic) } else { lessOf.remove(topic) }
                            }
                        )) {
                            Text(topic.displayName)
                        }
                        .accessibilityIdentifier("feedback.less.\(topic.rawValue)")
                    }
                }

                Section("Anything else?") {
                    TextField("Optional notes", text: $freeText, axis: .vertical)
                        .lineLimit(3...6)
                        .accessibilityIdentifier("feedback.freetext")
                }
                if let onBundledExample {
                    Section {
                        Button("Review bundled global-context example", action: onBundledExample)
                            .disabled(isSubmitting)
                            .accessibilityIdentifier("feedback.bundledExample")
                    } header: {
                        Text("Offline example")
                    } footer: {
                        Text("Argentina only. Adds a fixed reading prompt to one future prose chapter after you review and Apply. No AI call; your feedback is saved normally, but the example does not interpret it.")
                    }
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("feedback.error")
                    }
                }
            }
            .navigationTitle("Chapter feedback")
            .disabled(isSubmitting)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { onClose() }
                        .disabled(isSubmitting)
                        .accessibilityIdentifier("feedback.close")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        onSubmit()
                    } label: {
                        if isSubmitting {
                            ProgressView()
                        } else {
                            Text("Continue")
                        }
                    }
                    .disabled(isSubmitting)
                    .accessibilityIdentifier("feedback.submit")
                }
            }
        }
        .accessibilityIdentifier("feedback.sheet")
        .interactiveDismissDisabled(isSubmitting)
    }
}
