import XCTest
@testable import LivingReader

/// Ask BookBot chrome + voice mode rules. Foundation-only on purpose: the push-
/// to-talk / hold-to-talk decisions are testable without a mic, an audio
/// session, or a simulator.
final class AskBookBotVoiceTests: XCTestCase {

    // MARK: - Naming

    func testAskControlNeverCarriesTheBareBotName() {
        XCTAssertEqual(BookBotChrome.askAction, "Ask BookBot")
        XCTAssertEqual(BookBotChrome.askActionCompact, "Ask Bot")
        XCTAssertEqual(BookBotChrome.sheetTitle, "Ask BookBot")

        XCTAssertFalse(
            BookBotChrome.isAcceptableAskLabel(BookBotChrome.botName),
            "The bare bot name is exactly what the rename removes"
        )
        XCTAssertFalse(BookBotChrome.isAcceptableAskLabel("bookbot"))
        XCTAssertFalse(BookBotChrome.isAcceptableAskLabel(" "))
        XCTAssertTrue(BookBotChrome.isAcceptableAskLabel(BookBotChrome.askAction))
        XCTAssertTrue(BookBotChrome.isAcceptableAskLabel(BookBotChrome.askActionCompact))
    }

    func testComposerPlaceholderCarriesTheAskCopy() {
        XCTAssertTrue(BookBotChrome.composerPlaceholder.hasPrefix("Ask BookBot"))
        XCTAssertEqual(BookBotChrome.suggestionsPrompt, "Tap to ask:")
    }

    // MARK: - Context line truncation

    func testContextLineTruncatesOnAWordBoundary() {
        let selection = """
        The pampas run flat to the horizon, and the men who crossed them measured distance in days
        """
        let line = BookBotChrome.contextLine(for: selection)

        XCTAssertTrue(line.hasPrefix("Asking about: “"))
        XCTAssertTrue(line.hasSuffix("”"))
        XCTAssertTrue(line.contains("…"), "A selection past the limit must be elided")

        let quoted = String(line.dropFirst("Asking about: “".count).dropLast())
        let body = String(quoted.dropLast())
        XCTAssertFalse(body.hasSuffix(" "), "The ellipsis must follow a word, not a space")
        // Every retained word must be a whole word from the source.
        let sourceWords = Set(selection.split(separator: " ").map(String.init))
        for word in body.split(separator: " ").map(String.init) {
            XCTAssertTrue(sourceWords.contains(word), "“\(word)” was cut mid-word")
        }
    }

    func testShortSelectionIsNotTruncatedAndWhitespaceCollapses() {
        XCTAssertEqual(BookBotChrome.truncatedAtWordBoundary("Riverbanks, the rooftops", limit: 88),
                       "Riverbanks, the rooftops")
        XCTAssertEqual(BookBotChrome.truncatedAtWordBoundary("the  pampas\n ran   flat", limit: 88),
                       "the pampas ran flat")
        XCTAssertFalse(BookBotChrome.truncatedAtWordBoundary("short", limit: 88).contains("…"))
    }

    func testTruncationHandlesASingleOverlongWord() {
        let truncated = BookBotChrome.truncatedAtWordBoundary("Buenosairesbuenosaires", limit: 10)
        XCTAssertTrue(truncated.hasSuffix("…"))
        XCTAssertLessThanOrEqual(truncated.count, 11)
    }

    // MARK: - Tap-to-send suggestions

    func testSuggestionsDifferForSelectionAndAreNeverEmpty() {
        let withSelection = AskSuggestions.suggestions(hasSelection: true)
        let withoutSelection = AskSuggestions.suggestions(hasSelection: false)

        XCTAssertFalse(withSelection.isEmpty)
        XCTAssertFalse(withoutSelection.isEmpty)
        XCTAssertNotEqual(withSelection.map(\.id), withoutSelection.map(\.id))
        XCTAssertEqual(Set(withSelection.map(\.id)).count, withSelection.count, "Chip ids feed accessibility identifiers")
        XCTAssertEqual(Set(withoutSelection.map(\.id)).count, withoutSelection.count)
    }

