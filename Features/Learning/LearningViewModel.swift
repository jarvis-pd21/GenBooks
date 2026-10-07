import Foundation
import SwiftUI

@MainActor
final class LearningViewModel: ObservableObject {
    @Published private(set) var course: LearningCourse?
    @Published private(set) var progress = LearningProgress()
    @Published var errorMessage: String?
    @Published private(set) var canSave = false
    @Published private(set) var isLoading = true
    private var store: LearningProgressStore?

    func load(directory: URL? = nil) {
        isLoading = true
        defer { isLoading = false }
        do {
            var root = try directory ?? LibraryViewModel.defaultRootDirectory().appendingPathComponent("Learning", isDirectory: true)
            #if DEBUG
            let args = ProcessInfo.processInfo.arguments
            if directory == nil, args.contains("-uitesting"), let flag = args.firstIndex(of: "-learningTestID"),
               args.indices.contains(flag + 1), let testID = UUID(uuidString: args[flag + 1]) {
                root = try LibraryViewModel.defaultRootDirectory().appendingPathComponent("LearningUITest-" + testID.uuidString)
            }
            #endif
            course = try LearningCourse.loadSnapshot(directory: root)
            let newStore = try LearningProgressStore(directory: root)
            let saved = try newStore.load()
            store = newStore
            progress = saved
            canSave = true
            errorMessage = nil
        } catch {
            canSave = false
            errorMessage = "Learning could not fully open. Existing saved files have been kept. Lessons already open can still be read. \(error.localizedDescription)"
        }
    }

    @discardableResult
    func save(_ mutation: (inout LearningProgress) throws -> Void) -> Bool {
        guard canSave, let store else { return false }
        do {
            progress = try store.update(mutation)
            errorMessage = nil
            return true
        } catch {
            errorMessage = "That change was not saved. Your previous progress is still available. \(error.localizedDescription)"
            return false
        }
    }

    var suggestion: LearningSuggestion? {
        guard canSave, let course else { return nil }
        return LearningRecommendation.suggest(lessonIDs: course.lessons.map(\.id), conceptIDs: course.concepts.map(\.id), progress: progress)
    }

    func markRead(_ lesson: LearningCourse.Lesson) -> Bool {
        save {
            LearningScore.recordTeaching(conceptIDs: lesson.conceptIds, progress: &$0)
            if !$0.completedLessonIDs.contains(lesson.id) { $0.completedLessonIDs.append(lesson.id) }
            $0.lastLessonID = lesson.id
        }
    }

    var scoreSummary: LearningScoreSummary { LearningScore.summary(progress: progress) }

    @discardableResult
    func recordTeachingExposure(conceptIDs: [String], now: Date = Date()) -> Bool {
        save { LearningScore.recordTeaching(conceptIDs: conceptIDs, progress: &$0, now: now) }
    }

    @discardableResult
    func recordHelpExposure(presentationID: UUID, now: Date = Date()) -> Bool {
        save { try LearningScore.recordHelp(presentationID: presentationID, progress: &$0, now: now) }
    }

    func startQuestionPresentation(_ question: LearningCourse.Question, reviewing: Bool,
        now: Date = Date()) -> LearningQuestionPresentation? {
        guard let course else { return nil }
        var result: LearningQuestionPresentation?
        let saved = save {
            result = LearningScore.startQuestionPresentation(conceptID: question.conceptId, questionID: question.id,
                isReview: reviewing, version: course.id, progress: &$0, now: now)
        }
        return saved ? result : nil
    }

    func submitAnswer(_ question: LearningCourse.Question, choiceID: String, usedHelp: Bool,
        presentationID: UUID, now: Date = Date()) -> LearningScoreReceipt? {
        var result: LearningScoreReceipt?
        let saved = save {
            guard let presentation = $0.questionPresentations.first(where: { $0.id == presentationID }),
                  presentation.questionID == question.id, presentation.conceptID == question.conceptId,
                  question.choices.contains(where: { $0.id == choiceID }) else {
                throw LearningScore.ScoreError.mismatchedQuestion
            }
            result = try LearningScore.submit(presentationID: presentationID, selectedChoiceID: choiceID,
                correct: choiceID == question.correctChoiceId, usedHelp: usedHelp, progress: &$0, now: now)
        }
        return saved ? result : nil
    }

    func question(conceptID: String, reviewing: Bool, now: Date = Date()) -> LearningCourse.Question? {
        guard let questions = course?.questions(for: conceptID, reviewing: reviewing), !questions.isEmpty else { return nil }
        if reviewing, let course {
            let slots = LearningScore.summary(progress: progress, now: now).slots
            let eligible = questions.filter {
                LearningScore.previewEligibility(conceptID: conceptID, questionID: $0.id, isReview: true,
                    version: course.id, progress: progress, now: now).canCount
            }
            func rank(_ question: LearningCourse.Question) -> Int {
                switch slots.first(where: { $0.id == question.id })?.status ?? .unknown {
                case .unknown: return 0
                case .incorrect: return 1
                case .correct: return 2
                }
            }
            if let next = eligible.min(by: { a, b in
                if rank(a) != rank(b) { return rank(a) < rank(b) }
                let aDate = slots.first(where: { $0.id == a.id })?.date ?? .distantPast
                let bDate = slots.first(where: { $0.id == b.id })?.date ?? .distantPast
                if aDate != bDate { return aDate < bDate }
                return questions.firstIndex(where: { $0.id == a.id })! < questions.firstIndex(where: { $0.id == b.id })!
            }) { return next }
        }
        // Prefer a fresh scenario. Once all have been seen, choose the least recently attempted.
        let savedAttempts = progress.attempts
        let savedExposures = progress.learningExposures
        return questions.min { a, b in
            func lastSeen(_ questionID: String) -> Date {
                let attempts = savedAttempts.filter { $0.questionID == questionID }.map(\.date)
                let exposures = savedExposures.filter { $0.questionID == questionID }.map(\.date)
                return (attempts + exposures).max() ?? .distantPast
            }
            let aDate = lastSeen(a.id)
            let bDate = lastSeen(b.id)
            if aDate == bDate { return questions.firstIndex(where: { $0.id == a.id })! < questions.firstIndex(where: { $0.id == b.id })! }
            return aDate < bDate
        }
    }

    func evidenceLabel(_ conceptID: String) -> String {
        guard canSave else { return "Progress unavailable" }
        if LearningRecommendation.recalledLater(conceptID: conceptID, progress: progress) { return "Answered a later check correctly" }
        if progress.attempts.contains(where: { $0.conceptID == conceptID && $0.correct && !$0.usedHelp }) { return "Answered a check correctly" }
        if progress.selfReportedLearned[conceptID] != nil { return "Learned · self-reported" }
        if progress.attempts.contains(where: { $0.conceptID == conceptID }) { return "Practicing" }
        return "Not checked yet"
    }
}
