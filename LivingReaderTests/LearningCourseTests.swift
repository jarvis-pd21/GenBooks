import XCTest
@testable import LivingReader

final class LearningCourseTests: XCTestCase {
    func testBundledPhysicsUnitIsCompleteAndEveryQuestionHasEvidence() throws {
        let course = try LearningCourse.load()
        XCTAssertEqual(course.lessons.count, 6)
        XCTAssertEqual(course.concepts.count, 5)
        XCTAssertEqual(course.delayedReview.checks.count, 5)
        XCTAssertGreaterThan(course.lessons.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }, 2000)
        for concept in course.concepts {
            XCTAssertFalse(concept.objective.isEmpty)
            XCTAssertGreaterThanOrEqual(course.questions(for: concept.id, reviewing: false).count, 2)
            XCTAssertTrue(course.delayedReview.checks.contains { $0.conceptId == concept.id })
        }
        // Independently calculated examples, rather than deriving the expected key from content.
        let model = try XCTUnwrap(course.lessons.flatMap(\.checks).first { $0.id == "model-now-1" })
        XCTAssertEqual(model.choices.first { $0.id == model.correctChoiceId }?.text, "6 meters")
        XCTAssertTrue(course.lessons.allSatisfy { !$0.text.contains("imagePlaceholder") })
    }

    func testLocalSnapshotReopensExactlyAndCorruptionIsNotReplaced() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try LearningCourse.loadSnapshot(directory: directory)
        let url = directory.appendingPathComponent("physics-foundations-v1.json")
        let bytes = try Data(contentsOf: url)
        let second = try LearningCourse.loadSnapshot(directory: directory)
        XCTAssertEqual(first.lessons.map(\.text), second.lessons.map(\.text))
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        let corrupt = Data("broken saved unit".utf8)
        try corrupt.write(to: url)
        XCTAssertThrowsError(try LearningCourse.loadSnapshot(directory: directory))
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
    }

    func testBookBotPromptDoesNotClaimExternalVerification() {
        let request = AskRequest(userQuestion: "Why?", bookTitle: "Physics", bookAuthor: "GenBooks", consumedContext: "An original lesson")
        let prompt = AskContextBuilder.systemPrompt(for: request)
        XCTAssertTrue(prompt.contains("No external source retrieval or independent source check was performed"))
        XCTAssertTrue(prompt.contains("never invent quotations or citations"))
    }
    @MainActor
    func testCorruptProgressKeepsLessonsReadableWithoutInventingZeroHistory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("learning.json")
        let corrupt = Data("unreadable existing history".utf8)
        try corrupt.write(to: file)
        let model = LearningViewModel()
        model.load(directory: directory)
        XCTAssertNotNil(model.course)
        XCTAssertFalse(model.canSave)
        XCTAssertNil(model.suggestion)
        XCTAssertEqual(model.evidenceLabel("models"), "Progress unavailable")
        XCTAssertFalse(model.save { $0.completedLessonIDs.append("physics-01") })
        XCTAssertEqual(try Data(contentsOf: file), corrupt)
    }

    @MainActor
    func testCorruptPinnedCourseNeverSilentlyUsesBundledReplacement() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("physics-foundations-v1.json")
        let corrupt = Data("unreadable pinned course".utf8)
        try corrupt.write(to: file)
        let model = LearningViewModel()
        model.load(directory: directory)
        XCTAssertNil(model.course)
        XCTAssertFalse(model.canSave)
        XCTAssertEqual(try Data(contentsOf: file), corrupt)
    }

}
