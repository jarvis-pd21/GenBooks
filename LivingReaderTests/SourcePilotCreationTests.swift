import XCTest
import CryptoKit
@testable import LivingReader

/// End-to-end service tests with authored evidence and counting actor mocks.
/// No network, model request, key access, or app/UI launch occurs here.
final class SourcePilotCreationTests: XCTestCase {
    func testApprovedPreviewPublishesAndReopensWithSourceReceiptAndDisclosure() async throws {
        let environment = try PilotTestEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.root) }
        let draft = try PilotCreationFixture.draft()
        let source = PilotCreationFixture.source()
        let retriever = PilotCountingRetriever(source: source)
        let ai = PilotCountingAI()
        let result = try await environment.wizard(ai: ai, retriever: retriever).generateAndSave(draft: draft)
        XCTAssertEqual(result.book.id, draft.id)
        XCTAssertEqual(result.book.chapters.count, 1)
        XCTAssertEqual(result.generatedChapterIds, result.book.chapters.map(\.id))
        XCTAssertTrue(result.skippedChapterIds.isEmpty)
        XCTAssertFalse(result.usedDeterministicFallback)
        XCTAssertEqual(result.book.outlineChapterCount, 0)
        assertCheckedMetadata(result.book)
        XCTAssertNil(try environment.drafts.load(id: draft.id))
        let reopened = try PilotTestEnvironment(root: environment.root)
        let loaded = try await reopened.versioning.loadBook(id: draft.id)
        assertCheckedMetadata(try XCTUnwrap(loaded))
        let chapter = try XCTUnwrap(loaded?.chapters.first)
        let requirement = try XCTUnwrap(chapter.sourceGrounding)
        let revision = try XCTUnwrap(chapter.activeRevision)
        XCTAssertEqual(requirement.source, source)
        XCTAssertEqual(chapter.revisions.count, 2)
        XCTAssertEqual(chapter.manuscriptStatus, .polished)
        XCTAssertNotNil(revision.sourceReview)
        XCTAssertNoThrow(try SourceGrounding.validate(receipt: revision.sourceReview, bookID: draft.id,
            chapterID: chapter.id, blocks: revision.blocks, requirement: requirement))
        XCTAssertTrue(revision.blocks.contains { $0.text == SourcePilotPlan.disclosure })
        XCTAssertEqual(revision.blocks.last?.text, SourceGrounding.sourceFooter(source))
        XCTAssertEqual(try SourceGrounding.proseWordCount(revision.blocks, source: source), 370)
        XCTAssertEqual(try SourceGrounding.prose(revision.blocks, source: source),
            PilotCreationFixture.paragraphs().map { $0.text + " [1]" })
        XCTAssertEqual(loaded?.synopsis, draft.trimmedTopic, "Display quality must not rewrite the approved writing brief")
        XCTAssertEqual(requirement.approvedBriefHash, draft.sourcePilot?.approvedBriefHash)
        let facts = try reopened.packets.loadFactChecklist(bookId: draft.id)
        XCTAssertEqual(facts.evidenceItem(id: "source1")?.retrievedSource, source)
        XCTAssertFalse(facts.claims.contains { $0.status == .verified })
        let calls = await ai.snapshot()
        let titles = await retriever.requestedTitles()
        XCTAssertEqual(titles, ["River Archive"])
        XCTAssertEqual(calls.writes.count, 1)
        XCTAssertEqual(calls.reviews.count, 1)
        XCTAssertEqual(calls.legacy, 0)
        XCTAssertEqual(calls.writes.first?.source, source)
        XCTAssertEqual(calls.reviews.first?.paragraphs, try SourceGrounding.prose(revision.blocks, source: source))
    }

    func testFailedReviewRetryReusesRetrievedSnapshotAndExactSavedWritingDraft() async throws {
        let environment = try PilotTestEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.root) }
        let draft = try PilotCreationFixture.draft()
        let retriever = PilotCountingRetriever(source: PilotCreationFixture.source())
        let ai = PilotCountingAI(reviews: [PilotCreationFixture.review(firstAssessment: .unsupported), PilotCreationFixture.review()])
        await expectFailure {
            _ = try await environment.wizard(ai: ai, retriever: retriever).generateAndSave(draft: draft)
        }
        let savedDraft = try XCTUnwrap(environment.drafts.load(id: draft.id))
        let beforeBook = try await environment.versioning.loadBook(id: draft.id)
        assertPendingMetadata(try XCTUnwrap(beforeBook))
        let outline = try XCTUnwrap(beforeBook?.chapters.first)
        XCTAssertTrue(outline.isOutlineStub)
        XCTAssertEqual(outline.revisions.count, 1)
        let pending = try XCTUnwrap(environment.packets.loadFactChecklist(bookId: draft.id).sourcePilot?.candidate)
        XCTAssertNil(pending.sourceReview)
        let firstCalls = await ai.snapshot()
        XCTAssertEqual(firstCalls.writes.count, 1)
        XCTAssertEqual(firstCalls.reviews.count, 1)

        // Fresh service/store instances prove retry state is on disk, not an actor cache.
        let reopened = try PilotTestEnvironment(root: environment.root)
        let result = try await reopened.wizard(ai: ai, retriever: retriever).generateAndSave(draft: savedDraft)
        assertCheckedMetadata(result.book)
        let published = try XCTUnwrap(result.book.chapters.first?.activeRevision)
        XCTAssertEqual(published.blocks, pending.blocks)
        XCTAssertNotNil(published.sourceReview)
        XCTAssertEqual(published.sourceReview?.baseRevisionID, outline.activeRevisionId)
        XCTAssertEqual(result.book.chapters.first?.sourceGrounding, outline.sourceGrounding)
        XCTAssertNil(try reopened.drafts.load(id: draft.id))
        let calls = await ai.snapshot()
        let titles = await retriever.requestedTitles()
        XCTAssertEqual(titles.count, 1, "Review retry must not retrieve a newer source revision")
        XCTAssertEqual(calls.writes.count, 1, "Review retry must not purchase/rewrite the saved draft")
        XCTAssertEqual(calls.reviews.count, 2)
        XCTAssertEqual(calls.reviews[0].paragraphs, calls.reviews[1].paragraphs)
        XCTAssertEqual(calls.reviews[0].source, calls.reviews[1].source)
        XCTAssertEqual(calls.legacy, 0)
    }

    func testOpeningExcerptPublishesThroughExcerptRouteAndReopensExactSourceMetadata() async throws {
        let environment = try PilotTestEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.root) }
        let draft = try PilotCreationFixture.draft(scope: .wikipediaOpeningExcerpt)
        let source = PilotCreationFixture.openingSource()
        let retriever = PilotCountingRetriever(source: source)
        let ai = PilotCountingAI()

        let result = try await environment.wizard(ai: ai, retriever: retriever).generateAndSave(draft: draft)

        XCTAssertEqual(result.book.id, draft.id)
        XCTAssertEqual(result.book.chapters.count, 1)
        XCTAssertEqual(result.generatedChapterIds, result.book.chapters.map(\.id))
        XCTAssertFalse(result.usedDeterministicFallback)
        assertCheckedMetadata(result.book, scope: .wikipediaOpeningExcerpt)
        XCTAssertNil(try environment.drafts.load(id: draft.id))
        let reopened = try PilotTestEnvironment(root: environment.root)
        let loaded = try await reopened.versioning.loadBook(id: draft.id)
        let chapter = try XCTUnwrap(loaded?.chapters.first)
        let requirement = try XCTUnwrap(chapter.sourceGrounding)
        let revision = try XCTUnwrap(chapter.activeRevision)
        XCTAssertEqual(chapter.revisions.count, 2)
        XCTAssertEqual(chapter.manuscriptStatus, .polished)
        XCTAssertEqual(requirement.source, source)
        XCTAssertEqual(requirement.source.extractionMetadata, PilotCreationFixture.openingMetadata())
        XCTAssertEqual(requirement.approvedBriefHash, draft.sourcePilot?.approvedBriefHash)
        XCTAssertEqual(revision.sourceReview?.sourceHash, try SourceGrounding.hash(source))
        XCTAssertNoThrow(try SourceGrounding.validate(receipt: revision.sourceReview, bookID: draft.id,
            chapterID: chapter.id, blocks: revision.blocks, requirement: requirement))
        XCTAssertTrue(revision.blocks.contains { $0.text == SourcePilotPlan.disclosure(for: .wikipediaOpeningExcerpt) })
        XCTAssertFalse(revision.blocks.contains { $0.text == SourcePilotPlan.disclosure })
        XCTAssertEqual(revision.blocks.last?.text, SourceGrounding.sourceFooter(source))
        XCTAssertEqual(try SourceGrounding.proseWordCount(revision.blocks, source: source), 370)
        XCTAssertEqual(loaded?.synopsis, draft.trimmedTopic)
        assertCheckedMetadata(try XCTUnwrap(loaded), scope: .wikipediaOpeningExcerpt)
        let facts = try reopened.packets.loadFactChecklist(bookId: draft.id)
        XCTAssertEqual(facts.evidenceItem(id: "source1")?.retrievedSource, source)
        XCTAssertFalse(facts.claims.contains { $0.status == .verified })
        let routes = await retriever.snapshot()
        let calls = await ai.snapshot()
        XCTAssertTrue(routes.introductions.isEmpty)
        XCTAssertEqual(routes.excerpts, ["River Archive"])
        XCTAssertEqual(calls.writes.count, 1)
        XCTAssertEqual(calls.reviews.count, 1)
        XCTAssertEqual(calls.writes.first?.source, source)
        XCTAssertEqual(calls.reviews.first?.source, source)
        XCTAssertEqual(calls.reviews.first?.paragraphs, try SourceGrounding.prose(revision.blocks, source: source))
        XCTAssertEqual(calls.legacy, 0)
    }

    func testMalformedOrMismatchedOpeningSourceStopsBeforeAnyAIWork() async throws {
        let wrongVersion = RetrievedResearchSource.ExtractionMetadata(
            extractionVersion: "unrecognized-extraction-version",
            paragraphLocators: PilotCreationFixture.openingMetadata().paragraphLocators)
        let missingParagraph = RetrievedResearchSource.ExtractionMetadata(
            extractionVersion: "wikipedia-opening-paragraphs-v1",
            paragraphLocators: Array(PilotCreationFixture.openingMetadata().paragraphLocators.prefix(1)))
        let cases: [(name: String, source: RetrievedResearchSource?)] = [
            ("missing article", nil),
            ("introduction instead of approved excerpt", PilotCreationFixture.source()),
            ("different requested article", PilotCreationFixture.source(scope: .wikipediaOpeningExcerpt,
                requestedTitle: "Another Archive", extractionMetadata: PilotCreationFixture.openingMetadata())),
            ("missing extraction metadata", PilotCreationFixture.source(scope: .wikipediaOpeningExcerpt)),
            ("unknown extraction version", PilotCreationFixture.source(scope: .wikipediaOpeningExcerpt,
                extractionMetadata: wrongVersion)),
            ("paragraph locator mismatch", PilotCreationFixture.source(scope: .wikipediaOpeningExcerpt,
                extractionMetadata: missingParagraph))
        ]
        for item in cases {
            let environment = try PilotTestEnvironment()
            defer { try? FileManager.default.removeItem(at: environment.root) }
            let draft = try PilotCreationFixture.draft(scope: .wikipediaOpeningExcerpt)
            let retriever = PilotCountingRetriever(source: item.source)
            let ai = PilotCountingAI()

            await expectFailure {
                _ = try await environment.wizard(ai: ai, retriever: retriever).generateAndSave(draft: draft)
            }

            let saved = try await environment.versioning.loadBook(id: draft.id)
            let book = try XCTUnwrap(saved)
            assertPendingMetadata(book)
            let chapter = try XCTUnwrap(book.chapters.first)
            XCTAssertTrue(chapter.isOutlineStub, item.name)
            XCTAssertEqual(chapter.revisions.count, 1, item.name)
            XCTAssertNil(chapter.sourceGrounding, item.name)
            XCTAssertNotNil(try environment.drafts.load(id: draft.id), item.name)
            let routes = await retriever.snapshot()
            let calls = await ai.snapshot()
            XCTAssertTrue(routes.introductions.isEmpty, item.name)
            XCTAssertEqual(routes.excerpts, ["River Archive"], item.name)
            XCTAssertTrue(calls.writes.isEmpty, item.name)
            XCTAssertTrue(calls.reviews.isEmpty, item.name)
            XCTAssertEqual(calls.legacy, 0, item.name)
        }
    }

    func testOpeningExcerptReviewRetryAcrossReopenedStoresReusesSourceAndCandidate() async throws {
        let environment = try PilotTestEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.root) }
        let draft = try PilotCreationFixture.draft(scope: .wikipediaOpeningExcerpt)
        let source = PilotCreationFixture.openingSource()
        let firstRetriever = PilotCountingRetriever(source: source)
        let firstAI = PilotCountingAI(reviews: [PilotCreationFixture.review(firstAssessment: .unsupported)])
        await expectFailure {
            _ = try await environment.wizard(ai: firstAI, retriever: firstRetriever).generateAndSave(draft: draft)
        }
        let savedDraft = try XCTUnwrap(environment.drafts.load(id: draft.id))
        XCTAssertEqual(savedDraft.sourcePilot?.selectedScope, .wikipediaOpeningExcerpt)
        let beforeBook = try await environment.versioning.loadBook(id: draft.id)
        assertPendingMetadata(try XCTUnwrap(beforeBook))
        let outline = try XCTUnwrap(beforeBook?.chapters.first)
        let pending = try XCTUnwrap(environment.packets.loadFactChecklist(bookId: draft.id).sourcePilot?.candidate)
        XCTAssertNil(pending.sourceReview)
        XCTAssertEqual(outline.sourceGrounding?.source, source)

        // Every service and mock is fresh. This retriever would fail if retry tried
        // to fetch anything; the new writer's counter proves the draft stays intact.
        let reopened = try PilotTestEnvironment(root: environment.root)
        let retryRetriever = PilotCountingRetriever(source: nil)
        let retryAI = PilotCountingAI()
        let result = try await reopened.wizard(ai: retryAI, retriever: retryRetriever).generateAndSave(draft: savedDraft)

        assertCheckedMetadata(result.book, scope: .wikipediaOpeningExcerpt)
        let chapter = try XCTUnwrap(result.book.chapters.first)
        let published = try XCTUnwrap(chapter.activeRevision)
        XCTAssertEqual(chapter.revisions.count, 2)
        XCTAssertEqual(chapter.sourceGrounding, outline.sourceGrounding)
        XCTAssertEqual(published.blocks, pending.blocks)
        XCTAssertEqual(published.sourceReview?.baseRevisionID, outline.activeRevisionId)
        XCTAssertEqual(published.sourceReview?.sourceHash, try SourceGrounding.hash(source))
        XCTAssertNil(try reopened.drafts.load(id: draft.id))
        let firstRoutes = await firstRetriever.snapshot()
        let retryRoutes = await retryRetriever.snapshot()
        let firstCalls = await firstAI.snapshot()
        let retryCalls = await retryAI.snapshot()
        XCTAssertTrue(firstRoutes.introductions.isEmpty)
        XCTAssertEqual(firstRoutes.excerpts, ["River Archive"])
        XCTAssertTrue(retryRoutes.introductions.isEmpty)
        XCTAssertTrue(retryRoutes.excerpts.isEmpty)
        XCTAssertEqual(firstCalls.writes.count, 1)
        XCTAssertEqual(firstCalls.reviews.count, 1)
        XCTAssertTrue(retryCalls.writes.isEmpty)
        XCTAssertEqual(retryCalls.reviews.count, 1)
        XCTAssertEqual(firstCalls.reviews.first?.paragraphs, retryCalls.reviews.first?.paragraphs)
        XCTAssertEqual(firstCalls.reviews.first?.source, source)
        XCTAssertEqual(retryCalls.reviews.first?.source, source)
        XCTAssertEqual(firstCalls.legacy, 0)
        XCTAssertEqual(retryCalls.legacy, 0)
    }

    func testChangedApprovedSourceScopeFailsPreflightWithoutPersistenceOrProviderWork() async throws {
        var introToExcerpt = try PilotCreationFixture.draft()
        introToExcerpt.sourcePilot?.sourceScope = .wikipediaOpeningExcerpt
        var excerptToImplicitIntro = try PilotCreationFixture.draft(scope: .wikipediaOpeningExcerpt)
        excerptToImplicitIntro.sourcePilot?.sourceScope = nil
        var excerptToExplicitIntro = try PilotCreationFixture.draft(scope: .wikipediaOpeningExcerpt)
        excerptToExplicitIntro.sourcePilot?.sourceScope = .wikipediaIntroduction
        for draft in [introToExcerpt, excerptToImplicitIntro, excerptToExplicitIntro] {
            let environment = try PilotTestEnvironment()
            defer { try? FileManager.default.removeItem(at: environment.root) }
            let retriever = PilotCountingRetriever(source: PilotCreationFixture.openingSource())
            let ai = PilotCountingAI()
            XCTAssertNotEqual(draft.sourcePilot?.approvedBriefHash, try SourcePilotPlan.briefHash(draft))

            await expectFailure {
                _ = try await environment.wizard(ai: ai, retriever: retriever).generateAndSave(draft: draft)
            }

            let book = try await environment.versioning.loadBook(id: draft.id)
            XCTAssertNil(book)
            XCTAssertNil(try environment.drafts.load(id: draft.id))
            let routes = await retriever.snapshot()
            let calls = await ai.snapshot()
            XCTAssertTrue(routes.introductions.isEmpty)
            XCTAssertTrue(routes.excerpts.isEmpty)
            XCTAssertTrue(calls.writes.isEmpty)
            XCTAssertTrue(calls.reviews.isEmpty)
            XCTAssertEqual(calls.legacy, 0)
        }
    }

    func testMissingOrInsufficientSourceStopsBeforeWriterAndRetainsOutlineDraft() async throws {
        for source in [nil, PilotCreationFixture.source(text: "Insufficient source text.")] as [RetrievedResearchSource?] {
            let environment = try PilotTestEnvironment()
            defer { try? FileManager.default.removeItem(at: environment.root) }
            let draft = try PilotCreationFixture.draft()
            let retriever = PilotCountingRetriever(source: source)
            let ai = PilotCountingAI()
            await expectFailure {
                _ = try await environment.wizard(ai: ai, retriever: retriever).generateAndSave(draft: draft)
            }
            let book = try await environment.versioning.loadBook(id: draft.id)
            assertPendingMetadata(try XCTUnwrap(book))
            let chapter = try XCTUnwrap(book?.chapters.first)
            XCTAssertTrue(chapter.isOutlineStub)
            XCTAssertEqual(chapter.revisions.count, 1)
            XCTAssertNil(chapter.sourceGrounding)
            XCTAssertNil(chapter.activeRevision?.sourceReview)
            XCTAssertNotNil(try environment.drafts.load(id: draft.id))
            let calls = await ai.snapshot()
            let titles = await retriever.requestedTitles()
            XCTAssertEqual(titles.count, 1)
            XCTAssertTrue(calls.writes.isEmpty)
            XCTAssertTrue(calls.reviews.isEmpty)
            XCTAssertEqual(calls.legacy, 0)
        }
    }

    func testChangedApprovedBriefFailsPreflightBeforeAnyPersistenceOrProviderWork() async throws {
        let original = try PilotCreationFixture.draft()
        var topic = original; topic.topic += " Changed topic."
        var voice = original; voice.voice = "A different approved voice"
        var outline = original; outline.outlineTitles = ["Different chapter"]
        var length = original; length.length = .long
        for draft in [topic, voice, outline, length] {
            let environment = try PilotTestEnvironment()
            defer { try? FileManager.default.removeItem(at: environment.root) }
            let retriever = PilotCountingRetriever(source: PilotCreationFixture.source())
            let ai = PilotCountingAI()
            await expectFailure {
                _ = try await environment.wizard(ai: ai, retriever: retriever).generateAndSave(draft: draft)
            }
            let book = try await environment.versioning.loadBook(id: draft.id)
            let titles = await retriever.requestedTitles()
            let calls = await ai.snapshot()
            XCTAssertNil(book)
            XCTAssertNil(try environment.drafts.load(id: draft.id))
            XCTAssertTrue(titles.isEmpty)
            XCTAssertTrue(calls.writes.isEmpty)
            XCTAssertTrue(calls.reviews.isEmpty)
            XCTAssertEqual(calls.legacy, 0)
        }
    }

    func testRevisionPublishedDuringAwaitedWriterCannotBeOverwritten() async throws {
        try await assertCompetingPublicationSurvives(duringReview: false)
    }

    func testRevisionPublishedDuringAwaitedReviewerCannotBeOverwritten() async throws {
        try await assertCompetingPublicationSurvives(duringReview: true)
    }

    func testProseWordCountUsesWhitespaceTokensWithoutCitationsOrNonProseBlocks() throws {
        let source = PilotCreationFixture.openingSource()
        let paragraphs = PilotCreationFixture.paragraphs().map {
            SourceDraftParagraph(text: $0.text.replacingOccurrences(of: " ", with: " \t\n"), citations: $0.citations)
        }
        let blocks = try SourceGrounding.blocks(title: "A deliberately long heading that is not part of the prose count",
            paragraphs: paragraphs, source: source)
        XCTAssertEqual(paragraphs.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }, 370)
        XCTAssertEqual(try SourceGrounding.proseWordCount(blocks, source: source), 370)
        XCTAssertGreaterThan(blocks.map(\.text).joined(separator: " ").split(whereSeparator: \.isWhitespace).count, 372,
            "The authored fixture must distinguish prose from citations, heading, disclosure, and source footer")
        var changed = blocks
        changed[1].text = String(changed[1].text.dropLast(4))
        XCTAssertThrowsError(try SourceGrounding.proseWordCount(changed, source: source),
            "A missing required citation is invalid structure, not countable reviewed prose")
    }

    func testFinalPacketFailureRetryKeepsActualWordCountBriefAndConsumedHistoryWithoutAIWork() async throws {
        for consumed in [false, true] {
            let environment = try PilotTestEnvironment()
            defer { try? FileManager.default.removeItem(at: environment.root) }
            let draft = try PilotCreationFixture.draft(scope: .wikipediaOpeningExcerpt)
            try environment.preferences.save(.empty(bookId: draft.id, at: PilotCreationFixture.date))
            let firstAI = PilotCountingAI()
            let firstRetriever = PilotCountingRetriever(source: PilotCreationFixture.openingSource())
            let failingPackets = PilotFinalPacketFailureStore(base: environment.packets)
            let wizard = CreateBookWizardService(versioning: environment.versioning,
                preferenceStore: environment.preferences, packets: failingPackets, drafts: environment.drafts,
                ai: firstAI, sourceRetriever: firstRetriever)
            do {
                _ = try await wizard.generateAndSave(draft: draft)
                XCTFail("A final metadata-read failure cannot report completed creation")
            } catch {
                XCTAssertEqual(error as? PilotMockError, .finalPacketReadUnavailable)
            }
            let savedDraft = try XCTUnwrap(environment.drafts.load(id: draft.id))
            var expectedDraft = draft
            expectedDraft.updatedAt = savedDraft.updatedAt // Saving updates only this bookkeeping timestamp.
            XCTAssertEqual(savedDraft, expectedDraft)
            let savedBook = try await environment.versioning.loadBook(id: draft.id)
            let publishedBook = try XCTUnwrap(savedBook)
            assertCheckedMetadata(publishedBook, scope: .wikipediaOpeningExcerpt)
            XCTAssertEqual(publishedBook.synopsis, draft.trimmedTopic)
            let chapter = try XCTUnwrap(publishedBook.chapters.first)
            let revision = try XCTUnwrap(chapter.activeRevision)
            let requirement = try XCTUnwrap(chapter.sourceGrounding)
            XCTAssertEqual(requirement.approvedBriefHash, draft.sourcePilot?.approvedBriefHash)
            XCTAssertEqual(try SourceGrounding.proseWordCount(revision.blocks, source: requirement.source), 370)
            if consumed {
                try await environment.versioning.consume(bookId: draft.id, chapterId: chapter.id, revisionId: revision.id)
            }
            let beforeRetry = try await environment.versioning.loadBook(id: draft.id)
            let expectedBook = try XCTUnwrap(beforeRetry)
            let expectedLedger = try await environment.versioning.ledgerSnapshot()
            let factsBefore = try environment.packets.loadFactChecklist(bookId: draft.id)
            let preferencesBefore = try environment.preferences.load(bookId: draft.id)
            let reviewedCandidate = try XCTUnwrap(factsBefore.sourcePilot?.candidate)
            XCTAssertNotNil(reviewedCandidate.sourceReview)

            let reopened = try PilotTestEnvironment(root: environment.root)
            let retryAI = PilotCountingAI(reviews: [])
            let retryRetriever = PilotCountingRetriever(source: nil)
            let result = try await reopened.wizard(ai: retryAI, retriever: retryRetriever).generateAndSave(draft: savedDraft)

            XCTAssertTrue(result.isComplete)
            assertCheckedMetadata(result.book, scope: .wikipediaOpeningExcerpt)
            XCTAssertEqual(result.book, expectedBook, "Finishing metadata must not rewrite reviewed or consumed history")
            XCTAssertEqual(result.book.synopsis, draft.trimmedTopic)
            XCTAssertEqual(result.book.chapters.first?.activeRevision?.blocks, reviewedCandidate.blocks)
            XCTAssertEqual(result.book.chapters.first?.activeRevision?.sourceReview, reviewedCandidate.sourceReview)
            XCTAssertEqual(result.packet.facts, factsBefore)
            XCTAssertEqual(try reopened.preferences.load(bookId: draft.id), preferencesBefore)
            let ledgerAfter = try await reopened.versioning.ledgerSnapshot()
            XCTAssertEqual(ledgerAfter, expectedLedger)
            XCTAssertNil(try reopened.drafts.load(id: draft.id))
            if consumed {
                let consumedRevision = try await reopened.versioning.retrieveConsumedRevision(bookId: draft.id, chapterId: chapter.id)
                XCTAssertEqual(consumedRevision, expectedBook.chapters.first?.activeRevision)
            }
            let firstCalls = await firstAI.snapshot()
            XCTAssertEqual(firstCalls.writes.count, 1)
            XCTAssertEqual(firstCalls.reviews.count, 1)
            let retryCalls = await retryAI.snapshot()
            XCTAssertTrue(retryCalls.writes.isEmpty)
            XCTAssertTrue(retryCalls.reviews.isEmpty)
            XCTAssertEqual(retryCalls.legacy, 0)
            let retryRoutes = await retryRetriever.snapshot()
            XCTAssertTrue(retryRoutes.introductions.isEmpty)
            XCTAssertTrue(retryRoutes.excerpts.isEmpty)
        }
    }

    private func assertCompetingPublicationSurvives(duringReview: Bool) async throws {
        let environment = try PilotTestEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.root) }
        let draft = try PilotCreationFixture.draft()
        let retriever = PilotCountingRetriever(source: PilotCreationFixture.source())
        let recorder = PilotCompetingRevisionRecorder()
        let versioning = environment.versioning
        let bookID = draft.id
        let hook: @Sendable () async throws -> Void = {
            let revision = try await PilotCreationFixture.publishCompetingRevision(versioning: versioning, bookID: bookID)
            await recorder.record(revision)
        }
        let ai = PilotCountingAI(onWrite: duringReview ? nil : hook, onReview: duringReview ? hook : nil)
        await expectFailure {
            _ = try await environment.wizard(ai: ai, retriever: retriever).generateAndSave(draft: draft)
        }
        let recordedRevision = await recorder.value()
        let competing = try XCTUnwrap(recordedRevision)
        let reloaded = try await environment.versioning.loadBook(id: draft.id)
        let chapter = try XCTUnwrap(reloaded?.chapters.first)
        XCTAssertEqual(chapter.revisions.count, 2, "The suspended attempt must not append a third revision")
        XCTAssertEqual(chapter.activeRevisionId, competing.id)
        XCTAssertEqual(chapter.activeRevision?.blocks, competing.blocks)
        XCTAssertEqual(chapter.activeRevision?.sourceReview?.contentHash, competing.sourceReview?.contentHash)
        XCTAssertNotNil(try environment.drafts.load(id: draft.id), "Failed stale work keeps its retry handle")
        let calls = await ai.snapshot()
        let titles = await retriever.requestedTitles()
        XCTAssertEqual(titles.count, 1)
        XCTAssertEqual(calls.writes.count, 1)
        if duringReview { XCTAssertEqual(calls.reviews.count, 1) }
        XCTAssertEqual(calls.legacy, 0)
    }

    private func expectFailure(file: StaticString = #filePath, line: UInt = #line,
                               _ operation: () async throws -> Void) async {
        do { try await operation(); XCTFail("Expected source-preview refusal", file: file, line: line) }
        catch { }
    }

    private func assertPendingMetadata(_ book: Book, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(book.subtitle, "Source preview · not reviewed", file: file, line: line)
        XCTAssertTrue(book.provenanceNotes.contains("Pending preview: no source-support review has been completed."), file: file, line: line)
        XCTAssertFalse(book.provenanceNotes.contains(SourcePilotPlan.disclosure), file: file, line: line)
        XCTAssertFalse(book.provenanceNotes.contains(SourcePilotPlan.disclosure(for: .wikipediaOpeningExcerpt)), file: file, line: line)
        XCTAssertFalse(book.chapters.contains { $0.activeRevision?.sourceReview != nil }, file: file, line: line)
    }

    private func assertCheckedMetadata(_ book: Book, scope: RetrievedResearchSource.Scope = .wikipediaIntroduction,
                                       file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(book.subtitle, "Source-checked preview · 370 prose words", file: file, line: line)
        XCTAssertTrue(book.provenanceNotes.contains(SourcePilotPlan.disclosure(for: scope)), file: file, line: line)
        XCTAssertFalse(book.provenanceNotes.contains("Pending preview: no source-support review has been completed."), file: file, line: line)
        XCTAssertTrue(book.chapters.allSatisfy { $0.activeRevision?.sourceReview != nil }, file: file, line: line)
    }
}