    /// A one-tap chip must not be the thing that trips the spoiler gate.
    func testEverySuggestionIsSpoilerSafe() {
        for suggestion in AskSuggestions.selection + AskSuggestions.reading {
            XCTAssertFalse(
                AskContextBuilder.questionAppearsToNeedUnread(suggestion.prompt, hasUnread: true),
                "“\(suggestion.prompt)” would ask for unread material"
            )
            XCTAssertFalse(suggestion.title.isEmpty)
            XCTAssertFalse(suggestion.prompt.isEmpty)
            XCTAssertLessThanOrEqual(suggestion.title.count, 32, "Chip labels stay bubble-sized")
        }
    }

    // MARK: - Voice mode: push-to-talk

    func testTapLatchesTheMicOpenAndASecondTapCommits() {
        var machine = VoiceModeMachine()
        XCTAssertEqual(machine.phase, .idle)

        // A tap is a press and release at the same instant.
        XCTAssertEqual(machine.pressBegan(at: 0), .startListening)
        XCTAssertEqual(machine.phase, .preparing)
        XCTAssertEqual(machine.pressEnded(at: 0), .none)

        machine.listeningStarted()
        XCTAssertEqual(machine.phase, .listening(latched: true))
        XCTAssertTrue(machine.isCapturing)

        machine.partialReceived("what does this")
        XCTAssertEqual(machine.partialTranscript, "what does this")

        XCTAssertEqual(machine.pressBegan(at: 4), .none)
        XCTAssertEqual(machine.pressEnded(at: 4), .commitTranscript)
        XCTAssertEqual(machine.phase, .finishing)

        XCTAssertEqual(machine.commitFinished("What does this mean?"), "What does this mean?")
        XCTAssertEqual(machine.phase, .idle)
        XCTAssertEqual(machine.partialTranscript, "")
    }

    func testReleaseDuringPreparingLatchesWhenListeningStarts() {
        var machine = VoiceModeMachine()
        XCTAssertEqual(machine.pressBegan(at: 0), .startListening)
        XCTAssertEqual(machine.phase, .preparing)

        // Wall-clock "tap" longer than holdThreshold must not empty-commit.
        let lateRelease = VoiceModeMachine.holdThreshold + 0.5
        XCTAssertEqual(machine.pressEnded(at: lateRelease), .none)
        XCTAssertEqual(machine.phase, .preparing)

        machine.listeningStarted()
        XCTAssertEqual(machine.phase, .listening(latched: true),
                       "Finger already up → latch once the mic opens")
        XCTAssertEqual(machine.statusText, "Listening… tap the mic to send")
    }

    /// StubVoiceDictation opens instantly, so a UITest tap is already `.listening`
    /// (finger still down) by the time XCUITest releases — past holdThreshold.
    /// That release must latch, not hold-commit, or `ask.voice.status` vanishes.
    func testInstantListenThenSlowReleaseLatchesWhenTreatedAsTap() {
        var machine = VoiceModeMachine()
        XCTAssertEqual(machine.pressBegan(at: 0), .startListening)
        machine.listeningStarted()
        XCTAssertEqual(machine.phase, .listening(latched: false))

        let lateRelease = VoiceModeMachine.holdThreshold + 0.5
        XCTAssertEqual(machine.pressEnded(at: lateRelease), .commitTranscript,
                       "Production hold-to-talk still commits on a long release")
        XCTAssertEqual(machine.phase, .finishing)

        var stubTap = VoiceModeMachine()
        XCTAssertEqual(stubTap.pressBegan(at: 0), .startListening)
        stubTap.listeningStarted()
        XCTAssertEqual(
            stubTap.pressEnded(at: lateRelease, treatAsTap: true),
            .none,
            "A stub/UITest tap must latch even when wall-clock exceeds holdThreshold"
        )
        XCTAssertEqual(stubTap.phase, .listening(latched: true))
        XCTAssertTrue(stubTap.statusText.contains("Listening"))

        stubTap.latchListening()
        XCTAssertEqual(stubTap.phase, .listening(latched: true))

        XCTAssertEqual(stubTap.pressBegan(at: lateRelease + 1), .none)
        XCTAssertEqual(stubTap.pressEnded(at: lateRelease + 1, treatAsTap: true), .commitTranscript)
        XCTAssertEqual(stubTap.phase, .finishing)
    }

