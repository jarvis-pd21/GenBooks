import XCTest
@testable import LivingReader

/// Wave 3 Create / New Book — RDR-930…937.
final class CreateBookTests: XCTestCase {
    private var root: URL!
    private var versioning: ManuscriptVersioningService!
    private var preferenceStore: FileReaderPreferenceStore!
    private var packets: FilePEPacketStore!
    private var drafts: FileCreateBookDraftStore!
    private var ai: MockAIService!
    private var wizard: CreateBookWizardService!
    private var argentina: Book!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CreateBook-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        packets = try FilePEPacketStore(rootDirectory: root)
        versioning = try ManuscriptVersioningService(rootDirectory: root, packets: packets)
        preferenceStore = try FileReaderPreferenceStore(rootDirectory: root)
        drafts = try FileCreateBookDraftStore(rootDirectory: root)
        ai = MockAIService()
        wizard = CreateBookWizardService(
            versioning: versioning,
            preferenceStore: preferenceStore,
            packets: packets,
            drafts: drafts,
            ai: ai
        )
        argentina = try BundleFixtureLoader.loadArgentinaMinimal()
        try await versioning.saveBook(argentina)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        root = nil
        versioning = nil
        preferenceStore = nil
        packets = nil
        drafts = nil
        ai = nil
        wizard = nil
        argentina = nil
    }

    // MARK: - Import (RDR-931 / RDR-932)

    func testImportSplitsMarkdownHeadingsIntoChapters() throws {
        let text = """
        # River and Port
        Buenos Aires grew where the river met the ships.

        The customs house set the terms.

        # Interior Bargain
        The interior sent cattle and wanted a voice.

        Rail and rumor moved faster than law.
        """
        let book = try ManuscriptImporter.importPlainText(
            text: text,
            title: "Two Rooms",
            author: "Test Author",
            sourceKind: .pastedText
        )
        XCTAssertEqual(book.title, "Two Rooms")
        XCTAssertEqual(book.author, "Test Author")
        XCTAssertEqual(book.chapters.count, 2)
        XCTAssertEqual(book.chapters[0].title, "River and Port")
        XCTAssertEqual(book.chapters[1].title, "Interior Bargain")
        XCTAssertEqual(book.chapters[0].manuscriptStatus, .polished)
        XCTAssertEqual(book.chapters[0].revisions.first?.origin?.kind, .imported)
        XCTAssertTrue(book.chapters[0].activeRevision!.blocks.contains { $0.kind == .paragraph })
        XCTAssertTrue(book.provenanceNotes.contains { $0.contains("Codable manuscript") })
    }

    func testImportSplitsNumberedChapterHeadings() throws {
        let text = """
        Chapter 1: Before the trains
        People walked and the river decided.

        Chapter 2: After the rails
        Distances collapsed and so did patience.
        """
        let book = try ManuscriptImporter.importPlainText(
            text: text,
            title: nil,
            author: nil,
            sourceKind: .pastedText
        )
        XCTAssertEqual(book.chapters.count, 2)
        XCTAssertEqual(book.chapters[0].title, "Before the trains")
        XCTAssertEqual(book.chapters[1].title, "After the rails")
        XCTAssertEqual(book.author, "Unknown")
    }

    func testImportFallbackSingleChapterWhenShort() throws {
        let text = "A short note about mate and inflation that never becomes two rooms."
        let book = try ManuscriptImporter.importPlainText(
            text: text,
            title: "Note",
            author: "Reader",
            sourceKind: .pastedText
        )
        XCTAssertEqual(book.chapters.count, 1)
        XCTAssertTrue(book.chapters[0].activeRevision!.blocks.contains { $0.text.contains("mate") })
    }

    func testImportFallbackWordBudgetSplitsLongPaste() throws {
        let paragraph = Array(repeating: "Silver, wheat, and rumor filled another afternoon in the plaza.", count: 40)
            .joined(separator: " ")
        let text = (0..<6).map { "Part \($0 + 1) of the afternoon.\n\n\(paragraph)" }.joined(separator: "\n\n")
        let book = try ManuscriptImporter.importPlainText(
            text: text,
            title: "Long afternoon",
            author: "Importer",
            sourceKind: .pdfExtract
        )
        XCTAssertGreaterThanOrEqual(book.chapters.count, 2)
        XCTAssertEqual(book.subtitle, "Canon · PDF")
        XCTAssertNotEqual(book.id, ArgentinaFixtureIDs.book)
    }

    func testImportProducesCodableManuscriptAndDoesNotTouchArgentina() async throws {
        let before = try JSONCoding.encoder.encode(try await versioning.loadBook(id: argentina.id)!)
        var draft = CreateBookDraft.blank()
        draft.title = "Imported river"
        draft.author = "Tester"
        draft.importedText = """
        # Customs
        The house on the river counted every sack.

        # Interior
        Cattle walked toward a price they did not set.
        """
        let book = try await wizard.importAndSave(draft: draft)
        XCTAssertEqual(book.title, "Imported river")
        XCTAssertEqual(book.chapters.count, 2)

        let manuscriptsDirectory = await versioning.manuscriptsDirectory
        let reopened = try FileManuscriptStore(directory: manuscriptsDirectory)
        let stored = try await reopened.loadBook(id: book.id)
        XCTAssertEqual(stored?.title, book.title)
        XCTAssertEqual(stored?.chapters.count, 2)

        let after = try JSONCoding.encoder.encode(try await versioning.loadBook(id: argentina.id)!)
        XCTAssertEqual(before, after, "Import must not rewrite the Argentina seed")

        let listed = try await versioning.listBooks()
        XCTAssertTrue(listed.contains { $0.id == argentina.id })
        XCTAssertTrue(listed.contains { $0.id == book.id })
        let sorted = LibraryBookOrdering.sorted([book, argentina])
        XCTAssertEqual(sorted.first?.id, ArgentinaFixtureIDs.book)
    }

    func testLibraryOrderingKeepsArgentinaThenQuranThenCreatedBook() throws {
        // Ordering is an identity rule; exercise it without translation content.
        let quran = Book(id: QuranFixtureIDs.book, title: "Protected sample metadata",
                         author: "Fixture", chapters: [])
        var draftBook = try ManuscriptImporter.importPlainText(
            text: "# One\nA reader-made book.",
            title: "Zebra Notes",
            author: "Test Author",
            sourceKind: .pastedText
        )
        draftBook.title = "Zebra Notes"
        let sorted = LibraryBookOrdering.sorted([draftBook, quran, argentina])
        XCTAssertEqual(sorted.map(\.id), [argentina.id, quran.id, draftBook.id])
    }

    func testImportRefusesToOverwriteArgentinaIdentity() {
        XCTAssertThrowsError(
            try ManuscriptImporter.importPlainText(
                text: "# No\nNever replace the seed.",
                title: "Hijack",
                author: "Nope",
                sourceKind: .pastedText,
                bookId: ArgentinaFixtureIDs.book
            )
        ) { error in
            XCTAssertEqual(error as? CreateBookError, .argentinaProtected)
        }
    }

    func testImportRefusesToOverwriteQuranIdentity() {
        XCTAssertThrowsError(
            try ManuscriptImporter.importPlainText(
                text: "# No\nNever replace the Quran seed.",
                title: "Hijack",
                author: "Nope",
                sourceKind: .pastedText,
                bookId: QuranFixtureIDs.book
            )
        ) { error in
            XCTAssertEqual(error as? CreateBookError, .quranProtected)
        }
    }

    func testMinimalZipReadsFriendCanonEPUB() throws {
        let data = try Data(contentsOf: try BundleFixtureLoader.urlForFriendCanonEPUB())
        let files = try MinimalZipArchive.fileMap(from: data)
        XCTAssertEqual(String(data: files["mimetype"] ?? Data(), encoding: .utf8), "application/epub+zip")
        XCTAssertTrue(files.keys.contains("OEBPS/content.opf"))
        XCTAssertTrue(files.keys.contains("OEBPS/ch1.xhtml"))
    }

    func testEPUBExtractSplitsChaptersVerbatimAsCanon() throws {
        let url = try BundleFixtureLoader.urlForFriendCanonEPUB()
        let extract = try EPUBTextExtractor.extract(from: url)
        XCTAssertEqual(extract.title, "Plaza Evening")
        XCTAssertEqual(extract.author, "A Friend")
        XCTAssertTrue(extract.plainText.contains("# River Light"))
        XCTAssertTrue(extract.plainText.contains("The plaza kept the river's last light on the stones."))
        XCTAssertTrue(extract.plainText.contains("# Interior Bargain"))
        XCTAssertTrue(extract.plainText.contains("Cattle walked toward a price they did not set."))
        XCTAssertFalse(extract.plainText.contains("<p>"), "HTML must be stripped; words stay verbatim")

        let book = try ManuscriptImporter.importPlainText(
            text: extract.plainText,
            title: extract.title,
            author: extract.author,
            sourceKind: .epubExtract
        )
        XCTAssertEqual(book.title, "Plaza Evening")
        XCTAssertEqual(book.author, "A Friend")
        XCTAssertEqual(book.chapters.count, 2)
        XCTAssertEqual(book.chapters[0].title, "River Light")
        XCTAssertEqual(book.chapters[1].title, "Interior Bargain")
        XCTAssertEqual(book.subtitle, "Canon · EPUB")
        XCTAssertEqual(book.edition?.label, "Canon")
        XCTAssertTrue(book.isCanonImport)
        XCTAssertEqual(book.libraryKindLabel, "CANON")
        XCTAssertFalse(argentina.isCanonImport)
        XCTAssertEqual(argentina.libraryKindLabel, "A LIVING BOOK")
    }

    func testEPUBImportSavesOfflineWithoutAI() async throws {
        ai.resetCallCount()
        let extract = try EPUBTextExtractor.extract(from: try BundleFixtureLoader.urlForFriendCanonEPUB())
        var draft = CreateBookDraft.blank()
        draft.title = extract.title ?? ""
        draft.author = extract.author ?? ""
        draft.importedText = extract.plainText
        draft.importSourceKind = .epubExtract
        let book = try await wizard.importAndSave(draft: draft)
        XCTAssertEqual(book.title, "Plaza Evening")
        XCTAssertEqual(book.subtitle, "Canon · EPUB")
        XCTAssertEqual(ai.adaptCallCount, 0)
        XCTAssertEqual(ai.askCallCount, 0)
        XCTAssertEqual(ai.totalCallCount, 0)
    }

    func testImportedBookIsOfflineReadableWithoutAI() async throws {
        ai.resetCallCount()
        var draft = CreateBookDraft.blank()
        draft.importedText = "# One\nOffline prose stays readable."
        _ = try await wizard.importAndSave(draft: draft)
        XCTAssertEqual(ai.adaptCallCount, 0)
        XCTAssertEqual(ai.askCallCount, 0)
        XCTAssertEqual(ai.totalCallCount, 0)
    }

    // MARK: - Generate wizard + PE (RDR-933…936)

    func testGenerateWizardBuildsPEPacketInAssemblyOrder() async throws {
        let draft = generateDraft()
        let result = try await wizard.generateAndSave(draft: draft)

        XCTAssertEqual(result.book.title, "Plaza Stories")
        XCTAssertGreaterThanOrEqual(result.book.chapters.count, 3)
        XCTAssertFalse(result.generatedChapterIds.isEmpty)
        XCTAssertNotNil(ai.lastGenerateRequest?.packet)

        let rendered = PEPacketPromptAssembler.render(ai.lastGenerateRequest?.packet)
        let briefHeader = rendered.range(of: PEPacketSection.readerBrief.header)
        let continuityHeader = rendered.range(of: PEPacketSection.continuityState.header)
        let factsHeader = rendered.range(of: PEPacketSection.factChecklist.header)
        XCTAssertNotNil(briefHeader)
        XCTAssertNotNil(continuityHeader)
        XCTAssertNotNil(factsHeader)
        XCTAssertLessThan(briefHeader!.lowerBound, continuityHeader!.lowerBound)
        XCTAssertLessThan(continuityHeader!.lowerBound, factsHeader!.lowerBound)
        XCTAssertEqual(PEPacketPromptAssembler.sectionOrder, ["READER BRIEF", "CONTINUITY STATE", "FACT CHECKLIST"])

        XCTAssertEqual(result.packet.brief?.bookTitle, "Plaza Stories")
        XCTAssertFalse(result.packet.facts.evidence.isEmpty, "Research notes should seed supporting evidence")
        XCTAssertEqual(ai.askCallCount, 0, "Create generate must not call Ask / Luna")
    }

    func testExplicitMockReportsDeterministicGeneration() async throws {
        let result = try await wizard.generateAndSave(draft: generateDraft())
        XCTAssertTrue(result.usedDeterministicFallback)
        let prose = result.book.chapters.flatMap { $0.activeRevision?.blocks ?? [] }.map(\.text).joined()
        XCTAssertTrue(prose.contains("[Adapted]") || result.book.outlineChapterCount < result.book.chapters.count)
        XCTAssertNotEqual(result.book.id, ArgentinaFixtureIDs.book)
        XCTAssertTrue(result.completionMessage.contains("No live AI"))
        XCTAssertTrue(result.book.subtitle?.contains("Bundled demo") == true)
        XCTAssertTrue(result.book.provenanceNotes.contains { $0.contains("no live AI") })
    }

    func testAllFailedGenerationKeepsDraftAndReportsActualFailure() async throws {
        let draft = generateDraft()
        ai.stubGenerate { _ in throw CreateBookError.generationFailed("Provider unavailable.") }
        let result = try await wizard.generateAndSave(draft: draft)
        XCTAssertFalse(result.isComplete)
        XCTAssertTrue(result.generatedChapterIds.isEmpty)
        XCTAssertEqual(result.skippedChapterIds.count, draft.outlineTitles.count)
        XCTAssertTrue(result.completionMessage.contains("No chapters were written"))
        XCTAssertTrue(result.completionMessage.contains("Provider unavailable"))
        XCTAssertFalse(result.completionMessage.contains("Created"))
        XCTAssertNotNil(try drafts.load(id: draft.id))
    }

    func testSecondWizardCannotGenerateTheSameDraftWhileFirstIsRunning() async throws {
        var draft = generateDraft()
        draft.outlineTitles = ["First"]
        let otherAI = MockAIService()
        let other = CreateBookWizardService(versioning: versioning, preferenceStore: preferenceStore,
            packets: packets, drafts: drafts, ai: otherAI)
        ai.stubGenerate { request in
            do {
                _ = try await other.generateAndSave(draft: draft)
                XCTFail("A second sheet must not start a duplicate provider request")
            } catch { XCTAssertTrue(error.localizedDescription.contains("already being generated")) }
            return DeterministicAdaptationSynthesizer.generate(request)
        }
        let result = try await wizard.generateAndSave(draft: draft)
        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(otherAI.totalCallCount, 0)
    }

    func testContinuityFailureStopsGenerationAndRetryRepairsSavedConsumedProse() async throws {
        var draft = generateDraft()
        draft.outlineTitles = ["First", "Second"]
        let failing = FailingCreatePacketStore(base: packets)
        failing.failMerge = true
        let service = CreateBookWizardService(versioning: versioning, preferenceStore: preferenceStore,
            packets: failing, drafts: drafts, ai: ai)
        let prose = "The blue key remained beneath the brass bell."
        let fact = "A supporting detail retained with the published chapter."
        var requests: [AdaptationGenerateRequest] = []
        ai.stubGeneratedPacket { request in
            requests.append(request)
            return GeneratedChapter(
                blocks: [ContentBlock(id: UUID(), kind: .paragraph, text: prose, orderIndex: 0)],
                proposedClaims: [FactClaim(chapterId: request.chapterId, statement: fact,
                    importance: .supporting, status: .unverified, evidenceIds: [])]
            )
        }

        let partial = try await service.generateAndSave(draft: draft)
        let first = try XCTUnwrap(partial.book.chapters.first)
        let revision = try XCTUnwrap(first.activeRevision)
        let publishedFacts = try packets.loadFactChecklist(bookId: draft.id)
        XCTAssertEqual(requests.map(\.chapterTitle), ["First"], "Do not generate chapter 2 from stale continuity")
        XCTAssertFalse(partial.isComplete)
        XCTAssertEqual(partial.skippedChapterIds, [first.id])
        XCTAssertTrue(partial.completionMessage.contains("Continuity storage unavailable"))
        XCTAssertFalse(first.isOutlineStub)
        XCTAssertEqual(revision.blocks.first?.text, prose)
        XCTAssertTrue(publishedFacts.claims.contains { $0.statement == fact }, "Post-activation failure must not restore the pre-generation checklist")
        XCTAssertNotNil(try drafts.load(id: draft.id))

        // Reading can pin the new prose while metadata remains unfinished.
        try await versioning.consume(bookId: draft.id, chapterId: first.id, revisionId: revision.id)
        let consumedBefore = try await versioning.retrieveConsumedRevision(bookId: draft.id, chapterId: first.id)
        let ledgerBefore = try await versioning.ledgerSnapshot()
        failing.failMerge = false
        requests = []
        ai.stubGeneratedPacket { request in
            requests.append(request)
            let continuity = request.packet?.continuity.entry(chapterId: first.id)
            XCTAssertNotNil(continuity)
            XCTAssertEqual(continuity?.revisionId, revision.id)
            XCTAssertEqual(continuity?.digest, prose)
            XCTAssertEqual(continuity?.isConsumed, true)
            return GeneratedChapter(blocks: [ContentBlock(id: UUID(), kind: .paragraph,
                text: "The door opened in the next chapter.", orderIndex: 0)])
        }
        let complete = try await service.generateAndSave(draft: draft)
        XCTAssertTrue(complete.isComplete)
        XCTAssertEqual(requests.map(\.chapterTitle), ["Second"], "Repair must not regenerate published text")
        let consumedAfter = try await versioning.retrieveConsumedRevision(bookId: draft.id, chapterId: first.id)
        let ledgerAfter = try await versioning.ledgerSnapshot()
        XCTAssertEqual(consumedAfter, consumedBefore)
        XCTAssertEqual(ledgerAfter, ledgerBefore)
        XCTAssertEqual(complete.book.chapters.first?.revisions.count, first.revisions.count)
        let factsAfter = try packets.loadFactChecklist(bookId: draft.id)
        XCTAssertEqual(factsAfter.claims, publishedFacts.claims)
        XCTAssertEqual(factsAfter.evidence, publishedFacts.evidence)
        XCTAssertNil(try drafts.load(id: draft.id))
    }

    func testRepeatedMetadataFailureCannotTurnPolishedBookIntoFalseSuccess() async throws {
        var draft = generateDraft()
        draft.outlineTitles = ["Only chapter"]
        let failing = FailingCreatePacketStore(base: packets)
        failing.failMerge = true
        let service = CreateBookWizardService(versioning: versioning, preferenceStore: preferenceStore,
            packets: failing, drafts: drafts, ai: ai)
        let partial = try await service.generateAndSave(draft: draft)
        XCTAssertFalse(partial.isComplete)
        let savedBefore = try await versioning.loadBook(id: draft.id)
        let factsBefore = try packets.loadFactChecklist(bookId: draft.id)
        ai.stubGenerate { _ in
            XCTFail("Metadata repair must not request another generation")
            throw CreateBookError.generationFailed("Unexpected regeneration")
        }

        do {
            _ = try await service.generateAndSave(draft: draft)
            XCTFail("A polished chapter with missing continuity is not complete")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Could not repair saved continuity"))
        }
        let savedAfter = try await versioning.loadBook(id: draft.id)
        XCTAssertEqual(savedAfter, savedBefore)
        XCTAssertEqual(try packets.loadFactChecklist(bookId: draft.id), factsBefore)
        XCTAssertNotNil(try drafts.load(id: draft.id))
    }

    func testMetadataRepairNeverReplacesMismatchedConsumedContinuity() async throws {
        var draft = generateDraft()
        draft.outlineTitles = ["Only chapter"]
        let failing = FailingCreatePacketStore(base: packets)
        failing.failMerge = true
        let service = CreateBookWizardService(versioning: versioning, preferenceStore: preferenceStore,
            packets: failing, drafts: drafts, ai: ai)
        let partial = try await service.generateAndSave(draft: draft)
        let chapter = try XCTUnwrap(partial.book.chapters.first)
        let revision = try XCTUnwrap(chapter.activeRevision)
        try await versioning.consume(bookId: draft.id, chapterId: chapter.id, revisionId: revision.id)
        // Preserve an already-pinned packet even when it names the older outline.
        _ = try packets.recordConsumedContinuity(bookId: draft.id, chapter: chapter, revision: revision)
        let before = try packets.loadContinuity(bookId: draft.id)
        XCTAssertNotEqual(before.entry(chapterId: chapter.id)?.revisionId, revision.id)
        failing.failMerge = false
        let consumedBefore = try await versioning.retrieveConsumedRevision(bookId: draft.id, chapterId: chapter.id)
        do {
            _ = try await service.generateAndSave(draft: draft)
            XCTFail("Consumed metadata mismatch requires repair, not replacement")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("consumed continuity"))
        }
        XCTAssertEqual(try packets.loadContinuity(bookId: draft.id), before)
        let consumedAfter = try await versioning.retrieveConsumedRevision(bookId: draft.id, chapterId: chapter.id)
        XCTAssertEqual(consumedAfter, consumedBefore)
        XCTAssertNotNil(try drafts.load(id: draft.id))
    }

    func testFinalPacketReadFailureKeepsDraftAndRetriesWithoutRegeneration() async throws {
        var draft = generateDraft()
        draft.outlineTitles = ["Only chapter"]
        let failing = FailingCreatePacketStore(base: packets)
        failing.failPacketReadAfterMerge = true
        let service = CreateBookWizardService(versioning: versioning, preferenceStore: preferenceStore,
            packets: failing, drafts: drafts, ai: ai)
        do {
            _ = try await service.generateAndSave(draft: draft)
            XCTFail("The final packet cannot be replaced with an empty success")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Packet read unavailable"))
        }
        let savedBefore = try await versioning.loadBook(id: draft.id)
        let factsBefore = try packets.loadFactChecklist(bookId: draft.id)
        XCTAssertEqual(savedBefore?.outlineChapterCount, 0)
        XCTAssertNotNil(try drafts.load(id: draft.id))
        failing.failPacketReadAfterMerge = false
        failing.failPacketRead = false
        ai.stubGenerate { _ in
            XCTFail("A final-read retry must not regenerate already-published text")
            throw CreateBookError.generationFailed("Unexpected regeneration")
        }
        let complete = try await service.generateAndSave(draft: draft)
        XCTAssertTrue(complete.isComplete)
        XCTAssertTrue(complete.generatedChapterIds.isEmpty)
        XCTAssertEqual(complete.book, savedBefore)
        XCTAssertEqual(complete.packet.facts, factsBefore)
        XCTAssertNil(try drafts.load(id: draft.id))
    }

    func testPartialRetryPreservesConsumedChapterAndPublishesOnlyRemainingOutlines() async throws {
        var draft = generateDraft()
        draft.outlineTitles = ["First", "Second"]
        ai.stubGenerate { request in
            if request.chapterTitle == "Second" { throw CreateBookError.generationFailed("Connection lost.") }
            return DeterministicAdaptationSynthesizer.generate(request)
        }
        let partial = try await wizard.generateAndSave(draft: draft)
        XCTAssertFalse(partial.isComplete)
        XCTAssertEqual(partial.generatedChapterIds.count, 1)
        XCTAssertTrue(partial.completionMessage.contains("1 of 2"))
        let first = try XCTUnwrap(partial.book.chapters.first { $0.title == "First" })
        let firstRevision = try XCTUnwrap(first.activeRevision)
        try await versioning.consume(bookId: draft.id, chapterId: first.id, revisionId: firstRevision.id)
        let consumedForPacket = try await versioning.readableRevision(bookId: draft.id, chapterId: first.id)
        _ = try packets.recordConsumedContinuity(bookId: draft.id, chapter: first, revision: consumedForPacket)
        let consumedBefore = try await versioning.retrieveConsumedRevision(bookId: draft.id, chapterId: first.id)
        let preferencesBefore = try preferenceStore.load(bookId: draft.id)
        let continuityBefore = try packets.loadContinuity(bookId: draft.id).entry(chapterId: first.id)
        var retried: [String] = []
        ai.stubGenerate { request in
            retried.append(request.chapterTitle)
            XCTAssertTrue(request.plan.lockedChapterIds.contains(first.id))
            return DeterministicAdaptationSynthesizer.generate(request)
        }
        let result = try await wizard.generateAndSave(draft: draft)
        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(retried, ["Second"])
        XCTAssertEqual(result.book.chapters.map(\.id), partial.book.chapters.map(\.id))
        let after = try await versioning.retrieveConsumedRevision(bookId: draft.id, chapterId: first.id)
        XCTAssertEqual(after, consumedBefore)
        XCTAssertEqual(result.book.chapters.first { $0.id == first.id }?.revisions.count, first.revisions.count)
        XCTAssertEqual(try packets.loadContinuity(bookId: draft.id).entry(chapterId: first.id), continuityBefore)
        XCTAssertNil(try drafts.load(id: draft.id))
        XCTAssertEqual(try preferenceStore.load(bookId: draft.id), preferencesBefore)
    }

    func testRetryDoesNotRegenerateConsumedOrRevisedOutlines() async throws {
        var draft = generateDraft()
        draft.outlineTitles = ["Consumed outline", "Revised outline"]
        ai.stubGenerate { _ in throw CreateBookError.generationFailed("Offline") }
        let partial = try await wizard.generateAndSave(draft: draft)
        let first = partial.book.chapters[0]
        let second = partial.book.chapters[1]
        try await versioning.consume(bookId: draft.id, chapterId: first.id, revisionId: XCTUnwrap(first.activeRevisionId))
        _ = try await versioning.createRevision(bookId: draft.id, chapterId: second.id,
            blocks: [ContentBlock(id: UUID(), kind: .paragraph, text: "Already published prose", orderIndex: 0)])
        let before = try await versioning.loadBook(id: draft.id)
        ai.stubGenerate { request in
            XCTFail("Protected outlines must not trigger another generation")
            return DeterministicAdaptationSynthesizer.generate(request)
        }
        let result = try await wizard.generateAndSave(draft: draft)
        XCTAssertFalse(result.isComplete)
        XCTAssertEqual(result.skippedChapterIds.count, 2)
        XCTAssertEqual(result.book, before)
        XCTAssertNotNil(try drafts.load(id: draft.id))
    }

    func testRetryCannotReplaceAnExistingUnownedBookOrChangeItsOutline() async throws {
        var draft = generateDraft()
        ai.stubGenerate { _ in throw CreateBookError.generationFailed("Offline") }
        let partial = try await wizard.generateAndSave(draft: draft)
        let before = try JSONCoding.encoder.encode(partial.book)
        draft.outlineTitles = ["A different outline"]
        do {
            _ = try await wizard.generateAndSave(draft: draft)
            XCTFail("A retry must not recreate the book")
        } catch { XCTAssertTrue(error.localizedDescription.contains("cannot be replaced")) }
        let unchanged = try await versioning.loadBook(id: draft.id)
        XCTAssertEqual(try JSONCoding.encoder.encode(unchanged!), before)
        XCTAssertEqual(try drafts.load(id: draft.id)?.outlineTitles, partial.book.chapters.map(\.title))
        draft.outlineTitles = partial.book.chapters.map(\.title)
        try drafts.delete(id: draft.id)
        do {
            _ = try await wizard.generateAndSave(draft: draft)
            XCTFail("An arbitrary existing book is not an unfinished draft")
        } catch { XCTAssertTrue(error.localizedDescription.contains("cannot be replaced")) }
    }

    @MainActor
    func testIncompleteGenerationDoesNotCallFinishedOrShowSuccessScreen() async throws {
        let draft = generateDraft()
        ai.stubGenerate { _ in throw CreateBookError.generationFailed("Provider unavailable") }
        let result = try await wizard.generateAndSave(draft: draft)
        let suite = "CreatePublication-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = CreateBookViewModel(wizard: wizard, modelPrefs: AIModelPreferenceStore(defaults: defaults), draft: draft)
        var finishedCount = 0
        model.onFinished = { _ in finishedCount += 1 }
        model.presentGeneration(result)
        XCTAssertEqual(finishedCount, 0)
        XCTAssertEqual(model.step, .form)
        XCTAssertTrue(model.errorMessage?.contains("No chapters were written") == true)
        XCTAssertEqual(model.draft, draft)
    }

    func testSwitchingFailedGenerateDraftToImportCannotOverwriteSavedBook() async throws {
        var draft = generateDraft()
        ai.stubGenerate { _ in throw CreateBookError.generationFailed("Offline") }
        let result = try await wizard.generateAndSave(draft: draft)
        let before = try JSONCoding.encoder.encode(result.book)
        draft.path = .importManuscript
        draft.importedText = "A completely different book that must not replace the saved draft."
        do {
            _ = try await wizard.importAndSave(draft: draft)
            XCTFail("Import must not overwrite an existing generated book")
        } catch { XCTAssertTrue(error.localizedDescription.contains("already has a saved book")) }
        let saved = try await versioning.loadBook(id: draft.id)
        XCTAssertEqual(try JSONCoding.encoder.encode(saved!), before)
        XCTAssertEqual(try drafts.load(id: draft.id)?.path, .generate)
    }

    func testPastedOutlineLengthEstimateMatchesGenerationTargets() async throws {
        var draft = generateDraft()
        let paste = "## Voice\nWarm and plain\n\n## Outline\n- The river\n- The plaza"
        CreateProfileCardParser.importCards(from: paste, into: &draft)

        for length in CreateBookLength.allCases {
            draft.id = UUID()
            draft.length = length
            let advertisedWords = draft.estimatedReadingTime.proseWordCount
            let advertisedPages = draft.pagesLabel(for: length)
            let result = try await wizard.generateAndSave(draft: draft)
            let targets = try XCTUnwrap(ai.lastGenerateRequest?.plan.chapterTargets)

            XCTAssertEqual(result.book.chapters.map(\.title), ["The river", "The plaza"])
            XCTAssertEqual(advertisedWords, targets.reduce(0) { $0 + $1.targetWordCount })
            let pages = max(1, Int((Double(advertisedWords) / Double(CreateBookLength.wordsPerPage)).rounded()))
            XCTAssertEqual(advertisedPages, "\(pages) pages")
            XCTAssertEqual(draft.readingTimeLabel, "About \(draft.estimatedReadingTime.compactLabel) to read")
            XCTAssertTrue(result.skippedChapterIds.isEmpty)
        }
    }

    func testNextChapterUsesPublishedProseAndContinuityWithActualRevisionIdentity() async throws {
        var draft = generateDraft()
        draft.outlineTitles = ["The hidden key", "The unopened door"]
        let prose = "The clockmaker hid a blue key beneath the brass bell."
        let summary = "A blue key is hidden beneath the brass bell."
        let thread = "Which door does the blue key unlock?"
        let wrongBookId = UUID()
        let wrongChapterId = UUID()
        let wrongRevisionId = UUID()
        var requests: [AdaptationGenerateRequest] = []
        ai.stubGeneratedPacket { request in
            requests.append(request)
            return GeneratedChapter(
                blocks: [ContentBlock(id: UUID(), kind: .paragraph, text: prose, orderIndex: 0)],
                continuityDelta: ContinuityDelta(
                    bookId: wrongBookId,
                    entries: [ContinuityEntry(
                        id: UUID(), chapterId: wrongChapterId, chapterTitle: "Wrong title",
                        chapterOrderIndex: 99, revisionId: wrongRevisionId,
                        digest: summary, establishedFacts: ["The key is blue."],
                        openThreads: [thread], isConsumed: true, recordedAt: Date()
                    )],
                    newThreads: [thread]
                )
            )
        }

        let result = try await wizard.generateAndSave(draft: draft)
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(result.generatedChapterIds.count, 2)
        let second = try XCTUnwrap(requests.dropFirst().first)
        let firstChapter = try XCTUnwrap(result.book.chapters.min { $0.orderIndex < $1.orderIndex })
        let firstRevision = try XCTUnwrap(firstChapter.activeRevision)
        let requestChapter = try XCTUnwrap(second.book.chapters.first { $0.id == firstChapter.id })
        XCTAssertEqual(requestChapter.activeRevision, firstRevision,
                       "Chapter 2 must receive the book with Chapter 1's published prose")
        XCTAssertEqual(requestChapter.activeRevision?.blocks.first?.text, prose)
        XCTAssertFalse(requestChapter.isOutlineStub)

        let packet = try XCTUnwrap(second.packet)
        let entry = try XCTUnwrap(packet.continuity.entry(chapterId: firstChapter.id))
        XCTAssertEqual(packet.continuity.bookId, result.book.id)
        XCTAssertEqual(entry.revisionId, firstRevision.id)
        XCTAssertNotEqual(entry.revisionId, wrongRevisionId)
        XCTAssertEqual(entry.chapterTitle, firstChapter.title)
        XCTAssertEqual(entry.chapterOrderIndex, firstChapter.orderIndex)
        XCTAssertFalse(entry.isConsumed, "The generator cannot mark a new chapter consumed")
        XCTAssertEqual(entry.digest, summary)
        XCTAssertEqual(entry.establishedFacts, ["The key is blue."])
        XCTAssertEqual(entry.openThreads, [thread])
        XCTAssertTrue(packet.continuity.carriedThreads.contains(thread))
        let rendered = PEPacketPromptAssembler.render(packet, focusChapterId: second.chapterId)
        XCTAssertTrue(rendered.contains(summary), "The next chapter's prompt must carry the generated summary")
        XCTAssertTrue(rendered.contains(thread), "The next chapter's prompt must carry the unresolved thread")
        XCTAssertNil(result.packet.continuity.entry(chapterId: wrongChapterId))
        XCTAssertTrue(try packets.loadContinuity(bookId: wrongBookId).timeline.isEmpty,
                      "A generated book UUID must not redirect continuity into another book")
    }

    func testLaterGeneratedDeltaCannotChangeConsumedEarlierChapter() async throws {
        var draft = generateDraft()
        draft.outlineTitles = ["First chapter", "Second chapter"]
        let versioning = self.versioning!
        let packets = self.packets!
        var consumedEntry: ContinuityEntry?
        var consumedRevision: ChapterRevision?
        ai.stubGenerate { request in
            let first = try XCTUnwrap(request.book.chapters.min { $0.orderIndex < $1.orderIndex })
            if request.chapterId != first.id {
                let revision = try XCTUnwrap(first.activeRevision)
                try await versioning.consume(bookId: request.book.id, chapterId: first.id, revisionId: revision.id)
                // Finish Chapter records both the immutable manuscript revision
                // and its continuity entry through these two stores.
                try packets.recordConsumedContinuity(bookId: request.book.id, chapter: first, revision: revision)
                consumedEntry = try packets.loadContinuity(bookId: request.book.id).entry(chapterId: first.id)
                consumedRevision = try await versioning.readableRevision(bookId: request.book.id, chapterId: first.id)
            }
            return [ContentBlock(id: UUID(), kind: .paragraph, text: "Published \(request.chapterTitle).", orderIndex: 0)]
        }
        ai.stubGeneratedPacket { request in
            // Include an attempted update to every chapter. Only the generated
            // target's payload may merge; stored consumed entries stay untouched.
            let entries = request.book.chapters.map { chapter in
                ContinuityEntry(
                    id: UUID(), chapterId: chapter.id, chapterTitle: "Untrusted title",
                    chapterOrderIndex: 99, revisionId: UUID(),
                    digest: "Summary from \(request.chapterTitle)", establishedFacts: [],
                    openThreads: [], isConsumed: false, recordedAt: Date()
                )
            }
            return GeneratedChapter(blocks: [], continuityDelta: ContinuityDelta(bookId: request.book.id, entries: entries))
        }

        let result = try await wizard.generateAndSave(draft: draft)
        let before = try XCTUnwrap(consumedEntry)
        XCTAssertTrue(before.isConsumed)
        XCTAssertEqual(result.packet.continuity.entry(chapterId: before.chapterId), before)
        let after = try await versioning.readableRevision(bookId: result.book.id, chapterId: before.chapterId)
        XCTAssertEqual(after, consumedRevision)
        XCTAssertEqual(result.generatedChapterIds.count, 2)
        let last = try XCTUnwrap(result.book.chapters.max { $0.orderIndex < $1.orderIndex })
        XCTAssertEqual(result.packet.continuity.entry(chapterId: last.id)?.revisionId, last.activeRevisionId)
    }

    func testNewerRevisionDuringCreateGenerationIsKept() async throws {
        let versioning = self.versioning!
        ai.stubGenerate { request in
            _ = try await versioning.createRevision(
                bookId: request.book.id, chapterId: request.chapterId,
                blocks: [ContentBlock(id: UUID(), kind: .paragraph, text: "Newer authoring revision.", orderIndex: 0)]
            )
            return DeterministicAdaptationSynthesizer.generate(request)
        }
        let result = try await wizard.generateAndSave(draft: generateDraft())
        XCTAssertTrue(result.generatedChapterIds.isEmpty)
        XCTAssertEqual(Set(result.skippedChapterIds), Set(result.book.chapters.map(\.id)))
        for chapter in result.book.chapters {
            XCTAssertEqual(chapter.revisions.count, 2)
            XCTAssertEqual(chapter.activeRevision?.blocks.first?.text, "Newer authoring revision.")
            XCTAssertTrue(chapter.isOutlineStub, "A stale generator must not polish the newer revision")
        }
        let unchanged = try await versioning.loadBook(id: argentina.id)!
        XCTAssertEqual(try JSONCoding.encoder.encode(unchanged), try JSONCoding.encoder.encode(argentina))
    }

    func testUnverifiedEssentialClaimLeavesOutlineAndDoesNotCorruptArgentina() async throws {
        let before = try JSONCoding.encoder.encode(try await versioning.loadBook(id: argentina.id)!)
        ai.stubGeneratedPacket { request in
            let claim = FactClaim(
                chapterId: request.chapterId,
                statement: "An essential invention with no source",
                importance: .essential,
                status: .unverified,
                evidenceIds: []
            )
            return GeneratedChapter(
                blocks: DeterministicAdaptationSynthesizer.generate(request),
                proposedClaims: [claim],
                proposedEvidence: []
            )
        }

        let result = try await wizard.generateAndSave(draft: generateDraft())
        XCTAssertTrue(result.generatedChapterIds.isEmpty)
        XCTAssertFalse(result.skippedChapterIds.isEmpty)
        XCTAssertEqual(result.book.outlineChapterCount, result.book.chapters.count)

        let after = try JSONCoding.encoder.encode(try await versioning.loadBook(id: argentina.id)!)
        XCTAssertEqual(before, after)

        let ledger = try await versioning.ledgerSnapshot()
        XCTAssertTrue(ledger.filter { $0.bookId == argentina.id }.isEmpty)
    }

    func testAskStaysLunaAndGenerationStaysAstra() {
        XCTAssertEqual(OpenAIModelOption.defaultAsk, .gpt56Luna)
        XCTAssertEqual(OpenAIModelOption.defaultAsk.rawValue, "gpt-5.6-luna")
        XCTAssertEqual(OpenAIModelOption.defaultGeneration, .gpt6Astra)
        XCTAssertEqual(OpenAIModelOption.defaultGeneration.rawValue, "gpt-6-astra")
    }

    func testDraftStoreRoundTrip() throws {
        var draft = generateDraft()
        draft.readerNotes = "Keep plazas concrete"
        try drafts.save(draft)
        let reopened = try FileCreateBookDraftStore(rootDirectory: root)
        let loaded = try reopened.load(id: draft.id)
        XCTAssertEqual(loaded?.title, draft.title)
        XCTAssertEqual(loaded?.readerNotes, "Keep plazas concrete")
        XCTAssertEqual(loaded?.moreOf, draft.moreOf)
    }

    func testProfileCardsParseFromChatGPTPaste() {
        let paste = """
        ## Voice
        warm historical storyteller

        ## Outline
        - The river
        - The interior

        ## Research notes
        The cabildo still faces the plaza.
        """
        let cards = CreateProfileCardParser.parse(paste)
        XCTAssertEqual(cards.count, 3)
        XCTAssertEqual(cards[0].title, "Voice")
        XCTAssertEqual(CreateProfileCardParser.outlineTitles(from: cards), ["The river", "The interior"])
        XCTAssertTrue(CreateBookDraft.chatgptExportPrompt.contains("## Outline"))
    }

    func testProposeOutlinePrefersSignedOffTitles() async {
        var draft = generateDraft()
        draft.outlineTitles = ["Customs house", "Interior bargain", "Plaza night"]
        let titles = await wizard.proposeOutline(for: draft)
        XCTAssertEqual(titles, ["Customs house", "Interior bargain", "Plaza night"])
    }

    // MARK: - Helpers

    private func generateDraft() -> CreateBookDraft {
        var draft = CreateBookDraft.blank()
        draft.path = .generate
        draft.title = "Plaza Stories"
        draft.author = "Test Author"
        draft.topic = "How a plaza remembers inflation and football"
        draft.voice = "warm historical storyteller"
        draft.length = .short
        draft.style = .narrative
        draft.referenceStyles = ["A Little History of the World"]
        draft.moreOf = [.stories, .placesIllVisit]
        draft.lessOf = [.dates]
        draft.researchNotes = "The cabildo still faces the plaza.\nMate is a social clock."
        draft.outlineTitles = CreateBookOutline.defaultTitles(
            topic: draft.topic,
            count: draft.length.chapterCount
        )
        return draft
    }
}

