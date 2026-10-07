import XCTest
import CryptoKit
@testable import LivingReader

/// Authored fixtures and local temporary stores only: no provider or network calls.
/// These checks bind a fallible source-support review, never FactClaim.verified.
final class SourceGroundingTests: XCTestCase {
    private let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
    private let firstQuote = "The archive describes river communities sharing boats, recording harvests, and maintaining meeting records for exchanges between nearby settlements."
    private let secondQuote = "Its introduction explains how seasonal travel shaped schedules, while local councils kept written accounts of trade and public gatherings."

    func testOpeningExcerptReceiptBindsScopeExtractionVersionAndEveryParagraphLocator() throws {
        let source = makeOpeningSource()
        let fixture = try makeFixture(source: source)
        let receipt = try XCTUnwrap(fixture.candidate.sourceReview)
        XCTAssertNoThrow(try validate(receipt, fixture: fixture))
        XCTAssertEqual(receipt.sourceHash, try SourceGrounding.hash(source))
        XCTAssertTrue(fixture.candidate.blocks.contains {
            $0.text == SourcePilotPlan.disclosure(for: .wikipediaOpeningExcerpt)
        })
        XCTAssertFalse(fixture.candidate.blocks.contains { $0.text == SourcePilotPlan.disclosure })

        let metadata = try XCTUnwrap(source.extractionMetadata)
        let locators = metadata.paragraphLocators
        var variants: [RetrievedResearchSource] = [
            uncheckedSourceCopy(source, scope: .wikipediaIntroduction, metadata: metadata),
            uncheckedSourceCopy(source, metadata: nil),
            uncheckedSourceCopy(source, metadata: .init(extractionVersion: "wikipedia-opening-paragraphs-v2",
                paragraphLocators: locators))
        ]
        for changedLocator: RetrievedResearchSource.ParagraphLocator in [
            .init(sectionAnchor: "Changed_anchor", sectionTitle: locators[1].sectionTitle, paragraphIndex: 1),
            .init(sectionAnchor: locators[1].sectionAnchor, sectionTitle: "Changed section", paragraphIndex: 1),
            .init(sectionAnchor: locators[1].sectionAnchor, sectionTitle: locators[1].sectionTitle, paragraphIndex: 2)
        ] {
            var changedLocators = locators
            changedLocators[1] = changedLocator
            let changed = uncheckedSourceCopy(source, metadata: .init(extractionVersion: metadata.extractionVersion,
                paragraphLocators: changedLocators))
            if changedLocator.paragraphIndex == 1 {
                XCTAssertNoThrow(try SourceGrounding.validateSource(changed), "Valid metadata changes must exercise receipt binding, not just structural rejection")
                XCTAssertNoThrow(try JSONDecoder().decode(RetrievedResearchSource.self, from: JSONEncoder().encode(changed)))
            }
            variants.append(changed)
        }
        variants.append(uncheckedSourceCopy(source, metadata: .init(extractionVersion: metadata.extractionVersion,
            paragraphLocators: Array(locators.reversed()))))
        for changed in variants {
            XCTAssertEqual(changed.text, source.text, "Metadata-only mutation leaves quoted evidence bytes unchanged")
            XCTAssertEqual(changed.textSHA256, source.textSHA256)
            XCTAssertNotEqual(try SourceGrounding.hash(changed), receipt.sourceHash)
            let requirement = SourceGroundingRequirement(source: changed, outlineRevisionID: fixture.outlineID,
                outlineContentHash: fixture.requirement.outlineContentHash,
                approvedBriefHash: fixture.requirement.approvedBriefHash)
            XCTAssertThrowsError(try SourceGrounding.validate(receipt: receipt, bookID: fixture.book.id,
                chapterID: fixture.chapterID, blocks: fixture.candidate.blocks, requirement: requirement))
        }
    }

    func testOpeningExcerptCannotIssueReceiptWithMissingMalformedOrUnknownExtractionMetadata() throws {
        let source = makeOpeningSource()
        let metadata = try XCTUnwrap(source.extractionMetadata)
        let locators = metadata.paragraphLocators
        var malformed: [RetrievedResearchSource.ExtractionMetadata?] = [
            nil,
            .init(extractionVersion: "unknown-extractor", paragraphLocators: locators),
            .init(extractionVersion: metadata.extractionVersion, paragraphLocators: []),
            .init(extractionVersion: metadata.extractionVersion, paragraphLocators: [locators[0]])
        ]
        for changedLocator: RetrievedResearchSource.ParagraphLocator in [
            .init(sectionAnchor: nil, sectionTitle: "", paragraphIndex: 1),
            .init(sectionAnchor: nil, sectionTitle: "Introduction", paragraphIndex: 0),
            .init(sectionAnchor: nil, sectionTitle: "Introduction", paragraphIndex: -1)
        ] {
            var changed = locators; changed[0] = changedLocator
            malformed.append(.init(extractionVersion: metadata.extractionVersion, paragraphLocators: changed))
        }
        var sources = malformed.map { uncheckedSourceCopy(source, metadata: $0) }
        for invalid in sources {
            let bytes = try JSONEncoder().encode(invalid)
            XCTAssertThrowsError(try JSONDecoder().decode(RetrievedResearchSource.self, from: bytes),
                "Malformed opening-excerpt metadata must also fail at the persistence decode boundary")
        }
        sources.append(uncheckedSourceCopy(source, scope: .wikipediaIntroduction, metadata: metadata))
        for invalid in sources {
            XCTAssertThrowsError(try SourceGrounding.validateSource(invalid))
            XCTAssertThrowsError(try makeFixture(source: invalid), "Invalid extraction metadata cannot produce an app-owned receipt")
        }
    }

