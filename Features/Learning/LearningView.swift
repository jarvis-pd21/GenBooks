import SwiftUI

private enum LearningRoute: Hashable {
    case lesson(String)
    case concept(String)
}

struct LearningView: View {
    @ObservedObject var model: LearningViewModel
    @State private var path: [LearningRoute] = []
    @State private var showsSettings = false

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                LRColor.background.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        if let course = model.course {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Physics").font(.system(.largeTitle, design: .serif).weight(.semibold))
                                Text("\(course.lessons.count) readings · Available offline")
                                    .font(.subheadline).foregroundStyle(LRColor.secondaryText)
                            }
                            if let error = model.errorMessage { progressError(error) }
                            nextActivity(course)
                            if model.canSave {
                                NavigationLink {
                                    LearningScoreDetailView(model: model)
                                } label: {
                                    LearningScoreSummaryView(model: model)
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("learning.score")
                            }
                            readingPath(course)
                            VStack(spacing: 0) {
                                NavigationLink {
                                    LearningConceptCollectionView(model: model, course: course)
                                } label: {
                                    LearningRowLabel(title: "Concepts", subtitle: "\(course.concepts.count) ideas and your saved check results", symbol: "square.grid.2x2")
                                }
                                .accessibilityIdentifier("learning.concepts")
                                Divider().overlay(LRColor.separator).padding(.leading, 16)
                                NavigationLink {
                                    LearningSourcesView(course: course)
                                } label: {
                                    LearningRowLabel(title: "Sources and authorship", symbol: "text.book.closed")
                                }
                                .accessibilityIdentifier("learning.sources")
                                Divider().overlay(LRColor.separator).padding(.leading, 16)
                                NavigationLink {
                                    FoundationsView()
                                } label: {
                                    LearningRowLabel(title: "Foundations", subtitle: "How this learning system works", symbol: "info.circle")
                                }
                                .accessibilityIdentifier("learning.foundations")
                            }
                            .buttonStyle(.plain)
                            .background(LRColor.surface, in: RoundedRectangle(cornerRadius: 16))
                        } else if model.isLoading {
                            ProgressView("Opening your learning path…")
                                .frame(maxWidth: .infinity)
                        } else {
                            ContentUnavailableView("Lessons unavailable", systemImage: "book.closed",
                                description: Text("Your Library is still available."))
                            if let error = model.errorMessage { progressError(error) }
                        }
                    }
                    .foregroundStyle(LRColor.text)
                    .frame(maxWidth: 680, alignment: .leading)
                    .padding(20)
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Learning")
            .navigationBarTitleDisplayMode(.inline)
            .learningPaperToolbar()
            .navigationDestination(for: LearningRoute.self) { route in
                if let course = model.course {
                    switch route {
                    case .lesson(let id):
                        if let lesson = course.lessons.first(where: { $0.id == id }) {
                            LearningLessonView(model: model, course: course, lesson: lesson)
                        }
                    case .concept(let id):
                        if let concept = course.concepts.first(where: { $0.id == id }) {
                            LearningConceptView(model: model, course: course, concept: concept)
                        }
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showsSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings")
                        .accessibilityIdentifier("learning.settings")
                }
            }
            .sheet(isPresented: $showsSettings) { AppSettingsView(learningModel: model) }
        }
        .tint(LRColor.accent)
    }

    private func readingPath(_ course: LearningCourse) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            LearningSectionHeading(title: "Readings", detail: model.canSave
                ? "\(course.lessons.filter { model.progress.completedLessonIDs.contains($0.id) }.count) of \(course.lessons.count) marked read"
                : "Progress unavailable")
            VStack(spacing: 0) {
                ForEach(Array(course.lessons.enumerated()), id: \.element.id) { index, lesson in
                    NavigationLink {
                        LearningLessonView(model: model, course: course, lesson: lesson)
                    } label: {
                        HStack(alignment: .top, spacing: 14) {
                            Text(String(index + 1))
                                .font(.subheadline.monospacedDigit()).foregroundStyle(LRColor.secondaryText)
                                .frame(minWidth: 20).accessibilityHidden(true)
                            Text(lesson.title).font(.body.weight(.medium))
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if model.canSave && model.progress.completedLessonIDs.contains(lesson.id) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(LRColor.accent).accessibilityHidden(true)
                            } else {
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold)).foregroundStyle(LRColor.secondaryText)
                                    .accessibilityHidden(true)
                            }
                        }
                        .padding(16).frame(minHeight: 56)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("learning.lesson.\(lesson.id)")
                    .accessibilityLabel("Reading \(index + 1). \(lesson.title)")
                    .accessibilityValue(!model.canSave ? "Progress unavailable" : model.progress.completedLessonIDs.contains(lesson.id) ? "Marked read" : "Not marked read")
                    if index < course.lessons.count - 1 { Divider().overlay(LRColor.separator).padding(.leading, 50) }
                }
            }
            .background(LRColor.surface, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    @ViewBuilder private func nextActivity(_ course: LearningCourse) -> some View {
        if let suggestion = model.suggestion {
            VStack(alignment: .leading, spacing: 14) {
                Text("NEXT").font(.caption.weight(.semibold)).foregroundStyle(LRColor.accent)
                switch suggestion.kind {
                case .read(let id), .revisit(let id):
                    if let lesson = course.lessons.first(where: { $0.id == id }) {
                        Text(lesson.title).font(.system(.title2, design: .serif))
                        Text(suggestion.reason).font(.subheadline).foregroundStyle(LRColor.secondaryText)
                        NavigationLink(value: LearningRoute.lesson(lesson.id)) {
                            Label("Read", systemImage: "book").frame(minHeight: 28)
                        }
                        .buttonStyle(.borderedProminent).foregroundStyle(LRColor.onAccent)
                        .accessibilityIdentifier("learning.next.read")
                    }
                case .review(let id):
                    if let concept = course.concepts.first(where: { $0.id == id }) {
                        Text(concept.title).font(.system(.title2, design: .serif))
                        Text(suggestion.reason).font(.subheadline).foregroundStyle(LRColor.secondaryText)
                        NavigationLink(value: LearningRoute.concept(concept.id)) {
                            Label("Review concept", systemImage: "arrow.clockwise").frame(minHeight: 28)
                        }
                        .buttonStyle(.borderedProminent).foregroundStyle(LRColor.onAccent)
                        .accessibilityIdentifier("learning.next.review")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .learningCard()
        }
    }

    private func progressError(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Progress needs attention", systemImage: "exclamationmark.circle").font(.headline)
            Text(error).font(.callout)
            Button("Try opening progress again") { model.load() }
                .frame(minHeight: 44)
        }.learningCard()
    }
}

struct LearningConceptCollectionView: View {
    @ObservedObject var model: LearningViewModel
    let course: LearningCourse

    var body: some View {
        List {
            Section {
                ForEach(course.concepts) { concept in
                    NavigationLink {
                        LearningConceptView(model: model, course: course, concept: concept)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(concept.title).font(.headline)
                            Text(model.evidenceLabel(concept.id)).font(.subheadline)
                                .foregroundStyle(LRColor.secondaryText)
                        }.padding(.vertical, 8)
                    }
                    .listRowBackground(LRColor.surface)
                    .accessibilityIdentifier("learning.concept.\(concept.id)")
                }
            } footer: {
                Text("Your self-reported learning and saved question results remain separate.")
            }
        }
        .scrollContentBackground(.hidden).background(LRColor.background)
        .foregroundStyle(LRColor.text).tint(LRColor.accent)
        .navigationTitle("Concepts").navigationBarTitleDisplayMode(.inline)
        .learningPaperToolbar()
    }
}

struct LearningPreferencesView: View {
    @ObservedObject var model: LearningViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var minutes = 10
    @State private var goal = ""
    @State private var examples = true

    var body: some View {
        NavigationStack {
            Form {
                if !model.canSave {
                    Text("Saved preferences are unavailable. Return to Learning and try opening progress again.")
                } else {
                    Section {
                        Picker("Time budget", selection: $minutes) {
                            Text("5 minutes").tag(5)
                            Text("10 minutes").tag(10)
                            Text("20 minutes").tag(20)
                        }
                    } header: { Text("What fits today?") }
                    footer: { Text("A suggested budget, not a timer or a deadline.") }
                    Section {
                        TextField("Your goal", text: $goal, axis: .vertical)
                        Toggle("Use everyday examples", isOn: $examples)
                    } header: { Text("When you ask BookBot") }
                    footer: { Text("These preferences guide BookBot replies. The six readings keep their original order and wording.") }
                }
                if let error = model.errorMessage { Text(error).foregroundStyle(.red) }
            }
            .scrollContentBackground(.hidden).background(LRColor.background)
            .navigationTitle("Learning preferences").navigationBarTitleDisplayMode(.inline)
            .learningPaperToolbar()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if model.save({ $0.preferences = LearningPreferences(sessionMinutes: minutes, goal: goal, prefersExamples: examples) }) { dismiss() }
                    }
                    .disabled(!model.canSave).accessibilityIdentifier("learning.preferences.save")
                }
            }
            .onAppear {
                minutes = model.progress.preferences.sessionMinutes
                goal = model.progress.preferences.goal
                examples = model.progress.preferences.prefersExamples
            }
        }.tint(LRColor.accent)
    }
}

