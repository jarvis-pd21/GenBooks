import XCTest
@testable import LivingReader

@MainActor
final class AIServiceTests: XCTestCase {
    private var tempRoot: URL!
    private var versioning: ManuscriptVersioningService!
    private var defaults: UserDefaults!
    private var defaultsSuite: String!
    private var keyStore: InMemoryAPIKeyStore!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("LR-AI-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        versioning = try ManuscriptVersioningService(rootDirectory: tempRoot)
        defaultsSuite = "LivingReaderAITests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuite)
        defaults.removePersistentDomain(forName: defaultsSuite)
        keyStore = InMemoryAPIKeyStore()
        MockURLProtocol.reset()
    }

    override func tearDownWithError() throws {
        MockURLProtocol.reset()
        if let defaultsSuite {
            defaults?.removePersistentDomain(forName: defaultsSuite)
        }
        try? FileManager.default.removeItem(at: tempRoot)
    }

    private func liveService(
        preferredModel: OpenAIModelOption = .gpt41Mini,
        timeout: TimeInterval = 2
    ) -> LiveOpenAIService {
        let store = keyStore!
        return LiveOpenAIService(
            apiKeyProvider: { try store.loadAPIKey() },
            preferredModel: preferredModel,
            session: MockURLProtocol.makeSession(),
            timeout: timeout
        )
    }

    // MARK: - Keychain / key store

    func testNoKeyHandled() async throws {
        XCTAssertNil(try keyStore.loadAPIKey())
        let live = liveService(timeout: 1)
        let request = AskRequest(
            userQuestion: "What is this?",
            bookTitle: "T",
            bookAuthor: "A",
            consumedContext: "hello"
        )
        do {
            _ = try await live.ask(request)
            XCTFail("Expected missingAPIKey")
        } catch let error as AIServiceError {
            XCTAssertEqual(error, .missingAPIKey)
        }
    }

