import XCTest
import CryptoKit
@testable import LivingReader

/// The reader picks a word: everything through that word is frozen, only the
/// continuation is eligible for change, and every rewrite stays restorable.
final class WordForwardRegenTests: XCTestCase {
    private var root: URL!
    private var versioning: ManuscriptVersioningService!
    private var book: Book!
    private var feedbackStore: FileFeedbackStore!
    private var preferenceStore: FileReaderPreferenceStore!
    private var ai: MockAIService!
    private var adaptation: LivingBookAdaptationService!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WordRegen-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        versioning = try ManuscriptVersioningService(rootDirectory: root)
        book = try BundleFixtureLoader.loadArgentinaMinimal()
        try await versioning.saveBook(book)
        feedbackStore = try FileFeedbackStore(rootDirectory: root)
        preferenceStore = try FileReaderPreferenceStore(rootDirectory: root)
        ai = MockAIService()
        adaptation = LivingBookAdaptationService(
            versioning: versioning,
            feedbackStore: feedbackStore,
            preferenceStore: preferenceStore,
            ai: ai
        )
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        root = nil
        versioning = nil
        book = nil
        adaptation = nil
        ai = nil
    }

    // MARK: - Splitting at a UTF-16 offset

    func testSplitAtNearestWordFreezesTheWholeWordAndLosesNothing() throws {
        let blocks = [
            ContentBlock(id: UUID(), kind: .heading, text: "Independence", orderIndex: 0),
            ContentBlock(id: UUID(), kind: .paragraph, text: "Across the pampas, settlements grew.", orderIndex: 1),
            ContentBlock(id: UUID(), kind: .paragraph, text: "The port argued with the interior.", orderIndex: 2)
        ]
        // Offset 13 sits inside "pampas"; preserve that whole word and its punctuation.
        let split = try ChapterAnchorSplitter.split(
            blocks: blocks,
            blockId: blocks[1].id,
            utf16OffsetInBlock: 13
        )

        XCTAssertEqual(split.anchorWord, "pampas")
        XCTAssertEqual(split.frozenPrefix.map(\.text), ["Independence", "Across the pampas, "])
        XCTAssertEqual(
            split.regenerableSuffix.map(\.text),
            ["settlements grew.", "The port argued with the interior."]
        )
        XCTAssertEqual(split.dividedBlockId, blocks[1].id)
        XCTAssertEqual(
            split.frozenPrefix.last?.id,
            blocks[1].id,
            "The already-read half keeps the block id so highlights and the saved place still resolve"
        )
        XCTAssertNotEqual(split.regenerableSuffix.first?.id, blocks[1].id)
        XCTAssertEqual(
            (split.frozenPrefix.last?.text ?? "") + (split.regenerableSuffix.first?.text ?? ""),
            blocks[1].text,
            "A split must be lossless"
        )
        XCTAssertEqual(split.frozenPrefix.map(\.orderIndex), [0, 1])
        XCTAssertEqual(split.regenerableSuffix.map(\.orderIndex), [0, 1])
    }

    func testSplitAtBlockStartPreservesTheFirstWord() throws {
        let blocks = [
            ContentBlock(id: UUID(), kind: .paragraph, text: "First block.", orderIndex: 0),
            ContentBlock(id: UUID(), kind: .paragraph, text: "Second block.", orderIndex: 1)
        ]
        let split = try ChapterAnchorSplitter.split(
            blocks: blocks,
            blockId: blocks[1].id,
            utf16OffsetInBlock: 0
        )

        XCTAssertEqual(split.frozenPrefix.map(\.text), ["First block.", "Second "])
        XCTAssertEqual(split.regenerableSuffix.map(\.text), ["block."])
        XCTAssertEqual(split.dividedBlockId, blocks[1].id)
    }

    func testSplitInLeadingWhitespacePreservesTheNearestWord() throws {
        let blocks = [
            ContentBlock(id: UUID(), kind: .paragraph, text: "Earlier text.", orderIndex: 0),
            ContentBlock(id: UUID(), kind: .paragraph, text: "  Later text.", orderIndex: 1)
        ]
        // Leading whitespace belongs to the frozen first word.
        let split = try ChapterAnchorSplitter.split(
            blocks: blocks,
            blockId: blocks[1].id,
            utf16OffsetInBlock: 1
        )

        XCTAssertEqual(split.frozenPrefix.map(\.text), ["Earlier text.", "  Later "])
        XCTAssertEqual(split.regenerableSuffix.map(\.text), ["text."])
    }

    func testSplitUsesUtf16OffsetsPastAstralCharacters() throws {
        // "🇦🇷" is four UTF-16 units, so a Character-based cut would land in the wrong place.
        let text = "🇦🇷 flag then gauchos ride"
        let block = ContentBlock(id: UUID(), kind: .paragraph, text: text, orderIndex: 0)
        let anchorOffset = (text as NSString).range(of: "gauchos").location

        let split = try ChapterAnchorSplitter.split(
            blocks: [block],
            blockId: block.id,
            utf16OffsetInBlock: anchorOffset + 3
        )

        XCTAssertEqual(split.anchorWord, "gauchos")
        XCTAssertEqual(split.frozenPrefix.map(\.text), ["🇦🇷 flag then gauchos "])
        XCTAssertEqual(split.regenerableSuffix.map(\.text), ["ride"])
    }

    func testSplitRejectsAnchorOnAMissingBlock() {
        let block = ContentBlock(id: UUID(), kind: .paragraph, text: "Only block.", orderIndex: 0)
        let stranger = UUID()
        XCTAssertThrowsError(
            try ChapterAnchorSplitter.split(blocks: [block], blockId: stranger, utf16OffsetInBlock: 2)
        ) { error in
            XCTAssertEqual(error as? ChapterAnchorSplitError, .blockNotFound(stranger))
        }
    }

    func testFrozenPrefixTailStaysWithinThePromptBudget() throws {
        let long = Array(repeating: "word", count: 4_000).joined(separator: " ")
        let tail = ChapterAnchorSplitter.frozenPrefixTail(
            [ContentBlock(id: UUID(), kind: .paragraph, text: long, orderIndex: 0)],
            words: 600
        )
        let count = AdaptationPlanValidator.wordCount(of: tail)
        XCTAssertGreaterThanOrEqual(count, ChapterAnchorSplitter.minimumPromptTailWords)
        XCTAssertLessThanOrEqual(count, ChapterAnchorSplitter.maximumPromptTailWords)
    }

    func testAssertPrefixPreservedCatchesARewrittenFrozenBlock() throws {
        let frozen = [ContentBlock(id: UUID(), kind: .paragraph, text: "Read already.", orderIndex: 0)]
        var tampered = frozen
        tampered[0].text = "Read already, but improved."
        XCTAssertNoThrow(
            try ChapterAnchorSplitter.assertPrefixPreserved(
                frozen,
                in: ChapterAnchorSplitter.assemble(
                    frozenPrefix: frozen,
                    regenerated: [ContentBlock(id: UUID(), kind: .paragraph, text: "New future.", orderIndex: 0)]
                )
            )
        )
        XCTAssertThrowsError(try ChapterAnchorSplitter.assertPrefixPreserved(frozen, in: tampered)) { error in
            XCTAssertEqual(error as? ChapterAnchorSplitError, .prefixMutated)
        }
    }

    // MARK: - Apply

    func testApplyKeepsEveryWordThroughTheAnchorByteForByte() async throws {
        let seeded = try await seedAnchorChapter()
        let latest = try await versioning.loadBook(id: book.id)!
        let expected = try ChapterAnchorSplitter.split(
            blocks: seeded.revision.blocks,
            blockId: seeded.anchorBlockId,
            utf16OffsetInBlock: seeded.anchorOffset
        )

        let preview = try await adaptation.previewWordForwardRegeneration(
            book: latest,
            request: WordForwardRegenerationRequest(
                anchor: seeded.anchor,
                intents: [.moreStories],
                maxFollowOnChapters: 0
            )
        )
        XCTAssertEqual(preview.frozenPrefixWordCount, expected.prefixWordCount)
        XCTAssertTrue(preview.regeneratesAnchorChapter)

        _ = try await adaptation.applyWordForwardRegeneration(book: latest, preview: preview)

        let regenerated = try await versioning.readableRevision(
            bookId: book.id,
            chapterId: ArgentinaFixtureIDs.chapter2
        )
        XCTAssertNotEqual(regenerated.id, seeded.revision.id, "Apply appends a new revision")
        XCTAssertEqual(
            Array(regenerated.blocks.prefix(expected.frozenPrefix.count)).map(\.text),
            expected.frozenPrefix.map(\.text)
        )
        XCTAssertEqual(
            Array(regenerated.blocks.prefix(expected.frozenPrefix.count)).map(\.id),
            expected.frozenPrefix.map(\.id)
        )
        XCTAssertGreaterThan(regenerated.blocks.count, expected.frozenPrefix.count)
        XCTAssertFalse(
            regenerated.blocks
                .dropFirst(expected.frozenPrefix.count)
                .contains { $0.text == expected.regenerableSuffix.first?.text },
            "The stretch after the anchor should actually be rewritten"
        )
        XCTAssertEqual(regenerated.origin?.kind, .regenerateFromWord)
        XCTAssertEqual(regenerated.origin?.anchorWord, seeded.anchor.displayWord)
        let source = seeded.revision.blocks[1].text as NSString
        let selected = source.range(of: seeded.anchor.word)
        let frozenThroughWord = source.substring(to: NSMaxRange(selected)) + " "
        XCTAssertEqual(Array(regenerated.blocks[1].text.utf8), Array(frozenThroughWord.utf8),
                       "Apply must preserve the selected word too, independently of the expected splitter result")
        XCTAssertFalse(regenerated.blocks[expected.frozenPrefix.count].text.hasPrefix(seeded.anchor.word),
                       "The offline generator must not duplicate the frozen word as its opening")
        XCTAssertTrue(regenerated.origin?.summary.hasPrefix("Regenerated after") == true)
    }

    func testAnchorContextCarriesFrozenTailAndReaderRequestToTheGenerator() async throws {
        let seeded = try await seedAnchorChapter()
        let latest = try await versioning.loadBook(id: book.id)!

        let captured = CapturedRequest()
        ai.stubGenerate { request in
            await captured.store(request)
            return DeterministicAdaptationSynthesizer.generate(request)
        }

        let preview = try await adaptation.previewWordForwardRegeneration(
            book: latest,
            request: WordForwardRegenerationRequest(
                anchor: seeded.anchor,
                intents: [.moreImages],
                freeText: "keep it concrete",
                readerPreferencesSummary: "230 wpm, sepia",
                maxFollowOnChapters: 0
            )
        )
        _ = try await adaptation.applyWordForwardRegeneration(book: latest, preview: preview)

        let request = await captured.value
        let context = try XCTUnwrap(request?.anchorContext)
        XCTAssertEqual(context.anchorWord, seeded.anchor.displayWord)
        XCTAssertEqual(context.frozenPrefixWordCount, preview.frozenPrefixWordCount)
        XCTAssertTrue(context.userRequest.localizedCaseInsensitiveContains("images"))
        XCTAssertTrue(context.userRequest.localizedCaseInsensitiveContains("keep it concrete"))
        XCTAssertEqual(context.readerPreferencesSummary, "230 wpm, sepia")

        let tailWords = AdaptationPlanValidator.wordCount(of: context.frozenPrefixTail)
        XCTAssertGreaterThan(tailWords, 0)
        XCTAssertLessThanOrEqual(tailWords, ChapterAnchorSplitter.maximumPromptTailWords)
        XCTAssertFalse(
            context.frozenPrefixTail.contains(seeded.suffixMarker),
            "The frozen tail is context, not the text being replaced"
        )
        XCTAssertTrue(context.frozenPrefixTail.hasSuffix(seeded.anchor.word),
                      "The prompt tail trims whitespace but includes the complete selected word")
        XCTAssertFalse(try XCTUnwrap(request).currentPlainText.contains(seeded.anchor.word))

        // Live generation is Astra-shaped JSON; the prompt must name the frozen stretch.
        let prompt = AdaptationLivePrompts.generateUser(try XCTUnwrap(request))
        XCTAssertTrue(prompt.contains("FROZEN"))
        XCTAssertTrue(prompt.contains(context.anchorWord))
        XCTAssertTrue(prompt.contains("already frozen; do not repeat it as the opening"))
        XCTAssertTrue(prompt.contains("words including the anchor"))
        XCTAssertFalse(AdaptationLivePrompts.continueFromWordSystem.contains("open at the anchor word"))
    }

    func testMoreImagesBuysVisualsWithProseNotWithReadingTime() async throws {
        let seeded = try await seedAnchorChapter()
        let latest = try await versioning.loadBook(id: book.id)!

        let plain = try await adaptation.previewWordForwardRegeneration(
            book: latest,
            request: WordForwardRegenerationRequest(anchor: seeded.anchor, maxFollowOnChapters: 0)
        )
        let withImages = try await adaptation.previewWordForwardRegeneration(
            book: latest,
            request: WordForwardRegenerationRequest(
                anchor: seeded.anchor,
                intents: [.moreImages],
                maxFollowOnChapters: 0
            )
        )

        XCTAssertGreaterThan(withImages.plannedVisualCount, plain.plannedVisualCount)
        XCTAssertLessThan(
            withImages.suffixTargetWordCount,
            plain.suffixTargetWordCount,
            "Extra visuals borrow their minutes from prose"
        )
        XCTAssertNoThrow(
            try ReadingTimeGuardrail.assertPreservesRemainingTime(
                baseline: withImages.baselineRemaining,
                planned: withImages.plannedRemaining,
                preferences: .default
            )
        )

        _ = try await adaptation.applyWordForwardRegeneration(book: latest, preview: withImages)
        let regenerated = try await versioning.readableRevision(
            bookId: book.id,
            chapterId: ArgentinaFixtureIDs.chapter2
        )
        let visuals = regenerated.blocks.filter { $0.kind == .imagePlaceholder }
        XCTAssertEqual(visuals.count, withImages.plannedVisualCount)
    }

    func testFollowOnUnreadChapterIsReplacedWholeAndStaysWithinTime() async throws {
        let seeded = try await seedAnchorChapter()
        let latest = try await versioning.loadBook(id: book.id)!
        let followOnChapter = try XCTUnwrap(
            latest.chapters.sorted { $0.orderIndex < $1.orderIndex }.first { $0.orderIndex == 2 }
        )
        let before = try await versioning.readableRevision(bookId: book.id, chapterId: followOnChapter.id)

        let preview = try await adaptation.previewWordForwardRegeneration(
            book: latest,
            request: WordForwardRegenerationRequest(anchor: seeded.anchor, maxFollowOnChapters: 1)
        )
        XCTAssertEqual(preview.followOnChapters.map(\.id), [followOnChapter.id])
        XCTAssertEqual(preview.plan.affectedChapterIds.count, 2)

        let activated = try await adaptation.applyWordForwardRegeneration(book: latest, preview: preview)
        XCTAssertEqual(activated.count, 2)

        let after = try await versioning.readableRevision(bookId: book.id, chapterId: followOnChapter.id)
        XCTAssertNotEqual(after.id, before.id)
        XCTAssertNoThrow(
            try ReadingTimeGuardrail.assertPreservesRemainingTime(
                baseline: ReadingTimeEstimator.estimate(blocks: before.blocks),
                planned: ReadingTimeEstimator.estimate(blocks: after.blocks),
                preferences: .default
            )
        )
    }

    func testConsumedChapterCannotBeRegeneratedFromAWord() async throws {
        try await versioning.consume(
            bookId: book.id,
            chapterId: ArgentinaFixtureIDs.chapter1,
            revisionId: ArgentinaFixtureIDs.chapter1Revision1
        )
        let consumed = try await versioning.readableRevision(
            bookId: book.id,
            chapterId: ArgentinaFixtureIDs.chapter1
        )
        let before = try JSONCoding.encoder.encode(try await versioning.loadBook(id: book.id))
        let anchor = RegenerationWordAnchor(
            bookId: book.id,
            chapterId: ArgentinaFixtureIDs.chapter1,
            chapterTitle: "Before the Nation",
            revisionId: consumed.id,
            blockId: consumed.blocks[0].id,
            utf16OffsetInBlock: 2,
            word: "Before",
            createdAt: Date()
        )

        do {
            _ = try await adaptation.previewWordForwardRegeneration(
                book: book,
                request: WordForwardRegenerationRequest(anchor: anchor)
            )
            XCTFail("A finished chapter must not be regenerable from a word")
        } catch AdaptationError.lockedChapter(let id) {
            XCTAssertEqual(id, ArgentinaFixtureIDs.chapter1)
        }

        let after = try await versioning.loadBook(id: book.id)
        XCTAssertEqual(try JSONCoding.encoder.encode(after), before)
    }

    func testStaleAnchorRefusesToRewriteRatherThanCutBehindTheReader() async throws {
        let seeded = try await seedAnchorChapter()
        let latest = try await versioning.loadBook(id: book.id)!
        let preview = try await adaptation.previewWordForwardRegeneration(
            book: latest,
            request: WordForwardRegenerationRequest(anchor: seeded.anchor, maxFollowOnChapters: 0)
        )

        // Something else moves the chapter on between preview and Apply.
        _ = try await versioning.createRevision(
            bookId: book.id,
            chapterId: ArgentinaFixtureIDs.chapter2,
            blocks: [ContentBlock(id: UUID(), kind: .paragraph, text: "A different future.", orderIndex: 0)]
        )
        let afterOtherWrite = try await versioning.readableRevision(
            bookId: book.id,
            chapterId: ArgentinaFixtureIDs.chapter2
        )

        do {
            _ = try await adaptation.applyWordForwardRegeneration(book: latest, preview: preview)
            XCTFail("A stale anchor must not be applied")
        } catch AdaptationError.anchorMoved {
            // expected
        }

        let unchanged = try await versioning.readableRevision(
            bookId: book.id,
            chapterId: ArgentinaFixtureIDs.chapter2
        )
        XCTAssertEqual(unchanged.id, afterOtherWrite.id)
    }

    func testNewerRevisionCreatedDuringGenerationCannotBeReplacedByOldApply() async throws {
        try await assertMutationDuringGenerationIsPreserved { versioning, bookId, _ in
            try await versioning.createRevision(
                bookId: bookId,
                chapterId: ArgentinaFixtureIDs.chapter2,
                blocks: [ContentBlock(
                    id: UUID(), kind: .paragraph,
                    text: "The newer revision won while the older generation was running.",
                    orderIndex: 0
                )]
            )
        }
    }

    func testRestoreDuringGenerationCannotBeReplacedByOldApply() async throws {
        try await assertMutationDuringGenerationIsPreserved { versioning, bookId, _ in
            try await versioning.restoreRevision(
                bookId: bookId,
                chapterId: ArgentinaFixtureIDs.chapter2,
                sourceRevisionId: ArgentinaFixtureIDs.chapter2Revision1
            )
        }
    }

    func testConsumptionDuringGenerationKeepsThePinnedRevisionAndLedgerUnchanged() async throws {
        try await assertMutationDuringGenerationIsPreserved(expectConsumed: true) { versioning, bookId, anchor in
            try await versioning.consume(
                bookId: bookId,
                chapterId: anchor.chapterId,
                revisionId: anchor.revisionId
            )
            return try await versioning.readableRevision(bookId: bookId, chapterId: anchor.chapterId)
        }
    }

    // MARK: - Version history + restore

    func testEveryWordRegenIsRestorableAndRestoreLeavesTheConsumedPastIntact() async throws {
        try await versioning.consume(
            bookId: book.id,
            chapterId: ArgentinaFixtureIDs.chapter1,
            revisionId: ArgentinaFixtureIDs.chapter1Revision1
        )
        let consumedBefore = try await versioning.retrieveConsumedRevision(
            bookId: book.id,
            chapterId: ArgentinaFixtureIDs.chapter1
        )
        let consumedFingerprint = try JSONCoding.encoder.encode(consumedBefore)

        let seeded = try await seedAnchorChapter()
        let latest = try await versioning.loadBook(id: book.id)!
        let preview = try await adaptation.previewWordForwardRegeneration(
            book: latest,
            request: WordForwardRegenerationRequest(
                anchor: seeded.anchor,
                intents: [.moreStories],
                maxFollowOnChapters: 0
            )
        )
        _ = try await adaptation.applyWordForwardRegeneration(book: latest, preview: preview)

        let history = try await versioning.listChapterVersions(
            bookId: book.id,
            chapterId: ArgentinaFixtureIDs.chapter2
        )
        let regenRow = try XCTUnwrap(history.first { $0.origin?.kind == .regenerateFromWord })
        XCTAssertTrue(regenRow.isActive)
        XCTAssertEqual(regenRow.originLabel?.contains(seeded.anchor.displayWord), true)

        let priorRow = try XCTUnwrap(history.first { $0.revisionId == seeded.revision.id })
        XCTAssertFalse(priorRow.isActive)
        XCTAssertFalse(priorRow.isConsumedLocked)

        let restored = try await versioning.restoreRevision(
            bookId: book.id,
            chapterId: ArgentinaFixtureIDs.chapter2,
            sourceRevisionId: priorRow.revisionId
        )
        XCTAssertNotEqual(restored.id, priorRow.revisionId, "Restore appends a new tip")
        XCTAssertEqual(restored.origin?.kind, .restore)
        XCTAssertEqual(restored.origin?.restoredFromRevisionIndex, priorRow.revisionIndex)

        let readable = try await versioning.readableRevision(
            bookId: book.id,
            chapterId: ArgentinaFixtureIDs.chapter2
        )
        XCTAssertEqual(readable.id, restored.id)
        XCTAssertEqual(readable.blocks.map(\.text), seeded.revision.blocks.map(\.text))

        let regenStillThere = try await versioning.listChapterVersions(
            bookId: book.id,
            chapterId: ArgentinaFixtureIDs.chapter2
        )
        XCTAssertTrue(
            regenStillThere.contains { $0.revisionId == regenRow.revisionId },
            "Restoring must not delete the version it stepped back from"
        )

        let consumedAfter = try await versioning.retrieveConsumedRevision(
            bookId: book.id,
            chapterId: ArgentinaFixtureIDs.chapter1
        )
        XCTAssertEqual(try JSONCoding.encoder.encode(consumedAfter), consumedFingerprint)
        let readableChapter1 = try await versioning.readableRevision(
            bookId: book.id,
            chapterId: ArgentinaFixtureIDs.chapter1
        )
        XCTAssertEqual(readableChapter1.id, ArgentinaFixtureIDs.chapter1Revision1)
    }

    func testHistoryRowsExplainWhereEachVersionCameFrom() async throws {
        let seeded = try await seedAnchorChapter()
        let history = try await versioning.listChapterVersions(
            bookId: book.id,
            chapterId: ArgentinaFixtureIDs.chapter2
        )
        let fixtureRow = try XCTUnwrap(history.first { $0.revisionIndex == 1 })
        XCTAssertNil(fixtureRow.originLabel, "Manuscripts authored before provenance stay unlabelled")
        XCTAssertEqual(history.last?.revisionId, seeded.revision.id)
        XCTAssertEqual(history.first?.chapterOrderIndex, 1)
    }

    // MARK: - Frontier wiring

    func testGenerationResolvesToLiveAstraWithOrWithoutAKey() throws {
        let keyed = InMemoryAPIKeyStore()
        try keyed.saveAPIKey("sk-test-key")
        let live = AIServiceResolver.makeAskAndAdaptation(sharingPermission: { true },
            keyStore: keyed,
            askModel: .defaultAsk,
            generationModel: .defaultGeneration,
            processInfo: MockProcessInfo(arguments: [])
        )
        let generation = try XCTUnwrap(live.adaptation as? LiveOpenAIService)
        XCTAssertEqual(generation.preferredModelID, OpenAIModelOption.gpt6Astra.rawValue)

        let keyless = AIServiceResolver.makeAskAndAdaptation(sharingPermission: { true },
            keyStore: InMemoryAPIKeyStore(),
            generationModel: .defaultGeneration,
            processInfo: MockProcessInfo(arguments: [])
        )
        XCTAssertTrue(
            keyless.adaptation is LiveOpenAIService,
            "Missing credentials must be reported on invocation, not select substitute generation"
        )
    }

    func testKeylessLiveGenerationThrowsAndPreservesContinuation() async throws {
        let seeded = try await seedAnchorChapter()
        let latest = try await versioning.loadBook(id: book.id)!
        let keyless = LiveOpenAIService(sharingPermission: { true }, apiKeyProvider: { nil }, preferredModel: .gpt6Astra, timeout: 1)
        let service = LivingBookAdaptationService(
            versioning: versioning,
            feedbackStore: feedbackStore,
            preferenceStore: preferenceStore,
            ai: keyless
        )

        let preview = try await service.previewWordForwardRegeneration(
            book: latest,
            request: WordForwardRegenerationRequest(anchor: seeded.anchor, maxFollowOnChapters: 0)
        )
        let before = try JSONCoding.encoder.encode(latest)
        do {
            _ = try await service.applyWordForwardRegeneration(book: latest, preview: preview)
            XCTFail("Keyless live generation must not activate substitute text")
        } catch {
            XCTAssertEqual(error as? AdaptationError, .malformedGeneration(AIServiceError.missingAPIKey.localizedDescription))
        }

        let regenerated = try await versioning.readableRevision(
            bookId: book.id,
            chapterId: ArgentinaFixtureIDs.chapter2
        )
        XCTAssertEqual(regenerated.id, seeded.revision.id)
        let after = try await versioning.loadBook(id: book.id)
        XCTAssertEqual(try JSONCoding.encoder.encode(try XCTUnwrap(after)), before)
    }

    // MARK: - Inclusive boundary service regressions

    func testLastWordWithoutFollowOnDoesNotGenerateOrWrite() async throws {
        let seeded = try await seedAnchorChapter()
        var anchor = seeded.anchor
        let last = try XCTUnwrap(seeded.revision.blocks.last)
        anchor.blockId = last.id
        anchor.utf16OffsetInBlock = (last.text as NSString).range(of: "starts", options: .backwards).location
        anchor.word = "starts"
        let latest = try await versioning.loadBook(id: book.id)!
        let before = try JSONCoding.encoder.encode(latest)
        do {
            _ = try await adaptation.previewWordForwardRegeneration(
                book: latest, request: WordForwardRegenerationRequest(anchor: anchor, maxFollowOnChapters: 0)
            )
            XCTFail("The final word and period are already frozen; no suffix is eligible")
        } catch {
            guard case AdaptationError.nothingToAdapt = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(ai.totalCallCount, 0)
        let after = try await versioning.loadBook(id: book.id)!
        XCTAssertEqual(try JSONCoding.encoder.encode(after), before)
    }

    func testLastWordWithFollowOnLeavesAnchorRevisionUntouched() async throws {
        let seeded = try await seedAnchorChapter()
        var anchor = seeded.anchor
        let last = try XCTUnwrap(seeded.revision.blocks.last)
        anchor.blockId = last.id
        anchor.utf16OffsetInBlock = (last.text as NSString).range(of: "starts", options: .backwards).location
        anchor.word = "starts"
        let latest = try await versioning.loadBook(id: book.id)!
        let preview = try await adaptation.previewWordForwardRegeneration(
            book: latest, request: WordForwardRegenerationRequest(anchor: anchor, maxFollowOnChapters: 1)
        )
        XCTAssertFalse(preview.regeneratesAnchorChapter)
        XCTAssertEqual(preview.regeneratingWordCount, 0)
        XCTAssertEqual(preview.plan.chapterTargets.count, 1)
        let activated = try await adaptation.applyWordForwardRegeneration(book: latest, preview: preview)
        XCTAssertEqual(activated.count, 1)
        XCTAssertNotEqual(activated.first?.chapterId, anchor.chapterId)
        let after = try await versioning.readableRevision(bookId: book.id, chapterId: anchor.chapterId)
        XCTAssertEqual(try JSONCoding.encoder.encode(after), try JSONCoding.encoder.encode(seeded.revision))
        XCTAssertNil(ai.lastGenerateRequest?.anchorContext)
    }

    func testExplicitChapterStartPreviewAndApplyRewriteWholeUnreadChapter() async throws {
        let seeded = try await seedAnchorChapter()
        var anchor = seeded.anchor
        // An explicit chapter-start boundary is not offset zero at a selected first word.
        anchor.boundary = .chapterStart
        anchor.utf16OffsetInBlock = 0
        anchor.word = ""
        let latest = try await versioning.loadBook(id: book.id)!
        let preview = try await adaptation.previewWordForwardRegeneration(
            book: latest, request: WordForwardRegenerationRequest(anchor: anchor, maxFollowOnChapters: 0)
        )
        XCTAssertEqual(preview.frozenPrefixWordCount, 0)
        XCTAssertEqual(preview.regeneratingWordCount,
                       AdaptationPlanValidator.wordCount(of: seeded.revision.blocks))
        XCTAssertTrue(preview.regeneratesAnchorChapter)
        let activated = try await adaptation.applyWordForwardRegeneration(book: latest, preview: preview)
        let generated = try XCTUnwrap(activated.first)
        let request = try XCTUnwrap(ai.lastGenerateRequest)
        XCTAssertNil(request.anchorContext, "No selected word in an entirely unread chapter")
        XCTAssertEqual(request.currentPlainText, seeded.revision.blocks.map(\.text).joined(separator: "\n"))
        XCTAssertEqual(generated.origin?.kind, .regenerateFromChapter)
        XCTAssertTrue(Set(generated.blocks.map(\.id)).isDisjoint(with: seeded.revision.blocks.map(\.id)))
    }

    func testOlderAnchorsDecodeAsInclusiveSelectionsAndExplicitStartRoundTrips() throws {
        var anchor = RegenerationWordAnchor(bookId: UUID(), chapterId: UUID(), chapterTitle: "Chapter",
                                           revisionId: UUID(), blockId: UUID(), utf16OffsetInBlock: 0,
                                           word: "First", createdAt: Date())
        let legacyData = try JSONCoding.encoder.encode(anchor)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: legacyData) as? [String: Any])
        XCTAssertNil(fields["boundary"])
        XCTAssertEqual(try JSONCoding.decoder.decode(RegenerationWordAnchor.self, from: legacyData).effectiveBoundary,
                       .afterWord)
        anchor.boundary = .chapterStart
        let decoded = try JSONCoding.decoder.decode(RegenerationWordAnchor.self,
                                                    from: JSONCoding.encoder.encode(anchor))
        XCTAssertEqual(decoded.effectiveBoundary, .chapterStart)
        XCTAssertEqual(decoded.utf16OffsetInBlock, 0)
    }

    // MARK: - Authored source-aware assembly (no writer, reviewer or retrieval)

    func testSourceMidParagraphContinuationKeepsExactPrefixIDsAndMetadata() throws {
        let fixture = try sourceBoundaryFixture()
        let selected = fixture.base.blocks[2]
        let cut = try XCTUnwrap(SourceGrounding.wordCut(base: fixture.base, blockID: selected.id,
            utf16Offset: (selected.text as NSString).range(of: "records").location + 2, source: fixture.source))
        let frozen = "Cafe\u{301} 🇦🇷 records, \t  "
        XCTAssertEqual(cut.baseRevisionID, fixture.base.id)
        XCTAssertEqual(cut.blockID, selected.id)
        XCTAssertEqual(cut.wordStartUTF16, (selected.text as NSString).range(of: "records").location)
        XCTAssertEqual(cut.endUTF16, (frozen as NSString).length)
        XCTAssertEqual(cut.word, "records")
        let assembled = try SourceGrounding.assembleContinuation(base: fixture.base, cut: cut,
            paragraphs: fixture.continuation, source: fixture.source)
        XCTAssertEqual(Array(assembled.prefix(2)), Array(fixture.base.blocks.prefix(2)))
        XCTAssertEqual(assembled[2].id, selected.id)
        XCTAssertEqual(Array(assembled[2].text.utf8), Array((frozen + fixture.continuation[0].text + " [1]").utf8))
        XCTAssertEqual(assembled[3].text, fixture.continuation[1].text + " [1]")
        XCTAssertFalse(fixture.base.blocks.map(\.id).contains(assembled[3].id))
        assertSourceMetadataPreserved(fixture.base, in: assembled)
        XCTAssertNoThrow(try SourceGrounding.validateWordCut(cut, base: fixture.base, blocks: assembled, source: fixture.source))
        XCTAssertEqual(try SourceGrounding.prose(assembled, source: fixture.source).count, 3)
    }

    func testSourceEndParagraphPreservesEntireSelectedParagraphAndAppendsContinuation() throws {
        let fixture = try sourceBoundaryFixture()
        let selected = fixture.base.blocks[1]
        let cut = try XCTUnwrap(SourceGrounding.wordCut(base: fixture.base, blockID: selected.id,
            utf16Offset: (selected.text as NSString).range(of: "register", options: .backwards).location,
            source: fixture.source))
        XCTAssertEqual(cut.endUTF16, (String(selected.text.dropLast(4)) as NSString).length)
        let assembled = try SourceGrounding.assembleContinuation(base: fixture.base, cut: cut,
            paragraphs: fixture.continuation, source: fixture.source)
        XCTAssertEqual(Array(assembled.prefix(2)), Array(fixture.base.blocks.prefix(2)))
        XCTAssertEqual(Array(assembled[1].text.utf8), Array(selected.text.utf8), "The original period and citation stay unchanged")
        XCTAssertEqual(assembled[2].text, fixture.continuation[0].text + " [1]")
        XCTAssertEqual(assembled[3].text, fixture.continuation[1].text + " [1]")
        XCTAssertFalse(assembled.contains { $0.id == fixture.base.blocks[2].id })
        assertSourceMetadataPreserved(fixture.base, in: assembled)
        XCTAssertNoThrow(try SourceGrounding.validateWordCut(cut, base: fixture.base, blocks: assembled, source: fixture.source))
    }

    func testSourceCutHandlesDecomposedWordAndOffsetsAfterSurrogatePairs() throws {
        let fixture = try sourceBoundaryFixture()
        let selected = fixture.base.blocks[2]
        let accent = try XCTUnwrap(SourceGrounding.wordCut(base: fixture.base, blockID: selected.id,
            utf16Offset: 1, source: fixture.source))
        XCTAssertEqual(Array(accent.word.utf8), Array("Cafe\u{301}".utf8))
        XCTAssertEqual(accent.wordStartUTF16, 0)
        XCTAssertEqual(accent.endUTF16, ("Cafe\u{301} " as NSString).length)
        let recordsRange = (selected.text as NSString).range(of: "records")
        XCTAssertGreaterThan(recordsRange.location, "Cafe\u{301} 🇦🇷 ".count)
        let pastFlag = try XCTUnwrap(SourceGrounding.wordCut(base: fixture.base, blockID: selected.id,
            utf16Offset: recordsRange.location + 3, source: fixture.source))
        XCTAssertEqual(pastFlag.wordStartUTF16, recordsRange.location)
        let wire = try JSONCoding.encoder.encode(pastFlag)
        let decoded = try JSONCoding.decoder.decode(SourceWordCut.self, from: wire)
        XCTAssertEqual(decoded, pastFlag)
        XCTAssertEqual(Set([decoded, pastFlag]).count, 1)
        let assembled = try SourceGrounding.assembleContinuation(base: fixture.base, cut: decoded,
            paragraphs: fixture.continuation, source: fixture.source)
        let prefix = (selected.text as NSString).substring(to: decoded.endUTF16)
        XCTAssertEqual(Array(assembled[2].text.utf8.prefix(prefix.utf8.count)), Array(prefix.utf8))
    }

    func testSourceFinalActualProseWordHasNoContinuationDespiteCitationAndFooter() throws {
        let fixture = try sourceBoundaryFixture()
        let selected = fixture.base.blocks[2]
        XCTAssertEqual(fixture.base.blocks.suffix(2).count, 2)
        XCTAssertNil(try SourceGrounding.wordCut(base: fixture.base, blockID: selected.id,
            utf16Offset: (selected.text as NSString).range(of: "shelves", options: .backwards).location + 2,
            source: fixture.source))
        var emojiBase = fixture.base
        emojiBase.blocks[2].text = String(selected.text.dropLast(4)) + " 🧭 [1]"
        XCTAssertNil(try SourceGrounding.wordCut(base: emojiBase, blockID: selected.id,
            utf16Offset: (selected.text as NSString).range(of: "shelves", options: .backwards).location + 2,
            source: fixture.source), "A trailing symbol, citation and source notes are not remaining prose words")
    }

    func testSourceCutRejectsHeadingDisclosureFooterAndCitationOffsets() throws {
        let fixture = try sourceBoundaryFixture()
        for index in [0, 3, 4] {
            XCTAssertThrowsError(try SourceGrounding.wordCut(base: fixture.base,
                blockID: fixture.base.blocks[index].id, utf16Offset: 0, source: fixture.source), "block \(index)")
        }
        let paragraph = fixture.base.blocks[1]
        let proseEnd = (paragraph.text as NSString).length - 4
        for offset in proseEnd..<(paragraph.text as NSString).length {
            XCTAssertThrowsError(try SourceGrounding.wordCut(base: fixture.base, blockID: paragraph.id,
                utf16Offset: offset, source: fixture.source), "citation offset \(offset)")
        }
    }

    func testSourceCutRejectsMissingBlockOutsideRangeAndBrokenUnicodeBoundaries() throws {
        let fixture = try sourceBoundaryFixture()
        let paragraph = fixture.base.blocks[2]
        let flag = (paragraph.text as NSString).range(of: "🇦🇷")
        for offset in [-1, (paragraph.text as NSString).length, Int.max, flag.location + 1, flag.location + 3, 4] {
            XCTAssertThrowsError(try SourceGrounding.wordCut(base: fixture.base, blockID: paragraph.id,
                utf16Offset: offset, source: fixture.source), "invalid UTF-16 offset \(offset)")
        }
        XCTAssertThrowsError(try SourceGrounding.wordCut(base: fixture.base, blockID: UUID(), utf16Offset: 0, source: fixture.source))
        for symbols in ["1️⃣", "🧭", "…"] {
            var nonword = fixture.base
            nonword.blocks[1].text = symbols + " [1]"
            XCTAssertThrowsError(try SourceGrounding.wordCut(base: nonword, blockID: nonword.blocks[1].id,
                utf16Offset: 0, source: fixture.source), "Symbols alone do not identify a prose word")
        }
    }

    func testSourceValidatorRejectsChangedFrozenTextAndBlockIDs() throws {
        let fixture = try sourceBoundaryFixture()
        let cut = try sourceMidCut(fixture)
        let assembled = try SourceGrounding.assembleContinuation(base: fixture.base, cut: cut,
            paragraphs: fixture.continuation, source: fixture.source)
        for index in 0...2 {
            var changedID = assembled
            changedID[index].id = UUID()
            XCTAssertThrowsError(try SourceGrounding.validateWordCut(cut, base: fixture.base, blocks: changedID, source: fixture.source), "changed ID \(index)")
            var changedText = assembled
            changedText[index].text = "Rewritten " + changedText[index].text
            XCTAssertThrowsError(try SourceGrounding.validateWordCut(cut, base: fixture.base, blocks: changedText, source: fixture.source), "changed prefix \(index)")
        }
    }

    func testSourceValidatorRejectsUnicodeNormalizationOfFrozenPrefix() throws {
        let fixture = try sourceBoundaryFixture()
        let cut = try sourceMidCut(fixture)
        let assembled = try SourceGrounding.assembleContinuation(base: fixture.base, cut: cut,
            paragraphs: fixture.continuation, source: fixture.source)
        for index in 0...2 {
            var normalized = assembled
            normalized[index].text = normalized[index].text.precomposedStringWithCanonicalMapping
            XCTAssertEqual(normalized[index].text, assembled[index].text, "Swift equality alone considers these canonically equivalent")
            XCTAssertNotEqual(Array(normalized[index].text.utf8), Array(assembled[index].text.utf8))
            XCTAssertThrowsError(try SourceGrounding.validateWordCut(cut, base: fixture.base, blocks: normalized, source: fixture.source), "normalized prefix \(index)")
        }
    }

    func testSourceValidatorRejectsAlteredCutMetadataOrDifferentBase() throws {
        let fixture = try sourceBoundaryFixture()
        let cut = try sourceMidCut(fixture)
        let assembled = try SourceGrounding.assembleContinuation(base: fixture.base, cut: cut,
            paragraphs: fixture.continuation, source: fixture.source)
        let invalid = [
            SourceWordCut(baseRevisionID: UUID(), blockID: cut.blockID, wordStartUTF16: cut.wordStartUTF16, endUTF16: cut.endUTF16, word: cut.word),
            SourceWordCut(baseRevisionID: cut.baseRevisionID, blockID: UUID(), wordStartUTF16: cut.wordStartUTF16, endUTF16: cut.endUTF16, word: cut.word),
            SourceWordCut(baseRevisionID: cut.baseRevisionID, blockID: cut.blockID, wordStartUTF16: cut.wordStartUTF16 + 1, endUTF16: cut.endUTF16, word: cut.word),
            SourceWordCut(baseRevisionID: cut.baseRevisionID, blockID: cut.blockID, wordStartUTF16: cut.wordStartUTF16, endUTF16: cut.endUTF16 - 1, word: cut.word),
            SourceWordCut(baseRevisionID: cut.baseRevisionID, blockID: cut.blockID, wordStartUTF16: cut.wordStartUTF16, endUTF16: cut.endUTF16, word: "invented")
        ]
        for altered in invalid {
            XCTAssertThrowsError(try SourceGrounding.validateWordCut(altered, base: fixture.base, blocks: assembled, source: fixture.source))
            XCTAssertThrowsError(try SourceGrounding.assembleContinuation(base: fixture.base, cut: altered, paragraphs: fixture.continuation, source: fixture.source))
        }
        var otherBase = fixture.base
        otherBase.id = UUID()
        XCTAssertThrowsError(try SourceGrounding.validateWordCut(cut, base: otherBase, blocks: assembled, source: fixture.source))
    }

    func testSourceValidatorRejectsChangedSourceMetadataBlocks() throws {
        let fixture = try sourceBoundaryFixture()
        let cut = try sourceMidCut(fixture)
        let assembled = try SourceGrounding.assembleContinuation(base: fixture.base, cut: cut,
            paragraphs: fixture.continuation, source: fixture.source)
        for index in (assembled.count - 2)..<assembled.count {
            var changed = assembled
            changed[index].id = UUID()
            XCTAssertThrowsError(try SourceGrounding.validateWordCut(cut, base: fixture.base, blocks: changed, source: fixture.source))
            changed = assembled
            changed[index].text += " changed"
            XCTAssertThrowsError(try SourceGrounding.validateWordCut(cut, base: fixture.base, blocks: changed, source: fixture.source))
        }
    }

    func testSourceAssemblerRejectsEmptyOrMalformedContinuationCitations() throws {
        let fixture = try sourceBoundaryFixture()
        let cut = try sourceMidCut(fixture)
        let invalid: [[SourceDraftParagraph]] = [
            [], [.init(text: "", citations: ["source1"])], [.init(text: "A continuation.", citations: [])],
            [.init(text: "A continuation.", citations: ["source2"])],
            [.init(text: "A continuation.", citations: ["source1", "source1"])],
            [.init(text: "A continuation. [1]", citations: ["source1"])],
            [fixture.continuation[0], .init(text: "Invalid later paragraph.", citations: ["source2"])]
        ]
        for paragraphs in invalid {
            XCTAssertThrowsError(try SourceGrounding.assembleContinuation(base: fixture.base, cut: cut,
                paragraphs: paragraphs, source: fixture.source))
        }
    }

    // MARK: - Fixture

    private struct SourceBoundaryFixture {
        let source: RetrievedResearchSource
        let base: ChapterRevision
        let continuation: [SourceDraftParagraph]
    }

    private func sourceBoundaryFixture() throws -> SourceBoundaryFixture {
        // Authored evidence only. No article or model is contacted by these tests.
        let first = """
        At Cafe\u{301}, the harbor keepers maintained a register of boats arriving at the town quay. Each entry named the vessel, its landing place, and the goods recorded by the clerk. A second column noted whether the cargo remained aboard or moved into a warehouse. The register did not explain why a captain chose one route rather than another. Readers could compare entries made on different days, but an empty line alone did not establish that the harbor had closed. The keepers stored receipts beside the volumes so later clerks could distinguish a corrected entry from an unrecorded journey. A small index listed the names used in each volume without changing the spelling found on its pages. Visitors consulted that index before requesting the register.
        """
        let second = """
        Cafe\u{301} 🇦🇷 records, \t  arranged on wooden shelves, remained available after the original clerks left office. The archive supplied a reading table and asked visitors to return each volume before requesting another. Notes about a damaged binding described the object rather than the truth of its contents. When two entries disagreed, the catalogue preserved both and recorded their locations. A reader could therefore identify a disagreement without assuming that the later entry was correct. Copies made for visitors carried the volume number and page reference, while the original sheets stayed in the archive. These practices helped readers trace the words they quoted to a particular document. They did not turn every written claim into an independently established fact. At closing time, staff returned the volumes to their marked shelves.
        """
        let text = first + "\n\n" + second
        XCTAssertGreaterThanOrEqual(text.split(whereSeparator: \.isWhitespace).count, 160)
        XCTAssertLessThanOrEqual(text.count, 8_000)
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let source = RetrievedResearchSource(requestedTitle: "Harbor Archive", title: "Harbor Archive",
            canonicalURL: URL(string: "https://en.wikipedia.org/wiki/Harbor_Archive")!, pageID: 42, revisionID: 9001,
            revisionURL: URL(string: "https://en.wikipedia.org/w/index.php?oldid=9001")!,
            revisionTimestamp: timestamp, retrievedAt: timestamp, scope: .wikipediaIntroduction,
            text: text, textSHA256: SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined(),
            attribution: "Authored Wikipedia-shaped fixture; no retrieval occurred.",
            attributionURL: URL(string: "https://en.wikipedia.org/w/index.php?title=Harbor_Archive&action=history")!,
            licenseName: "Fixture CC BY-SA 4.0", licenseURL: URL(string: "https://creativecommons.org/licenses/by-sa/4.0/")!)
        let blocks = try SourceGrounding.blocks(title: "Cafe\u{301} archive", paragraphs: [
            .init(text: first, citations: ["source1"]), .init(text: second, citations: ["source1"])
        ], source: source)
        let base = ChapterRevision(id: UUID(), chapterId: UUID(), revisionIndex: 2,
            createdAt: timestamp, blocks: blocks, isConsumed: false)
        return SourceBoundaryFixture(source: source, base: base, continuation: [
            .init(text: "arranged on shelves, kept their original volume and page references.", citations: ["source1"]),
            .init(text: second, citations: ["source1"])
        ])
    }

    private func sourceMidCut(_ fixture: SourceBoundaryFixture) throws -> SourceWordCut {
        let paragraph = fixture.base.blocks[2]
        return try XCTUnwrap(SourceGrounding.wordCut(base: fixture.base, blockID: paragraph.id,
            utf16Offset: (paragraph.text as NSString).range(of: "records").location, source: fixture.source))
    }

    private func assertSourceMetadataPreserved(_ base: ChapterRevision, in blocks: [ContentBlock],
                                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(blocks.map(\.orderIndex), Array(blocks.indices), file: file, line: line)
        for (old, new) in zip(base.blocks.suffix(2), blocks.suffix(2)) {
            XCTAssertEqual(new.id, old.id, file: file, line: line)
            XCTAssertEqual(new.kind, old.kind, file: file, line: line)
            XCTAssertEqual(Array(new.text.utf8), Array(old.text.utf8), file: file, line: line)
        }
    }

    /// The mock completes a competing local write before returning the old generated prose.
    /// This exercises the await inside generation deterministically, without timing or sleeps.
    private func assertMutationDuringGenerationIsPreserved(
        expectConsumed: Bool = false,
        file: StaticString = #filePath,
        line: UInt = #line,
        mutation: @escaping (ManuscriptVersioningService, UUID, RegenerationWordAnchor) async throws -> ChapterRevision
    ) async throws {
        try await versioning.consume(
            bookId: book.id,
            chapterId: ArgentinaFixtureIDs.chapter1,
            revisionId: ArgentinaFixtureIDs.chapter1Revision1
        )
        let seeded = try await seedAnchorChapter()
        let latest = try await versioning.loadBook(id: book.id)!
        let preview = try await adaptation.previewWordForwardRegeneration(
            book: latest,
            request: WordForwardRegenerationRequest(anchor: seeded.anchor, maxFollowOnChapters: 0)
        )
        let service = try XCTUnwrap(versioning)
        let bookId = latest.id
        let manuscriptURL = root.appendingPathComponent("Manuscripts/\(bookId.uuidString).json")
        let ledgerURL = root.appendingPathComponent("Ledger/consumed-ledger.json")
        let winningWrite = CapturedGenerationMutation()
        ai.stubGenerate { request in
            let revision = try await mutation(service, bookId, seeded.anchor)
            let snapshot = GenerationMutationSnapshot(
                revision: revision,
                manuscriptBytes: try Data(contentsOf: manuscriptURL),
                ledgerBytes: try Data(contentsOf: ledgerURL)
            )
            await winningWrite.store(snapshot)
            return DeterministicAdaptationSynthesizer.generate(request)
        }

        do {
            _ = try await adaptation.applyWordForwardRegeneration(book: latest, preview: preview)
            XCTFail("An old generation must not publish after the intervening write", file: file, line: line)
        } catch {
            if expectConsumed {
                XCTAssertEqual(
                    error as? ManuscriptError,
                    .cannotMutateConsumedChapter(seeded.anchor.chapterId),
                    file: file, line: line
                )
            } else {
                XCTAssertEqual(error as? AdaptationError, .anchorMoved, file: file, line: line)
            }
        }

        let captured = await winningWrite.value
        let snapshot = try XCTUnwrap(captured, "The generation hook must actually run", file: file, line: line)
        let state = await adaptation.currentState()
        XCTAssertEqual(state, .failed, file: file, line: line)
        XCTAssertEqual(
            try Data(contentsOf: manuscriptURL), snapshot.manuscriptBytes,
            "All newer manuscript content and prior revision history must remain byte-identical",
            file: file, line: line
        )
        XCTAssertEqual(try Data(contentsOf: ledgerURL), snapshot.ledgerBytes, file: file, line: line)

        // Reopening proves that the winner is durable, not merely an in-memory view.
        let reopened = try ManuscriptVersioningService(rootDirectory: root)
        let readable = try await reopened.readableRevision(bookId: bookId, chapterId: seeded.anchor.chapterId)
        XCTAssertEqual(readable.id, snapshot.revision.id, file: file, line: line)
        XCTAssertEqual(
            try JSONCoding.encoder.encode(readable), try JSONCoding.encoder.encode(snapshot.revision),
            file: file, line: line
        )
        if expectConsumed {
            let consumed = try await reopened.retrieveConsumedRevision(bookId: bookId, chapterId: seeded.anchor.chapterId)
            XCTAssertEqual(consumed?.id, seeded.anchor.revisionId, file: file, line: line)
        } else {
            XCTAssertNotEqual(readable.id, seeded.anchor.revisionId, file: file, line: line)
        }
    }

    private struct SeededAnchor {
        var revision: ChapterRevision
        var anchor: RegenerationWordAnchor
        var anchorBlockId: UUID
        var anchorOffset: Int
        var suffixMarker: String
    }

    /// Seeds chapter 2 with a body long enough to have a real "before" and "after",
    /// then anchors on a word in the middle of it.
    private func seedAnchorChapter() async throws -> SeededAnchor {
        let marker = "MIDPOINT"
        let suffixMarker = "FUTURE_MARKER"
        let opening = Array(
            repeating: "Argentina argued with itself about the port, the interior, and the price of bread.",
            count: 60
        ).joined(separator: " ")
        let closing = Array(
            repeating: "\(suffixMarker) the pampas kept feeding an argument nobody won outright.",
            count: 40
        ).joined(separator: " ")
        let bodyText = "\(opening) \(marker) \(closing)"

        let blocks = [
            ContentBlock(id: UUID(), kind: .heading, text: "Independence", orderIndex: 0),
            ContentBlock(id: UUID(), kind: .paragraph, text: bodyText, orderIndex: 1),
            ContentBlock(
                id: UUID(),
                kind: .paragraph,
                text: Array(repeating: "The nation practised democracy in fits and starts.", count: 30)
                    .joined(separator: " "),
                orderIndex: 2
            )
        ]
        let revision = try await versioning.createRevision(
            bookId: book.id,
            chapterId: ArgentinaFixtureIDs.chapter2,
            blocks: blocks
        )
        let bodyBlock = revision.blocks[1]
        let offset = (bodyBlock.text as NSString).range(of: marker).location
        XCTAssertNotEqual(offset, NSNotFound)

        return SeededAnchor(
            revision: revision,
            anchor: RegenerationWordAnchor(
                bookId: book.id,
                chapterId: ArgentinaFixtureIDs.chapter2,
                chapterTitle: "Independence Sparks",
                revisionId: revision.id,
                blockId: bodyBlock.id,
                utf16OffsetInBlock: offset + 2,
                word: marker,
                createdAt: Date()
            ),
            anchorBlockId: bodyBlock.id,
            anchorOffset: offset + 2,
            suffixMarker: suffixMarker
        )
    }
}

/// Captures the generation request the service actually sent.
private actor CapturedRequest {
    private(set) var value: AdaptationGenerateRequest?

    func store(_ request: AdaptationGenerateRequest) {
        value = request
    }
}

private struct GenerationMutationSnapshot: Sendable {
    let revision: ChapterRevision
    let manuscriptBytes: Data
    let ledgerBytes: Data
}

private actor CapturedGenerationMutation {
    private(set) var value: GenerationMutationSnapshot?

    func store(_ snapshot: GenerationMutationSnapshot) {
        value = snapshot
    }
}
