import XCTest
@testable import LivingReader

final class LearningScoreTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 86_400

    private func date(_ days: Double) -> Date { start.addingTimeInterval(days * day) }
    private func prepared() -> LearningProgress {
        var progress = LearningProgress()
        LearningScore.recordTeaching(conceptIDs: ["force"], progress: &progress, now: start)
        return progress
    }
    private func present(_ progress: inout LearningProgress, question: String = "force-later-1",
        days: Double = 1, review: Bool = true) -> LearningQuestionPresentation {
        LearningScore.startQuestionPresentation(conceptID: "force", questionID: question,
            isReview: review, progress: &progress, now: date(days))
    }
    private func submit(_ progress: inout LearningProgress, _ presentation: LearningQuestionPresentation,
        correct: Bool = true, help: Bool = false, days: Double = 1) throws -> LearningScoreReceipt {
        try LearningScore.submit(presentationID: presentation.id, selectedChoiceID: correct ? "b" : "a",
            correct: correct, usedHelp: help, progress: &progress, now: date(days))
    }
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LearningScoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testUntestedIsUnknownAndTeachingDoesNotAwardPoints() {
        let progress = prepared()
        let summary = LearningScore.summary(progress: progress, now: date(20))
        XCTAssertEqual(summary.score, 0)
        XCTAssertEqual(summary.completedSlotCount, 0)
        XCTAssertEqual(summary.slots.count, 10)
        XCTAssertTrue(summary.slots.allSatisfy { $0.status == .unknown && $0.date == nil && !$0.older })
    }

    func testTwentyFourHourBoundaryIsComputedBeforePresentation() throws {
        var early = prepared()
        let earlyQuestion = present(&early, days: 1 - 1 / day)
        XCTAssertFalse(earlyQuestion.eligibility.canCount)
        // Waiting on the same open prompt cannot turn a practice presentation into delayed evidence.
        XCTAssertFalse(try submit(&early, earlyQuestion, days: 2).counted)
        var exact = prepared()
        let exactQuestion = present(&exact)
        XCTAssertTrue(exactQuestion.eligibility.canCount)
        XCTAssertEqual(try submit(&exact, exactQuestion).delta, 10)
    }

    func testSevenDayQuestionExposureBoundaryAndSkippedPresentation() {
        var progress = prepared()
        _ = present(&progress, days: 1) // Skipped, but the prompt was still seen.
        var early = progress
        XCTAssertFalse(present(&early, days: 8 - 1 / day).eligibility.canCount)
        XCTAssertTrue(present(&progress, days: 8).eligibility.canCount)
        XCTAssertTrue(progress.attempts.isEmpty)
    }

    func testPlusTenRepeatZeroMinusTenAndRecoveryAreBoundedPerSlot() throws {
        var progress = prepared()
        let first = present(&progress)
        XCTAssertEqual(try submit(&progress, first).delta, 10)
        let repeatQuestion = present(&progress, days: 8)
        XCTAssertEqual(try submit(&progress, repeatQuestion, days: 8).delta, 0)
        XCTAssertEqual(LearningScore.summary(progress: progress).score, 10)
        let wrong = present(&progress, days: 15)
        XCTAssertEqual(try submit(&progress, wrong, correct: false, days: 15).delta, -10)
        let summary = LearningScore.summary(progress: progress)
        XCTAssertEqual(summary.score, 0)
        XCTAssertEqual(summary.completedSlotCount, 1)
        XCTAssertEqual(summary.slots.first { $0.id == "force-later-1" }?.status, .incorrect)
        let recovery = present(&progress, days: 22)
        XCTAssertEqual(try submit(&progress, recovery, days: 22).delta, 10)
        XCTAssertEqual(progress.scoreReceipts.count, 4)
    }

    func testInitialWrongIsCountedEvidenceButNotNegativePoints() throws {
        var progress = prepared()
        let question = present(&progress)
        let receipt = try submit(&progress, question, correct: false)
        XCTAssertTrue(receipt.counted)
        XCTAssertEqual(receipt.delta, 0)
        XCTAssertEqual(receipt.previousStatus, .unknown)
        XCTAssertEqual(receipt.newStatus, .incorrect)
    }

    func testHelpRecordedBeforeSaveOverridesFalseHelpFlag() throws {
        var progress = prepared()
        let question = present(&progress)
        try LearningScore.recordHelp(presentationID: question.id, progress: &progress, now: date(1))
        let receipt = try submit(&progress, question)
        XCTAssertTrue(receipt.usedHelp)
        XCTAssertFalse(receipt.counted)
        XCTAssertEqual(receipt.delta, 0)
        XCTAssertTrue(progress.attempts[0].usedHelp)
        XCTAssertEqual(LearningScore.summary(progress: progress).completedSlotCount, 0)
    }

    func testExplicitHelpFlagIsUnscoredEvenWithoutRevealEvent() throws {
        var progress = prepared()
        let question = present(&progress)
        XCTAssertFalse(try submit(&progress, question, help: true).counted)
        XCTAssertEqual(progress.attempts.count, 1)
    }

    func testTeachingAfterPresentationInSameSecondDisqualifies() throws {
        var progress = prepared()
        let question = present(&progress)
        LearningScore.recordTeaching(conceptIDs: ["force"], progress: &progress, now: date(1))
        let receipt = try submit(&progress, question)
        XCTAssertFalse(receipt.counted)
        XCTAssertEqual(receipt.delta, 0)
        XCTAssertTrue(receipt.reason.contains("teaching"))
    }

    func testParallelEligiblePresentationsCannotBothCount() throws {
        var progress = prepared()
        let first = present(&progress)
        XCTAssertTrue(first.eligibility.canCount)
        XCTAssertTrue(try submit(&progress, first, correct: false).counted)
        let second = present(&progress, question: "force-now-2")
        XCTAssertFalse(second.eligibility.canCount)
        XCTAssertFalse(try submit(&progress, second).counted)
        XCTAssertEqual(LearningScore.summary(progress: progress).completedSlotCount, 1)
    }

    func testAnotherPresentationInvalidatesTheOlderPendingCheck() throws {
        var progress = prepared()
        let first = present(&progress)
        _ = present(&progress, question: "force-now-1") // Still invalidates even when practice was skipped.
        let receipt = try submit(&progress, first)
        XCTAssertFalse(receipt.counted)
        XCTAssertTrue(receipt.reason.contains("another question"))
    }

    func testPureEligibilityPreviewDoesNotRecordExposure() {
        let progress = prepared()
        let before = progress
        let eligibility = LearningScore.previewEligibility(conceptID: "force", questionID: "force-later-1",
            isReview: true, progress: progress, now: date(1))
        XCTAssertTrue(eligibility.canCount)
        XCTAssertEqual(progress, before)
        XCTAssertTrue(progress.questionPresentations.isEmpty)
    }

    func testAnswerFeedbackRestartsConceptAndQuestionClocks() throws {
        var progress = prepared()
        let question = present(&progress)
        _ = try submit(&progress, question, days: 2)
        var early = progress
        XCTAssertFalse(present(&early, question: "force-now-2", days: 3 - 1 / day).eligibility.canCount)
        XCTAssertTrue(present(&progress, question: "force-now-2", days: 3).eligibility.canCount)
        var repeated = progress
        XCTAssertFalse(present(&repeated, days: 9 - 1 / day).eligibility.canCount)
        XCTAssertTrue(present(&progress, days: 9).eligibility.canCount)
    }

    func testOrdinaryPracticeAndNonDesignatedQuestionsStillFeedAttempts() throws {
        for (questionID, review) in [("force-now-2", false), ("force-now-1", true)] {
            var progress = prepared()
            let question = present(&progress, question: questionID, review: review)
            let receipt = try submit(&progress, question)
            XCTAssertFalse(receipt.counted)
            XCTAssertEqual(progress.attempts.count, 1)
            XCTAssertEqual(progress.attempts[0].isReview, review)
            XCTAssertEqual(LearningScore.summary(progress: progress).score, 0)
        }
    }

    func testDuplicateSubmissionPreservesFirstWrongAnswerAndExposureCount() throws {
        var progress = prepared()
        let question = present(&progress)
        let first = try submit(&progress, question, correct: false)
        let before = progress
        let duplicate = try submit(&progress, question, correct: true, days: 20)
        XCTAssertEqual(first, duplicate)
        XCTAssertEqual(progress, before)
        XCTAssertEqual(progress.attempts.first?.selectedChoiceID, "a")
    }

    func testEvidenceAgesWithoutScoreDecayAndStrictFourteenDayBoundary() throws {
        var progress = prepared()
        let question = present(&progress)
        _ = try submit(&progress, question)
        XCTAssertFalse(LearningScore.summary(progress: progress, now: date(15)).slots.first { $0.id == question.questionID }!.older)
        let later = LearningScore.summary(progress: progress, now: date(15).addingTimeInterval(1))
        XCTAssertTrue(later.slots.first { $0.id == question.questionID }!.older)
        XCTAssertEqual(later.score, 10)
        XCTAssertEqual(LearningScore.summary(progress: progress, now: date(500)).score, 10)
    }

    func testLegacyDecodePreservesHistoryWithoutManufacturingScore() throws {
        let legacy = """
        {"schemaVersion":1,"preferences":{"sessionMinutes":10,"goal":"Physics","prefersExamples":true},
        "lastLessonID":"physics-02","completedLessonIDs":["physics-02"],"selfReportedLearned":{},
        "attempts":[{"id":"A2222222-2222-2222-2222-222222222222","conceptID":"force","questionID":"force-now-2",
        "selectedChoiceID":"b","correct":true,"usedHelp":false,"isReview":true,"date":"2027-01-15T08:00:00Z"}],"feedback":[]}
        """
        var progress = try JSONCoding.decoder.decode(LearningProgress.self, from: Data(legacy.utf8))
        XCTAssertEqual(progress.attempts.count, 1)
        XCTAssertNil(progress.attempts[0].presentationID)
        XCTAssertEqual(LearningScore.summary(progress: progress).completedSlotCount, 0)
        let baseline = present(&progress, days: 10)
        XCTAssertFalse(baseline.eligibility.canCount)
        XCTAssertEqual(progress.legacyScoreBaselineAt, date(10))
        var early = progress
        XCTAssertFalse(present(&early, question: "force-now-2", days: 17 - 1 / day).eligibility.canCount)
        XCTAssertTrue(present(&progress, question: "force-now-2", days: 17).eligibility.canCount)
        XCTAssertEqual(progress.attempts.count, 1)
    }

    func testNoTeachingBaselineAndUnknownContentVersionCannotCount() {
        var progress = LearningProgress()
        XCTAssertFalse(present(&progress).eligibility.canCount)
        var known = prepared()
        let changedVersion = LearningScore.startQuestionPresentation(conceptID: "force", questionID: "force-later-1",
            isReview: true, version: "physics-foundations-v2", progress: &known, now: date(1))
        XCTAssertFalse(changedVersion.eligibility.canCount)
    }

    func testPersistenceRoundTripAndDuplicateAfterRelaunch() throws {
        let root = try directory()
        let store = try LearningProgressStore(directory: root)
        let saved = try store.update {
            $0 = prepared()
            let question = present(&$0)
            _ = try submit(&$0, question)
        }
        let reopened = try LearningProgressStore(directory: root).load()
        XCTAssertEqual(saved, reopened)
        XCTAssertEqual(LearningScore.summary(progress: reopened).score, 10)
        let original = try XCTUnwrap(reopened.scoreReceipts.first)
        let afterDuplicate = try store.update {
            let receipt = try LearningScore.submit(presentationID: original.presentationID, selectedChoiceID: "a",
                correct: false, usedHelp: true, progress: &$0, now: date(8))
            XCTAssertEqual(receipt, original)
        }
        XCTAssertEqual(afterDuplicate, reopened)
    }

    func testCorruptPersistenceAndInvalidDuplicateKeepBytesAndHistory() throws {
        let root = try directory()
        let store = try LearningProgressStore(directory: root)
        _ = try store.update {
            $0 = prepared()
            let question = present(&$0)
            _ = try submit(&$0, question)
        }
        let file = root.appendingPathComponent("learning.json")
        let original = try Data(contentsOf: file)
        XCTAssertThrowsError(try store.update { $0.scoreReceipts.append($0.scoreReceipts[0]) })
        XCTAssertThrowsError(try store.update { $0.questionPresentations.append($0.questionPresentations[0]) })
        XCTAssertEqual(try Data(contentsOf: file), original)
        let corrupt = Data("{bad scoring data".utf8)
        try corrupt.write(to: file)
        var called = false
        XCTAssertThrowsError(try store.update { _ in called = true })
        XCTAssertFalse(called)
        XCTAssertEqual(try Data(contentsOf: file), corrupt)
    }

    func testFailedAtomicWriteDoesNotCreateSuccessfulScore() throws {
        let root = try directory()
        let store = try LearningProgressStore(directory: root)
        let saved = try store.update { $0 = prepared() }
        let file = root.appendingPathComponent("learning.json")
        let original = try Data(contentsOf: file)
        // Turn the parent path into a file to force I/O failure without relying on Unix permissions.
        let moved = root.appendingPathExtension("saved")
        try FileManager.default.moveItem(at: root, to: moved)
        addTeardownBlock { try? FileManager.default.removeItem(at: moved) }
        try Data("blocked parent".utf8).write(to: root)
        XCTAssertThrowsError(try store.update {
            let question = present(&$0)
            _ = try submit(&$0, question)
        })
        XCTAssertEqual(try Data(contentsOf: moved.appendingPathComponent("learning.json")), original)
        XCTAssertEqual(LearningScore.summary(progress: saved).score, 0)
    }

    func testBackwardClockRejectsSubmissionWithoutAttempt() {
        var progress = prepared()
        let question = present(&progress)
        XCTAssertThrowsError(try submit(&progress, question, days: 0))
        XCTAssertTrue(progress.attempts.isEmpty)
        XCTAssertTrue(progress.scoreReceipts.isEmpty)
    }
}