private struct PilotTestEnvironment {
    let root: URL
    let packets: FilePEPacketStore
    let versioning: ManuscriptVersioningService
    let preferences: FileReaderPreferenceStore
    let drafts: FileCreateBookDraftStore

    init(root: URL? = nil) throws {
        self.root = root ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("SourcePilotCreationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
        packets = try FilePEPacketStore(rootDirectory: self.root)
        versioning = try ManuscriptVersioningService(rootDirectory: self.root, packets: packets)
        preferences = try FileReaderPreferenceStore(rootDirectory: self.root)
        drafts = try FileCreateBookDraftStore(rootDirectory: self.root)
    }

    func wizard(ai: PilotCountingAI, retriever: PilotCountingRetriever) -> CreateBookWizardService {
        CreateBookWizardService(versioning: versioning, preferenceStore: preferences, packets: packets,
            drafts: drafts, ai: ai, sourceRetriever: retriever)
    }
}

private enum PilotCreationFixture {
    static let firstQuote = "The archive describes river communities sharing boats, recording harvests, and maintaining meeting records for exchanges between nearby settlements."
    static let secondQuote = "Its introduction explains how seasonal travel shaped schedules, while local councils kept written accounts of trade and public gatherings."
    static let date = Date(timeIntervalSince1970: 1_800_000_000)