    func testLegacyIntroductionWireHashAndReceiptRemainReadableWithoutExtractionMetadata() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // This DTO contains exactly the pre-excerpt source keys, independently of the new model's encoder.
        let legacyWire = try legacyIntroductionWire(makeSource())
        let legacyHash = SHA256.hash(data: legacyWire).map { String(format: "%02x", $0) }.joined()
        let decoded = try JSONCoding.decoder.decode(RetrievedResearchSource.self, from: legacyWire)
        XCTAssertEqual(decoded.scope, .wikipediaIntroduction)
        XCTAssertNil(decoded.extractionMetadata)
        XCTAssertEqual(try SourceGrounding.hash(decoded), legacyHash)
        let reencoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONCoding.encoder.encode(decoded)) as? [String: Any])
        XCTAssertNil(reencoded["extractionMetadata"], "Legacy nil metadata must stay omitted, not become an encoded default")
        var explicitNull = try XCTUnwrap(JSONSerialization.jsonObject(with: legacyWire) as? [String: Any])
        explicitNull["extractionMetadata"] = NSNull()
        let decodedNull = try JSONCoding.decoder.decode(RetrievedResearchSource.self,
            from: JSONSerialization.data(withJSONObject: explicitNull))
        XCTAssertEqual(try SourceGrounding.hash(decodedNull), legacyHash)

        let fixture = try makeFixture(source: decoded)
        let receipt = SourceReviewReceipt(bookID: fixture.book.id, chapterID: fixture.chapterID,
            baseRevisionID: fixture.outlineID, contentHash: try SourceGrounding.contentHash(fixture.candidate.blocks),
            sourceHash: legacyHash, model: "gpt-6-astra", promptVersion: "source-preview-1",
            reviewedAt: timestamp, response: supportedResponse())
        let oldReceipt = try JSONCoding.decoder.decode(SourceReviewReceipt.self, from: JSONCoding.encoder.encode(receipt))
        XCTAssertEqual(oldReceipt, receipt)
        XCTAssertNil(oldReceipt.wordCutHash)
        let receiptWire = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONCoding.encoder.encode(receipt)) as? [String: Any])
        XCTAssertNil(receiptWire["wordCutHash"], "An older introduction receipt must not acquire a continuation binding")
        XCTAssertNoThrow(try validate(oldReceipt, fixture: fixture))
        XCTAssertTrue(fixture.candidate.blocks.contains {
            $0.text == "AI-checked against one Wikipedia introduction, not independently fact-checked."
        })
        var candidate = fixture.candidate; candidate.sourceReview = oldReceipt
        let service = try ManuscriptVersioningService(rootDirectory: root)
        try await service.saveBook(fixture.book)
        try await service.stageCandidate(candidate)
        let published = try await service.activateCandidate(id: candidate.id)
        let reopened = try ManuscriptVersioningService(rootDirectory: root)
        let loaded = try await reopened.loadBook(id: fixture.book.id)
        XCTAssertNil(loaded?.chapters.first?.sourceGrounding?.source.extractionMetadata)
        let readable = try await reopened.readableRevision(bookId: fixture.book.id, chapterId: fixture.chapterID)
        XCTAssertEqual(readable.sourceReview?.sourceHash, legacyHash)
        XCTAssertEqual(readable.sourceReview?.promptVersion, "source-preview-1")
        let restored = try await reopened.restoreRevision(bookId: fixture.book.id, chapterId: fixture.chapterID,
            sourceRevisionId: published.id)
        XCTAssertEqual(restored.sourceReview?.sourceHash, legacyHash)
        XCTAssertEqual(restored.sourceReview?.promptVersion, "source-preview-1")
        XCTAssertEqual(restored.sourceReview?.response, oldReceipt.response)
    }

    func testBookGuideExposesExactRetainedSourceAndDeduplicatesSnapshots() throws {
        let fixture = try makeFixture()
        var book = fixture.book
        XCTAssertEqual(BookGuideContent(book: book).sources, [fixture.requirement.source])
        book.chapters.append(book.chapters[0])
        XCTAssertEqual(BookGuideContent(book: book).sources, [fixture.requirement.source])
        book.chapters = []
        XCTAssertTrue(BookGuideContent(book: book).sources.isEmpty)
    }

    func testProtectedPreviewDoesNotSpendAnAdaptationPlanningRequest() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeFixture()
        let versioning = try ManuscriptVersioningService(rootDirectory: root)
        try await versioning.saveBook(fixture.book)
        let ai = MockAIService()
        let service = LivingBookAdaptationService(versioning: versioning,
            feedbackStore: try FileFeedbackStore(rootDirectory: root),
            preferenceStore: try FileReaderPreferenceStore(rootDirectory: root), ai: ai)
        let feedback = ChapterFeedback(id: UUID(), bookId: fixture.book.id, chapterId: fixture.chapterID,
            revisionId: fixture.outlineID, overall: .fine, moreOf: [], lessOf: [],
            freeText: "More context", createdAt: timestamp)
        do {
            _ = try await service.submitFeedbackAndPlan(book: fixture.book, feedback: feedback)
            XCTFail("Source preview must not buy an unpublishable adaptation plan")
        } catch {
            XCTAssertTrue(error is SourceGroundingError)
        }
        XCTAssertEqual(ai.totalCallCount, 0)
        let book = try await versioning.loadBook(id: fixture.book.id)
        XCTAssertEqual(book?.chapters.first?.revisions.count, 1)
    }

    func testCorrectReceiptBindsExactSourceBookChapterAndBase() throws {
        let fixture = try makeFixture()
        let receipt = try XCTUnwrap(fixture.candidate.sourceReview)
        XCTAssertNoThrow(try validate(receipt, fixture: fixture))
        XCTAssertEqual(receipt.contentHash, try SourceGrounding.contentHash(fixture.candidate.blocks))
        XCTAssertEqual(receipt.sourceHash, try SourceGrounding.hash(fixture.requirement.source))
        XCTAssertEqual(receipt.promptVersion, SourceGrounding.promptVersion)
        XCTAssertEqual(receipt.model, OpenAIModelOption.defaultGeneration.rawValue)
        XCTAssertEqual(receipt.response.units.count, 2)
        XCTAssertThrowsError(try SourceGrounding.validate(receipt: receipt, bookID: UUID(),
            chapterID: fixture.chapterID, blocks: fixture.candidate.blocks, requirement: fixture.requirement))
        XCTAssertThrowsError(try SourceGrounding.validate(receipt: receipt, bookID: fixture.book.id,
            chapterID: UUID(), blocks: fixture.candidate.blocks, requirement: fixture.requirement))
        XCTAssertThrowsError(try SourceGrounding.validate(receipt: receipt, bookID: fixture.book.id,
            chapterID: fixture.chapterID, blocks: fixture.candidate.blocks, requirement: fixture.requirement,
            baseRevisionID: UUID()))
        XCTAssertThrowsError(try validate(nil, fixture: fixture))
        for field in ["model", "promptVersion", "contentHash", "sourceHash"] {
            let changed: SourceReviewReceipt = try replacing(receipt, key: field, with: "forged")
            XCTAssertThrowsError(try validate(changed, fixture: fixture))
        }
    }

    func testIncompleteDuplicateExtraAndNegativeReviewCoverageCannotIssueReceipt() throws {
        let fixture = try makeFixture()
        let valid = supportedResponse()
        let invalid = [
            SourceReviewResponse(units: []),
            SourceReviewResponse(units: [valid.units[0]]),
            SourceReviewResponse(units: [valid.units[0], valid.units[0]]),
            SourceReviewResponse(units: valid.units + [.init(index: 2, assessment: .supported, quotes: [firstQuote])]),
            SourceReviewResponse(units: [.init(index: -1, assessment: .supported, quotes: [firstQuote]), valid.units[1]])
        ]
        for response in invalid {
            XCTAssertThrowsError(try issueReceipt(fixture: fixture, response: response))
            XCTAssertThrowsError(try validate(try receiptWithResponse(response, fixture: fixture), fixture: fixture))
        }
    }

    func testMissingInventedShortUnsupportedAndContradictoryQuotesCannotIssueReceipt() throws {
        let fixture = try makeFixture()
        let invalidUnits: [SourceReviewUnit] = [
            .init(index: 0, assessment: .supported, quotes: []),
            .init(index: 0, assessment: .supported, quotes: ["This quotation does not occur in the retained source."]),
            .init(index: 0, assessment: .supported, quotes: ["The"]),
            .init(index: 0, assessment: .supported, quotes: Array(repeating: firstQuote, count: 9)),
            .init(index: 0, assessment: .unsupported, quotes: [firstQuote]),
            .init(index: 0, assessment: .contradictory, quotes: [firstQuote])
        ]
        for unit in invalidUnits {
            let response = SourceReviewResponse(units: [unit, supportedResponse().units[1]])
            XCTAssertThrowsError(try issueReceipt(fixture: fixture, response: response))
            XCTAssertThrowsError(try validate(try receiptWithResponse(response, fixture: fixture), fixture: fixture))
        }
        XCTAssertThrowsError(try SourceGrounding.receipt(bookID: fixture.book.id, chapterID: fixture.chapterID,
            baseRevisionID: fixture.outlineID, blocks: fixture.candidate.blocks, source: fixture.requirement.source,
            model: "fixture-unapproved-reviewer", response: supportedResponse()))
    }

    func testWriterCannotOmitInventOrPreformatCitations() throws {
        let source = makeSource()
        let good = paragraphs()
        for citations in [[], ["other-source"], ["source1", "other-source"], ["source1", "source1"]] {
            let bad = [SourceDraftParagraph(text: good[0].text, citations: citations), good[1]]
            XCTAssertThrowsError(try SourceGrounding.blocks(title: "River Archive", paragraphs: bad, source: source))
        }
        XCTAssertThrowsError(try SourceGrounding.blocks(title: "River Archive", paragraphs: [good[0]], source: source))
        XCTAssertThrowsError(try SourceGrounding.blocks(title: "River Archive", paragraphs: [
            SourceDraftParagraph(text: good[0].text + " [1]", citations: ["source1"]), good[1]
        ], source: source))
    }

    func testBlockUUIDChangesPreserveContentAssessmentButTextKindOrderAndDisclosureChangesDoNot() throws {
        let fixture = try makeFixture()
        let original = fixture.candidate.blocks
        let freshIDs = original.map { ContentBlock(id: UUID(), kind: $0.kind, text: $0.text, orderIndex: $0.orderIndex) }
        XCTAssertEqual(try SourceGrounding.contentHash(original), try SourceGrounding.contentHash(freshIDs))
        XCTAssertNoThrow(try validate(fixture.candidate.sourceReview, fixture: fixture, blocks: freshIDs))
        var variants: [[ContentBlock]] = []
        var text = original; text[1].text += " An unsupported extra assertion."; variants.append(text)
        var kind = original; kind[1].kind = .quote; variants.append(kind)
        var order = original; order[1].orderIndex = 99; variants.append(order)
        var swapped = original; swapped.swapAt(1, 2); variants.append(swapped)
        var title = original; title[0].text = "Different historical subject"; variants.append(title)
        var disclosure = original; disclosure[disclosure.count - 2].text = "Independently verified."; variants.append(disclosure)
        var footer = original; footer[footer.count - 1].text += " Changed source."; variants.append(footer)
        for changed in variants {
            XCTAssertNotEqual(try SourceGrounding.contentHash(original), try SourceGrounding.contentHash(changed))
            XCTAssertThrowsError(try validate(fixture.candidate.sourceReview, fixture: fixture, blocks: changed))
        }
    }

    func testRetainedSourceTamperAndChangedSourceIdentityCannotReuseReceipt() throws {
        let fixture = try makeFixture()
        let source = fixture.requirement.source
        for field in ["text", "textSHA256", "revisionID", "canonicalURL", "attribution", "licenseName"] {
            let changed: RetrievedResearchSource = try replacing(source, key: field, with: field == "revisionID" ? 9002 : "tampered")
            let requirement = SourceGroundingRequirement(source: changed, outlineRevisionID: fixture.outlineID,
                outlineContentHash: fixture.requirement.outlineContentHash, approvedBriefHash: fixture.requirement.approvedBriefHash)
            XCTAssertThrowsError(try SourceGrounding.validate(receipt: fixture.candidate.sourceReview,
                bookID: fixture.book.id, chapterID: fixture.chapterID, blocks: fixture.candidate.blocks, requirement: requirement))
        }
        let changed = makeSource(text: source.text + " Additional retained material.")
        XCTAssertNoThrow(try SourceGrounding.validateSource(changed))
        let requirement = SourceGroundingRequirement(source: changed, outlineRevisionID: fixture.outlineID,
            outlineContentHash: fixture.requirement.outlineContentHash, approvedBriefHash: fixture.requirement.approvedBriefHash)
        XCTAssertThrowsError(try SourceGrounding.validate(receipt: fixture.candidate.sourceReview,
            bookID: fixture.book.id, chapterID: fixture.chapterID, blocks: fixture.candidate.blocks, requirement: requirement))
        XCTAssertThrowsError(try SourceGrounding.validateSource(makeSource(text: "Too little source text.")))
        XCTAssertThrowsError(try SourceGrounding.validateSource(makeSource(text: String(repeating: "word ", count: 1_601))))
    }

    func testValidPublicationReopensWithExactSourceAndAssessment() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeFixture()
        let service = try ManuscriptVersioningService(rootDirectory: root)
        try await service.saveBook(fixture.book)
        try await service.stageCandidate(fixture.candidate)
        let published = try await service.activateCandidate(id: fixture.candidate.id)
        let reopened = try ManuscriptVersioningService(rootDirectory: root)
        let book = try await reopened.loadBook(id: fixture.book.id)
        let chapter = try XCTUnwrap(book?.chapters.first)
        XCTAssertEqual(chapter.sourceGrounding, fixture.requirement)
        XCTAssertEqual(chapter.revisions.count, 2)
        XCTAssertEqual(chapter.activeRevisionId, published.id)
        XCTAssertEqual(chapter.activeRevision?.blocks, fixture.candidate.blocks)
        XCTAssertEqual(chapter.activeRevision?.sourceReview, fixture.candidate.sourceReview)
        let facts = try await reopened.packetStore.loadFactChecklist(bookId: fixture.book.id)
        XCTAssertTrue(facts.claims.isEmpty, "Source-support approval must not manufacture legacy verified claims")
    }

    func testFractionalRetrievalTimestampsDoNotInvalidatePublicationAfterPersistence() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeFixture(source: makeSource(date: timestamp.addingTimeInterval(0.375)))
        let service = try ManuscriptVersioningService(rootDirectory: root)
        try await service.saveBook(fixture.book)
        try await service.stageCandidate(fixture.candidate)
        _ = try await service.activateCandidate(id: fixture.candidate.id)
        let reopened = try ManuscriptVersioningService(rootDirectory: root)
        let book = try await reopened.loadBook(id: fixture.book.id)
        let chapter = try XCTUnwrap(book?.chapters.first)
        let requirement = try XCTUnwrap(chapter.sourceGrounding)
        let revision = try XCTUnwrap(chapter.activeRevision)
        XCTAssertEqual(try SourceGrounding.hash(requirement.source), fixture.candidate.sourceReview?.sourceHash)
        XCTAssertNoThrow(try SourceGrounding.validate(receipt: revision.sourceReview, bookID: fixture.book.id,
            chapterID: fixture.chapterID, blocks: revision.blocks, requirement: requirement))
    }

    func testMissingReviewAndAfterReviewTextMutationCannotActivate() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeFixture()
        let service = try ManuscriptVersioningService(rootDirectory: root)
        try await service.saveBook(fixture.book)
        let before = try Data(contentsOf: manuscriptURL(root: root, bookID: fixture.book.id))
        var missing = fixture.candidate; missing.id = UUID(); missing.sourceReview = nil
        var changed = fixture.candidate; changed.id = UUID(); changed.blocks[1].text += " Unreviewed claim."
        for candidate in [missing, changed] {
            try await service.stageCandidate(candidate)
            await expectFailure { _ = try await service.activateCandidate(id: candidate.id) }
            XCTAssertEqual(try Data(contentsOf: manuscriptURL(root: root, bookID: fixture.book.id)), before)
        }
    }

    func testStaleReceiptCannotActivateWhenCallerOmitsExpectedRevisionID() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeFixture()
        let service = try ManuscriptVersioningService(rootDirectory: root)
        try await service.saveBook(fixture.book)
        var stale = fixture.candidate; stale.id = UUID()
        try await service.stageCandidate(stale)
        try await service.stageCandidate(fixture.candidate)
        let published = try await service.activateCandidate(id: fixture.candidate.id)
        let before = try Data(contentsOf: manuscriptURL(root: root, bookID: fixture.book.id))
        await expectFailure { _ = try await service.activateCandidate(id: stale.id) }
        XCTAssertEqual(try Data(contentsOf: manuscriptURL(root: root, bookID: fixture.book.id)), before)
        let readable = try await service.readableRevision(bookId: fixture.book.id, chapterId: fixture.chapterID)
        XCTAssertEqual(readable.id, published.id)
    }

    func testDirectCreateRevisionCannotBypassReviewedActivation() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeFixture()
        let service = try ManuscriptVersioningService(rootDirectory: root)
        try await service.saveBook(fixture.book)
        let before = try Data(contentsOf: manuscriptURL(root: root, bookID: fixture.book.id))
        await expectFailure {
            _ = try await service.createRevision(bookId: fixture.book.id, chapterId: fixture.chapterID,
                blocks: fixture.candidate.blocks, origin: .adapted)
        }
        XCTAssertEqual(try Data(contentsOf: manuscriptURL(root: root, bookID: fixture.book.id)), before)
    }

    func testRawStoreCannotRemovePolicyDeletePointerChangeHistoryOrAppendUnreviewedText() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeFixture()
        let service = try ManuscriptVersioningService(rootDirectory: root)
        try await service.saveBook(fixture.book)
        try await service.stageCandidate(fixture.candidate)
        _ = try await service.activateCandidate(id: fixture.candidate.id)
        let raw = try FileManuscriptStore(directory: root.appendingPathComponent("Manuscripts"))
        let saved = try XCTUnwrap(raw.loadBook(id: fixture.book.id))
        let before = try Data(contentsOf: raw.bookURL(id: fixture.book.id))
        var variants: [Book] = []
        var policy = saved; policy.chapters[0].sourceGrounding = nil; variants.append(policy)
        var pointer = saved; pointer.chapters[0].activeRevisionId = nil; variants.append(pointer)
        var missingPointer = saved; missingPointer.chapters[0].activeRevisionId = UUID(); variants.append(missingPointer)
        var oldPointer = saved; oldPointer.chapters[0].activeRevisionId = fixture.outlineID; variants.append(oldPointer)
        var text = saved; text.chapters[0].revisions[0].blocks[0].text += " Replaced history."; variants.append(text)
        var index = saved; index.chapters[0].revisions[0].revisionIndex = 999; variants.append(index)
        var chapterIdentity = saved; chapterIdentity.chapters[0].revisions[0].chapterId = UUID(); variants.append(chapterIdentity)
        var historyDate = saved; historyDate.chapters[0].revisions[0].createdAt = timestamp.addingTimeInterval(60); variants.append(historyDate)
        var removed = saved; removed.chapters[0].revisions.removeFirst(); variants.append(removed)
        var missingChapter = saved; missingChapter.chapters = []; variants.append(missingChapter)
        var appended = saved
        let unreviewed = ChapterRevision(id: UUID(), chapterId: fixture.chapterID, revisionIndex: 999,
            createdAt: timestamp, blocks: fixture.candidate.blocks, isConsumed: false)
        appended.chapters[0].revisions.append(unreviewed)
        variants.append(appended) // Even an inactive unreviewed revision is forbidden.
        appended.chapters[0].activeRevisionId = unreviewed.id
        variants.append(appended)
        variants.append(fixture.book) // A stale whole-book save must not erase publication.
        for changed in variants {
            XCTAssertThrowsError(try raw.saveBook(changed))
            XCTAssertEqual(try Data(contentsOf: raw.bookURL(id: fixture.book.id)), before)
        }
        var metadata = saved; metadata.subtitle = "Metadata-only update"
        XCTAssertNoThrow(try raw.saveBook(metadata))
        XCTAssertEqual(try raw.loadBook(id: fixture.book.id)?.chapters, saved.chapters)
    }

    func testExactContentRestoreRebindsBaseWithoutInventingNewReview() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeFixture()
        let service = try ManuscriptVersioningService(rootDirectory: root)
        try await service.saveBook(fixture.book)
        try await service.stageCandidate(fixture.candidate)
        let first = try await service.activateCandidate(id: fixture.candidate.id)
        let second = try continuationCandidate(fixture: fixture, base: first)
        try await service.stageCandidate(second)
        let later = try await service.activateCandidate(id: second.id)
        let beforeRestore = try await service.loadBook(id: fixture.book.id)
        let original = try XCTUnwrap(beforeRestore?.chapters[0].revision(id: first.id))
        let restored = try await service.restoreRevision(bookId: fixture.book.id, chapterId: fixture.chapterID,
            sourceRevisionId: first.id)
        XCTAssertNotEqual(restored.id, first.id)
        XCTAssertNotEqual(restored.blocks.map(\.id), original.blocks.map(\.id))
        XCTAssertEqual(try SourceGrounding.contentHash(restored.blocks), try SourceGrounding.contentHash(original.blocks))
        XCTAssertEqual(restored.sourceReview?.baseRevisionID, later.id)
        XCTAssertEqual(restored.sourceReview?.reviewedAt, original.sourceReview?.reviewedAt)
        XCTAssertEqual(restored.sourceReview?.model, original.sourceReview?.model)
        XCTAssertEqual(restored.sourceReview?.response, original.sourceReview?.response)
        XCTAssertEqual(restored.sourceReview?.sourceHash, original.sourceReview?.sourceHash)
        let reopened = try ManuscriptVersioningService(rootDirectory: root)
        let readable = try await reopened.readableRevision(bookId: fixture.book.id, chapterId: fixture.chapterID)
        XCTAssertEqual(readable.id, restored.id)
        await expectFailure {
            _ = try await reopened.restoreRevision(bookId: fixture.book.id, chapterId: fixture.chapterID,
                sourceRevisionId: fixture.outlineID)
        }
        await expectFailure {
            try await reopened.consume(bookId: fixture.book.id, chapterId: fixture.chapterID, revisionId: first.id)
        }
        let emptyLedger = try await reopened.ledgerSnapshot()
        XCTAssertTrue(emptyLedger.isEmpty)
        try await reopened.consume(bookId: fixture.book.id, chapterId: fixture.chapterID, revisionId: restored.id)
        let consumed = try await reopened.retrieveConsumedRevision(bookId: fixture.book.id, chapterId: fixture.chapterID)
        XCTAssertEqual(consumed?.id, restored.id)
        XCTAssertEqual(consumed?.blocks, restored.blocks)
        await expectFailure {
            _ = try await reopened.restoreRevision(bookId: fixture.book.id, chapterId: fixture.chapterID, sourceRevisionId: first.id)
        }
    }

    func testBoundaryReviewedContinuationPublishesReopensAndRestoresItsOriginalAssessment() async throws {
        for source in [makeSource(), makeOpeningSource()] {
            let root = try temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let fixture = try makeFixture(source: source)
            let service = try ManuscriptVersioningService(rootDirectory: root)
            try await service.saveBook(fixture.book)
            try await service.stageCandidate(fixture.candidate)
            let first = try await service.activateCandidate(id: fixture.candidate.id)
            let candidate = try continuationCandidate(fixture: fixture, base: first)
            let cut = try XCTUnwrap(candidate.origin?.sourceWordCut)
            XCTAssertEqual(cut.baseRevisionID, first.id)
            XCTAssertEqual(candidate.sourceReview?.wordCutHash, try SourceGrounding.hash(cut))
            XCTAssertNil(first.sourceReview?.wordCutHash)
            XCTAssertNotEqual(candidate.sourceReview?.contentHash, first.sourceReview?.contentHash)
            XCTAssertEqual(candidate.sourceReview?.response.units.count,
                try SourceGrounding.prose(candidate.blocks, source: source).count)
            XCTAssertEqual(candidate.blocks[0], first.blocks[0])
            XCTAssertEqual(candidate.blocks[1].id, first.blocks[1].id)
            XCTAssertTrue(candidate.blocks[1].text.utf8.elementsEqual(first.blocks[1].text.utf8))
            XCTAssertEqual(Array(candidate.blocks.suffix(2)), Array(first.blocks.suffix(2)))
            try await service.stageCandidate(candidate)
            let continued = try await service.activateCandidate(id: candidate.id, expectedRevisionId: first.id)

            let reopened = try ManuscriptVersioningService(rootDirectory: root)
            let loaded = try await reopened.loadBook(id: fixture.book.id)
            let chapter = try XCTUnwrap(loaded?.chapters.first)
            XCTAssertEqual(chapter.activeRevisionId, continued.id)
            XCTAssertEqual(chapter.revisions.count, 3)
            XCTAssertEqual(chapter.sourceGrounding, fixture.requirement)
            XCTAssertEqual(try SourceGrounding.hash(chapter.revision(id: first.id)), try SourceGrounding.hash(first))
            XCTAssertEqual(chapter.activeRevision?.origin?.sourceWordCut, cut)
            XCTAssertEqual(chapter.activeRevision?.sourceReview, candidate.sourceReview)

            // Restore away from the continuation, then back to it. Its cut still
            // refers to the original base; only the receipt's current base changes.
            let originalRestore = try await reopened.restoreRevision(bookId: fixture.book.id,
                chapterId: fixture.chapterID, sourceRevisionId: first.id)
            let restored = try await reopened.restoreRevision(bookId: fixture.book.id,
                chapterId: fixture.chapterID, sourceRevisionId: continued.id)
            XCTAssertEqual(restored.origin?.kind, .restore)
            XCTAssertEqual(restored.origin?.restoredFromRevisionIndex, continued.revisionIndex)
            XCTAssertEqual(restored.origin?.sourceWordCut, cut)
            XCTAssertEqual(restored.sourceReview?.baseRevisionID, originalRestore.id)
            XCTAssertEqual(restored.sourceReview?.wordCutHash, candidate.sourceReview?.wordCutHash)
            XCTAssertEqual(restored.sourceReview?.reviewedAt, candidate.sourceReview?.reviewedAt)
            XCTAssertEqual(restored.sourceReview?.response, candidate.sourceReview?.response)
            XCTAssertEqual(restored.sourceReview?.model, candidate.sourceReview?.model)
            XCTAssertEqual(restored.sourceReview?.sourceHash, candidate.sourceReview?.sourceHash)
            XCTAssertEqual(try SourceGrounding.contentHash(restored.blocks), try SourceGrounding.contentHash(continued.blocks))
            XCTAssertNotEqual(restored.blocks.map(\.id), continued.blocks.map(\.id))
            let reopenedAgain = try ManuscriptVersioningService(rootDirectory: root)
            let readable = try await reopenedAgain.readableRevision(bookId: fixture.book.id, chapterId: fixture.chapterID)
            XCTAssertEqual(readable.id, restored.id)
            XCTAssertEqual(readable.origin?.sourceWordCut, cut)
            try await reopenedAgain.consume(bookId: fixture.book.id, chapterId: fixture.chapterID, revisionId: restored.id)
            let consumed = try await reopenedAgain.retrieveConsumedRevision(bookId: fixture.book.id, chapterId: fixture.chapterID)
            XCTAssertEqual(consumed?.blocks, restored.blocks)
            XCTAssertEqual(consumed?.sourceReview, restored.sourceReview)
        }
    }

    func testContinuationActivationRejectsMissingTamperedCutsAndOriginBypassesWithoutWrites() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeFixture(source: makeOpeningSource())
        let service = try ManuscriptVersioningService(rootDirectory: root)
        try await service.saveBook(fixture.book)
        try await service.stageCandidate(fixture.candidate)
        let first = try await service.activateCandidate(id: fixture.candidate.id)
        let valid = try continuationCandidate(fixture: fixture, base: first)
        let cut = try XCTUnwrap(valid.origin?.sourceWordCut)
        let receipt = try XCTUnwrap(valid.sourceReview)
        let noBinding: SourceReviewReceipt = try replacing(receipt, key: "wordCutHash", with: NSNull())
        var variants: [(String, CandidateRevision)] = []
        for origin: RevisionOrigin? in [nil, .generated(style: "Label cannot authorize replacement"),
            .regeneratedFromWord(word: cut.word, request: "Missing cut", frozenPrefixWordCount: 1),
            .restored(fromRevisionIndex: first.revisionIndex)] {
            var candidate = valid
            candidate.origin = origin
            candidate.sourceReview = noBinding
            variants.append(("missing cut with \(origin?.kind.rawValue ?? "nil") origin", candidate))
        }
        var missingHash = valid; missingHash.sourceReview = noBinding
        variants.append(("cut missing its receipt binding", missingHash))
        var wrongHash = valid
        wrongHash.sourceReview = try replacing(receipt, key: "wordCutHash", with: "different-cut")
        variants.append(("wrong receipt cut hash", wrongHash))
        let earlier = try XCTUnwrap(SourceGrounding.wordCut(base: first, blockID: cut.blockID,
            utf16Offset: 0, source: fixture.requirement.source))
        XCTAssertNotEqual(earlier.endUTF16, cut.endUTF16)
        var moved = valid; moved.origin?.sourceWordCut = earlier
        variants.append(("earlier valid cut with original receipt", moved))
        let cutMutations: [(String, Any)] = [("baseRevisionID", UUID().uuidString),
            ("blockID", UUID().uuidString), ("endUTF16", cut.endUTF16 - 1), ("word", "forged-word")]
        for (key, value) in cutMutations {
            let changed: SourceWordCut = try replacing(cut, key: key, with: value)
            var candidate = valid; candidate.origin?.sourceWordCut = changed
            // Rehashing the malformed cut must not evade reconstruction from the base.
            candidate.sourceReview = try replacing(receipt, key: "wordCutHash", with: SourceGrounding.hash(changed))
            variants.append(("malformed cut \(key) with matching hash", candidate))
        }
        var changedID = valid; changedID.blocks[1].id = UUID()
        XCTAssertEqual(try SourceGrounding.contentHash(changedID.blocks), receipt.contentHash)
        variants.append(("changed frozen block ID with valid text receipt", changedID))
        var changedPrefix = valid
        changedPrefix.blocks[1].text = changedPrefix.blocks[1].text.replacingOccurrences(of: "archive", with: "records")
        changedPrefix.sourceReview = try issueReceipt(fixture: fixture, response: receipt.response,
            blocks: changedPrefix.blocks, baseID: first.id, wordCut: cut)
        variants.append(("fresh text receipt cannot authorize changed prefix", changedPrefix))

        for (name, prepared) in variants {
            var candidate = prepared; candidate.id = UUID()
            try await service.stageCandidate(candidate)
            let urls = [manuscriptURL(root: root, bookID: fixture.book.id),
                root.appendingPathComponent("Candidates/\(candidate.id.uuidString).json"),
                root.appendingPathComponent("Ledger/consumed-ledger.json")]
            let before = try urls.map { try savedFileState($0) }
            await expectSavedSourceCorruption(expectsDecodeFailure: false, context: name) {
                _ = try await service.activateCandidate(id: candidate.id, expectedRevisionId: first.id)
            }
            XCTAssertEqual(try urls.map { try savedFileState($0) }, before, name)
        }
    }

    func testCopiedOldReviewCannotApproveChangedContinuationAfterBaseRebinding() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeFixture()
        let service = try ManuscriptVersioningService(rootDirectory: root)
        try await service.saveBook(fixture.book)
        try await service.stageCandidate(fixture.candidate)
        let first = try await service.activateCandidate(id: fixture.candidate.id)
        var candidate = try continuationCandidate(fixture: fixture, base: first)
        let old = try XCTUnwrap(first.sourceReview)
        candidate.sourceReview = try replacing(old, key: "baseRevisionID", with: first.id.uuidString)
        XCTAssertNotEqual(candidate.sourceReview?.contentHash, try SourceGrounding.contentHash(candidate.blocks))
        try await service.stageCandidate(candidate)
        let urls = [manuscriptURL(root: root, bookID: fixture.book.id),
            root.appendingPathComponent("Candidates/\(candidate.id.uuidString).json")]
        let before = try urls.map { try savedFileState($0) }
        await expectSavedSourceCorruption(expectsDecodeFailure: false, context: "copied first-publication assessment") {
            _ = try await service.activateCandidate(id: candidate.id)
        }
        XCTAssertEqual(try urls.map { try savedFileState($0) }, before)
    }

    func testRawSaveAndReopenRejectContinuationCutAndOriginTampering() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeFixture(source: makeOpeningSource())
        let service = try ManuscriptVersioningService(rootDirectory: root)
        try await service.saveBook(fixture.book)
        try await service.stageCandidate(fixture.candidate)
        let first = try await service.activateCandidate(id: fixture.candidate.id)
        let candidate = try continuationCandidate(fixture: fixture, base: first)
        try await service.stageCandidate(candidate)
        let continued = try await service.activateCandidate(id: candidate.id)
        let raw = try FileManuscriptStore(directory: root.appendingPathComponent("Manuscripts"))
        let saved = try XCTUnwrap(raw.loadBook(id: fixture.book.id))
        let index = try XCTUnwrap(saved.chapters[0].revisions.firstIndex { $0.id == continued.id })
        let cut = try XCTUnwrap(continued.origin?.sourceWordCut)
        let earlier = try XCTUnwrap(SourceGrounding.wordCut(base: first, blockID: cut.blockID,
            utf16Offset: 0, source: fixture.requirement.source))
        var variants: [(String, Book)] = []
        var noOrigin = saved; noOrigin.chapters[0].revisions[index].origin = nil
        variants.append(("removed continuation origin", noOrigin))
        var noCut = saved; noCut.chapters[0].revisions[index].origin?.sourceWordCut = nil
        variants.append(("removed cut only", noCut))
        var noHash = saved; noHash.chapters[0].revisions[index].sourceReview?.wordCutHash = nil
        variants.append(("removed receipt cut binding", noHash))
        var moved = saved; moved.chapters[0].revisions[index].origin?.sourceWordCut = earlier
        variants.append(("moved cut to earlier valid word", moved))
        for kind: RevisionOrigin.Kind in [.generated, .restore] {
            var changed = saved
            changed.chapters[0].revisions[index].origin = RevisionOrigin(kind: kind,
                summary: "An origin label cannot authorize changed historical text", restoredFromRevisionIndex: first.revisionIndex)
            changed.chapters[0].revisions[index].sourceReview?.wordCutHash = nil
            variants.append(("\(kind.rawValue) label with both cut fields omitted", changed))
        }
        var wrongID = saved; wrongID.chapters[0].revisions[index].blocks[1].id = UUID()
        variants.append(("same receipt text with changed frozen block ID", wrongID))
        var duplicateID = saved; duplicateID.chapters[0].revisions[index].id = first.id
        duplicateID.chapters[0].activeRevisionId = first.id
        variants.append(("duplicate revision ID", duplicateID))
        var duplicateIndex = saved; duplicateIndex.chapters[0].revisions[index].revisionIndex = first.revisionIndex
        variants.append(("duplicate revision index", duplicateIndex))
        var missingBase = saved; missingBase.chapters[0].revisions.removeAll { $0.id == first.id }
        variants.append(("missing reviewed base", missingBase))

        let url = raw.bookURL(id: fixture.book.id)
        let validBytes = try Data(contentsOf: url)
        for (name, changed) in variants {
            let beforeSave = try savedFileState(url)
            XCTAssertThrowsError(try raw.saveBook(changed), name) { XCTAssertTrue($0 is SourceGroundingError, name) }
            XCTAssertEqual(try savedFileState(url), beforeSave, name)
            // Test persisted validation independently of the previous-history comparison.
            // Only authored bytes in this test's own temporary directory are replaced.
            try AtomicFileWriter.writeAtomically(JSONCoding.encoder.encode(changed), to: url)
            let badBytes = try savedFileState(url)
            let reopened = try ManuscriptVersioningService(rootDirectory: root)
            await expectSavedSourceCorruption(expectsDecodeFailure: false, context: name) {
                _ = try await reopened.loadBook(id: fixture.book.id)
            }
            await expectSavedSourceCorruption(expectsDecodeFailure: false, context: name) {
                _ = try await reopened.readableRevision(bookId: fixture.book.id, chapterId: fixture.chapterID)
            }
            XCTAssertEqual(try savedFileState(url), badBytes, "Rejection must preserve corrupt evidence: \(name)")
            try AtomicFileWriter.writeAtomically(validBytes, to: url)
        }
        XCTAssertEqual(try raw.loadBook(id: fixture.book.id), saved)
    }

    func testRawSaveRejectsInactiveUnboundContinuationAndSelfAuthorizingExtraHistory() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeFixture()
        let service = try ManuscriptVersioningService(rootDirectory: root)
        try await service.saveBook(fixture.book)
        try await service.stageCandidate(fixture.candidate)
        let first = try await service.activateCandidate(id: fixture.candidate.id)
        let valid = try continuationCandidate(fixture: fixture, base: first)
        let raw = try FileManuscriptStore(directory: root.appendingPathComponent("Manuscripts"))
        let saved = try XCTUnwrap(raw.loadBook(id: fixture.book.id))
        let before = try savedFileState(raw.bookURL(id: fixture.book.id))
        var unbound = valid
        unbound.origin = nil
        unbound.sourceReview?.wordCutHash = nil
        let inactive = appending(unbound, to: saved, makeActive: false)
        XCTAssertEqual(inactive.chapters[0].activeRevisionId, first.id)
        XCTAssertThrowsError(try raw.saveBook(inactive)) { XCTAssertTrue($0 is SourceGroundingError) }
        XCTAssertThrowsError(try SourceGrounding.validateSave(inactive, previous: nil))
        XCTAssertEqual(try savedFileState(raw.bookURL(id: fixture.book.id)), before)

        let firstAppend = appending(valid, to: saved)
        let appendedRevision = try XCTUnwrap(firstAppend.chapters[0].activeRevision)
        var secondAppend = valid
        secondAppend.id = UUID()
        secondAppend.proposedRevisionIndex = appendedRevision.revisionIndex + 1
        secondAppend.origin = RevisionOrigin(kind: .restore, summary: "Cannot authorize two additions in one save",
            restoredFromRevisionIndex: appendedRevision.revisionIndex, sourceWordCut: valid.origin?.sourceWordCut)
        secondAppend.sourceReview = try replacing(try XCTUnwrap(valid.sourceReview), key: "baseRevisionID",
            with: appendedRevision.id.uuidString)
        let twoAdditions = appending(secondAppend, to: firstAppend)
        // The complete chain is structurally valid, but both additions are new to this save.
        XCTAssertNoThrow(try SourceGrounding.validateSave(twoAdditions, previous: nil))
        XCTAssertThrowsError(try raw.saveBook(twoAdditions)) { XCTAssertTrue($0 is SourceGroundingError) }
        XCTAssertEqual(try savedFileState(raw.bookURL(id: fixture.book.id)), before)
    }

    func testStaleAndConsumedContinuationPreserveSavedTextAndConsumedLedger() async throws {
        for consumed in [false, true] {
            let root = try temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let fixture = try makeFixture(source: makeOpeningSource())
            let service = try ManuscriptVersioningService(rootDirectory: root)
            try await service.saveBook(fixture.book)
            try await service.stageCandidate(fixture.candidate)
            let first = try await service.activateCandidate(id: fixture.candidate.id)
            let candidate = try continuationCandidate(fixture: fixture, base: first)
            try await service.stageCandidate(candidate)
            if consumed {
                try await service.consume(bookId: fixture.book.id, chapterId: fixture.chapterID, revisionId: first.id)
            } else {
                let winner = try continuationCandidate(fixture: fixture, base: first, variant: 1)
                try await service.stageCandidate(winner)
                _ = try await service.activateCandidate(id: winner.id, expectedRevisionId: first.id)
            }
            let raw = try FileManuscriptStore(directory: root.appendingPathComponent("Manuscripts"))
            let saved = try XCTUnwrap(raw.loadBook(id: fixture.book.id))
            let candidateURL = root.appendingPathComponent("Candidates/\(candidate.id.uuidString).json")
            let urls = [raw.bookURL(id: fixture.book.id), root.appendingPathComponent("Ledger/consumed-ledger.json")]
            let before = try urls.map { try savedFileState($0) }
            let stagedBefore = try savedFileState(candidateURL)
            if consumed {
                let append = appending(candidate, to: saved)
                var clear = saved
                let index = try XCTUnwrap(clear.chapters[0].revisions.firstIndex { $0.id == first.id })
                XCTAssertTrue(clear.chapters[0].revisions[index].isConsumed)
                clear.chapters[0].revisions[index].isConsumed = false
                let clearAndAppend = appending(candidate, to: clear)
                for changed in [append, clear, clearAndAppend] {
                    XCTAssertThrowsError(try raw.saveBook(changed)) { XCTAssertTrue($0 is SourceGroundingError) }
                    XCTAssertEqual(try urls.map { try savedFileState($0) }, before)
                    XCTAssertEqual(try savedFileState(candidateURL), stagedBefore)
                }
                do {
                    _ = try await service.activateCandidate(id: candidate.id, expectedRevisionId: first.id)
                    XCTFail("A continuation cannot replace a chapter consumed after staging")
                } catch ManuscriptError.cannotMutateConsumedChapter(let id) {
                    XCTAssertEqual(id, fixture.chapterID)
                } catch {
                    XCTFail("Expected the consumed-chapter guard, got \(error)")
                }
                let rejected = try JSONCoding.decoder.decode(CandidateRevision.self, from: Data(contentsOf: candidateURL))
                XCTAssertEqual(rejected.blocks, candidate.blocks)
                XCTAssertEqual(rejected.sourceReview, candidate.sourceReview)
                XCTAssertEqual(rejected.origin, candidate.origin)
                let pinned = try await service.retrieveConsumedRevision(bookId: fixture.book.id, chapterId: fixture.chapterID)
                XCTAssertEqual(pinned?.id, first.id)
                XCTAssertEqual(pinned?.blocks, first.blocks)
            } else {
                await expectSavedSourceCorruption(expectsDecodeFailure: false, context: "stale continuation without caller expected-ID") {
                    _ = try await service.activateCandidate(id: candidate.id)
                }
                XCTAssertEqual(try savedFileState(candidateURL), stagedBefore)
            }
            XCTAssertEqual(try urls.map { try savedFileState($0) }, before)
            let reopened = try ManuscriptVersioningService(rootDirectory: root)
            let readable = try await reopened.readableRevision(bookId: fixture.book.id, chapterId: fixture.chapterID)
            XCTAssertEqual(readable.id, saved.chapters[0].activeRevisionId)
        }
    }

    func testMidParagraphContinuationPublishesOnlyAfterReviewCoversTheJoinedParagraph() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeFixture(source: makeOpeningSource())
        let service = try ManuscriptVersioningService(rootDirectory: root)
        try await service.saveBook(fixture.book)
        try await service.stageCandidate(fixture.candidate)
        let first = try await service.activateCandidate(id: fixture.candidate.id)
        let selected = first.blocks[1]
        let offset = (selected.text as NSString).range(of: "boats").location
        XCTAssertNotEqual(offset, NSNotFound)
        let cut = try XCTUnwrap(SourceGrounding.wordCut(base: first, blockID: selected.id,
            utf16Offset: offset, source: fixture.requirement.source))
        XCTAssertLessThan(cut.endUTF16, (String(selected.text.dropLast(4)) as NSString).length)
        let joinedTail = "recording harvests, and maintaining meeting records for exchanges between nearby settlements. "
            + Array(repeating: firstQuote, count: 5).joined(separator: " ")
        let blocks = try SourceGrounding.assembleContinuation(base: first, cut: cut, paragraphs: [
            .init(text: joinedTail, citations: ["source1"]), paragraphs()[1]
        ], source: fixture.requirement.source)
        let frozenBytes = (selected.text as NSString).substring(to: cut.endUTF16).utf8
        XCTAssertTrue(blocks[1].text.utf8.starts(with: frozenBytes))
        XCTAssertEqual(blocks[1].id, selected.id)
        XCTAssertNotEqual(blocks[1].text, selected.text)
        XCTAssertEqual(blocks[0], first.blocks[0])
        XCTAssertEqual(Array(blocks.suffix(2)), Array(first.blocks.suffix(2)))
        let assembledProse = try SourceGrounding.prose(blocks, source: fixture.requirement.source)
        XCTAssertEqual(assembledProse.count, 2)
        let complete = supportedResponse()
        let missingJoin = SourceReviewResponse(units: [complete.units[1]])
        XCTAssertThrowsError(try issueReceipt(fixture: fixture, response: missingJoin,
            blocks: blocks, baseID: first.id, wordCut: cut))
        let review = try issueReceipt(fixture: fixture, response: complete, blocks: blocks,
            baseID: first.id, wordCut: cut)
        var candidate = CandidateRevision(id: UUID(), bookId: fixture.book.id, chapterId: fixture.chapterID,
            proposedRevisionIndex: first.revisionIndex + 1, createdAt: timestamp,
            blocks: blocks, status: .staged, rejectionReason: nil,
            origin: RevisionOrigin(kind: .regenerateFromWord, summary: "Mid-paragraph authored continuation",
                anchorWord: cut.word, sourceWordCut: cut), sourceReview: review)
        let saved = try await service.loadBook(id: fixture.book.id)
        let chapter = try XCTUnwrap(saved?.chapters.first)
        XCTAssertNoThrow(try SourceGrounding.validateTransition(receipt: review, origin: candidate.origin,
            blocks: blocks, bookID: fixture.book.id, chapter: chapter, history: chapter.revisions))

        // Bypass receipt issuance only inside this authored fixture to ensure
        // publication also rejects a review that omitted the joined paragraph.
        var incomplete = candidate; incomplete.id = UUID()
        incomplete.sourceReview = SourceReviewReceipt(bookID: review.bookID, chapterID: review.chapterID,
            baseRevisionID: review.baseRevisionID, contentHash: review.contentHash, sourceHash: review.sourceHash,
            model: review.model, promptVersion: review.promptVersion, reviewedAt: review.reviewedAt,
            response: missingJoin, wordCutHash: review.wordCutHash)
        try await service.stageCandidate(incomplete)
        let urls = [manuscriptURL(root: root, bookID: fixture.book.id),
            root.appendingPathComponent("Candidates/\(incomplete.id.uuidString).json")]
        let before = try urls.map { try savedFileState($0) }
        await expectSavedSourceCorruption(expectsDecodeFailure: false, context: "independent review omitted joined paragraph") {
            _ = try await service.activateCandidate(id: incomplete.id)
        }
        XCTAssertEqual(try urls.map { try savedFileState($0) }, before)

        candidate.id = UUID()
        try await service.stageCandidate(candidate)
        let published = try await service.activateCandidate(id: candidate.id, expectedRevisionId: first.id)
        let reopened = try ManuscriptVersioningService(rootDirectory: root)
        let readable = try await reopened.readableRevision(bookId: fixture.book.id, chapterId: fixture.chapterID)
        XCTAssertEqual(readable.id, published.id)
        XCTAssertEqual(readable.blocks, blocks)
        XCTAssertEqual(readable.sourceReview, review)
        XCTAssertEqual(readable.origin?.sourceWordCut, cut)
        XCTAssertTrue(readable.blocks[1].text.utf8.starts(with: frozenBytes))
    }

    func testSourceReceiptDoesNotOverrideLegacyUnverifiedEssentialClaim() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeFixture()
        let packets = try FilePEPacketStore(rootDirectory: root)
        let claim = FactClaim(chapterId: fixture.chapterID, statement: "A legacy essential obligation.",
            importance: .essential, status: .unverified, evidenceIds: ["legacy-source"])
        let facts = FactChecklist(bookId: fixture.book.id, claims: [claim], evidence: [
            FactEvidenceItem(id: "legacy-source", sourceLabel: "Authored fixture", digest: firstQuote)
        ], updatedAt: timestamp)
        try packets.saveFactChecklist(facts)
        let service = try ManuscriptVersioningService(rootDirectory: root, packets: packets)
        try await service.saveBook(fixture.book)
        try await service.stageCandidate(fixture.candidate)
        await expectFailure { _ = try await service.activateCandidate(id: fixture.candidate.id) }
        XCTAssertEqual(try packets.loadFactChecklist(bookId: fixture.book.id).claims.first?.status, .unverified)
        let readable = try await service.readableRevision(bookId: fixture.book.id, chapterId: fixture.chapterID)
        XCTAssertEqual(readable.id, fixture.outlineID)
    }

    func testRawSavedProseOrReceiptCorruptionRefusesReopenIncludingConsumedWhileLegacyStillReads() async throws {
        for consumed in [false, true] {
            for mutation in ["text", "missing-review", "source-hash"] {
                let root = try temporaryRoot()
                defer { try? FileManager.default.removeItem(at: root) }
                let fixture = try makeFixture()
                let service = try ManuscriptVersioningService(rootDirectory: root)
                try await service.saveBook(fixture.book)
                try await service.stageCandidate(fixture.candidate)
                let published = try await service.activateCandidate(id: fixture.candidate.id)
                if consumed {
                    try await service.consume(bookId: fixture.book.id, chapterId: fixture.chapterID, revisionId: published.id)
                }
                var legacy = fixture.book
                legacy.id = UUID()
                legacy.title = "Unrelated legacy book"
                legacy.chapters[0].bookId = legacy.id
                legacy.chapters[0].sourceGrounding = nil
                try await service.saveBook(legacy)

                // Deliberate corruption only inside this test's UUID-named temporary
                // directory: bypass saveBook to exercise persisted-read validation.
                let url = manuscriptURL(root: root, bookID: fixture.book.id)
                var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
                var chapters = try XCTUnwrap(object["chapters"] as? [[String: Any]])
                var revisions = try XCTUnwrap(chapters[0]["revisions"] as? [[String: Any]])
                let index = try XCTUnwrap(revisions.firstIndex { ($0["id"] as? String) == published.id.uuidString })
                if mutation == "text" {
                    var blocks = try XCTUnwrap(revisions[index]["blocks"] as? [[String: Any]])
                    blocks[1]["text"] = "Unreviewed replacement prose retaining the old source marker. [1]"
                    revisions[index]["blocks"] = blocks
                } else if mutation == "missing-review" {
                    revisions[index].removeValue(forKey: "sourceReview")
                } else {
                    var receipt = try XCTUnwrap(revisions[index]["sourceReview"] as? [String: Any])
                    receipt["sourceHash"] = "corrupted-source-fingerprint"
                    revisions[index]["sourceReview"] = receipt
                }
                chapters[0]["revisions"] = revisions
                object["chapters"] = chapters
                try AtomicFileWriter.writeAtomically(JSONSerialization.data(withJSONObject: object), to: url)

                let reopened = try ManuscriptVersioningService(rootDirectory: root)
                await expectFailure { _ = try await reopened.loadBook(id: fixture.book.id) }
                await expectFailure {
                    _ = try await reopened.readableRevision(bookId: fixture.book.id, chapterId: fixture.chapterID)
                }
                if consumed {
                    await expectFailure {
                        _ = try await reopened.retrieveConsumedRevision(bookId: fixture.book.id, chapterId: fixture.chapterID)
                    }
                }
                let readableLegacy = try await reopened.readableRevision(bookId: legacy.id, chapterId: legacy.chapters[0].id)
                XCTAssertEqual(readableLegacy.blocks, legacy.chapters[0].activeRevision?.blocks)
            }
        }
    }

    @MainActor
    func testLibraryIsolatesCorruptPublishedSourceWhileStrictOperationsPreserveAllSavedBytes() async throws {
        for scope: RetrievedResearchSource.Scope in [.wikipediaIntroduction, .wikipediaOpeningExcerpt] {
            for consumed in [false, true] {
                let mutations = ["text", "missing-review", "source-hash", "malformed-json"]
                    + (scope == .wikipediaOpeningExcerpt ? ["locators"] : [])
                for mutation in mutations {
                    let context = "\(scope.rawValue), consumed=\(consumed), mutation=\(mutation)"
                    let root = try temporaryRoot()
                    defer { try? FileManager.default.removeItem(at: root) }
                    let source = scope == .wikipediaOpeningExcerpt ? makeOpeningSource() : makeSource()
                    let fixture = try makeFixture(source: source)
                    let service = try ManuscriptVersioningService(rootDirectory: root)
                    try await service.saveBook(fixture.book)
                    try await service.stageCandidate(fixture.candidate)
                    let published = try await service.activateCandidate(id: fixture.candidate.id)

                    // A new, reviewed candidate is valid for the CURRENT published base.
                    // Reusing the original activated candidate would make rejection pass for the wrong reason.
                    let next = try continuationCandidate(fixture: fixture, base: published)
                    try SourceGrounding.validate(receipt: next.sourceReview, bookID: fixture.book.id,
                        chapterID: fixture.chapterID, blocks: next.blocks, requirement: fixture.requirement,
                        baseRevisionID: published.id)
                    try await service.stageCandidate(next)
                    if consumed {
                        try await service.consume(bookId: fixture.book.id, chapterId: fixture.chapterID,
                            revisionId: published.id)
                    }

                    let healthy = try makeFixture()
                    try await service.saveBook(healthy.book)
                    try await service.stageCandidate(healthy.candidate)
                    let healthyRevision = try await service.activateCandidate(id: healthy.candidate.id)
                    let raw = try FileManuscriptStore(directory: root.appendingPathComponent("Manuscripts"))
                    let cachedValid = try XCTUnwrap(raw.loadBook(id: fixture.book.id))
                    let badURL = raw.bookURL(id: fixture.book.id)
                    let candidateURL = root.appendingPathComponent("Candidates/\(next.id.uuidString).json")
                    let staged = try JSONCoding.decoder.decode(CandidateRevision.self, from: Data(contentsOf: candidateURL))
                    XCTAssertEqual(staged.status, .staged, context)
                    XCTAssertEqual(staged.sourceReview?.baseRevisionID, published.id, context)
                    let drafts = try FileCreateBookDraftStore(rootDirectory: root)
                    var savedDraft = CreateBookDraft.blank(id: fixture.book.id, at: timestamp)
                    savedDraft.path = .generate
                    savedDraft.title = fixture.book.title
                    try drafts.save(savedDraft)

                    try corruptSavedSource(at: badURL, revisionID: published.id, mutation: mutation)
                    let watchedURLs = [badURL, raw.bookURL(id: healthy.book.id), candidateURL,
                        root.appendingPathComponent("Ledger/consumed-ledger.json"),
                        drafts.directory.appendingPathComponent("\(fixture.book.id.uuidString).json")]
                    let unchanged = try watchedURLs.map { try savedFileState($0) }
                    func assertUnchanged(file: StaticString = #filePath, line: UInt = #line) throws {
                        XCTAssertEqual(try watchedURLs.map { try savedFileState($0) }, unchanged,
                            "Corruption isolation must not rewrite manuscripts, ledger, candidate, or saved draft: \(context)", file: file, line: line)
                    }

                    let snapshot = try raw.loadLibrarySnapshot()
                    XCTAssertEqual(Set(snapshot.books.map(\.id)), Set([healthy.book.id]), context)
                    XCTAssertEqual(snapshot.issues.count, 1, context)
                    let issue = try XCTUnwrap(snapshot.issues.first)
                    XCTAssertEqual(issue.filename, badURL.lastPathComponent, context)
                    XCTAssertEqual(issue.bookID, fixture.book.id, context)
                    XCTAssertFalse(issue.reason.isEmpty, context)
                    try assertUnchanged()

                    let reopened = try ManuscriptVersioningService(rootDirectory: root)
                    let forwarded = try await reopened.loadLibrarySnapshot()
                    XCTAssertEqual(Set(forwarded.books.map(\.id)), Set([healthy.book.id]), context)
                    XCTAssertEqual(forwarded.issues.map(\.filename), [badURL.lastPathComponent], context)
                    try assertUnchanged()

                    let ai = MockAIService()
                    let library = LibraryViewModel(ai: ai, rootDirectory: root)
                    await library.load()
                    XCTAssertNil(library.loadError, context)
                    XCTAssertTrue(library.books.contains { $0.id == healthy.book.id }, context)
                    XCTAssertFalse(library.books.contains { $0.id == fixture.book.id }, context)
                    XCTAssertFalse(library.resumableBookIDs.contains(fixture.book.id), context)
                    XCTAssertEqual(ai.totalCallCount, 0, context)
                    let readable = try await reopened.readableRevision(bookId: healthy.book.id,
                        chapterId: healthy.chapterID)
                    XCTAssertEqual(readable.id, healthyRevision.id, context)
                    XCTAssertEqual(readable.blocks, healthyRevision.blocks, context)
                    try assertUnchanged()

                    let expectsDecodeFailure = mutation == "malformed-json" || mutation == "locators"
                    let operations: [() async throws -> Void] = [
                        { _ = try raw.loadBook(id: fixture.book.id) },
                        { _ = try await reopened.loadBook(id: fixture.book.id) },
                        { _ = try await reopened.readableRevision(bookId: fixture.book.id, chapterId: fixture.chapterID) },
                        { try raw.saveBook(cachedValid) },
                        { try await reopened.saveBook(cachedValid) },
                        { _ = try await reopened.activateCandidate(id: next.id, expectedRevisionId: published.id) }
                    ]
                    for operation in operations {
                        await expectSavedSourceCorruption(expectsDecodeFailure: expectsDecodeFailure,
                            context: context, operation)
                        try assertUnchanged()
                    }
                    if consumed {
                        await expectSavedSourceCorruption(expectsDecodeFailure: expectsDecodeFailure, context: context) {
                            _ = try await reopened.retrieveConsumedRevision(bookId: fixture.book.id,
                                chapterId: fixture.chapterID)
                        }
                        try assertUnchanged()
                    }
                }
            }
        }
    }

    func testCaseOnlyNoncanonicalManuscriptNamesCannotBeReadSavedOrActivated() async throws {
        let bookID = try XCTUnwrap(UUID(uuidString: "ABCDEF12-ABCD-4ABC-8DEF-ABCDEF123456"))
        let aliases = [bookID.uuidString.lowercased() + ".json", bookID.uuidString + ".JSON"]
        for alias in aliases {
            let root = try temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let fixture = try makeFixture(source: makeOpeningSource(), bookID: bookID)
            let service = try ManuscriptVersioningService(rootDirectory: root)
            try await service.saveBook(fixture.book)
            try await service.stageCandidate(fixture.candidate)
            let published = try await service.activateCandidate(id: fixture.candidate.id)
            let next = try continuationCandidate(fixture: fixture, base: published)
            try SourceGrounding.validate(receipt: next.sourceReview, bookID: bookID,
                chapterID: fixture.chapterID, blocks: next.blocks, requirement: fixture.requirement,
                baseRevisionID: published.id)
            try await service.stageCandidate(next)

            let directory = root.appendingPathComponent("Manuscripts")
            let raw = try FileManuscriptStore(directory: directory)
            let cachedValid = try XCTUnwrap(raw.loadBook(id: bookID))
            let canonicalURL = raw.bookURL(id: bookID)
            let originalBytes = try Data(contentsOf: canonicalURL)
            let aliasURL = directory.appendingPathComponent(alias)
            let temporaryURL = directory.appendingPathComponent("case-swap-\(UUID().uuidString).tmp")
            // An intermediate name forces the directory entry's spelling to change on case-insensitive APFS.
            try FileManager.default.moveItem(at: canonicalURL, to: temporaryURL)
            try FileManager.default.moveItem(at: temporaryURL, to: aliasURL)
            XCTAssertEqual(try Data(contentsOf: aliasURL), originalBytes, alias)
            let candidateURL = root.appendingPathComponent("Candidates/\(next.id.uuidString).json")
            let staged = try JSONCoding.decoder.decode(CandidateRevision.self, from: Data(contentsOf: candidateURL))
            XCTAssertEqual(staged.status, .staged, alias)
            XCTAssertEqual(staged.sourceReview?.baseRevisionID, published.id, alias)
            let watchedURLs = [aliasURL, candidateURL, root.appendingPathComponent("Ledger/consumed-ledger.json")]
            let unchanged = try watchedURLs.map { try savedFileState($0) }
            func assertUnchanged(file: StaticString = #filePath, line: UInt = #line) throws {
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [alias],
                    "The actual saved filename must remain unchanged", file: file, line: line)
                XCTAssertEqual(try watchedURLs.map { try savedFileState($0) }, unchanged,
                    "Identity rejection must preserve manuscript, candidate, and ledger bytes and modification dates",
                    file: file, line: line)
            }
            try assertUnchanged()

            let reopened = try ManuscriptVersioningService(rootDirectory: root)
            let rawSnapshot = try raw.loadLibrarySnapshot()
            let serviceSnapshot = try await reopened.loadLibrarySnapshot()
            for snapshot in [rawSnapshot, serviceSnapshot] {
                XCTAssertTrue(snapshot.books.isEmpty, alias)
                XCTAssertEqual(snapshot.issues.count, 1, alias)
                let issue = try XCTUnwrap(snapshot.issues.first)
                XCTAssertEqual(issue.filename, alias, alias)
                XCTAssertEqual(issue.bookID, bookID, alias)
                XCTAssertFalse(issue.reason.isEmpty, alias)
            }
            try assertUnchanged()
            let operations: [() async throws -> Void] = [
                { _ = try raw.loadBook(id: bookID) },
                { _ = try await reopened.loadBook(id: bookID) },
                { _ = try await reopened.readableRevision(bookId: bookID, chapterId: fixture.chapterID) },
                { try raw.saveBook(cachedValid) },
                { try await reopened.saveBook(cachedValid) },
                { _ = try await reopened.activateCandidate(id: next.id, expectedRevisionId: published.id) }
            ]
            for operation in operations {
                await expectSavedSourceCorruption(expectsDecodeFailure: true, context: alias, operation)
                try assertUnchanged()
            }
        }
    }

    // MARK: - Local authored fixtures

    private struct SavedFileState: Equatable {
        let data: Data?
        let modifiedAt: Date?
    }

    private func savedFileState(_ url: URL) throws -> SavedFileState {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return SavedFileState(data: nil, modifiedAt: nil)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return SavedFileState(data: try Data(contentsOf: url), modifiedAt: attributes[.modificationDate] as? Date)
    }

    private func corruptSavedSource(at url: URL, revisionID: UUID, mutation: String) throws {
        if mutation == "malformed-json" {
            try AtomicFileWriter.writeAtomically(Data("not a manuscript".utf8), to: url)
            return
        }
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var chapters = try XCTUnwrap(object["chapters"] as? [[String: Any]])
        if mutation == "locators" {
            var requirement = try XCTUnwrap(chapters[0]["sourceGrounding"] as? [String: Any])
            var source = try XCTUnwrap(requirement["source"] as? [String: Any])
            var metadata = try XCTUnwrap(source["extractionMetadata"] as? [String: Any])
            metadata["paragraphLocators"] = []
            source["extractionMetadata"] = metadata
            requirement["source"] = source
            chapters[0]["sourceGrounding"] = requirement
        } else {
            var revisions = try XCTUnwrap(chapters[0]["revisions"] as? [[String: Any]])
            let index = try XCTUnwrap(revisions.firstIndex { ($0["id"] as? String) == revisionID.uuidString })
            switch mutation {
            case "text":
                var blocks = try XCTUnwrap(revisions[index]["blocks"] as? [[String: Any]])
                blocks[1]["text"] = "An unreviewed replacement must never become readable. [1]"
                revisions[index]["blocks"] = blocks
            case "missing-review":
                revisions[index].removeValue(forKey: "sourceReview")
            case "source-hash":
                var receipt = try XCTUnwrap(revisions[index]["sourceReview"] as? [String: Any])
                receipt["sourceHash"] = "tampered-source-hash"
                revisions[index]["sourceReview"] = receipt
            default:
                XCTFail("Unknown authored corruption fixture: \(mutation)")
            }
            chapters[0]["revisions"] = revisions
        }
        object["chapters"] = chapters
        try AtomicFileWriter.writeAtomically(JSONSerialization.data(withJSONObject: object), to: url)
    }

    private func expectSavedSourceCorruption(expectsDecodeFailure: Bool, context: String,
                                            file: StaticString = #filePath, line: UInt = #line,
                                            _ operation: () async throws -> Void) async {
        do {
            try await operation()
            XCTFail("Damaged source unexpectedly passed a strict operation: \(context)", file: file, line: line)
        } catch {
            // This excludes stale/handled-candidate or consumed-chapter rejection as a false-positive.
            XCTAssertTrue(expectsDecodeFailure ? error is DecodingError : error is SourceGroundingError,
                "Expected persisted-source rejection, got \(error): \(context)", file: file, line: line)
        }
    }

    private struct Fixture {
        let book: Book
        let requirement: SourceGroundingRequirement
        let candidate: CandidateRevision
        var chapterID: UUID { book.chapters[0].id }
        var outlineID: UUID { requirement.outlineRevisionID }
    }

    private func makeSource(text: String? = nil, date: Date? = nil,
                            scope: RetrievedResearchSource.Scope = .wikipediaIntroduction,
                            extractionMetadata: RetrievedResearchSource.ExtractionMetadata? = nil) -> RetrievedResearchSource {
        let text = text ?? Array(repeating: firstQuote + " " + secondQuote, count: 5).joined(separator: "\n")
        let digest = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        return RetrievedResearchSource(requestedTitle: "River Archive", title: "River Archive",
            canonicalURL: URL(string: "https://en.wikipedia.org/wiki/River_Archive")!, pageID: 42, revisionID: 9001,
            revisionURL: URL(string: "https://en.wikipedia.org/w/index.php?oldid=9001")!,
            revisionTimestamp: date ?? timestamp, retrievedAt: date ?? timestamp, scope: scope,
            text: text, textSHA256: digest, attribution: "Authored Wikipedia-shaped test fixture; no retrieval occurred.",
            attributionURL: URL(string: "https://en.wikipedia.org/w/index.php?title=River_Archive&action=history")!,
            licenseName: "Fixture CC BY-SA 4.0", licenseURL: URL(string: "https://creativecommons.org/licenses/by-sa/4.0/")!,
            extractionMetadata: extractionMetadata)
    }

    private func makeOpeningSource() -> RetrievedResearchSource {
        let text = [Array(repeating: firstQuote, count: 5).joined(separator: " "),
                    Array(repeating: secondQuote, count: 5).joined(separator: " ")].joined(separator: "\n\n")
        return makeSource(text: text, scope: .wikipediaOpeningExcerpt,
            extractionMetadata: .init(extractionVersion: "wikipedia-opening-paragraphs-v1", paragraphLocators: [
                .init(sectionAnchor: nil, sectionTitle: "Introduction", paragraphIndex: 1),
                .init(sectionAnchor: "Public_records", sectionTitle: "Public records", paragraphIndex: 1)
            ]))
    }

    private func legacyIntroductionWire(_ source: RetrievedResearchSource) throws -> Data {
        struct LegacySource: Encodable {
            let requestedTitle: String; let title: String; let canonicalURL: URL
            let pageID: Int64; let revisionID: Int64; let revisionURL: URL
            let revisionTimestamp: Date; let retrievedAt: Date; let scope: String
            let text: String; let textSHA256: String; let attribution: String
            let attributionURL: URL; let licenseName: String; let licenseURL: URL
        }
        let legacy = LegacySource(requestedTitle: source.requestedTitle, title: source.title,
            canonicalURL: source.canonicalURL, pageID: source.pageID, revisionID: source.revisionID,
            revisionURL: source.revisionURL, revisionTimestamp: source.revisionTimestamp, retrievedAt: source.retrievedAt,
            scope: "wikipediaIntroduction", text: source.text, textSHA256: source.textSHA256,
            attribution: source.attribution, attributionURL: source.attributionURL,
            licenseName: source.licenseName, licenseURL: source.licenseURL)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(legacy)
    }

    /// Deliberately bypasses decoding so malformed in-memory input reaches validateSource.
    private func uncheckedSourceCopy(_ source: RetrievedResearchSource,
                                     scope: RetrievedResearchSource.Scope? = nil,
                                     metadata: RetrievedResearchSource.ExtractionMetadata?) -> RetrievedResearchSource {
        RetrievedResearchSource(requestedTitle: source.requestedTitle, title: source.title,
            canonicalURL: source.canonicalURL, pageID: source.pageID, revisionID: source.revisionID,
            revisionURL: source.revisionURL, revisionTimestamp: source.revisionTimestamp, retrievedAt: source.retrievedAt,
            scope: scope ?? source.scope, text: source.text, textSHA256: source.textSHA256,
            attribution: source.attribution, attributionURL: source.attributionURL,
            licenseName: source.licenseName, licenseURL: source.licenseURL, extractionMetadata: metadata)
    }

    private func paragraphs() -> [SourceDraftParagraph] {
        [SourceDraftParagraph(text: Array(repeating: firstQuote, count: 10).joined(separator: " "), citations: ["source1"]),
         SourceDraftParagraph(text: Array(repeating: secondQuote, count: 10).joined(separator: " "), citations: ["source1"])]
    }

    private func supportedResponse() -> SourceReviewResponse {
        SourceReviewResponse(units: [
            .init(index: 0, assessment: .supported, quotes: [firstQuote]),
            .init(index: 1, assessment: .supported, quotes: [secondQuote])
        ])
    }

    private func makeFixture(source: RetrievedResearchSource? = nil, bookID: UUID = UUID()) throws -> Fixture {
        let source = source ?? makeSource()
        let chapterID = UUID(), outlineID = UUID()
        let outlineBlocks = [ContentBlock(id: UUID(), kind: .paragraph, text: "Outline: examine the retained river archive introduction.", orderIndex: 0)]
        let requirement = SourceGroundingRequirement(source: source, outlineRevisionID: outlineID,
            outlineContentHash: try SourceGrounding.contentHash(outlineBlocks), approvedBriefHash: "fixture-approved-brief")
        let outline = ChapterRevision(id: outlineID, chapterId: chapterID, revisionIndex: 1,
            createdAt: timestamp, blocks: outlineBlocks, isConsumed: false)
        let chapter = Chapter(id: chapterID, bookId: bookID, title: "River Archive", orderIndex: 0,
            activeRevisionId: outlineID, revisions: [outline], manuscriptStatus: .outline, sourceGrounding: requirement)
        let book = Book(id: bookID, title: "River Archive", author: "Test Author", chapters: [chapter])
        let blocks = try SourceGrounding.blocks(title: chapter.title, paragraphs: paragraphs(), source: source)
        var candidate = CandidateRevision(id: UUID(), bookId: bookID, chapterId: chapterID, proposedRevisionIndex: 2,
            createdAt: timestamp, blocks: blocks, status: .staged, rejectionReason: nil, origin: .generated(style: "Fixture"))
        let partial = Fixture(book: book, requirement: requirement, candidate: candidate)
        candidate.sourceReview = try issueReceipt(fixture: partial)
        return Fixture(book: book, requirement: requirement, candidate: candidate)
    }

    private func issueReceipt(fixture: Fixture, response: SourceReviewResponse? = nil,
                              blocks: [ContentBlock]? = nil, baseID: UUID? = nil,
                              wordCut: SourceWordCut? = nil) throws -> SourceReviewReceipt {
        let receipt = try SourceGrounding.receipt(bookID: fixture.book.id, chapterID: fixture.chapterID,
            baseRevisionID: baseID ?? fixture.outlineID, blocks: blocks ?? fixture.candidate.blocks,
            source: fixture.requirement.source, model: OpenAIModelOption.defaultGeneration.rawValue,
            response: response ?? supportedResponse(), wordCut: wordCut)
        return SourceReviewReceipt(bookID: receipt.bookID, chapterID: receipt.chapterID, baseRevisionID: receipt.baseRevisionID,
            contentHash: receipt.contentHash, sourceHash: receipt.sourceHash, model: receipt.model,
            promptVersion: receipt.promptVersion, reviewedAt: timestamp, response: receipt.response,
            wordCutHash: receipt.wordCutHash)
    }

    /// The first reviewed paragraph stays intact; only the following paragraph is authored anew.
    /// This is a deterministic fixture, not a provider invocation or an independent truth check.
    private func continuationCandidate(fixture: Fixture, base: ChapterRevision,
                                       variant: Int = 0) throws -> CandidateRevision {
        let block = base.blocks[1]
        let prose = String(block.text.dropLast(4))
        let lastWord = try XCTUnwrap(prose.range(of: "settlements", options: .backwards))
        let offset = NSRange(lastWord, in: prose).location
        let cut = try XCTUnwrap(SourceGrounding.wordCut(base: base, blockID: block.id,
            utf16Offset: offset, source: fixture.requirement.source))
        let tail = variant == 0 ? secondQuote + " " + firstQuote : firstQuote + " " + secondQuote
        let blocks = try SourceGrounding.assembleContinuation(base: base, cut: cut, paragraphs: [
            SourceDraftParagraph(text: Array(repeating: tail, count: 5).joined(separator: " "), citations: ["source1"])
        ], source: fixture.requirement.source)
        let response = SourceReviewResponse(units: try SourceGrounding.prose(blocks,
            source: fixture.requirement.source).indices.map {
                .init(index: $0, assessment: .supported, quotes: [firstQuote, secondQuote])
            })
        let origin = RevisionOrigin(kind: .regenerateFromWord, summary: "Authored continuation fixture",
            anchorWord: cut.word, sourceWordCut: cut)
        let candidate = CandidateRevision(id: UUID(), bookId: fixture.book.id, chapterId: fixture.chapterID,
            proposedRevisionIndex: base.revisionIndex + 1, createdAt: timestamp,
            blocks: blocks, status: .staged, rejectionReason: nil, origin: origin,
            sourceReview: try issueReceipt(fixture: fixture, response: response, blocks: blocks,
                baseID: base.id, wordCut: cut))
        // All callers use the actual first publication returned by activation.
        var chapter = fixture.book.chapters[0]
        XCTAssertEqual(base.revisionIndex, chapter.revisions[0].revisionIndex + 1)
        chapter.revisions.append(base)
        chapter.activeRevisionId = base.id
        try SourceGrounding.validateTransition(receipt: candidate.sourceReview, origin: candidate.origin,
            blocks: candidate.blocks, bookID: fixture.book.id, chapter: chapter, history: chapter.revisions)
        return candidate
    }

    private func appending(_ candidate: CandidateRevision, to book: Book,
                           makeActive: Bool = true) -> Book {
        var copy = book
        let revision = ChapterRevision(id: UUID(), chapterId: candidate.chapterId,
            revisionIndex: candidate.proposedRevisionIndex, createdAt: timestamp,
            blocks: candidate.blocks, isConsumed: false, origin: candidate.origin,
            sourceReview: candidate.sourceReview)
        copy.chapters[0].revisions.append(revision)
        if makeActive { copy.chapters[0].activeRevisionId = revision.id }
        return copy
    }

    private func validate(_ receipt: SourceReviewReceipt?, fixture: Fixture, blocks: [ContentBlock]? = nil) throws {
        try SourceGrounding.validate(receipt: receipt, bookID: fixture.book.id, chapterID: fixture.chapterID,
            blocks: blocks ?? fixture.candidate.blocks, requirement: fixture.requirement, baseRevisionID: fixture.outlineID)
    }

    private func receiptWithResponse(_ response: SourceReviewResponse, fixture: Fixture) throws -> SourceReviewReceipt {
        let receipt = try XCTUnwrap(fixture.candidate.sourceReview)
        return SourceReviewReceipt(bookID: receipt.bookID, chapterID: receipt.chapterID, baseRevisionID: receipt.baseRevisionID,
            contentHash: receipt.contentHash, sourceHash: receipt.sourceHash, model: receipt.model,
            promptVersion: receipt.promptVersion, reviewedAt: receipt.reviewedAt, response: response,
            wordCutHash: receipt.wordCutHash)
    }

    private func replacing<T: Codable>(_ value: T, key: String, with replacement: Any) throws -> T {
        let encoded = try JSONEncoder().encode(value)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object[key] = replacement
        return try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SourceGroundingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func manuscriptURL(root: URL, bookID: UUID) -> URL {
        root.appendingPathComponent("Manuscripts/\(bookID.uuidString).json")
    }

    private func expectFailure(file: StaticString = #filePath, line: UInt = #line,
                               _ operation: () async throws -> Void) async {
        do {
            try await operation()
            XCTFail("Unreviewed or stale source content must not be published", file: file, line: line)
        } catch { }
    }
}
