import XCTest
@testable import LivingReader

/// Wave F New Book redesign — RDR-950…954.
/// Two panes, no explanatory banners, and a scripted BookBot Q&A instead of the
/// old always-visible More of / Less of toggle lists.
final class NewBookTabsTests: XCTestCase {

    // MARK: - Two panes (RDR-950)

    func testNewBookHasExactlyTwoNamedPanes() {
        XCTAssertEqual(CreateBookTab.allCases, [.existingBooks, .generateBook])
        XCTAssertEqual(CreateBookTab.existingBooks.title, "Existing Books")
        XCTAssertEqual(CreateBookTab.generateBook.title, "Generate Book")
    }

    func testExistingBooksUsesAClassicSymbolAndGenerateUsesTheAISymbol() {
        XCTAssertEqual(CreateBookTab.existingBooks.systemImage, "books.vertical")
        XCTAssertEqual(CreateBookTab.generateBook.systemImage, "sparkles")
        XCTAssertEqual(CreateBookTab.existingBooks.accessibilityIdentifier, "create.tab.existing")
        XCTAssertEqual(CreateBookTab.generateBook.accessibilityIdentifier, "create.tab.generate")
    }

    /// Canon vs Living stays a code rule: the pane decides the path, no UI copy needed.
    func testPaneMapsToCanonImportOrLivingGenerate() {
        XCTAssertEqual(CreateBookTab.existingBooks.path, .importManuscript)
        XCTAssertEqual(CreateBookTab.generateBook.path, .generate)
        XCTAssertEqual(CreateBookTab(path: .importManuscript), .existingBooks)
        XCTAssertEqual(CreateBookTab(path: .generate), .generateBook)
    }

    // MARK: - Length in pages or read time (RDR-951)

    func testLengthOffersPagesAndTheMatchingReadTime() {
        XCTAssertEqual(CreateBookLength.short.targetWordCount, 1_200)
        XCTAssertEqual(CreateBookLength.medium.targetWordCount, 4_800)
        XCTAssertEqual(CreateBookLength.long.targetWordCount, 9_600)

        for length in CreateBookLength.allCases {
            XCTAssertEqual(
                length.approximatePageCount,
                Int((Double(length.targetWordCount) / Double(CreateBookLength.wordsPerPage)).rounded())
            )
            XCTAssertEqual(length.pagesLabel, "\(length.approximatePageCount) pages")
            XCTAssertTrue(length.readingTimeLabel.hasPrefix("About "))
            XCTAssertTrue(length.readingTimeLabel.hasSuffix(" to read"))
        }

        XCTAssertLessThan(CreateBookLength.short.approximatePageCount, CreateBookLength.medium.approximatePageCount)
        XCTAssertLessThan(CreateBookLength.medium.approximatePageCount, CreateBookLength.long.approximatePageCount)
    }

    /// Pages and time are two views of one word budget, so they cannot disagree.
    func testPagesAndReadTimeComeFromTheSameWordBudget()  {
        let medium = CreateBookLength.medium
        XCTAssertEqual(medium.estimatedReadingTime.proseWordCount, medium.targetWordCount)
        XCTAssertEqual(
            medium.estimatedReadingTime.wordsPerMinute,
            ReadingTimePreferences.default.wordsPerMinute
        )
        XCTAssertEqual(medium.estimatedReadingTime.visualBlockCount, 0)
    }

    // MARK: - BookBot Q&A replaces the toggle soup (RDR-952)

    func testChatOpensWithTheTopicQuestionAndNothingElse() {
        var chat = CreateBookChat()
        chat.start()
        XCTAssertEqual(chat.messages.count, 1)
        XCTAssertEqual(chat.messages.first?.role, .bot)
        XCTAssertEqual(chat.messages.first?.text, CreateChatSlot.topic.question)
        XCTAssertEqual(chat.pendingSlot, .topic)
        XCTAssertFalse(chat.isComplete)
    }

    func testStartIsIdempotent() {
        var chat = CreateBookChat()
        chat.start()
        chat.start()
        XCTAssertEqual(chat.messages.count, 1)
    }

    func testEveryQuestionIsOneShortLine() {
        for slot in CreateChatSlot.allCases {
            XCTAssertFalse(slot.question.contains("\n"), "\(slot.rawValue) must stay one line")
            XCTAssertLessThanOrEqual(slot.question.count, 56, "\(slot.rawValue): \(slot.question)")
        }
        XCTAssertTrue(CreateChatSlot.topic.isRequired)
        XCTAssertFalse(CreateChatSlot.moreOf.isRequired)
        XCTAssertFalse(CreateChatSlot.lessOf.isRequired)
    }

