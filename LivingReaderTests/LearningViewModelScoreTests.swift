import XCTest
@testable import LivingReader

final class LearningViewModelScoreTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 86_400

    @MainActor
    private func loadedModel() throws -> (LearningViewModel, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LearningViewModelScoreTests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let model = LearningViewModel()
        model.load(directory: root)
        XCTAssertTrue(model.canSave)
        XCTAssertTrue(model.save {
            LearningScore.recordTeaching(conceptIDs: ["force"], progress: &$0, now: self.start)
        })
        return (model, root)
    }

    @MainActor
    func testReviewSelectionPrefersUnknownThenIncorrectThenOldestCorrect() async throws {
        let (model, _) = try loadedModel()
        func question(_ days: Double) throws -> LearningCourse.Question {
            try XCTUnwrap(model.question(conceptID: "force", reviewing: true, now: start.addingTimeInterval(days * day)))
        }
        func answer(_ question: LearningCourse.Question, days: Double, correct: Bool) throws {
            let now = start.addingTimeInterval(days * day)
            let presentation = try XCTUnwrap(model.startQuestionPresentation(question, reviewing: true, now: now))
            let choice = correct ? question.correctChoiceId : try XCTUnwrap(question.choices.first { $0.id != question.correctChoiceId }?.id)
            let receipt = try XCTUnwrap(model.submitAnswer(question, choiceID: choice, usedHelp: false,
                presentationID: presentation.id, now: now))
            XCTAssertTrue(receipt.counted)
        }
        let first = try question(1)
        XCTAssertEqual(first.id, "force-later-1")
        try answer(first, days: 1, correct: true)
        let unknown = try question(9)
        XCTAssertEqual(unknown.id, "force-now-2")
        try answer(unknown, days: 9, correct: false)
        let incorrect = try question(16)
        XCTAssertEqual(incorrect.id, "force-now-2")
        try answer(incorrect, days: 16, correct: true)
        XCTAssertEqual(try question(23).id, "force-later-1")
        XCTAssertEqual(model.scoreSummary.score, 20)
    }

    @MainActor
    func testUnscoredFallbackRotatesAwayFromSkippedPrompt() async throws {
        let (model, _) = try loadedModel()
        let now = start.addingTimeInterval(60)
        let first = try XCTUnwrap(model.question(conceptID: "force", reviewing: true, now: now))
        let presentation = try XCTUnwrap(model.startQuestionPresentation(first, reviewing: true, now: now))
        XCTAssertFalse(presentation.eligibility.canCount)
        let second = try XCTUnwrap(model.question(conceptID: "force", reviewing: true, now: now))
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertTrue(model.progress.attempts.isEmpty)
        XCTAssertEqual(model.scoreSummary.completedSlotCount, 0)
    }

    @MainActor
    func testSaveFailureReturnsNoReceiptAndKeepsPublishedProgress() async throws {
        let (model, root) = try loadedModel()
        let now = start.addingTimeInterval(day)
        let question = try XCTUnwrap(model.question(conceptID: "force", reviewing: true, now: now))
        let presentation = try XCTUnwrap(model.startQuestionPresentation(question, reviewing: true, now: now))
        let before = model.progress
        let corrupt = Data("unreadable existing progress".utf8)
        let file = root.appendingPathComponent("learning.json")
        try corrupt.write(to: file)
        XCTAssertNil(model.submitAnswer(question, choiceID: question.correctChoiceId, usedHelp: false,
            presentationID: presentation.id, now: now))
        XCTAssertEqual(model.progress, before)
        XCTAssertEqual(model.scoreSummary.score, 0)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(try Data(contentsOf: file), corrupt)
    }

    @MainActor
    func testMismatchedQuestionOrChoiceDoesNotAppendAttempt() async throws {
        let (model, _) = try loadedModel()
        let now = start.addingTimeInterval(day)
        let question = try XCTUnwrap(model.question(conceptID: "force", reviewing: true, now: now))
        let presentation = try XCTUnwrap(model.startQuestionPresentation(question, reviewing: true, now: now))
        XCTAssertNil(model.submitAnswer(question, choiceID: "unknown-choice", usedHelp: false,
            presentationID: presentation.id, now: now))
        let other = try XCTUnwrap(model.course?.questions(for: "force", reviewing: true).first { $0.id != question.id })
        XCTAssertNil(model.submitAnswer(other, choiceID: other.correctChoiceId, usedHelp: false,
            presentationID: presentation.id, now: now))
        XCTAssertTrue(model.progress.attempts.isEmpty)
    }
}