    func testInvalidKeyHandled() async throws {
        try keyStore.saveAPIKey("sk-invalid-test-key")
        MockURLProtocol.requestHandler = { request in
            Self.assertNoKeyLogged(in: request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 401,
                httpVersion: nil,
                headerFields: nil
            )!
            let data = Data(#"{"error":{"message":"Incorrect API key","type":"invalid_request_error"}}"#.utf8)
            return (response, data)
        }
        let live = liveService(timeout: 2)
        do {
            _ = try await live.ask(AskRequest(
                userQuestion: "Hello",
                bookTitle: "T",
                bookAuthor: "A",
                consumedContext: "c"
            ))
            XCTFail("Expected invalidAPIKey")
        } catch let error as AIServiceError {
            XCTAssertEqual(error, .invalidAPIKey)
        }
    }

    func testKeychainStoreRoundTripDoesNotUseUserDefaults() throws {
        let store = KeychainAPIKeyStore(
            service: "com.jarvis.livingreader.tests.\(UUID().uuidString)",
            account: "apiKey"
        )
        let probe = "sk-test-livingreader-\(UUID().uuidString.prefix(8))"
        try store.saveAPIKey(probe)
        XCTAssertEqual(try store.loadAPIKey(), probe)
        // Ensure not mirrored into our defaults suite / standard for this key material.
        let defaultsDump = String(describing: defaults.dictionaryRepresentation())
        XCTAssertFalse(defaultsDump.contains(probe))
        try store.saveAPIKey(nil)
        XCTAssertNil(try store.loadAPIKey())
    }

    // MARK: - Network soft-fail

    func testTimeoutHandled() async throws {
        try keyStore.saveAPIKey("sk-test")
        MockURLProtocol.requestHandler = { _ in
            throw URLError(.timedOut)
        }
        let live = liveService(timeout: 1)
        do {
            _ = try await live.ask(AskRequest(
                userQuestion: "Hello",
                bookTitle: "T",
                bookAuthor: "A",
                consumedContext: "c"
            ))
            XCTFail("Expected timeout")
        } catch let error as AIServiceError {
            XCTAssertEqual(error, .timedOut)
        }
    }

    func testOfflineHandled() async throws {
        try keyStore.saveAPIKey("sk-test")
        MockURLProtocol.requestHandler = { _ in
            throw URLError(.notConnectedToInternet)
        }
        let live = liveService(timeout: 1)
        do {
            _ = try await live.ask(AskRequest(
                userQuestion: "Hello",
                bookTitle: "T",
                bookAuthor: "A",
                consumedContext: "c"
            ))
            XCTFail("Expected offline")
        } catch let error as AIServiceError {
            XCTAssertEqual(error, .offline)
        }
    }

    func testMalformedJSONHandled() async throws {
        try keyStore.saveAPIKey("sk-test")
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data("not-json{{{".utf8))
        }
        let live = liveService(timeout: 2)
        do {
            _ = try await live.ask(AskRequest(
                userQuestion: "Hello",
                bookTitle: "T",
                bookAuthor: "A",
                consumedContext: "c"
            ))
            XCTFail("Expected malformedResponse")
        } catch let error as AIServiceError {
            XCTAssertEqual(error, .malformedResponse)
        }
    }

    func testLivePathSucceedsWithStubbedNetwork() async throws {
        try keyStore.saveAPIKey("sk-test-valid-shape")
        MockURLProtocol.requestHandler = { request in
            Self.assertNoKeyLogged(in: request)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test-valid-shape")
            let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
            XCTAssertFalse(body.contains("[UNREAD"), "Unread must be omitted from normal chat body")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let data = Data("""
            {"id":"chatcmpl_test","choices":[{"message":{"role":"assistant","content":"Stubbed live answer about the passage."}}]}
            """.utf8)
            return (response, data)
        }
        let live = liveService(preferredModel: .gpt41Mini, timeout: 2)
        let response = try await live.ask(AskRequest(
            userQuestion: "Explain this",
            selectedText: "Geography is destiny",
            bookTitle: "A Little History of Argentina",
            bookAuthor: "Fixture",
            consumedContext: "[CURRENT Ch 1: Before the Nation]\nGeography is destiny…",
            unreadContext: "[UNREAD Ch 2: Independence Sparks]\nSECRET_UNREAD_TOKEN",
            allowUnreadSpoilers: false
        ))
        XCTAssertEqual(response.answer, "Stubbed live answer about the passage.")
        XCTAssertEqual(response.modelUsed, OpenAIModelOption.gpt41Mini.rawValue)
        XCTAssertFalse(response.isMock)
        XCTAssertFalse(response.usedUnreadSpoilers)
    }

    func testModelFallbackWhenPreferredUnavailable() async throws {
        try keyStore.saveAPIKey("sk-test")
        var seenModels: [String] = []
        let preferred = OpenAIModelOption.gpt41Mini
        let expectedFallback = preferred.fallbacks[0] // gpt-5.6-luna after Astra/Luna addition
        MockURLProtocol.requestHandler = { request in
            let raw = request.httpBody ?? Data()
            let body = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any]
            let model = body?["model"] as? String ?? ""
            seenModels.append(model)
            if model == preferred.rawValue {
                let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
                return (response, Data(#"{"error":{"message":"model_not_found"}}"#.utf8))
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let data = Data(#"{"choices":[{"message":{"role":"assistant","content":"Fallback model worked."}}]}"#.utf8)
            return (response, data)
        }
        let live = liveService(preferredModel: preferred, timeout: 2)
        let response = try await live.ask(AskRequest(
            userQuestion: "Hi",
            bookTitle: "T",
            bookAuthor: "A",
            consumedContext: "c"
        ))
        XCTAssertEqual(response.answer, "Fallback model worked.")
        XCTAssertEqual(response.modelUsed, expectedFallback.rawValue)
        XCTAssertEqual(seenModels.first, preferred.rawValue)
    }

    // MARK: - Spoiler rules

    func testUnreadOmittedFromNormalChatContext() throws {
        let book = Book(
            id: ArgentinaFixtureIDs.book,
            title: "A Little History of Argentina",
            author: "Fixture",
            chapters: []
        )
        let slices = [
            AskContextBuilder.ReadingSlice(
                chapterId: ArgentinaFixtureIDs.chapter1,
                title: "Before the Nation",
                orderIndex: 0,
                revisionId: ArgentinaFixtureIDs.chapter1Revision1,
                plainText: "CONSUMED_SAFE_TEXT geography",
                isConsumed: true,
                isCurrent: true
            ),
            AskContextBuilder.ReadingSlice(
                chapterId: ArgentinaFixtureIDs.chapter2,
                title: "Independence Sparks",
                orderIndex: 1,
                revisionId: ArgentinaFixtureIDs.chapter2Revision1,
                plainText: "UNREAD_SECRET_TOKEN must not leak",
                isConsumed: false,
                isCurrent: false
            )
        ]
        let request = AskContextBuilder.buildRequest(
            question: "What does geography mean here?",
            book: book,
            slices: slices,
            selectedText: "geography",
            surroundingContext: "Geography is destiny",
            currentChapterId: ArgentinaFixtureIDs.chapter1,
            notesAndQuestions: "• Why destiny?",
            readerPreferencesSummary: "font 18pt, theme system",
            allowUnreadSpoilers: false
        )
        XCTAssertTrue(request.consumedContext.contains("CONSUMED_SAFE_TEXT"))
        XCTAssertTrue(request.unreadContext?.contains("UNREAD_SECRET_TOKEN") == true)
        let payload = AskContextBuilder.contextPayload(for: request)
        XCTAssertFalse(AskContextBuilder.payloadContainsUnreadMarker(payload))
        XCTAssertFalse(payload.contains("UNREAD_SECRET_TOKEN"))
        XCTAssertTrue(payload.contains("CONSUMED_SAFE_TEXT"))
        XCTAssertTrue(payload.contains("CRITICAL"))
    }

    func testSpoilerRevealPathIncludesUnread() throws {
        let book = Book(
            id: ArgentinaFixtureIDs.book,
            title: "A Little History of Argentina",
            author: "Fixture",
            chapters: []
        )
        let slices = [
            AskContextBuilder.ReadingSlice(
                chapterId: ArgentinaFixtureIDs.chapter1,
                title: "Before the Nation",
                orderIndex: 0,
                revisionId: ArgentinaFixtureIDs.chapter1Revision1,
                plainText: "safe",
                isConsumed: true,
                isCurrent: true
            ),
            AskContextBuilder.ReadingSlice(
                chapterId: ArgentinaFixtureIDs.chapter2,
                title: "Independence Sparks",
                orderIndex: 1,
                revisionId: ArgentinaFixtureIDs.chapter2Revision1,
                plainText: "UNREAD_SECRET_TOKEN",
                isConsumed: false,
                isCurrent: false
            )
        ]
        let request = AskContextBuilder.buildRequest(
            question: "What happens later in the book?",
            book: book,
            slices: slices,
            selectedText: nil,
            surroundingContext: nil,
            currentChapterId: ArgentinaFixtureIDs.chapter1,
            notesAndQuestions: nil,
            readerPreferencesSummary: nil,
            allowUnreadSpoilers: true
        )
        let payload = AskContextBuilder.contextPayload(for: request)
        XCTAssertTrue(AskContextBuilder.payloadContainsUnreadMarker(payload))
        XCTAssertTrue(payload.contains("UNREAD_SECRET_TOKEN"))
        XCTAssertTrue(payload.contains("deliberately allowed UNREAD"))
    }

    func testMockSpoilerWarningThenReveal() async throws {
        let mock = MockAIService()
        let warn = try await mock.ask(AskRequest(
            userQuestion: "What happens later in the book?",
            bookTitle: "T",
            bookAuthor: "A",
            consumedContext: "ch1",
            unreadContext: "[UNREAD Ch 2]\nsecret",
            allowUnreadSpoilers: false
        ))
        XCTAssertTrue(warn.isSpoilerWarning)
        XCTAssertTrue(warn.answer.contains("ahead of where"))

        let revealed = try await mock.ask(AskRequest(
            userQuestion: "What happens later in the book?",
            bookTitle: "T",
            bookAuthor: "A",
            consumedContext: "ch1",
            unreadContext: "[UNREAD Ch 2]\nsecret",
            allowUnreadSpoilers: true
        ))
        XCTAssertFalse(revealed.isSpoilerWarning)
        XCTAssertTrue(revealed.usedUnreadSpoilers)
        XCTAssertTrue(revealed.isMock)
        XCTAssertTrue(revealed.answer.contains("deliberate unread reveal"))
    }

    // MARK: - Mock never on cold open

    func testMockAINeverCalledOnColdLibraryReaderOpen() async throws {
        let ai = MockAIService()
        XCTAssertEqual(ai.totalCallCount, 0)

        let library = LibraryViewModel(ai: ai)
        await library.load()
        XCTAssertTrue(library.didLoadOffline)
        XCTAssertEqual(ai.adaptCallCount, 0)
        XCTAssertEqual(ai.askCallCount, 0)

        let book = try XCTUnwrap(library.books.first)
        let settings = ReaderSettingsStore(defaults: defaults)
        let annotations = try FileAnnotationStore(rootDirectory: tempRoot)
        let vocabulary = try FileVocabularyStore(rootDirectory: tempRoot)
        let model = ReaderViewModel(
            book: book,
            versioning: try XCTUnwrap(library.versioning),
            checkpoints: try XCTUnwrap(library.checkpoints),
            settings: settings,
            annotations: annotations,
            vocabulary: vocabulary,
            bookmarks: try FileBookmarkStore(rootDirectory: tempRoot),
            feedbackStore: try! FileFeedbackStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("fb-\(UUID().uuidString)")),
            preferenceStore: try! FileReaderPreferenceStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("pf-\(UUID().uuidString)")),
            ai: ai,
            askService: ai
        )
        await model.open()
        XCTAssertEqual(model.aiAdaptCallCountAtOpen, 0)
        XCTAssertEqual(model.aiAskCallCountAtOpen, 0)
        XCTAssertEqual(ai.totalCallCount, 0)
        XCTAssertTrue(model.isReady)
    }

    func testMockAskDeterministic() async throws {
        let mock = MockAIService()
        let a = try await mock.ask(AskRequest(
            userQuestion: "What does this mean in context?",
            selectedText: "Geography is destiny",
            currentChapterTitle: "Before the Nation",
            bookTitle: "A Little History of Argentina",
            bookAuthor: "Fixture",
            consumedContext: "safe"
        ))
        let b = try await mock.ask(AskRequest(
            userQuestion: "What does this mean in context?",
            selectedText: "Geography is destiny",
            currentChapterTitle: "Before the Nation",
            bookTitle: "A Little History of Argentina",
            bookAuthor: "Fixture",
            consumedContext: "safe"
        ))
        XCTAssertEqual(a.answer, b.answer)
        XCTAssertTrue(a.isMock)
        XCTAssertEqual(mock.askCallCount, 2)
        XCTAssertEqual(mock.adaptCallCount, 0)
    }

    func testAskSessionSoftFailsWithoutImpairingState() async throws {
        let mock = MockAIService()
        mock.stubAsk { _ in throw AIServiceError.timedOut }
        let session = AskSession(ai: mock)
        session.configure(
            seedQuestion: "Hello?",
            selectedText: "Geography",
            buildRequest: { q, allow in
                AskRequest(
                    userQuestion: q,
                    selectedText: "Geography",
                    bookTitle: "T",
                    bookAuthor: "A",
                    consumedContext: "c",
                    allowUnreadSpoilers: allow
                )
            }
        )
        XCTAssertTrue(session.draft.isEmpty, "The composer opens empty; openers are one-tap chips")
        await session.sendSeedQuestion()
        XCTAssertFalse(session.isSending)
        XCTAssertEqual(session.lastError, AIServiceError.timedOut.localizedDescription)
        XCTAssertTrue(session.messages.contains(where: { $0.role == .assistant }))
        XCTAssertTrue(
            session.messages.contains(where: { $0.role == .assistant && $0.isSoftFailure }),
            "A soft failure is styled as recovery copy, not as an answer"
        )
    }

    /// A prompt bubble must ask its prompt, not fill the field with it.
    func testSuggestionBubbleAsksImmediatelyAndLeavesTheComposerClear() async throws {
        let mock = MockAIService()
        let session = makeAskSession(ai: mock)

        let suggestion = try XCTUnwrap(session.suggestions.first)
        await session.send(suggestion: suggestion)

        XCTAssertEqual(mock.askCallCount, 1)
        XCTAssertEqual(mock.lastAskRequest?.userQuestion, suggestion.prompt)
        XCTAssertEqual(session.messages.first(where: { $0.role == .user })?.content, suggestion.prompt)
        XCTAssertTrue(session.draft.isEmpty)
        XCTAssertTrue(session.hasConversation)
    }

    /// A selection offers passage openers; the toolbar entry offers reading ones.
    func testSuggestionsFollowTheSelectionContextAndLeadWithAnArrivingQuestion() {
        let selectionSession = makeAskSession(ai: MockAIService(), selectedText: "the pampas")
        XCTAssertTrue(selectionSession.hasSelectionContext)
        XCTAssertEqual(selectionSession.contextLine, BookBotChrome.contextLine(for: "the pampas"))
        XCTAssertEqual(selectionSession.suggestions.map(\.id).first, "seed", "An arriving question leads the chips")
        XCTAssertEqual(
            Set(selectionSession.suggestions.dropFirst().map(\.id)),
            Set(AskSuggestions.selection.map(\.id))
        )

        let readingSession = makeAskSession(ai: MockAIService(), seedQuestion: nil, selectedText: nil)
        XCTAssertFalse(readingSession.hasSelectionContext)
        XCTAssertNil(readingSession.contextLine)
        XCTAssertEqual(readingSession.suggestions.map(\.id), AskSuggestions.reading.map(\.id))
    }

    /// Retry replaces the failed bubble instead of asking the question twice.
    func testRetryReplacesTheFailedBubbleWithoutReAskingInTheTranscript() async throws {
        let mock = MockAIService()
        mock.stubAsk { _ in throw AIServiceError.offline }
        let session = makeAskSession(ai: mock)

        await session.send(question: "Who is Rosas?", allowUnreadSpoilers: false)
        XCTAssertEqual(session.messages.filter { $0.role == .user }.count, 1)
        XCTAssertEqual(session.messages.filter { $0.isSoftFailure }.count, 1)
        XCTAssertEqual(session.lastUserQuestion, "Who is Rosas?")

        mock.stubAsk { request in
            AskResponse(
                answer: "Answered: \(request.userQuestion)",
                modelUsed: "mock",
                usedUnreadSpoilers: false,
                isSpoilerWarning: false,
                isMock: true
            )
        }
        await session.retryLastQuestion()

        XCTAssertEqual(session.messages.filter { $0.role == .user }.count, 1, "The question is not asked twice")
        XCTAssertTrue(session.messages.filter { $0.isSoftFailure }.isEmpty, "The failed bubble is replaced")
        XCTAssertEqual(session.messages.last?.content, "Answered: Who is Rosas?")
        XCTAssertNil(session.lastError)
    }

    /// Locked default: BookBot answers out loud whether the question was
    /// spoken or typed. An explicit opt-out is never overridden.
    func testAnswersAreSpokenByDefaultAndAnOptOutSticks() {
        let fresh = AskVoiceController(dictation: StubVoiceDictation(), speaker: nil, defaults: defaults)
        XCTAssertTrue(fresh.speakRepliesAloud, "Auto-speak is the default, not mic-only behaviour")

        fresh.speakRepliesAloud = false
        XCTAssertEqual(defaults.object(forKey: AskVoiceController.speakRepliesDefaultsKey) as? Bool, false)

        let reopened = AskVoiceController(dictation: StubVoiceDictation(), speaker: nil, defaults: defaults)
        XCTAssertFalse(reopened.speakRepliesAloud, "A reader who turned it off keeps it off")

        reopened.speakRepliesAloud = true
        let again = AskVoiceController(dictation: StubVoiceDictation(), speaker: nil, defaults: defaults)
        XCTAssertTrue(again.speakRepliesAloud)
    }

    /// A soft failure is recovery copy — it is read, not read *out*.
    func testSoftFailuresAreNeverSpoken() {
        let voice = AskVoiceController(dictation: StubVoiceDictation(), speaker: nil, defaults: defaults)
        XCTAssertTrue(voice.speakRepliesAloud)

        let failure = AskMessage(role: .assistant, content: "You’re offline.", isSoftFailure: true)
        voice.speakLatestReplyIfNeeded(failure)
        XCTAssertFalse(voice.isReadingAloud(failure))

        let question = AskMessage(role: .user, content: "Who is Rosas?")
        voice.speakLatestReplyIfNeeded(question)
        XCTAssertFalse(voice.isReadingAloud(question), "Only answers are spoken")
    }

    private func makeAskSession(
        ai: any AIService,
        seedQuestion: String? = "What does this mean in context?",
        selectedText: String? = "the pampas"
    ) -> AskSession {
        let session = AskSession(ai: ai)
        session.configure(
            seedQuestion: seedQuestion,
            selectedText: selectedText,
            buildRequest: { question, allow in
                AskRequest(
                    userQuestion: question,
                    selectedText: selectedText,
                    bookTitle: "A Little History of Argentina",
                    bookAuthor: "Fixture",
                    consumedContext: "consumed",
                    allowUnreadSpoilers: allow,
                    forceMock: true
                )
            }
        )
        return session
    }

    // MARK: - Luna / Astra defaults + sticky mock refresh

    func testModelDefaultsAskLunaGenerationAstra() {
        XCTAssertEqual(OpenAIModelOption.defaultAsk, .gpt56Luna)
        XCTAssertEqual(OpenAIModelOption.defaultGeneration, .gpt6Astra)
        XCTAssertEqual(OpenAIModelOption.gpt56Luna.rawValue, "gpt-5.6-luna")
        XCTAssertEqual(OpenAIModelOption.gpt6Astra.rawValue, "gpt-6-astra")
        XCTAssertTrue(OpenAIModelOption.defaultAsk.fallbacks.contains(.gpt41Mini))
        XCTAssertTrue(OpenAIModelOption.defaultGeneration.fallbacks.contains(.gpt41))

        let prefs = AIModelPreferenceStore(defaults: defaults)
        XCTAssertEqual(prefs.askModel, .gpt56Luna)
        XCTAssertEqual(prefs.generationModel, .gpt6Astra)
    }

    func testAskPreferredListUsesLunaId() {
        let prefs = AIModelPreferenceStore(defaults: defaults)
        XCTAssertEqual(prefs.askModel.rawValue, "gpt-5.6-luna")
        let live = liveService(preferredModel: prefs.askModel, timeout: 1)
        XCTAssertEqual(live.preferredModelID, "gpt-5.6-luna")
        let models = [prefs.askModel] + prefs.askModel.fallbacks
        XCTAssertEqual(models.first?.rawValue, "gpt-5.6-luna")
    }

    func testRefreshAfterKeyChangesKeepsLiveServices() async throws {
        let book = try BundleFixtureLoader.loadArgentinaMinimal()
        try await versioning.saveBook(book)

        let settings = ReaderSettingsStore(defaults: defaults)
        let annotations = try FileAnnotationStore(rootDirectory: tempRoot)
        let vocabulary = try FileVocabularyStore(rootDirectory: tempRoot)
        let feedback = try FileFeedbackStore(rootDirectory: tempRoot)
        let prefsStore = try FileReaderPreferenceStore(rootDirectory: tempRoot)
        let modelPrefs = AIModelPreferenceStore(defaults: defaults)
        let checkpoints = try FileReadingCheckpointStore(rootDirectory: tempRoot)

        XCTAssertNil(try keyStore.loadAPIKey())
        let pair = AIServiceResolver.makeAskAndAdaptation(
            keyStore: keyStore,
            askModel: modelPrefs.askModel,
            generationModel: modelPrefs.generationModel
        )
        XCTAssertTrue(pair.ask is LiveOpenAIService)
        XCTAssertTrue(pair.adaptation is LiveOpenAIService)

        let model = ReaderViewModel(
            book: book,
            versioning: versioning,
            checkpoints: checkpoints,
            settings: settings,
            annotations: annotations,
            vocabulary: vocabulary,
            bookmarks: try FileBookmarkStore(rootDirectory: tempRoot),
            feedbackStore: feedback,
            preferenceStore: prefsStore,
            askService: pair.ask,
            adaptationAI: pair.adaptation
        )
        await model.open()
        XCTAssertTrue(model.askServiceTypeName.contains("LiveOpenAIService"))

        try keyStore.saveAPIKey("sk-test-refresh-shape")
        model.refreshAIServices(keyStore: keyStore, modelPrefs: modelPrefs)
        XCTAssertTrue(model.askServiceTypeName.contains("LiveOpenAIService"), model.askServiceTypeName)
        XCTAssertTrue(model.adaptationServiceTypeName.contains("LiveOpenAIService"), model.adaptationServiceTypeName)

        // Removing the key leaves a live service that reports missingAPIKey on use.
        try keyStore.saveAPIKey(nil)
        model.refreshAIServices(keyStore: keyStore, modelPrefs: modelPrefs)
        XCTAssertTrue(model.askServiceTypeName.contains("LiveOpenAIService"), model.askServiceTypeName)
        XCTAssertTrue(model.adaptationServiceTypeName.contains("LiveOpenAIService"), model.adaptationServiceTypeName)
    }

    func testLiveAdaptThrowsWhenOfflineOrMissingKeyAndAllowsExplicitDeterministicMode() async throws {
        let book = try BundleFixtureLoader.loadArgentinaMinimal()
        try await versioning.saveBook(book)
        let ch1 = try XCTUnwrap(book.chapters.first { $0.id == ArgentinaFixtureIDs.chapter1 })
        let ch2 = try XCTUnwrap(book.chapters.first { $0.id == ArgentinaFixtureIDs.chapter2 })
        let ch2Revision = try XCTUnwrap(ch2.revisions.sorted { $0.revisionIndex < $1.revisionIndex }.last)
        let plain = ch2Revision.blocks.map(\.text).joined(separator: "\n")
        let feedback = ChapterFeedback(
            id: UUID(),
            bookId: book.id,
            chapterId: ch1.id,
            revisionId: ArgentinaFixtureIDs.chapter1Revision1,
            overall: .fine,
            moreOf: [.stories],
            lessOf: [.repetition],
            freeText: "more stories",
            createdAt: Date()
        )
        let profile = ReaderPreferenceProfile.empty(bookId: book.id)
        let request = AdaptationPlanRequest(
            book: book,
            feedback: feedback,
            profile: profile,
            lockedChapterIds: [ch1.id],
            unreadChapters: [
                UnreadChapterSnapshot(
                    id: ch2.id,
                    title: ch2.title,
                    orderIndex: ch2.orderIndex,
                    currentWordCount: AdaptationPlanValidator.wordCount(of: plain),
                    plainText: plain
                )
            ],
            maxChaptersToAdapt: 1
        )

        let noKey = liveService(preferredModel: .gpt6Astra, timeout: 1)
        do {
            _ = try await noKey.makeAdaptationPlan(request)
            XCTFail("Missing key must not produce a substitute plan")
        } catch {
            XCTAssertEqual(error as? AIServiceError, .missingAPIKey)
        }

        try keyStore.saveAPIKey("sk-test")
        MockURLProtocol.requestHandler = { _ in
            throw URLError(.notConnectedToInternet)
        }
        let offline = liveService(preferredModel: .gpt6Astra, timeout: 1)
        do {
            _ = try await offline.makeAdaptationPlan(request)
            XCTFail("Offline must not produce a substitute plan")
        } catch {
            XCTAssertEqual(error as? AIServiceError, .offline)
        }

        let store = keyStore!
        let forced = LiveOpenAIService(
            apiKeyProvider: { try store.loadAPIKey() },
            preferredModel: .gpt6Astra,
            session: MockURLProtocol.makeSession(),
            timeout: 1,
            forceDeterministicAdaptation: true
        )
        let planForced = try await forced.makeAdaptationPlan(request)

        let genReq = AdaptationGenerateRequest(
            book: book,
            plan: planForced,
            chapterId: ch2.id,
            chapterTitle: ch2.title,
            currentPlainText: plain,
            target: try XCTUnwrap(planForced.chapterTargets.first),
            profile: profile,
            continuityNotes: planForced.continuityNotes
        )
        MockURLProtocol.requestHandler = { _ in
            throw URLError(.notConnectedToInternet)
        }
        do {
            _ = try await offline.generateAdaptedChapter(genReq)
            XCTFail("Offline must not produce substitute prose")
        } catch {
            XCTAssertEqual(error as? AIServiceError, .offline)
        }
        let blocks = try await forced.generateAdaptedChapter(genReq)
        XCTAssertFalse(blocks.isEmpty)
        XCTAssertTrue(blocks.contains(where: { $0.text.contains("[Adapted]") || $0.kind == .heading }))
    }

    func testResolverAskUsesLunaGenerationUsesAstra() throws {
        try keyStore.saveAPIKey("sk-test-resolver")
        let pair = AIServiceResolver.makeAskAndAdaptation(
            keyStore: keyStore,
            askModel: .gpt56Luna,
            generationModel: .gpt6Astra
        )
        let askLive = try XCTUnwrap(pair.ask as? LiveOpenAIService)
        let genLive = try XCTUnwrap(pair.adaptation as? LiveOpenAIService)
        XCTAssertEqual(askLive.preferredModelID, "gpt-5.6-luna")
        XCTAssertEqual(genLive.preferredModelID, "gpt-6-astra")
    }

    func testPrefersMockLaunchArgsStillForceMock() throws {
        try keyStore.saveAPIKey("sk-test-present")
        for arg in ["-useMockAI", "-phase4MockAsk", "-phase5AdaptationDemo", "-uitesting"] {
            let info = MockProcessInfo(arguments: [arg])
            XCTAssertTrue(AIServiceResolver.prefersMock(processInfo: info), arg)
            let service = AIServiceResolver.makeDefault(
                keyStore: keyStore,
                modelPreference: .gpt56Luna,
                processInfo: info
            )
            XCTAssertTrue(service is MockAIService, arg)
        }
    }

    /// RDR-914: overnight quality regen must not force Mock — live Astra needs the Keychain key.
    func testArgentinaQualityRegenLaunchArgDoesNotForceMock() throws {
        try keyStore.saveAPIKey("sk-test-present")
        let info = MockProcessInfo(arguments: [ArgentinaQualityRegen.launchArgument])
        XCTAssertFalse(AIServiceResolver.prefersMock(processInfo: info))
        let pair = AIServiceResolver.makeAskAndAdaptation(
            keyStore: keyStore,
            askModel: .gpt56Luna,
            generationModel: .gpt6Astra,
            processInfo: info
        )
        let askLive = try XCTUnwrap(pair.ask as? LiveOpenAIService)
        let genLive = try XCTUnwrap(pair.adaptation as? LiveOpenAIService)
        XCTAssertEqual(askLive.preferredModelID, "gpt-5.6-luna")
        XCTAssertEqual(genLive.preferredModelID, "gpt-6-astra")
    }

    // MARK: - Helpers

    private static func assertNoKeyLogged(in request: URLRequest) {
        // Authorization header is required for the API call, but must never be printed by app code.
        // This assertion only verifies the test harness itself isn't stuffing the key into the URL.
        XCTAssertFalse(request.url?.absoluteString.contains("sk-") == true)
    }
}


