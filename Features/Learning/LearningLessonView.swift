import SwiftUI

struct LearningLessonView: View {
    @ObservedObject var model: LearningViewModel
    let course: LearningCourse
    let lesson: LearningCourse.Lesson
    @State private var check: LearningCourse.Question?
    @State private var showsAsk = false
    @State private var feedbackSaved = false
    @ScaledMetric(relativeTo: .body) private var readingSize = 20

    private var readingNumber: Int { (course.lessons.firstIndex(where: { $0.id == lesson.id }) ?? 0) + 1 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("READING \(readingNumber) OF \(course.lessons.count)")
                        .font(.caption.weight(.semibold)).foregroundStyle(LRColor.secondaryText)
                    Text(lesson.title).font(.system(.largeTitle, design: .serif))
                        .accessibilityAddTraits(.isHeader)
                    Text(lesson.openingQuestion).font(.title3).foregroundStyle(LRColor.secondaryText)
                }
                VStack(alignment: .leading, spacing: 22) {
                    ForEach(Array(lesson.blocks.enumerated()), id: \.offset) { _, block in
                        if block.kind == "heading" {
                            Text(block.text).font(.system(.title2, design: .serif).weight(.semibold))
                                .padding(.top, 8).accessibilityAddTraits(.isHeader)
                        } else {
                            Text(block.text)
                                .font(.system(size: readingSize, design: .serif))
                                .lineSpacing(5).textSelection(.enabled)
                        }
                    }
                }
                Divider().overlay(LRColor.separator)
                VStack(alignment: .leading, spacing: 12) {
                    Text("Pause and consider").font(.headline)
                    Text(lesson.reflectionPrompt).font(.system(.title3, design: .serif))
                    Text("No response is required.").font(.subheadline).foregroundStyle(LRColor.secondaryText)
                }
                VStack(alignment: .leading, spacing: 14) {
                    Button {
                        _ = model.markRead(lesson)
                    } label: {
                        Label(!model.canSave ? "Progress unavailable" : model.progress.completedLessonIDs.contains(lesson.id) ? "Marked read" : "Finish reading", systemImage: "checkmark")
                            .frame(minHeight: 28)
                    }
                    .buttonStyle(.borderedProminent).foregroundStyle(LRColor.onAccent)
                    .disabled(!model.canSave).accessibilityIdentifier("learning.finish")
                    Text("Saves that you finished this reading. Question results are recorded separately.")
                        .font(.caption).foregroundStyle(LRColor.secondaryText)
                    if let first = lesson.checks.first {
                        Button { check = first } label: {
                            Label("Try an optional question", systemImage: "questionmark.circle")
                                .frame(minHeight: 28)
                        }
                        .buttonStyle(.bordered).disabled(!model.canSave)
                        .accessibilityIdentifier("learning.tryCheck")
                    }
                }
                feedback
                if let error = model.errorMessage { Text(error).font(.callout).foregroundStyle(.red) }
                VStack(spacing: 0) {
                    if readingNumber < course.lessons.count {
                        NavigationLink {
                            LearningLessonView(model: model, course: course, lesson: course.lessons[readingNumber])
                        } label: {
                            LearningRowLabel(title: "Next reading", subtitle: course.lessons[readingNumber].title, symbol: "arrow.right")
                        }
                        .accessibilityIdentifier("learning.nextLesson")
                        Divider().overlay(LRColor.separator).padding(.leading, 16)
                    }
                    NavigationLink {
                        LearningSourcesView(course: course)
                    } label: {
                        LearningRowLabel(title: "Sources for this unit", symbol: "text.book.closed")
                    }
                }
                .buttonStyle(.plain)
                .background(LRColor.surface, in: RoundedRectangle(cornerRadius: 16))
            }
            .frame(maxWidth: 640, alignment: .leading)
            .padding(24).frame(maxWidth: .infinity)
        }
        .background(LRColor.background).foregroundStyle(LRColor.text).tint(LRColor.accent)
        .navigationTitle("Physics").navigationBarTitleDisplayMode(.inline)
        .learningPaperToolbar()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showsAsk = true } label: { Image(systemName: "bubble.left.and.text.bubble.right") }
                    .accessibilityLabel("Ask BookBot").accessibilityIdentifier("learning.ask")
            }
        }
        .sheet(item: $check) { LearningCheckView(model: model, question: $0, reviewing: false) }
        .sheet(isPresented: $showsAsk) { LearningAskView(model: model, course: course, lesson: lesson) }
        .onAppear {
            if model.canSave && model.recordTeachingExposure(conceptIDs: lesson.conceptIds) {
                _ = model.save { $0.lastLessonID = lesson.id }
            }
        }
    }

    private var feedback: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                Text("Optional. ‘Too demanding’ changes the next suggestion while readings remain unfinished.")
                    .font(.caption).foregroundStyle(LRColor.secondaryText)
                ForEach(LearningFeedback.Experience.allCases, id: \.rawValue) { experience in
                    Button(experience.learningTitle) {
                        feedbackSaved = model.save { $0.feedback.append(LearningFeedback(lessonID: lesson.id, experience: experience)) }
                    }
                    .buttonStyle(.bordered).frame(minHeight: 44)
                    .disabled(!model.canSave || feedbackSaved)
                }
                if feedbackSaved { Text("Feedback saved.").font(.subheadline).foregroundStyle(LRColor.secondaryText) }
            }.padding(.top, 10)
        } label: {
            Text("How did this feel?").font(.headline).foregroundStyle(LRColor.text)
        }
        .learningCard()
    }
}