struct LearningSectionHeading: View {
    let title: String
    var detail: String? = nil
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 5)) : AnyLayout(HStackLayout(alignment: .firstTextBaseline))
        layout {
            Text(title).font(.headline)
            if !typeSize.isAccessibilitySize { Spacer(minLength: 8) }
            if let detail { Text(detail).font(.caption).foregroundStyle(LRColor.secondaryText) }
        }.accessibilityAddTraits(.isHeader)
    }
}

struct LearningRowLabel: View {
    let title: String
    var subtitle: String? = nil
    var symbol: String? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let symbol { Image(systemName: symbol).foregroundStyle(LRColor.accent).frame(width: 24).accessibilityHidden(true) }
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.body.weight(.medium))
                if let subtitle { Text(subtitle).font(.subheadline).foregroundStyle(LRColor.secondaryText) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                .foregroundStyle(LRColor.secondaryText).accessibilityHidden(true)
        }
        .foregroundStyle(LRColor.text)
        .padding(16).frame(minHeight: 56).contentShape(Rectangle())
    }
}

extension View {
    func learningCard() -> some View {
        self.padding(20).background(LRColor.surface, in: RoundedRectangle(cornerRadius: 16))
    }

    func learningPaperToolbar() -> some View {
        self.genBooksNavigationBar()
    }
}