/// Lightweight ProcessInfo stand-in for resolver launch-arg tests.
final class MockProcessInfo: ProcessInfo, @unchecked Sendable {
    private let _arguments: [String]
    init(arguments: [String]) {
        self._arguments = arguments
        super.init()
    }
    override var arguments: [String] { _arguments }
}

/// Provider-only regressions: URLProtocol intercepts every request and keys stay in memory.
@MainActor
final class GenerationProviderTests: XCTestCase {
    override func setUp() { MockURLProtocol.reset() }
    override func tearDown() { MockURLProtocol.reset() }

    private typealias Requests = (plan: AdaptationPlanRequest, generation: AdaptationGenerateRequest)

    private func requests() throws -> Requests {
        let book = try BundleFixtureLoader.loadArgentinaMinimal()
        let chapter = try XCTUnwrap(book.chapters.first)
        let revision = try XCTUnwrap(chapter.activeRevision)
        let plain = revision.blocks.map(\.text).joined(separator: " ")
        let profile = ReaderPreferenceProfile.empty(bookId: book.id)
        let feedback = ChapterFeedback(
            id: UUID(), bookId: book.id, chapterId: chapter.id, revisionId: revision.id,
            overall: .fine, moreOf: [], lessOf: [], freeText: "Explain the river", createdAt: Date()
        )
        let request = AdaptationPlanRequest(
            book: book, feedback: feedback, profile: profile, lockedChapterIds: [],
            unreadChapters: [UnreadChapterSnapshot(
                id: chapter.id, title: chapter.title, orderIndex: chapter.orderIndex,
                currentWordCount: AdaptationPlanValidator.wordCount(of: plain), plainText: plain
            )], maxChaptersToAdapt: 1
        )
        let plan = try DeterministicAdaptationSynthesizer.makePlan(request)
        var target = try XCTUnwrap(plan.chapterTargets.first)
        target.targetWordCount = 40
        target.mustRemainConcepts = ["river"]
        return (request, AdaptationGenerateRequest(
            book: book, plan: plan, chapterId: chapter.id, chapterTitle: chapter.title,
            currentPlainText: plain, target: target, profile: profile, continuityNotes: []
        ))
    }