    // MARK: - Voice mode: hold-to-talk

    func testHoldingCommitsOnReleaseWithoutLatching() {
        var machine = VoiceModeMachine()
        XCTAssertEqual(machine.pressBegan(at: 0), .startListening)
        machine.listeningStarted()
        XCTAssertEqual(machine.phase, .listening(latched: false),
                       "Still held, so the mic must close on release")

        machine.partialReceived("who is rosas")
        let release = VoiceModeMachine.holdThreshold + 0.4
        XCTAssertEqual(machine.pressEnded(at: release), .commitTranscript)
        XCTAssertEqual(machine.commitFinished("Who is Rosas?"), "Who is Rosas?")
        XCTAssertEqual(machine.phase, .idle)
    }

    func testFinalTranscriptFallsBackToTheLastPartial() {
        var machine = VoiceModeMachine()
        _ = machine.pressBegan(at: 0)
        machine.listeningStarted()
        machine.partialReceived("  why does it matter  ")
        _ = machine.pressEnded(at: VoiceModeMachine.holdThreshold + 0.1)

        XCTAssertEqual(machine.commitFinished(""), "why does it matter")
    }

    func testSilenceProducesAnEmptyTranscript() {
        var machine = VoiceModeMachine()
        _ = machine.pressBegan(at: 0)
        machine.listeningStarted()
        _ = machine.pressEnded(at: VoiceModeMachine.holdThreshold + 0.1)

        XCTAssertEqual(machine.commitFinished("   "), "")
    }

    func testCancelDiscardsCaptureAndStatusCopyReadsPerPhase() {
        var machine = VoiceModeMachine()
        _ = machine.pressBegan(at: 0)
        machine.listeningStarted()
        XCTAssertEqual(machine.statusText, "Listening… release to send")

        _ = machine.pressEnded(at: 0.05)
        XCTAssertEqual(machine.statusText, "Listening… tap the mic to send")

        XCTAssertEqual(machine.cancel(), .discardTranscript)
        XCTAssertEqual(machine.phase, .idle)
        XCTAssertEqual(machine.statusText, "")
        XCTAssertEqual(machine.partialTranscript, "")
    }

    func testTappingTheMicWhileAReplyPlaysStopsPlaybackFirst() {
        var machine = VoiceModeMachine()
        machine.speakingStarted()
        XCTAssertTrue(machine.isSpeaking)
        XCTAssertEqual(machine.statusText, "BookBot is speaking")

        XCTAssertEqual(machine.pressBegan(at: 1), .stopSpeaking)
        XCTAssertEqual(machine.phase, .idle)
        XCTAssertEqual(machine.pressEnded(at: 1), .none, "Stopping playback must not open the mic")
    }

    func testCaptureNeverStartsSpeakingOverItself() {
        var machine = VoiceModeMachine()
        _ = machine.pressBegan(at: 0)
        machine.listeningStarted()
        machine.speakingStarted()
        XCTAssertEqual(machine.phase, .listening(latched: false), "A reply must not interrupt live capture")
    }

