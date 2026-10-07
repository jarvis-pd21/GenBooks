import XCTest
@testable import LivingReader

@MainActor
final class VoiceLifecycleUsabilityTests: XCTestCase {
    func testPermissionCompletingAfterCloseNeverStartsMicrophone() async {
        let permissionRequested = expectation(description: "permission requested")
        let microphoneStarted = expectation(description: "microphone must stay off")
        microphoneStarted.isInverted = true
        let dictation = DelayedDictation(permissionRequested: permissionRequested,
                                         microphoneStarted: microphoneStarted)
        let controller = makeController(dictation)
        controller.tapped()
        await fulfillment(of: [permissionRequested], timeout: 1)
        controller.shutDown()
        dictation.resolvePermission(.granted)
        await fulfillment(of: [microphoneStarted], timeout: 0.1)
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(dictation.startCount, 0)
    }

    func testLateDeniedPermissionDoesNotReopenAnErrorAfterClose() async {
        let requested = expectation(description: "permission requested")
        let dictation = DelayedDictation(permissionRequested: requested)
        let controller = makeController(dictation)
        controller.tapped()
        await fulfillment(of: [requested], timeout: 1)
        controller.shutDown()
        dictation.resolvePermission(.microphoneDenied)
        // Let the released permission task reach its identity guard.
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertNil(controller.failureMessage)
    }

    func testFinalTranscriptAfterCloseIsNotSent() async {
        let stopping = expectation(description: "transcription pending")
        let transcriptSent = expectation(description: "closed transcript must not send")
        transcriptSent.isInverted = true
        let dictation = DelayedDictation(stopping: stopping, permissionImmediatelyGranted: true)
        var now: TimeInterval = 0
        let controller = makeController(dictation, clock: { now })
        controller.onTranscript = { _ in transcriptSent.fulfill() }
        controller.tapped()
        await waitForListening(controller)
        now = 2
        controller.tapped()
        await fulfillment(of: [stopping], timeout: 1)
        controller.shutDown()
        dictation.resolveTranscript("Do not send this")
        await fulfillment(of: [transcriptSent], timeout: 0.1)
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertTrue(controller.partialTranscript.isEmpty)
    }

    func testCancelledPermissionDoesNotPreventANewCapture() async {
        let firstPermission = expectation(description: "first permission requested")
        let dictation = DelayedDictation(permissionRequested: firstPermission)
        var now: TimeInterval = 0
        let controller = makeController(dictation, clock: { now })
        controller.tapped()
        await fulfillment(of: [firstPermission], timeout: 1)
        controller.cancel()
        dictation.resolvePermission(.granted)
        dictation.permissionImmediatelyGranted = true
        now = 2
        controller.tapped()
        await waitForListening(controller)
        XCTAssertEqual(dictation.startCount, 1)
        controller.shutDown()
    }

    private func makeController(_ dictation: DelayedDictation,
                                clock: @escaping () -> TimeInterval = { 0 }) -> AskVoiceController {
        let suite = "VoiceLifecycleUsability.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return AskVoiceController(dictation: dictation, speaker: nil, defaults: defaults,
                                  clock: clock, latchSlowTaps: true)
    }

    private func waitForListening(_ controller: AskVoiceController) async {
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline {
            if case .listening = controller.phase { return }
            await Task.yield()
        }
        XCTFail("Expected fixture capture to become ready")
    }
}

@MainActor
private final class DelayedDictation: VoiceDictating {
    let permissionRequested: XCTestExpectation?
    let microphoneStarted: XCTestExpectation?
    let stopping: XCTestExpectation?
    var permissionImmediatelyGranted: Bool
    private var permission: CheckedContinuation<VoiceDictationPermission, Never>?
    private var transcript: CheckedContinuation<String, Never>?
    private(set) var startCount = 0

    init(permissionRequested: XCTestExpectation? = nil,
         microphoneStarted: XCTestExpectation? = nil,
         stopping: XCTestExpectation? = nil,
         permissionImmediatelyGranted: Bool = false) {
        self.permissionRequested = permissionRequested
        self.microphoneStarted = microphoneStarted
        self.stopping = stopping
        self.permissionImmediatelyGranted = permissionImmediatelyGranted
    }

    func requestPermission() async -> VoiceDictationPermission {
        if permissionImmediatelyGranted { return .granted }
        return await withCheckedContinuation { continuation in
            permission = continuation
            permissionRequested?.fulfill()
        }
    }

    func resolvePermission(_ outcome: VoiceDictationPermission) {
        permission?.resume(returning: outcome)
        permission = nil
    }

    func startListening(onPartial: @escaping @Sendable (String) -> Void) async throws {
        startCount += 1
        microphoneStarted?.fulfill()
        onPartial("Fixture partial")
    }

    func stopListening() async -> String {
        await withCheckedContinuation { continuation in
            transcript = continuation
            stopping?.fulfill()
        }
    }

    func resolveTranscript(_ text: String) {
        transcript?.resume(returning: text)
        transcript = nil
    }

    func cancelListening() async { }
}