private extension LearningFeedback.Experience {
    var learningTitle: String {
        switch self {
        case .enjoyable: return "Enjoyable"
        case .neutral: return "Fine"
        case .tooDemanding: return "Too demanding today"
        }
    }
}

struct LearningCheckView: View {
    @ObservedObject var model: LearningViewModel
    let question: LearningCourse.Question
    let reviewing: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var selected: String?
    @State private var usedHelp = false
    @State private var showsExplanation = false
    @State private var presentation: LearningQuestionPresentation?
    @State private var receipt: LearningScoreReceipt?
    @State private var prepared = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if let presentation {
                        questionContent(presentation)
                    } else if !prepared {
                        ProgressView("Opening question…").frame(maxWidth: .infinity)
                    } else {
                        ContentUnavailableView("Question unavailable", systemImage: "questionmark.circle",
                            description: Text("The question could not be prepared with a saved record."))
                        Button("Try again", action: prepareQuestion).buttonStyle(.bordered)
                    }
                    if let error = model.errorMessage { Text(error).font(.callout).foregroundStyle(.red) }
                }
                .frame(maxWidth: 640, alignment: .leading)
                .padding(20).frame(maxWidth: .infinity)
            }
            .background(LRColor.background).foregroundStyle(LRColor.text)
            .navigationTitle(reviewing ? "Review check" : "Optional question")
            .navigationBarTitleDisplayMode(.inline).learningPaperToolbar()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(receipt == nil ? "Skip" : "Close") { dismiss() }
                        .accessibilityIdentifier("learning.check.close")
                }
            }
            .onAppear { if presentation == nil && !prepared { prepareQuestion() } }
        }.tint(LRColor.accent)
    }

    @ViewBuilder private func questionContent(_ presentation: LearningQuestionPresentation) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title = model.course?.concepts.first(where: { $0.id == question.conceptId })?.title {
                Text(title).font(.subheadline.weight(.medium)).foregroundStyle(LRColor.secondaryText)
            }
            Text(question.prompt).font(.system(.title2, design: .serif))
                .accessibilityAddTraits(.isHeader)
        }
        VStack(spacing: 10) {
            ForEach(question.choices) { choice in
                Button { selected = choice.id } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: selected == choice.id ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(selected == choice.id ? LRColor.accent : LRColor.secondaryText)
                            .accessibilityHidden(true)
                        Text(choice.text).font(.body).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .foregroundStyle(LRColor.text).padding(16).frame(minHeight: 52)
                    .background(selected == choice.id ? LRColor.accent.opacity(0.10) : LRColor.surface,
                        in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected == choice.id ? LRColor.accent : LRColor.separator, lineWidth: selected == choice.id ? 2 : 1))
                    .contentShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain).disabled(receipt != nil)
                .accessibilityIdentifier("learning.choice.\(choice.id)")
                .accessibilityLabel(choice.text)
                .accessibilityValue(selected == choice.id ? "Selected" : "Not selected")
                .accessibilityAddTraits(selected == choice.id ? .isSelected : [])
            }
        }
        if receipt == nil {
            VStack(alignment: .leading, spacing: 14) {
                Toggle("I used notes or other help", isOn: $usedHelp)
                    .disabled(showsExplanation)
                    .accessibilityIdentifier("learning.answer.help")
                Button("Show the explanation first") {
                    if model.recordHelpExposure(presentationID: presentation.id) {
                        usedHelp = true
                        showsExplanation = true
                    }
                }
                .frame(minHeight: 44).disabled(showsExplanation)
                .foregroundStyle(LRColor.accent)
                .accessibilityIdentifier("learning.answer.explanation")
                Text("Opening the explanation records help used.")
                    .font(.caption).foregroundStyle(LRColor.secondaryText)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(usedHelp ? "Practice with help" : presentation.eligibility.canCount ? "Eligible for your check score" : "Practice only")
                    .font(.subheadline.weight(.semibold))
                Text(usedHelp ? "Your answer will be saved with help used and will not change the check score." : presentation.eligibility.reason)
                    .font(.caption).foregroundStyle(LRColor.secondaryText)
                Button {
                    guard let selected else { return }
                    receipt = model.submitAnswer(question, choiceID: selected, usedHelp: usedHelp, presentationID: presentation.id)
                    if receipt != nil { showsExplanation = true }
                } label: {
                    Text("Save my answer").frame(maxWidth: .infinity).frame(minHeight: 30)
                }
                .buttonStyle(.borderedProminent)
                .foregroundStyle(selected == nil || !model.canSave ? LRColor.secondaryText : LRColor.onAccent)
                .disabled(selected == nil || !model.canSave)
                .accessibilityIdentifier("learning.answer.save")
            }
        }
        if showsExplanation {
            VStack(alignment: .leading, spacing: 14) {
                if let receipt {
                    Label(receipt.correct ? "Correct on this question" : "Here's the idea to revisit", systemImage: receipt.correct ? "checkmark.circle" : "arrow.clockwise.circle")
                        .font(.headline).accessibilityIdentifier("learning.answer.result")
                    Text(receipt.usedHelp ? "Saved with help used." : "Saved with no help reported.")
                        .font(.subheadline).foregroundStyle(LRColor.secondaryText)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(receipt.delta == 0 ? "Check score unchanged" : "Check score \(receipt.delta > 0 ? "+" : "")\(receipt.delta)")
                            .font(.subheadline.weight(.semibold))
                        Text(receipt.reason).font(.caption).foregroundStyle(LRColor.secondaryText)
                    }.accessibilityIdentifier("learning.answer.scoreReceipt")
                } else {
                    Text("Explanation").font(.headline)
                }
                Text(question.explanation).font(.body)
                if receipt != nil {
                    Button("Done") { dismiss() }.buttonStyle(.borderedProminent)
                        .foregroundStyle(LRColor.onAccent).frame(minHeight: 44)
                }
            }.learningCard()
        }
    }

    private func prepareQuestion() {
        guard presentation == nil else { return }
        presentation = model.startQuestionPresentation(question, reviewing: reviewing)
        prepared = true
    }
}