    func testFailureSurfacesRecoveryCopyAndClears() {
        var machine = VoiceModeMachine()
        _ = machine.pressBegan(at: 0)
        machine.listeningStarted()

        let message = VoiceDictationError.microphoneDenied.errorDescription ?? ""
        XCTAssertEqual(machine.failed(message), .discardTranscript)
        XCTAssertEqual(machine.failureMessage, message)
        XCTAssertEqual(machine.statusText, message)
        XCTAssertTrue(message.contains("Settings"), "A denied mic must tell the reader where to fix it")
        XCTAssertTrue(message.lowercased().contains("type"), "Typing must be offered as the fallback")

        machine.clearFailure()
        XCTAssertEqual(machine.phase, .idle)
        XCTAssertNil(machine.failureMessage)

        // A failure is not a dead end: the next press starts a fresh capture.
        XCTAssertEqual(machine.pressBegan(at: 9), .startListening)
    }

    func testEveryVoiceFailureIsSoft() {
        let errors: [VoiceDictationError] = [
            .microphoneDenied, .speechDenied, .unavailable, .nothingHeard, .captureFailed("engine")
        ]
        for error in errors {
            XCTAssertTrue(error.isSoftFailure)
            XCTAssertFalse((error.errorDescription ?? "").isEmpty)
        }
        XCTAssertEqual(VoiceDictationError.forPermission(.microphoneDenied), .microphoneDenied)
        XCTAssertEqual(VoiceDictationError.forPermission(.speechDenied), .speechDenied)
        XCTAssertEqual(VoiceDictationError.forPermission(.unavailable), .unavailable)
        XCTAssertNil(VoiceDictationError.forPermission(.granted))
        XCTAssertNil(VoiceDictationError.forPermission(.notDetermined))
    }

    // MARK: - Dictation seam

    func testStubDictationReturnsAPhraseAndOnlyOnce() async {
        let stub = StubVoiceDictation()
        let permission = await stub.requestPermission()
        XCTAssertEqual(permission, .granted)

        var partials: [String] = []
        try? await stub.startListening { partials.append($0) }
        XCTAssertFalse(partials.isEmpty, "The composer's live-transcript path needs a partial")

        let heard = await stub.stopListening()
        XCTAssertEqual(heard, StubVoiceDictation.defaultPhrase)

        let again = await stub.stopListening()
        XCTAssertEqual(again, "", "Stopping a closed mic must not replay the last phrase")
    }

    func testStubDictationHonoursADeniedPermission() async {
        let stub = StubVoiceDictation(permission: .microphoneDenied)
        let permission = await stub.requestPermission()
        XCTAssertEqual(permission, .microphoneDenied)

        do {
            try await stub.startListening { _ in }
            XCTFail("A denied mic must not start capturing")
        } catch let error as VoiceDictationError {
            XCTAssertEqual(error, .microphoneDenied)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testUITestLaunchesNeverReachTheMicrophone() {
        XCTAssertTrue(VoiceDictationResolver.prefersStub(arguments: ["-uitesting"]))
        XCTAssertTrue(VoiceDictationResolver.prefersStub(arguments: ["-mockVoice"]))
        XCTAssertTrue(VoiceDictationResolver.prefersStub(arguments: ["-stubVoice"]))
        XCTAssertTrue(VoiceDictationResolver.prefersStub(arguments: ["-other", "-mockVoice"]))
        XCTAssertFalse(VoiceDictationResolver.prefersStub(arguments: []))
        XCTAssertFalse(VoiceDictationResolver.prefersStub(arguments: ["-useMockAI"]))
    }

    // MARK: - Ask message soft-failure flag

    func testSoftFailureFlagRoundTripsAndDefaultsOffForOlderPayloads() throws {
        let failure = AskMessage(role: .assistant, content: "timed out", isSoftFailure: true)
        let decoded = try JSONDecoder().decode(
            AskMessage.self,
            from: try JSONEncoder().encode(failure)
        )
        XCTAssertTrue(decoded.isSoftFailure)

        let legacy = """
        {"id":"\(UUID().uuidString)","role":"assistant","content":"hi","createdAt":0}
        """
        let older = try JSONDecoder().decode(AskMessage.self, from: Data(legacy.utf8))
        XCTAssertFalse(older.isSoftFailure)
        XCTAssertFalse(older.isSpoilerWarning)
    }
}