    static func draft(scope: RetrievedResearchSource.Scope = .wikipediaIntroduction) throws -> CreateBookDraft {
        var draft = CreateBookDraft.blank()
        draft.path = .generate
        draft.title = "River Archive Preview"
        draft.topic = "An introduction to the retained river archive account"
        draft.voice = "Clear and direct"
        draft.length = .short
        draft.outlineTitles = ["River Archive"]
        draft.sourcePilot = try SourcePilotPlan.approved(articleTitle: "River Archive", draft: draft, scope: scope)
        return draft
    }

    static func source(text: String? = nil, scope: RetrievedResearchSource.Scope = .wikipediaIntroduction,
                       requestedTitle: String = "River Archive",
                       extractionMetadata: RetrievedResearchSource.ExtractionMetadata? = nil) -> RetrievedResearchSource {
        let text = text ?? (scope == .wikipediaIntroduction
            ? Array(repeating: firstQuote + " " + secondQuote, count: 5).joined(separator: "\n")
            : [Array(repeating: firstQuote, count: 5).joined(separator: " "),
               Array(repeating: secondQuote, count: 5).joined(separator: " ")].joined(separator: "\n\n"))
        let digest = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        return RetrievedResearchSource(requestedTitle: requestedTitle, title: "River Archive",
            canonicalURL: URL(string: "https://en.wikipedia.org/wiki/River_Archive")!, pageID: 42, revisionID: 9001,
            revisionURL: URL(string: "https://en.wikipedia.org/w/index.php?oldid=9001")!,
            revisionTimestamp: date, retrievedAt: date, scope: scope, text: text, textSHA256: digest,
            attribution: "Authored source fixture; not a real retrieval.",
            attributionURL: URL(string: "https://en.wikipedia.org/w/index.php?title=River_Archive&action=history")!,
            licenseName: "Fixture CC BY-SA 4.0", licenseURL: URL(string: "https://creativecommons.org/licenses/by-sa/4.0/")!,
            extractionMetadata: extractionMetadata)
    }