struct LearningConceptView: View {
    @ObservedObject var model: LearningViewModel
    let course: LearningCourse
    let concept: LearningCourse.Concept
    @State private var check: LearningCourse.Question?

    private var attempts: [LearningAttempt] {
        model.progress.attempts.filter { $0.conceptID == concept.id }.sorted { $0.date > $1.date }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(concept.title).font(.system(.largeTitle, design: .serif))
                        .accessibilityAddTraits(.isHeader)
                    Text(concept.objective).font(.body).foregroundStyle(LRColor.secondaryText)
                    DisclosureGroup("Scope of this idea") {
                        Text(concept.boundaries).font(.subheadline).foregroundStyle(LRColor.secondaryText)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                    }.font(.subheadline)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Button {
                        check = model.question(conceptID: concept.id, reviewing: true)
                    } label: {
                        Label("Practice this concept", systemImage: "arrow.clockwise")
                            .frame(minHeight: 28)
                    }
                    .buttonStyle(.borderedProminent).foregroundStyle(LRColor.onAccent)
                    .disabled(!model.canSave).accessibilityIdentifier("learning.concept.check")
                    if model.canSave, let due = LearningRecommendation.dueDate(conceptID: concept.id, progress: model.progress) {
                        Text("Next suggested practice: \(due.formatted(date: .abbreviated, time: .omitted))")
                            .font(.subheadline).foregroundStyle(LRColor.secondaryText)
                    }
                }
                VStack(alignment: .leading, spacing: 16) {
                    Text("Your record").font(.headline)
                    Text(model.evidenceLabel(concept.id)).font(.subheadline)
                        .accessibilityIdentifier("learning.concept.evidence")
                    Divider().overlay(LRColor.separator)
                    if let date = model.progress.selfReportedLearned[concept.id] {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Learned · self-reported").font(.subheadline.weight(.semibold))
                            Text("You marked this on \(date.formatted(date: .abbreviated, time: .omitted)).")
                                .font(.caption).foregroundStyle(LRColor.secondaryText)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            Button("I feel I've learned this") {
                                model.save { if $0.selfReportedLearned[concept.id] == nil { $0.selfReportedLearned[concept.id] = Date() } }
                            }
                            .frame(minHeight: 44).disabled(!model.canSave)
                            .foregroundStyle(LRColor.accent)
                            .accessibilityIdentifier("learning.markLearned")
                            Text("Saves your own assessment, separately from question results.")
                                .font(.caption).foregroundStyle(LRColor.secondaryText)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).learningCard()
                relatedReadings
                if !attempts.isEmpty { history }
                if let error = model.errorMessage { Text(error).font(.callout).foregroundStyle(.red) }
            }
            .frame(maxWidth: 640, alignment: .leading)
            .padding(20).frame(maxWidth: .infinity)
        }
        .background(LRColor.background).foregroundStyle(LRColor.text).tint(LRColor.accent)
        .navigationTitle("Concept").navigationBarTitleDisplayMode(.inline).learningPaperToolbar()
        .sheet(item: $check) { LearningCheckView(model: model, question: $0, reviewing: true) }
    }

    private var relatedReadings: some View {
        VStack(alignment: .leading, spacing: 12) {
            LearningSectionHeading(title: "Read about it")
            VStack(spacing: 0) {
                let lessons = course.lessons.filter { $0.conceptIds.contains(concept.id) }
                ForEach(Array(lessons.enumerated()), id: \.element.id) { index, lesson in
                    NavigationLink {
                        LearningLessonView(model: model, course: course, lesson: lesson)
                    } label: {
                        LearningRowLabel(title: lesson.title, symbol: "book")
                    }.buttonStyle(.plain)
                    if index < lessons.count - 1 { Divider().overlay(LRColor.separator).padding(.leading, 16) }
                }
            }.background(LRColor.surface, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 12) {
            LearningSectionHeading(title: "Saved checks", detail: "\(attempts.count) answers")
            VStack(spacing: 0) {
                ForEach(Array(attempts.prefix(20).enumerated()), id: \.element.id) { index, attempt in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(attempt.isReview ? "Review" : "Initial") check · \(attempt.correct ? "Correct" : "Incorrect")")
                            .font(.subheadline.weight(.medium))
                        Text(attempt.usedHelp ? "Help used" : "No help reported").font(.subheadline)
                            .foregroundStyle(LRColor.secondaryText)
                        Text(attempt.date.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption).foregroundStyle(LRColor.secondaryText)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                    if index < min(attempts.count, 20) - 1 { Divider().overlay(LRColor.separator).padding(.leading, 16) }
                }
            }.background(LRColor.surface, in: RoundedRectangle(cornerRadius: 16))
            if attempts.count > 20 {
                Text("Showing the latest 20 of \(attempts.count) saved answers.")
                    .font(.caption).foregroundStyle(LRColor.secondaryText)
            }
        }
    }
}

