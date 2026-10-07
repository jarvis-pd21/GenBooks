import XCTest
@testable import LivingReader

final class LearningProgressTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 86_400

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("LearningProgressTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func attempt(
        _ question: String = "q1", days: Double = 0, concept: String = "force",
        correct: Bool = true, help: Bool = false, review: Bool = false
    ) -> LearningAttempt {
        LearningAttempt(conceptID: concept, questionID: question, selectedChoiceID: "b",
                        correct: correct, usedHelp: help, isReview: review,
                        date: start.addingTimeInterval(days * day))
    }

    func testDemandingFeedbackStopsOverridingReviewsAfterOneDay() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var progress = LearningProgress()
        progress.lastLessonID = "l1"
        progress.feedback = [LearningFeedback(lessonID: "l1", experience: .tooDemanding, date: now)]
        progress.selfReportedLearned["force"] = now.addingTimeInterval(-2 * 86_400)
        XCTAssertEqual(LearningRecommendation.suggest(lessonIDs: ["l1", "l2"], conceptIDs: ["force"], progress: progress, now: now)?.kind, .read(lessonID: "l1"))
        XCTAssertEqual(LearningRecommendation.suggest(lessonIDs: ["l1", "l2"], conceptIDs: ["force"], progress: progress, now: now.addingTimeInterval(86_400))?.kind, .review(conceptID: "force"))
        XCTAssertEqual(LearningRecommendation.suggest(lessonIDs: ["l1", "l2"], conceptIDs: ["force"], progress: progress, now: now.addingTimeInterval(-1))?.kind, .review(conceptID: "force"))
    }

    func testMissingFileLoadsEmptyAndReadDoesNotCreateIt() throws {
        let root = try directory()
        let store = try LearningProgressStore(directory: root)
        XCTAssertEqual(try store.load(), LearningProgress())
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("learning.json").path))
    }

    func testReopenPreservesPreferencesUnknownIDsAndISOSecondDates() throws {
        let root = try directory()
        let store = try LearningProgressStore(directory: root)
        let first = attempt("future-question", concept: "future-concept")
        let result = try store.update {
            $0.preferences = LearningPreferences(sessionMinutes: 20, goal: "Understand energy", prefersExamples: false)
            $0.lastLessonID = "future-lesson"
            $0.completedLessonIDs = ["future-lesson"]
            $0.selfReportedLearned = ["future-concept": start]
            $0.attempts = [first]
            $0.feedback = [LearningFeedback(lessonID: "future-lesson", experience: .enjoyable, date: start)]
        }
        XCTAssertEqual(try LearningProgressStore(directory: root).load(), result)
        XCTAssertEqual(result.attempts.first, first)
        XCTAssertEqual(result.selfReportedLearned["future-concept"], start)
        XCTAssertEqual(result.feedback.first?.date, start)
        let json = try String(contentsOf: root.appendingPathComponent("learning.json"), encoding: .utf8)
        XCTAssertTrue(json.contains("2027-01-15T08:00:00Z"))
    }

    func testUpdateReturnsThePersistedISOSecondRepresentation() throws {
        let store = try LearningProgressStore(directory: directory())
        let saved = try store.update { $0.selfReportedLearned["force"] = start.addingTimeInterval(0.75) }
        XCTAssertEqual(saved, try store.load())
        XCTAssertEqual(saved.selfReportedLearned["force"], start)
    }

    func testCorruptBytesArePreservedAndMutationDoesNotRun() throws {
        let root = try directory()
        let file = root.appendingPathComponent("learning.json")
        let bytes = Data("{\"schemaVersion\":1,broken".utf8)
        try bytes.write(to: file)
        let store = try LearningProgressStore(directory: root)
        var invoked = false
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.update { _ in invoked = true })
        XCTAssertFalse(invoked)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }

    func testUnsupportedSchemaAndInvalidBudgetAreNeverOverwritten() throws {
        for invalidVersion in [true, false] {
            let root = try directory()
            let file = root.appendingPathComponent("learning.json")
            var invalid = LearningProgress()
            if invalidVersion { invalid.schemaVersion = 2 } else { invalid.preferences.sessionMinutes = 11 }
            let bytes = try JSONCoding.encoder.encode(invalid)
            try bytes.write(to: file)
            let store = try LearningProgressStore(directory: root)
            XCTAssertThrowsError(try store.load())
            XCTAssertThrowsError(try store.update { $0.preferences.sessionMinutes = 5 })
            XCTAssertEqual(try Data(contentsOf: file), bytes)
        }
    }

    func testDuplicateIDsAndEmptyEntryIDsRejectWithoutChangingSavedData() throws {
        let root = try directory()
        let store = try LearningProgressStore(directory: root)
        let first = attempt()
        let feedback = LearningFeedback(lessonID: "lesson1", experience: .neutral, date: start)
        _ = try store.update { $0.attempts = [first]; $0.feedback = [feedback] }
        let file = root.appendingPathComponent("learning.json")
        let before = try Data(contentsOf: file)
        XCTAssertThrowsError(try store.update { $0.attempts.append(first) })
        XCTAssertThrowsError(try store.update { $0.feedback.append(feedback) })
        XCTAssertThrowsError(try store.update { $0.attempts[0].questionID = " \n" })
        XCTAssertThrowsError(try store.update { $0.selfReportedLearned[""] = start })
        XCTAssertThrowsError(try store.update { $0.lastLessonID = "" })
        XCTAssertEqual(try Data(contentsOf: file), before)
    }

    func testThrowingMutationPreservesFileAndSiblingManuscript() throws {
        enum Stop: Error { case requested }
        let root = try directory()
        let sibling = root.appendingPathComponent("manuscript.json")
        let manuscript = Data("immutable manuscript bytes".utf8)
        try manuscript.write(to: sibling)
        let store = try LearningProgressStore(directory: root)
        _ = try store.update { $0.completedLessonIDs = ["lesson1"] }
        let file = root.appendingPathComponent("learning.json")
        let before = try Data(contentsOf: file)
        XCTAssertThrowsError(try store.update { $0.completedLessonIDs.append("lesson2"); throw Stop.requested })
        XCTAssertEqual(try Data(contentsOf: file), before)
        XCTAssertEqual(try Data(contentsOf: sibling), manuscript)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)), ["learning.json", "manuscript.json"])
    }

    func testConcurrentUpdatesOnOneStoreDoNotLoseEntries() throws {
        let store = try LearningProgressStore(directory: directory())
        DispatchQueue.concurrentPerform(iterations: 16) { index in
            _ = try? store.update { $0.completedLessonIDs.append("lesson-\(index)") }
        }
        let loaded = try store.load()
        XCTAssertEqual(Set(loaded.completedLessonIDs), Set((0..<16).map { "lesson-\($0)" }))
    }

    func testReadingAloneIsNotUnderstandingEvidenceAndManualLearnedSchedulesReview() {
        var progress = LearningProgress()
        progress.completedLessonIDs = ["lesson1"]
        progress.lastLessonID = "lesson1"
        XCTAssertNil(LearningRecommendation.dueDate(conceptID: "force", progress: progress))
        XCTAssertFalse(LearningRecommendation.recalledLater(conceptID: "force", progress: progress))
        progress.selfReportedLearned["force"] = start
        XCTAssertEqual(LearningRecommendation.dueDate(conceptID: "force", progress: progress), start.addingTimeInterval(day))
        XCTAssertFalse(LearningRecommendation.recalledLater(conceptID: "force", progress: progress))
    }

    func testFreshDelayedReviewsAdvanceOneThreeSevenFourteenThirtyDayIntervals() {
        var progress = LearningProgress()
        let dates = [0.0, 1.0, 4.0, 11.0, 25.0, 55.0]
        let expectedDueDays = [1.0, 4.0, 11.0, 25.0, 55.0, 85.0]
        for index in dates.indices {
            progress.attempts.append(attempt("q\(index)", days: dates[index], review: index > 0))
            XCTAssertEqual(LearningRecommendation.dueDate(conceptID: "force", progress: progress),
                           start.addingTimeInterval(expectedDueDays[index] * day))
        }
        XCTAssertTrue(LearningRecommendation.recalledLater(conceptID: "force", progress: progress))
    }

    func testSameDaySameQuestionHelpAndNonReviewDoNotAdvance() {
        let cases = [
            attempt("q2", days: 0.5, review: true),
            attempt("q1", days: 2, review: true),
            attempt("q2", days: 2, help: true, review: true),
            attempt("q2", days: 2, review: false),
        ]
        for last in cases {
            var progress = LearningProgress()
            progress.attempts = [attempt(), last]
            XCTAssertEqual(LearningRecommendation.dueDate(conceptID: "force", progress: progress), last.date.addingTimeInterval(day))
            XCTAssertFalse(LearningRecommendation.recalledLater(conceptID: "force", progress: progress))
        }
    }

    func testFirstUnassistedSuccessStillUsesOneDayAfterAnEarlierIncorrectAttempt() {
        var progress = LearningProgress()
        progress.attempts = [attempt("q1", correct: false), attempt("q2", days: 1, review: true)]
        XCTAssertEqual(LearningRecommendation.dueDate(conceptID: "force", progress: progress), start.addingTimeInterval(2 * day))
        // The delayed answer is evidence even though the first-success scheduling policy stays conservative.
        XCTAssertTrue(LearningRecommendation.recalledLater(conceptID: "force", progress: progress))
    }

    func testTwentyFourHourBoundaryAndChronologicalOrdering() {
        var progress = LearningProgress()
        progress.attempts = [attempt("q2", days: (day - 1) / day, review: true), attempt()]
        XCTAssertFalse(LearningRecommendation.recalledLater(conceptID: "force", progress: progress))
        progress.attempts[0].date = start.addingTimeInterval(day)
        XCTAssertTrue(LearningRecommendation.recalledLater(conceptID: "force", progress: progress))
        XCTAssertEqual(LearningRecommendation.dueDate(conceptID: "force", progress: progress), start.addingTimeInterval(4 * day))
    }

    func testAnOldAttemptCannotMakeAnImmediateRepeatCountAsDelayedRecall() {
        var progress = LearningProgress()
        progress.attempts = [attempt("q1"), attempt("q2", days: 3, help: true), attempt("q2", days: 3.01, review: true)]
        XCTAssertFalse(LearningRecommendation.recalledLater(conceptID: "force", progress: progress))
        XCTAssertEqual(LearningRecommendation.dueDate(conceptID: "force", progress: progress), start.addingTimeInterval(4.01 * day))
    }

    func testSameDaySuccessDoesNotAdvanceAnExistingInterval() {
        var progress = LearningProgress()
        progress.attempts = [attempt("q1"), attempt("q2", days: 1, review: true), attempt("q3", days: 1.25, review: true)]
        XCTAssertEqual(LearningRecommendation.dueDate(conceptID: "force", progress: progress), start.addingTimeInterval(4.25 * day))
    }

    func testFailedOrHintedReviewResetsIntervalWithoutErasingHistoricalEvidence() throws {
        for help in [false, true] {
            let store = try LearningProgressStore(directory: directory())
            let success = attempt("q2", days: 1, review: true)
            _ = try store.update {
                $0.selfReportedLearned["force"] = start
                $0.attempts = [attempt("q1"), success]
            }
            let saved = try store.update { $0.attempts.append(attempt("q3", days: 4, correct: help, help: help, review: true)) }
            XCTAssertEqual(saved.selfReportedLearned["force"], start)
            XCTAssertEqual(saved.attempts.count, 3)
            XCTAssertEqual(saved.attempts[1], success)
            XCTAssertTrue(LearningRecommendation.recalledLater(conceptID: "force", progress: saved))
            XCTAssertEqual(LearningRecommendation.dueDate(conceptID: "force", progress: saved), start.addingTimeInterval(5 * day))
        }
    }

    func testSelfReportCanAnchorFirstDelayedReviewButFirstAttemptKeepsOneDayInterval() {
        var progress = LearningProgress()
        progress.selfReportedLearned["force"] = start
        progress.attempts = [attempt("q1", days: 1, review: true)]
        XCTAssertTrue(LearningRecommendation.recalledLater(conceptID: "force", progress: progress))
        XCTAssertEqual(LearningRecommendation.dueDate(conceptID: "force", progress: progress), start.addingTimeInterval(2 * day))
        progress.selfReportedLearned["force"] = start.addingTimeInterval(10 * day)
        XCTAssertEqual(LearningRecommendation.dueDate(conceptID: "force", progress: progress), start.addingTimeInterval(11 * day))
    }

    func testRecommendationUsesOldestDueAndStableConceptOrderOnTies() {
        var progress = LearningProgress()
        progress.selfReportedLearned = ["force": start, "energy": start, "momentum": start.addingTimeInterval(-day)]
        let now = start.addingTimeInterval(3 * day)
        XCTAssertEqual(LearningRecommendation.suggest(lessonIDs: ["l1"], conceptIDs: ["force", "energy", "momentum"], progress: progress, now: now)?.kind, .review(conceptID: "momentum"))
        progress.selfReportedLearned.removeValue(forKey: "momentum")
        let tied = LearningRecommendation.suggest(lessonIDs: ["l1"], conceptIDs: ["energy", "force"], progress: progress, now: now)
        XCTAssertEqual(tied?.kind, .review(conceptID: "energy"))
        XCTAssertEqual(tied?.reason, "A later check is due. You can read instead.")
    }

    func testTimeBudgetIsPreferenceAndLatestDemandingFeedbackOverridesDueReview() {
        var progress = LearningProgress()
        progress.preferences.sessionMinutes = 5
        progress.completedLessonIDs = ["l1"]
        progress.lastLessonID = "l1"
        let initial = LearningRecommendation.suggest(lessonIDs: ["l1", "l2"], conceptIDs: [], progress: progress, now: start)
        XCTAssertEqual(initial?.kind, .read(lessonID: "l2"))
        XCTAssertEqual(initial?.reason, "Your reading budget is 5 minutes. Read at your own pace.")
        progress.selfReportedLearned["force"] = start.addingTimeInterval(-2 * day)
        progress.feedback = [
            LearningFeedback(lessonID: "l1", experience: .tooDemanding, date: start),
            LearningFeedback(lessonID: "l1", experience: .enjoyable, date: start.addingTimeInterval(-day)),
        ]
        let suggestion = LearningRecommendation.suggest(lessonIDs: ["l1", "l2"], conceptIDs: ["force"], progress: progress, now: start)
        XCTAssertEqual(suggestion?.kind, .read(lessonID: "l1"))
        XCTAssertEqual(suggestion?.reason, "Keep this session short; you said the last one felt demanding.")
        XCTAssertEqual(progress.preferences.sessionMinutes, 5)
        progress.lastLessonID = "removed-lesson"
        XCTAssertEqual(LearningRecommendation.suggest(lessonIDs: ["l1", "l2"], conceptIDs: ["force"], progress: progress, now: start)?.kind, .read(lessonID: "l2"))
    }

    func testAllReadRevisitsValidLastLessonOrFirstAndEmptyCourseHasNoSuggestion() {
        var progress = LearningProgress()
        progress.completedLessonIDs = ["l1", "l2"]
        progress.lastLessonID = "l2"
        XCTAssertEqual(LearningRecommendation.suggest(lessonIDs: ["l1", "l2"], conceptIDs: [], progress: progress, now: start)?.kind, .revisit(lessonID: "l2"))
        progress.lastLessonID = "removed"
        XCTAssertEqual(LearningRecommendation.suggest(lessonIDs: ["l1", "l2"], conceptIDs: [], progress: progress, now: start)?.kind, .revisit(lessonID: "l1"))
        XCTAssertNil(LearningRecommendation.suggest(lessonIDs: [], conceptIDs: [], progress: progress, now: start))
    }
}
