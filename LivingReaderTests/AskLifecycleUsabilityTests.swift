import XCTest
@testable import LivingReader

@MainActor
final class AskLifecycleUsabilityTests: XCTestCase {
    func testStopCancelsActualProviderAndDropsItsLateAnswer() async {
        let started = expectation(description: "request started")
        let cancelled = expectation(description: "provider received cancellation")
        let gate = ReplyGate()
        let ai = MockAIService()
        ai.stubAsk { request in
            await withTaskCancellationHandler {
                await gate.wait(for: request.userQuestion, started: started)
            } onCancel: { cancelled.fulfill() }
        }
        let session = configured(ai)
        let send = Task { await session.send(question: "old", allowUnreadSpoilers: false) }
        await fulfillment(of: [started], timeout: 1)
        session.cancelInFlight()
        XCTAssertFalse(session.isSending)
        await fulfillment(of: [cancelled], timeout: 1)
        await gate.finish("old", answer: "late answer")
        await send.value
        XCTAssertFalse(session.messages.contains { $0.content == "late answer" })
        XCTAssertTrue(session.messages.contains { $0.isSoftFailure && $0.content.contains("cancelled") })
    }

    func testClearConversationCannotBeRepopulatedByLateResponse() async {
        let started = expectation(description: "request started")
        let gate = ReplyGate()
        let ai = MockAIService()
        ai.stubAsk { request in await gate.wait(for: request.userQuestion, started: started) }
        let session = configured(ai)
        let send = Task { await session.send(question: "old", allowUnreadSpoilers: false) }
        await fulfillment(of: [started], timeout: 1)
        session.resetConversation()
        await gate.finish("old", answer: "late answer")
        await send.value
        XCTAssertTrue(session.messages.isEmpty)
        XCTAssertFalse(session.isSending)
        XCTAssertNil(session.lastError)
    }

    func testNewSelectionDropsOldContextResponse() async {
        let started = expectation(description: "request started")
        let gate = ReplyGate()
        let ai = MockAIService()
        ai.stubAsk { request in await gate.wait(for: request.userQuestion, started: started) }
        let session = configured(ai)
        let send = Task { await session.send(question: "old", allowUnreadSpoilers: false) }
        await fulfillment(of: [started], timeout: 1)
        configure(session, selectedText: "new passage")
        await gate.finish("old", answer: "old context answer")
        await send.value
        XCTAssertEqual(session.selectionContext, "new passage")
        XCTAssertTrue(session.messages.isEmpty)
        XCTAssertFalse(session.isSending)
    }

    func testSupersededRequestCannotClearNewRequestsSendingState() async {
        let firstStarted = expectation(description: "first started")
        let secondStarted = expectation(description: "second started")
        let gate = ReplyGate()
        let ai = MockAIService()
        ai.stubAsk { request in
            await gate.wait(for: request.userQuestion,
                            started: request.userQuestion == "first" ? firstStarted : secondStarted)
        }
        let session = configured(ai)
        let first = Task { await session.send(question: "first", allowUnreadSpoilers: false) }
        await fulfillment(of: [firstStarted], timeout: 1)
        let second = Task { await session.send(question: "second", allowUnreadSpoilers: false) }
        await fulfillment(of: [secondStarted], timeout: 1)
        await gate.finish("first", answer: "obsolete")
        await first.value
        XCTAssertTrue(session.isSending)
        XCTAssertFalse(session.messages.contains { $0.content == "obsolete" })
        await gate.finish("second", answer: "current")
        await second.value
        XCTAssertFalse(session.isSending)
        XCTAssertEqual(session.messages.last?.content, "current")
    }

    private func configured(_ ai: MockAIService) -> AskSession {
        let session = AskSession(ai: ai)
        configure(session, selectedText: "old passage")
        return session
    }

    private func configure(_ session: AskSession, selectedText: String) {
        session.configure(seedQuestion: nil, selectedText: selectedText) { question, allow in
            AskRequest(userQuestion: question, selectedText: selectedText,
                       bookTitle: "Offline fixture", bookAuthor: "Fixture",
                       consumedContext: "Already read", unreadContext: "Unread",
                       allowUnreadSpoilers: allow, forceMock: true)
        }
    }
}

/// Deliberately ignores cancellation to exercise the stale-publication guard,
/// not merely the cooperative provider's cancellation behavior.
private actor ReplyGate {
    private var replies: [String: CheckedContinuation<AskResponse, Never>] = [:]

    func wait(for question: String, started: XCTestExpectation) async -> AskResponse {
        await withCheckedContinuation { continuation in
            replies[question] = continuation
            started.fulfill()
        }
    }

    func finish(_ question: String, answer: String) {
        replies.removeValue(forKey: question)?.resume(returning: AskResponse(
            answer: answer, modelUsed: "offline-fixture", usedUnreadSpoilers: false,
            isSpoilerWarning: false, isMock: true))
    }
}