/// Injects a failure only after manuscript activation; all other writes use the
/// real temporary stores, including the checklist enforced by versioning.
private final class FailingCreatePacketStore: PEPacketStoring, @unchecked Sendable {
    let base: FilePEPacketStore
    var failMerge = false
    var failPacketReadAfterMerge = false
    var failPacketRead = false

    init(base: FilePEPacketStore) { self.base = base }

    func loadBrief(bookId: UUID) throws -> ReaderBrief? { try base.loadBrief(bookId: bookId) }
    func saveBrief(_ brief: ReaderBrief) throws { try base.saveBrief(brief) }
    func loadContinuity(bookId: UUID) throws -> ContinuityState { try base.loadContinuity(bookId: bookId) }
    func saveContinuity(_ state: ContinuityState) throws { try base.saveContinuity(state) }
    func loadFactChecklist(bookId: UUID) throws -> FactChecklist { try base.loadFactChecklist(bookId: bookId) }
    func saveFactChecklist(_ checklist: FactChecklist) throws { try base.saveFactChecklist(checklist) }
    func refreshBrief(book: Book, profile: ReaderPreferenceProfile) throws -> ReaderBrief {
        try base.refreshBrief(book: book, profile: profile)
    }
    func recordConsumedContinuity(bookId: UUID, chapter: Chapter, revision: ChapterRevision) throws -> ContinuityState {
        try base.recordConsumedContinuity(bookId: bookId, chapter: chapter, revision: revision)
    }
    func mergeContinuity(_ delta: ContinuityDelta) throws -> ContinuityMergeResult {
        if failMerge { throw CreateBookError.generationFailed("Continuity storage unavailable") }
        let result = try base.mergeContinuity(delta)
        if failPacketReadAfterMerge { failPacketRead = true }
        return result
    }
    func loadPacket(bookId: UUID) throws -> PEContinuityPacket {
        if failPacketRead { throw CreateBookError.generationFailed("Packet read unavailable") }
        return try base.loadPacket(bookId: bookId)
    }
}