    static func openingSource() -> RetrievedResearchSource {
        source(scope: .wikipediaOpeningExcerpt, extractionMetadata: openingMetadata())
    }

    static func openingMetadata() -> RetrievedResearchSource.ExtractionMetadata {
        .init(extractionVersion: "wikipedia-opening-paragraphs-v1", paragraphLocators: [
            .init(sectionAnchor: nil, sectionTitle: "Introduction", paragraphIndex: 1),
            .init(sectionAnchor: nil, sectionTitle: "Introduction", paragraphIndex: 2)
        ])
    }

    static func paragraphs() -> [SourceDraftParagraph] {
        [SourceDraftParagraph(text: Array(repeating: firstQuote, count: 10).joined(separator: " "), citations: ["source1"]),
         SourceDraftParagraph(text: Array(repeating: secondQuote, count: 10).joined(separator: " "), citations: ["source1"])]
    }

    static func review(firstAssessment: SourceReviewUnit.Assessment = .supported) -> SourceReviewResponse {
        SourceReviewResponse(units: [.init(index: 0, assessment: firstAssessment, quotes: [firstQuote]),
                                    .init(index: 1, assessment: .supported, quotes: [secondQuote])])
    }

    static func publishCompetingRevision(versioning: ManuscriptVersioningService, bookID: UUID) async throws -> ChapterRevision {
        guard let book = try await versioning.loadBook(id: bookID), let chapter = book.chapters.first,
              let base = chapter.activeRevision, let requirement = chapter.sourceGrounding else {
            throw PilotMockError.missingFixtureState
        }
        let blocks = try SourceGrounding.blocks(title: chapter.title, paragraphs: Array(paragraphs().reversed()), source: requirement.source)
        let response = SourceReviewResponse(units: [.init(index: 0, assessment: .supported, quotes: [secondQuote]),
                                                   .init(index: 1, assessment: .supported, quotes: [firstQuote])])
        let receipt = try SourceGrounding.receipt(bookID: bookID, chapterID: chapter.id, baseRevisionID: base.id,
            blocks: blocks, source: requirement.source, model: OpenAIModelOption.defaultGeneration.rawValue, response: response)
        let candidate = CandidateRevision(id: UUID(), bookId: bookID, chapterId: chapter.id,
            proposedRevisionIndex: base.revisionIndex + 1, createdAt: date, blocks: blocks, status: .staged,
            rejectionReason: nil, origin: .adapted, sourceReview: receipt)
        try await versioning.stageCandidate(candidate)
        return try await versioning.activateCandidate(id: candidate.id)
    }
}

private enum PilotMockError: Error, Equatable { case unexpectedLegacyCall, missingFixtureState, exhaustedReviewResponses, finalPacketReadUnavailable }

/// The real packet store performs every write. Only the final result read fails,
/// after publication and continuity persistence, so retry exercises saved state.
private final class PilotFinalPacketFailureStore: PEPacketStoring, @unchecked Sendable {
    private let base: FilePEPacketStore
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
    func mergeContinuity(_ delta: ContinuityDelta) throws -> ContinuityMergeResult { try base.mergeContinuity(delta) }
    func recordConsumedContinuity(bookId: UUID, chapter: Chapter, revision: ChapterRevision) throws -> ContinuityState {
        try base.recordConsumedContinuity(bookId: bookId, chapter: chapter, revision: revision)
    }
    func loadPacket(bookId: UUID) throws -> PEContinuityPacket { throw PilotMockError.finalPacketReadUnavailable }
}

private actor PilotCountingRetriever: ResearchSourceRetrieving, ResearchExcerptSourceRetrieving {
    struct Calls: Sendable {
        let introductions: [String]
        let excerpts: [String]
    }
    private let source: RetrievedResearchSource?
    private var titles: [String] = []
    private var excerptTitles: [String] = []
    init(source: RetrievedResearchSource?) { self.source = source }
    func retrieve(articleTitle: String) async throws -> RetrievedResearchSource {
        titles.append(articleTitle)
        guard let source else { throw WikipediaSourceError.missingArticle }
        return source
    }
    func retrieveOpeningExcerpt(articleTitle: String) async throws -> RetrievedResearchSource {
        excerptTitles.append(articleTitle)
        guard let source else { throw WikipediaSourceError.missingArticle }
        return source
    }
    func requestedTitles() -> [String] { titles }
    func snapshot() -> Calls { Calls(introductions: titles, excerpts: excerptTitles) }
}

private actor PilotCountingAI: AIService, SourceGroundedAI {
    struct Calls: Sendable {
        let writes: [SourceWritingRequest]
        let reviews: [SourceReviewRequest]
        let legacy: Int
    }
    nonisolated var usesDeterministicGeneration: Bool { false }
    nonisolated var sourceReviewModelID: String { OpenAIModelOption.defaultGeneration.rawValue }
    private var writes: [SourceWritingRequest] = []
    private var reviews: [SourceReviewRequest] = []
    private var legacy = 0
    private var responses: [SourceReviewResponse]
    private let onWrite: (@Sendable () async throws -> Void)?
    private let onReview: (@Sendable () async throws -> Void)?

    init(reviews: [SourceReviewResponse] = [PilotCreationFixture.review()],
         onWrite: (@Sendable () async throws -> Void)? = nil,
         onReview: (@Sendable () async throws -> Void)? = nil) {
        responses = reviews
        self.onWrite = onWrite
        self.onReview = onReview
    }
    func writeSourcePreview(_ request: SourceWritingRequest) async throws -> [SourceDraftParagraph] {
        writes.append(request)
        try await onWrite?()
        return PilotCreationFixture.paragraphs()
    }
    func reviewSourcePreview(_ request: SourceReviewRequest) async throws -> SourceReviewResponse {
        reviews.append(request)
        try await onReview?()
        guard !responses.isEmpty else { throw PilotMockError.exhaustedReviewResponses }
        return responses.removeFirst()
    }
    func snapshot() -> Calls { Calls(writes: writes, reviews: reviews, legacy: legacy) }
    func adaptChapter(chapterId: UUID, promptContext: String) async throws -> ChapterRevision {
        legacy += 1; throw PilotMockError.unexpectedLegacyCall
    }
    func makeAdaptationPlan(_ request: AdaptationPlanRequest) async throws -> AdaptationPlan {
        legacy += 1; throw PilotMockError.unexpectedLegacyCall
    }
    func generateAdaptedChapter(_ request: AdaptationGenerateRequest) async throws -> [ContentBlock] {
        legacy += 1; throw PilotMockError.unexpectedLegacyCall
    }
    func ask(_ request: AskRequest) async throws -> AskResponse {
        legacy += 1; throw PilotMockError.unexpectedLegacyCall
    }
}

private actor PilotCompetingRevisionRecorder {
    private var revision: ChapterRevision?
    func record(_ revision: ChapterRevision) { self.revision = revision }
    func value() -> ChapterRevision? { revision }
}