    func testAnsweringTopicFillsTheDraftAndAsksTheNextQuestion() {
        var draft = CreateBookDraft.blank()
        var chat = CreateBookChat()
        chat.start()
        chat.answer("How a plaza remembers inflation", into: &draft)

        XCTAssertEqual(draft.trimmedTopic, "How a plaza remembers inflation")
        XCTAssertEqual(chat.pendingSlot, .voice)
        XCTAssertEqual(chat.messages.map(\.role), [.bot, .reader, .bot])
        XCTAssertEqual(chat.messages.last?.text, CreateChatSlot.voice.question)
    }

    func testMoreOfAnswerReplacesTheOldToggleListAndKeepsTheWords() {
        var draft = CreateBookDraft.blank()
        var chat = CreateBookChat()
        chat.start()
        chat.answer("A plaza history", into: &draft)
        chat.answer("warm historical storyteller", into: &draft)
        chat.answer("stories and the places I'll visit", into: &draft)

        XCTAssertEqual(draft.voice, "warm historical storyteller")
        XCTAssertEqual(draft.moreOf, [.stories, .placesIllVisit])
        XCTAssertTrue(draft.readerNotes.contains("More of: stories and the places I'll visit"))
        XCTAssertEqual(chat.pendingSlot, .lessOf)
    }

    func testLessOfAnswerMapsToTopicsInAStableOrder() {
        var draft = CreateBookDraft.blank()
        XCTAssertEqual(
            CreateBookChatScript.lessTopics(in: "fewer dates, less political detail"),
            [.dates, .politicalDetail]
        )
        XCTAssertEqual(
            CreateBookChatScript.lessTopics(in: "less political detail, fewer dates"),
            [.dates, .politicalDetail]
        )
        CreateBookChatScript.apply(answer: "skip the party names", for: .lessOf, to: &draft)
        XCTAssertEqual(draft.lessOf, [.names, .politicalDetail])
    }

    func testUnmatchedAnswerStillReachesTheBriefAsNotes() {
        var draft = CreateBookDraft.blank()
        let before = draft.moreOf
        CreateBookChatScript.apply(answer: "more mate and football", for: .moreOf, to: &draft)
        XCTAssertEqual(draft.moreOf, before, "An answer the topics cannot express must not wipe them")
        XCTAssertTrue(draft.readerNotes.contains("more mate and football"))
    }

    func testSkipFillsTheSlotWithoutSettingAnything() {
        var draft = CreateBookDraft.blank()
        var chat = CreateBookChat()
        chat.start()
        chat.answer("A plaza history", into: &draft)
        chat.answer("skip", into: &draft)

        XCTAssertEqual(draft.voice, "neutral", "Skip leaves the default voice alone")
        XCTAssertEqual(chat.pendingSlot, .moreOf)
        XCTAssertTrue(CreateBookChatScript.isSkip("None"))
        XCTAssertTrue(CreateBookChatScript.isSkip("no preference"))
        XCTAssertTrue(CreateBookChatScript.isSkip("  Nothing. "))
        XCTAssertFalse(CreateBookChatScript.isSkip("nothing about the war"))
    }

    func testSkippingRequiredTopicKeepsItAnswerable() {
        var draft = CreateBookDraft.blank()
        var chat = CreateBookChat()
        chat.start()

        for answer in ["skip", "no", "you pick"] {
            chat.answer(answer, into: &draft)
            XCTAssertEqual(chat.pendingSlot, .topic)
            XCTAssertFalse(chat.isComplete)
            XCTAssertTrue(draft.trimmedTopic.isEmpty)
            XCTAssertNotEqual(chat.messages.last?.text, CreateBookChatScript.readyLine)
        }

        chat.answer("A plaza history", into: &draft)
        XCTAssertEqual(draft.trimmedTopic, "A plaza history")
        XCTAssertEqual(chat.pendingSlot, .voice)
    }

    func testResearchAnswerAppendsToResearchNotes() {
        var draft = CreateBookDraft.blank()
        CreateBookChatScript.apply(answer: "The cabildo still faces the plaza.", for: .research, to: &draft)
        CreateBookChatScript.apply(answer: "Mate is a social clock.", for: .research, to: &draft)
        XCTAssertEqual(draft.researchNotes, "The cabildo still faces the plaza.\nMate is a social clock.")
    }

    func testConversationEndsReadyAndLaterLinesBecomeNotes() {
        var draft = CreateBookDraft.blank()
        var chat = CreateBookChat()
        chat.start()
        chat.answer("A plaza history", into: &draft)
        for slot in CreateChatSlot.allCases where !slot.isRequired {
            chat.answer("skip", into: &draft)
        }
        XCTAssertTrue(chat.isComplete)
        XCTAssertNil(chat.pendingSlot)
        XCTAssertEqual(chat.messages.last?.text, CreateBookChatScript.readyLine)

        chat.answer("Keep the plazas concrete", into: &draft)
        XCTAssertTrue(draft.readerNotes.contains("Keep the plazas concrete"))
        XCTAssertEqual(chat.messages.last?.text, CreateBookChatScript.extraNoteAck)
    }