struct LearningAskView: View {
    @ObservedObject var model: LearningViewModel
    let course: LearningCourse
    let lesson: LearningCourse.Lesson
    @EnvironmentObject private var modelPrefs: AIModelPreferenceStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var session = AskSession(ai: AIServiceResolver.makeDefault())
    @StateObject private var voice = AskVoiceController(dictation: AskVoiceFactory.makeDictation(),
        speaker: AskVoiceFactory.makeReplySpeaker(services: nil))

    var body: some View {
        AskSheet(session: session, voice: voice, onClose: { dismiss() })
            .onAppear {
                _ = model.recordTeachingExposure(conceptIDs: lesson.conceptIds)
                session.updateAI(AIServiceResolver.makeDefault(modelPreference: modelPrefs.askModel))
                let preferences = model.progress.preferences
                session.configure(seedQuestion: "Help me understand this idea", selectedText: lesson.title) { question, _ in
                    AskRequest(userQuestion: question, surroundingContext: lesson.text,
                        currentChapterTitle: lesson.title, bookTitle: course.title, bookAuthor: "GenBooks",
                        consumedContext: "[CURRENT LESSON; opening a lesson does not prove it was read]\n\(lesson.text)",
                        readerPreferencesSummary: "Goal: \(preferences.goal). Time budget: \(preferences.sessionMinutes) minutes. \(preferences.prefersExamples ? "Prefer concrete everyday examples." : "Prefer a concise conceptual explanation.")")
                }
            }
            .onDisappear {
                session.cancelInFlight()
                _ = model.recordTeachingExposure(conceptIDs: lesson.conceptIds)
            }
    }
}
