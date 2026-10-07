import XCTest
@testable import LivingReader

@MainActor
final class SpeechFinalizationTests: XCTestCase {
    func testCancelledFinalizationReturnsWithoutWaitingForGraceDeadline() async {
        let completed = expectation(description: "cancelled finalization releases main actor")
        let task = Task { @MainActor in
            await SpeechVoiceDictation.waitForFinalResult { true }
            completed.fulfill()
        }
        await Task.yield()
        task.cancel()
        await fulfillment(of: [completed], timeout: 0.5)
    }

    func testAlreadyFinalizedRecognitionNeedsNoWait() async {
        var predicateCalls = 0
        await SpeechVoiceDictation.waitForFinalResult {
            predicateCalls += 1
            return false
        }
        XCTAssertEqual(predicateCalls, 1)
    }
}