    func testEmptyAnswerIsIgnored() {
        var draft = CreateBookDraft.blank()
        var chat = CreateBookChat()
        chat.start()
        chat.answer("   \n ", into: &draft)
        XCTAssertEqual(chat.messages.count, 1)
        XCTAssertEqual(chat.pendingSlot, .topic)
    }

    // MARK: - Optional AI context paste still works, with no always-visible block (RDR-953)

    func testPastedProfileCardsAreImportedInsteadOfAnsweringTheQuestion() {
        var draft = CreateBookDraft.blank()
        var chat = CreateBookChat()
        chat.start()
        let paste = """
        ## Voice
        warm historical storyteller

        ## Outline
        - The river
        - The interior

        ## Reference styles
        A Little History of the World, Ryszard Kapuscinski

        ## Research notes
        The cabildo still faces the plaza.
        """
        chat.answer(paste, into: &draft)

        XCTAssertEqual(draft.profileCards.count, 4)
        XCTAssertEqual(draft.voice, "warm historical storyteller")
        XCTAssertEqual(draft.outlineTitles, ["The river", "The interior"])
        XCTAssertEqual(draft.referenceStyles, ["A Little History of the World", "Ryszard Kapuscinski"])
        XCTAssertEqual(draft.researchNotes, "The cabildo still faces the plaza.")
        XCTAssertEqual(chat.messages.last?.text, CreateChatSlot.topic.question, "A card paste is context, not the answer")
        XCTAssertEqual(chat.pendingSlot, .topic)
    }

    func testAPlainSentenceIsNeverMistakenForACardPaste() {
        XCTAssertFalse(CreateBookChatScript.looksLikeProfileCardPaste("Stories and places, please"))
        XCTAssertFalse(CreateBookChatScript.looksLikeProfileCardPaste("## Voice\nwarm"))
        XCTAssertTrue(CreateBookChatScript.looksLikeProfileCardPaste("## Voice\nwarm\n\n## Outline\n- One"))
    }

    // MARK: - Generated book still goes through the existing Living path (RDR-954)

    func testChatAnswersProduceADraftTheWizardCanGenerateFrom() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NewBookTabs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let packets = try FilePEPacketStore(rootDirectory: root)
        let versioning = try ManuscriptVersioningService(rootDirectory: root, packets: packets)
        let wizard = CreateBookWizardService(
            versioning: versioning,
            preferenceStore: try FileReaderPreferenceStore(rootDirectory: root),
            packets: packets,
            drafts: try FileCreateBookDraftStore(rootDirectory: root),
            ai: MockAIService()
        )

        var draft = CreateBookDraft.blank()
        draft.path = CreateBookTab.generateBook.path
        draft.title = "Plaza Stories"
        draft.length = .short
        draft.referenceStyles = ["A Little History of the World"]

        var chat = CreateBookChat()
        chat.start()
        chat.answer("How a plaza remembers inflation and football", into: &draft)
        chat.answer("warm historical storyteller", into: &draft)
        chat.answer("stories and economics", into: &draft)
        chat.answer("fewer dates", into: &draft)
        chat.answer("The cabildo still faces the plaza.", into: &draft)
        XCTAssertTrue(chat.isComplete)

        let result = try await wizard.generateAndSave(draft: draft)
        XCTAssertEqual(result.book.title, "Plaza Stories")
        XCTAssertEqual(result.book.chapters.count, CreateBookLength.short.chapterCount)
        XCTAssertEqual(result.packet.brief?.bookTitle, "Plaza Stories")
        XCTAssertFalse(result.packet.facts.evidence.isEmpty, "Chat research answers seed supporting evidence")
    }

    /// Generate needs a title and a topic; the topic only arrives through the chat.
    func testGenerateStillRefusesAnUntitledOrUndescribedDraft() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NewBookTabs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let packets = try FilePEPacketStore(rootDirectory: root)
        let wizard = CreateBookWizardService(
            versioning: try ManuscriptVersioningService(rootDirectory: root, packets: packets),
            preferenceStore: try FileReaderPreferenceStore(rootDirectory: root),
            packets: packets,
            drafts: try FileCreateBookDraftStore(rootDirectory: root),
            ai: MockAIService()
        )

        var untitled = CreateBookDraft.blank()
        untitled.topic = "A plaza history"
        do {
            _ = try await wizard.generateAndSave(draft: untitled)
            XCTFail("Expected a missing-title error")
        } catch {
            XCTAssertEqual(error as? CreateBookError, .missingTitle)
        }

        var undescribed = CreateBookDraft.blank()
        undescribed.title = "Plaza Stories"
        do {
            _ = try await wizard.generateAndSave(draft: undescribed)
            XCTFail("Expected a missing-topic error")
        } catch {
            XCTAssertEqual(error as? CreateBookError, .missingTopic)
        }
    }
}