    private func live(key: String? = "test-provider-key", forced: Bool = false) -> LiveOpenAIService {
        LiveOpenAIService(
            apiKeyProvider: { key }, preferredModel: .gpt6Astra,
            session: MockURLProtocol.makeSession(), forceDeterministicAdaptation: forced
        )
    }

    private func assertFailure(
        _ expected: AIServiceError, service: LiveOpenAIService, requests: Requests,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            _ = try await service.makeAdaptationPlan(requests.plan)
            XCTFail("A provider failure must not return a plan", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? AIServiceError, expected, file: file, line: line)
        }
        do {
            _ = try await service.generateAdaptedChapterWithPacket(requests.generation)
            XCTFail("A provider failure must not return prose", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? AIServiceError, expected, file: file, line: line)
        }
    }

    private func stubContent(_ content: String) throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "choices": [["message": ["role": "assistant", "content": content]]]
        ])
        MockURLProtocol.requestHandler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
        }
    }

    func testResolverDefersKeyReadAndTracksLaterKeyChanges() async throws {
        let store = CountingKeyStore()
        let pair = AIServiceResolver.makeAskAndAdaptation(
            keyStore: store, session: MockURLProtocol.makeSession(),
            processInfo: MockProcessInfo(arguments: [])
        )
        let ask = try XCTUnwrap(pair.ask as? LiveOpenAIService)
        XCTAssertTrue(pair.adaptation is LiveOpenAIService)
        XCTAssertFalse(pair.adaptation.usesDeterministicGeneration)
        XCTAssertEqual(store.loadCount, 0, "Constructing services must not read Keychain")
        let request = AskRequest(userQuestion: "Hello", bookTitle: "Book", bookAuthor: "Author", consumedContext: "river")
        do {
            _ = try await ask.ask(request)
            XCTFail("Expected a missing key error")
        } catch { XCTAssertEqual(error as? AIServiceError, .missingAPIKey) }
        XCTAssertEqual(store.loadCount, 1)
        XCTAssertNil(MockURLProtocol.lastRequest)

        try store.saveAPIKey("test-provider-key")
        try stubContent("A provider answer")
        let answer = try await ask.ask(request)
        XCTAssertEqual(answer.answer, "A provider answer")
        XCTAssertFalse(answer.isMock)
        try store.saveAPIKey(nil)
        MockURLProtocol.reset()
        do {
            _ = try await ask.ask(request)
            XCTFail("Removing the key must not select Mock")
        } catch { XCTAssertEqual(error as? AIServiceError, .missingAPIKey) }
        XCTAssertEqual(store.loadCount, 3)
        XCTAssertNil(MockURLProtocol.lastRequest)
    }

    func testMissingKeyFailsBothAdaptationStagesBeforeTransport() async throws {
        await assertFailure(.missingAPIKey, service: live(key: nil), requests: try requests())
        XCTAssertNil(MockURLProtocol.lastRequest)
    }

    func testAdaptationNetworkFailuresPropagate() async throws {
        let input = try requests()
        for (code, expected) in [(URLError.notConnectedToInternet, AIServiceError.offline),
                                 (.timedOut, .timedOut), (.cancelled, .cancelled)] {
            var calls = 0
            MockURLProtocol.requestHandler = { _ in
                calls += 1
                throw URLError(code)
            }
            await assertFailure(expected, service: live(), requests: input)
            XCTAssertEqual(calls, 2, "Each stage makes one request")
        }
    }

    func testAdaptationHTTPFailuresNeverTryAnotherModel() async throws {
        let input = try requests()
        let cases: [(Int, String, AIServiceError)] = [
            (401, "{}", .invalidAPIKey),
            (404, "{}", .modelUnavailable("gpt-6-astra")),
            (400, #"{"error":{"message":"model unavailable","code":"model_not_found"}}"#, .modelUnavailable("gpt-6-astra")),
            (400, #"{"error":{"message":"model unavailable"}}"#, .httpStatus(400, "model unavailable")),
            (400, #"{"error":{"message":"invalid request"}}"#, .httpStatus(400, "invalid request")),
            (429, "{}", .httpStatus(429, nil)),
            (500, "{}", .httpStatus(500, nil)),
            (200, "not-json", .malformedResponse)
        ]
        for (status, body, expected) in cases {
            var models: [String] = []
            MockURLProtocol.requestHandler = { request in
                let payload = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                models.append(payload["model"] as! String)
                return (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
            }
            await assertFailure(expected, service: live(), requests: input)
            XCTAssertEqual(models, ["gpt-6-astra", "gpt-6-astra"], "Failure \(status) must not downgrade either stage")
        }
    }

    func testMalformedAdaptationContentPropagatesDecodeErrors() async throws {
        let input = try requests()
        try stubContent("not valid JSON")
        do {
            _ = try await live().makeAdaptationPlan(input.plan)
            XCTFail("Malformed content must not become a deterministic plan")
        } catch { XCTAssertTrue(error is DecodingError) }
        do {
            _ = try await live().generateAdaptedChapterWithPacket(input.generation)
            XCTFail("Malformed content must not become deterministic prose")
        } catch { XCTAssertTrue(error is DecodingError) }
    }

    func testAdaptationValidationErrorsPropagate() async throws {
        let input = try requests()
        let illegalID = UUID()
        try stubContent("{\"chapterTargets\":[{\"chapterId\":\"\(illegalID)\",\"targetWordCount\":40}]}")
        do {
            _ = try await live().makeAdaptationPlan(input.plan)
            XCTFail("Illegal plan must not become a deterministic plan")
        } catch { XCTAssertEqual(error as? AdaptationError, .illegalChapterId(illegalID)) }

        try stubContent(#"{"blocks":[{"kind":"paragraph","text":"river"}]}"#)
        do {
            _ = try await live().generateAdaptedChapterWithPacket(input.generation)
            XCTFail("Under-length text must not be replaced by deterministic prose")
        } catch { XCTAssertEqual(error as? AdaptationError, .wordCountOutOfRange(expected: 40, actual: 1)) }

        let text = Array(repeating: "mountain", count: 40).joined(separator: " ")
        try stubContent("{\"blocks\":[{\"kind\":\"paragraph\",\"text\":\"\(text)\"}]}")
        do {
            _ = try await live().generateAdaptedChapterWithPacket(input.generation)
            XCTFail("Missing continuity must remain an error")
        } catch { XCTAssertEqual(error as? AdaptationError, .continuityMissing(["river"])) }
    }

    func testSuccessfulAdaptationUsesOnlySelectedModelAndProviderText() async throws {
        let input = try requests()
        let service = LiveOpenAIService(apiKey: "test-provider-key", preferredModel: .gpt41, session: MockURLProtocol.makeSession())
        let prose = Array(repeating: "river", count: 40).joined(separator: " ")
        var models: [String] = []
        MockURLProtocol.requestHandler = { request in
            let payload = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            models.append(payload["model"] as! String)
            let messages = payload["messages"] as! [[String: String]]
            let isPlan = messages[0]["content"]!.contains("adaptation planner")
            let content = isPlan
                ? "{\"chapterTargets\":[{\"chapterId\":\"\(input.generation.chapterId)\",\"targetWordCount\":40}]}"
                : "{\"blocks\":[{\"kind\":\"paragraph\",\"text\":\"\(prose)\"}]}"
            let data = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]]])
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
        }
        let plan = try await service.makeAdaptationPlan(input.plan)
        XCTAssertEqual(plan.affectedChapterIds, [input.generation.chapterId])
        let generated = try await service.generateAdaptedChapterWithPacket(input.generation)
        XCTAssertEqual(generated.blocks.map(\.text), [prose])
        XCTAssertEqual(models, ["gpt-4.1", "gpt-4.1"])
        XCTAssertFalse(service.usesDeterministicGeneration)
    }

    func testOnlyExplicitDeterministicModeBypassesProvider() async throws {
        let input = try requests()
        let service = LiveOpenAIService(
            apiKeyProvider: { XCTFail("Explicit deterministic mode must not read keys"); return nil },
            session: MockURLProtocol.makeSession(), forceDeterministicAdaptation: true
        )
        XCTAssertTrue(service.usesDeterministicGeneration)
        XCTAssertTrue(MockAIService().usesDeterministicGeneration)
        let plan = try await service.makeAdaptationPlan(input.plan)
        XCTAssertFalse(plan.chapterTargets.isEmpty)
        let generated = try await service.generateAdaptedChapter(input.generation)
        XCTAssertFalse(generated.isEmpty)
        let legacy = try await service.adaptChapter(chapterId: UUID(), promptContext: "test")
        XCTAssertFalse(legacy.blocks.isEmpty)
        XCTAssertNil(MockURLProtocol.lastRequest)
        for arg in ["-useMockAI", "-phase4MockAsk", "-phase5AdaptationDemo", "-uitesting"] {
            let store = CountingKeyStore()
            let resolved = AIServiceResolver.makeDefault(keyStore: store, processInfo: MockProcessInfo(arguments: [arg]))
            XCTAssertTrue(resolved is MockAIService)
            XCTAssertTrue(resolved.usesDeterministicGeneration)
            XCTAssertEqual(store.loadCount, 0)
        }
    }

    func testLegacyLiveAdaptationReportsUnsupportedPath() async throws {
        do {
            _ = try await live().adaptChapter(chapterId: UUID(), promptContext: "test")
            XCTFail("Legacy live adaptation must not fabricate a revision")
        } catch {
            XCTAssertEqual(error as? AIServiceError, .underlying("Direct chapter adaptation is unsupported. Use the plan-and-generate path."))
        }
        XCTAssertNil(MockURLProtocol.lastRequest)
    }

    func testAskRequestUsesCompatibleParametersForEverySupportedModel() async throws {
        let request = AskRequest(userQuestion: "Hello", bookTitle: "Book", bookAuthor: "Author", consumedContext: "river")
        for model in OpenAIModelOption.allCases {
            var bodies: [[String: Any]] = []
            MockURLProtocol.requestHandler = { request in
                bodies.append(try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any])
                XCTAssertEqual(request.timeoutInterval, 30)
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        Data(#"{"choices":[{"message":{"content":"Provider answer"}}]}"#.utf8))
            }
            let service = LiveOpenAIService(apiKey: "test-provider-key", preferredModel: model, session: MockURLProtocol.makeSession())
            _ = try await service.ask(request)
            XCTAssertEqual(bodies.count, 1)
            let body = try XCTUnwrap(bodies.first)
            assertRequestParameters(body, model: model, cap: 700, jsonObject: false)
            XCTAssertEqual(body["messages"] as? [[String: String]], [
                ["role": "system", "content": AskContextBuilder.systemPrompt(for: request)],
                ["role": "user", "content": AskContextBuilder.userPrompt(for: request)]
            ])
        }
    }

    func testPlanAndGenerationUseCompatibleParametersWithoutChangingBudgets() async throws {
        let input = try requests()
        let prose = Array(repeating: "river", count: 40).joined(separator: " ")
        for model in OpenAIModelOption.allCases {
            var bodies: [[String: Any]] = []
            MockURLProtocol.requestHandler = { request in
                bodies.append(try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any])
                XCTAssertEqual(request.timeoutInterval, bodies.count == 1 ? 30 : 60)
                let content = bodies.count == 1
                    ? "{\"chapterTargets\":[{\"chapterId\":\"\(input.generation.chapterId)\",\"targetWordCount\":40}]}"
                    : "{\"blocks\":[{\"kind\":\"paragraph\",\"text\":\"\(prose)\"}]}"
                let data = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]]])
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
            }
            let service = LiveOpenAIService(apiKey: "test-provider-key", preferredModel: model, session: MockURLProtocol.makeSession())
            _ = try await service.makeAdaptationPlan(input.plan)
            _ = try await service.generateAdaptedChapterWithPacket(input.generation)
            XCTAssertEqual(bodies.count, 2)
            guard bodies.count == 2 else { continue }
            assertRequestParameters(bodies[0], model: model, cap: 1800, jsonObject: true)
            assertRequestParameters(bodies[1], model: model, cap: 2500, jsonObject: true)
            XCTAssertEqual(bodies[0]["messages"] as? [[String: String]], [
                ["role": "system", "content": AdaptationLivePrompts.planSystem],
                ["role": "user", "content": AdaptationLivePrompts.planUser(input.plan)]
            ])
            XCTAssertEqual(bodies[1]["messages"] as? [[String: String]], [
                ["role": "system", "content": AdaptationLivePrompts.generateSystem],
                ["role": "user", "content": AdaptationLivePrompts.generateUser(input.generation)]
            ])
        }
        XCTAssertEqual(OpenAIModelOption.defaultGeneration, .gpt6Astra)
    }

    func testGenerationBudgetsAndDeadlinesCoverEveryOfferedLengthAndBoundaries() async throws {
        let cases: [(Int, Int, TimeInterval)] = [
            (400, 2500, 60), (401, 4500, 90), (800, 4500, 90),
            (801, 6500, 120), (1200, 6500, 120), (1201, 6500, 120)
        ]
        for (words, cap, deadline) in cases {
            var input = try requests()
            input.generation.target.targetWordCount = words
            let prose = Array(repeating: "river", count: words).joined(separator: " ")
            var calls = 0
            MockURLProtocol.requestHandler = { request in
                calls += 1
                let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                XCTAssertEqual(body["model"] as? String, "gpt-6-astra")
                XCTAssertEqual(body["max_completion_tokens"] as? Int, cap)
                XCTAssertNil(body["max_tokens"])
                XCTAssertEqual(request.timeoutInterval, deadline)
                let content = "{\"blocks\":[{\"kind\":\"paragraph\",\"text\":\"\(prose)\"}]}"
                let data = try JSONSerialization.data(withJSONObject: ["choices": [[
                    "finish_reason": "stop", "message": ["content": content]
                ]]])
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
            }
            let generated = try await live().generateAdaptedChapterWithPacket(input.generation)
            XCTAssertEqual(AdaptationPlanValidator.wordCount(of: generated.blocks), words)
            XCTAssertEqual(calls, 1, "Each requested length gets one bounded generation call")
        }
    }

    func testExplicitTimeoutOverridesRemainExactForAskPlanAndEveryGenerationLength() async throws {
        for timeout: TimeInterval in [1, 2, 30] {
            let input = try requests()
            var calls = 0
            MockURLProtocol.requestHandler = { request in
                calls += 1
                XCTAssertEqual(request.timeoutInterval, timeout, "Explicit deadlines must not be scaled")
                let content: String
                if calls == 1 {
                    content = "Provider answer"
                } else if calls == 2 {
                    content = "{\"chapterTargets\":[{\"chapterId\":\"\(input.generation.chapterId)\",\"targetWordCount\":40}]}"
                } else {
                    let words = [400, 800, 1200][calls - 3]
                    let prose = Array(repeating: "river", count: words).joined(separator: " ")
                    content = "{\"blocks\":[{\"kind\":\"paragraph\",\"text\":\"\(prose)\"}]}"
                }
                let data = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]]])
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
            }
            let service = LiveOpenAIService(apiKey: "test-provider-key", preferredModel: .gpt6Astra,
                                           session: MockURLProtocol.makeSession(), timeout: timeout)
            _ = try await service.ask(AskRequest(userQuestion: "Hello", bookTitle: "Book", bookAuthor: "Author", consumedContext: "river"))
            _ = try await service.makeAdaptationPlan(input.plan)
            for words in [400, 800, 1200] {
                var generation = input.generation
                generation.target.targetWordCount = words
                _ = try await service.generateAdaptedChapterWithPacket(generation)
            }
            XCTAssertEqual(calls, 5)
        }
    }

    func testLengthLimitedResponseFailsBeforeContentParsingWithoutRetryOrFallback() async throws {
        let input = try requests()
        for content in ["not JSON", "{\"chapterTargets\":[{\"chapterId\":\"\(input.generation.chapterId)\",\"targetWordCount\":40}]}"] {
            var models: [String] = []
            MockURLProtocol.requestHandler = { request in
                let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                models.append(body["model"] as! String)
                let data = try JSONSerialization.data(withJSONObject: ["choices": [[
                    "finish_reason": "length", "message": ["content": content]
                ]]])
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
            }
            let service = live()
            let expected = AIServiceError.underlying("The AI response reached its output token limit before finishing. Try a shorter chapter or request.")
            await assertFailure(expected, service: service, requests: input)
            do {
                _ = try await service.ask(AskRequest(userQuestion: "Hello", bookTitle: "Book", bookAuthor: "Author", consumedContext: "river"))
                XCTFail("A truncated answer must not be returned as complete")
            } catch { XCTAssertEqual(error as? AIServiceError, expected) }
            XCTAssertEqual(models, Array(repeating: "gpt-6-astra", count: 3))
            XCTAssertNil(service.lastModelUsed)
        }
    }

    func testWizardDoesNotPublishParseableLengthLimitedHalfLengthChapter() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TruncationRejection-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let packets = try FilePEPacketStore(rootDirectory: root)
        let versioning = try ManuscriptVersioningService(rootDirectory: root, packets: packets)
        let preferences = try FileReaderPreferenceStore(rootDirectory: root)
        let drafts = try FileCreateBookDraftStore(rootDirectory: root)
        let prose = Array(repeating: "river", count: 600).joined(separator: " ")
        let content = try JSONSerialization.data(withJSONObject: ["blocks": [["kind": "paragraph", "text": prose]]])
        let response = try JSONSerialization.data(withJSONObject: ["choices": [[
            "finish_reason": "length", "message": ["content": String(decoding: content, as: UTF8.self)]
        ]]])
        var calls = 0
        MockURLProtocol.requestHandler = { request in
            calls += 1
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            XCTAssertEqual(body["model"] as? String, "gpt-6-astra")
            XCTAssertEqual(body["max_completion_tokens"] as? Int, 6500)
            XCTAssertEqual(request.timeoutInterval, 120)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, response)
        }
        let service = live()
        let wizard = CreateBookWizardService(versioning: versioning, preferenceStore: preferences,
                                             packets: packets, drafts: drafts, ai: service)
        var draft = CreateBookDraft.blank()
        draft.path = .generate
        draft.title = "Truncation rejection"
        draft.topic = "river"
        draft.outlineTitles = ["river"]
        draft.length = .long
        let result = try await wizard.generateAndSave(draft: draft)
        XCTAssertEqual(draft.length.targetWordsPerChapter, 1200)
        XCTAssertEqual(calls, 1)
        XCTAssertFalse(result.isComplete)
        XCTAssertTrue(result.generatedChapterIds.isEmpty)
        XCTAssertEqual(result.skippedChapterIds.count, 1)
        XCTAssertEqual(result.book.outlineChapterCount, 1)
        XCTAssertEqual(result.book.chapters[0].revisions.count, 1, "No partial prose is published as a new revision")
        XCTAssertTrue(result.failureMessages.first?.contains("output token limit") == true)
        XCTAssertNotNil(try drafts.load(id: draft.id), "The draft stays available for an explicit retry")
        XCTAssertFalse(result.usedDeterministicFallback)
        XCTAssertNil(service.lastModelUsed)
    }

    func testUnsupportedParameterDetailsPropagateWithoutAnyModelFallback() async throws {
        let input = try requests()
        let cases = [
            ("max_tokens", "Unsupported parameter: 'max_tokens' is not supported with this model. Use 'max_completion_tokens' instead."),
            ("temperature", "Unsupported parameter: 'temperature' is not supported with this model."),
            ("top_p", "Unsupported parameter: 'top_p' is not supported with this model.")
        ]
        for (param, message) in cases {
            var models: [String] = []
            MockURLProtocol.requestHandler = { request in
                let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                models.append(body["model"] as! String)
                let data = try JSONSerialization.data(withJSONObject: ["error": [
                    "message": message, "type": "invalid_request_error", "code": "unsupported_parameter", "param": param
                ]])
                return (HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!, data)
            }
            let service = live()
            await assertFailure(.httpStatus(400, message), service: service, requests: input)
            do {
                _ = try await service.ask(AskRequest(userQuestion: "Hello", bookTitle: "Book", bookAuthor: "Author", consumedContext: "river"))
                XCTFail("Ask must not hide a request-schema error with another model")
            } catch { XCTAssertEqual(error as? AIServiceError, .httpStatus(400, message)) }
            XCTAssertEqual(models, Array(repeating: "gpt-6-astra", count: 3))
            XCTAssertNil(service.lastModelUsed)
        }
    }

    func testExplicitModelNotFoundStillAllowsAskFallback() async throws {
        var models: [String] = []
        MockURLProtocol.requestHandler = { request in
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            models.append(body["model"] as! String)
            let unavailable = models.count == 1
            let data = unavailable
                ? Data(#"{"error":{"message":"Requested model is not available","code":"model_not_found"}}"#.utf8)
                : Data(#"{"choices":[{"message":{"content":"Fallback answer"}}]}"#.utf8)
            return (HTTPURLResponse(url: request.url!, statusCode: unavailable ? 400 : 200, httpVersion: nil, headerFields: nil)!, data)
        }
        let response = try await live().ask(AskRequest(userQuestion: "Hello", bookTitle: "Book", bookAuthor: "Author", consumedContext: "river"))
        XCTAssertEqual(models, ["gpt-6-astra", "gpt-4.1"])
        XCTAssertEqual(response.modelUsed, "gpt-4.1")
    }

    private func assertRequestParameters(
        _ body: [String: Any], model: OpenAIModelOption, cap: Int, jsonObject: Bool,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let reasoning = model == .gpt6Astra || model == .gpt56Luna
        var keys: Set<String> = ["model", "messages", reasoning ? "max_completion_tokens" : "max_tokens"]
        if !reasoning { keys.insert("temperature") }
        if jsonObject { keys.insert("response_format") }
        XCTAssertEqual(Set(body.keys), keys, file: file, line: line)
        XCTAssertEqual(body["model"] as? String, model.rawValue, file: file, line: line)
        XCTAssertEqual(body[reasoning ? "max_completion_tokens" : "max_tokens"] as? Int, cap, file: file, line: line)
        XCTAssertNil(body[reasoning ? "max_tokens" : "max_completion_tokens"], file: file, line: line)
        XCTAssertNil(body["top_p"], file: file, line: line)
        if reasoning {
            XCTAssertNil(body["temperature"], file: file, line: line)
        } else {
            XCTAssertEqual(body["temperature"] as? Double, jsonObject ? 0.3 : 0.4, file: file, line: line)
        }
        if jsonObject {
            XCTAssertEqual(body["response_format"] as? [String: String], ["type": "json_object"], file: file, line: line)
        }
    }

    private final class CountingKeyStore: APIKeyStoring, @unchecked Sendable {
        private let lock = NSLock()
        private var key: String?
        private var loads = 0
        var loadCount: Int { lock.lock(); defer { lock.unlock() }; return loads }
        func loadAPIKey() throws -> String? {
            lock.lock(); defer { lock.unlock() }
            loads += 1
            return key
        }
        func saveAPIKey(_ key: String?) throws {
            lock.lock(); defer { lock.unlock() }
            self.key = key
        }
    }
}
