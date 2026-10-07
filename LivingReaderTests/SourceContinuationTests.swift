import XCTest
import CryptoKit
@testable import LivingReader

/// Authored 400-word manuscripts, retained fixture evidence and counting actors only.
/// These tests make no network, credential, source-retrieval or real model request.
final class SourceContinuationTests: XCTestCase {
    func testReviewRetryAfterServiceReconstructionUsesExactSavedCandidateAndNoSecondWriter() async throws {
        let environment = try ContinuationEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.root) }
        let fixture = try await environment.publishFixture()
        let before = try environment.manuscriptState(fixture.book.id)
        let ai = ContinuationCountingAI(assessments: [.unsupported, .supported], onReview: { request in
            let state = try XCTUnwrap(environment.packets.loadFactChecklist(bookId: fixture.book.id).sourceContinuation)
            let candidate = try XCTUnwrap(state.candidate, "The assembled writing must be on disk before review begins")
            XCTAssertNil(candidate.sourceReview)
            XCTAssertEqual(request.paragraphs, try SourceGrounding.prose(candidate.blocks, source: fixture.source))
            XCTAssertEqual(request.source, fixture.source)
            XCTAssertEqual(candidate.origin?.sourceWordCut, state.cut)
        })
        let service = try environment.service(ai: ai)
        let prepared = try await service.prepareSourceContinuation(request: fixture.request())
        XCTAssertEqual(prepared.phase, .prepared)
        XCTAssertEqual(prepared.frozenPrefixWordCount, 200)
        XCTAssertEqual(prepared.replacingWordCount, 200, "Source footer and citation markers are not future prose")
        await expectFailure { _ = try await service.runSourceContinuation(bookID: fixture.book.id, attemptID: prepared.id) }
        XCTAssertEqual(try environment.manuscriptState(fixture.book.id), before)
        let pending = try XCTUnwrap(environment.packets.loadFactChecklist(bookId: fixture.book.id).sourceContinuation)
        let candidate = try XCTUnwrap(pending.candidate)
        XCTAssertEqual(pending.id, prepared.id)
        XCTAssertEqual(pending.phase, .needsReview)
        XCTAssertNil(candidate.sourceReview)
        XCTAssertFalse((pending.errorMessage ?? "").isEmpty)
        let initialCalls = await ai.snapshot()
        XCTAssertEqual(initialCalls.writes.count, 1)
        XCTAssertEqual(initialCalls.reviews.count, 1)
        XCTAssertEqual(initialCalls.legacy, 0)

        let reopened = try ContinuationEnvironment(root: environment.root)
        let resumed = try reopened.service(ai: ai)
        let restoredState = try await resumed.sourceContinuation(bookID: fixture.book.id)
        XCTAssertEqual(restoredState?.candidate, candidate)
        let published = try await resumed.runSourceContinuation(bookID: fixture.book.id, attemptID: prepared.id)
        XCTAssertEqual(published.blocks, candidate.blocks)
        XCTAssertEqual(published.origin?.sourceWordCut, prepared.cut)
        XCTAssertEqual(published.sourceReview?.baseRevisionID, fixture.base.id)
        XCTAssertEqual(published.sourceReview?.wordCutHash, try SourceGrounding.hash(prepared.cut))
        let calls = await ai.snapshot()
        XCTAssertEqual(calls.writes.count, 1)
        XCTAssertEqual(calls.reviews.count, 2)
        XCTAssertEqual(calls.reviews[0].paragraphs, calls.reviews[1].paragraphs)
        XCTAssertEqual(calls.reviews[0].source, calls.reviews[1].source)
        XCTAssertEqual(calls.writes[0].source, fixture.source)
        XCTAssertEqual(calls.writes[0].frozenParagraphs, [String(fixture.base.blocks[1].text.dropLast(4))])
        XCTAssertEqual(calls.writes[0].oldSuffix, [String(fixture.base.blocks[2].text.dropLast(4))])
        XCTAssertFalse(calls.writes[0].joinsSelectedParagraph)
        XCTAssertEqual(calls.legacy, 0)
        let finalBook = try await reopened.versioning.loadBook(id: fixture.book.id)
        let chapter = try XCTUnwrap(finalBook?.chapters.first)
        XCTAssertEqual(chapter.revisions.count, 3)
        XCTAssertEqual(chapter.activeRevisionId, published.id)
        XCTAssertEqual(chapter.sourceGrounding, fixture.book.chapters[0].sourceGrounding)
        XCTAssertEqual(try SourceGrounding.hash(chapter.revision(id: fixture.base.id)), try SourceGrounding.hash(fixture.base))
        XCTAssertEqual(published.blocks[1].id, fixture.base.blocks[1].id)
        XCTAssertTrue(published.blocks[1].text.utf8.elementsEqual(fixture.base.blocks[1].text.utf8))
        let originalAgain = try await reopened.versioning.restoreRevision(bookId: fixture.book.id,
            chapterId: fixture.chapterID, sourceRevisionId: fixture.base.id)
        XCTAssertEqual(try SourceGrounding.contentHash(originalAgain.blocks), try SourceGrounding.contentHash(fixture.base.blocks))
        let continuationAgain = try await reopened.versioning.restoreRevision(bookId: fixture.book.id,
            chapterId: fixture.chapterID, sourceRevisionId: published.id)
        XCTAssertEqual(continuationAgain.origin?.sourceWordCut, prepared.cut)
        XCTAssertEqual(continuationAgain.sourceReview?.wordCutHash, published.sourceReview?.wordCutHash)
        XCTAssertEqual(continuationAgain.sourceReview?.reviewedAt, published.sourceReview?.reviewedAt)
    }

    func testPublicationRetryUsesSavedReceiptWithoutWriterOrReviewerCalls() async throws {
        let environment = try ContinuationEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.root) }
        let fixture = try await environment.publishFixture()
        var facts = try environment.packets.loadFactChecklist(bookId: fixture.book.id)
        let blockedClaim = FactClaim(chapterId: fixture.chapterID, statement: "Authored essential fixture obligation",
            importance: .essential, status: .unverified, evidenceIds: ["fixture-evidence"], updatedAt: ContinuationFixture.date)
        facts.claims.append(blockedClaim)
        try environment.packets.saveFactChecklist(facts)
        let ai = ContinuationCountingAI()
        let service = try environment.service(ai: ai)
        let prepared = try await service.prepareSourceContinuation(request: fixture.request())
        let before = try environment.manuscriptState(fixture.book.id)
        await expectFailure { _ = try await service.runSourceContinuation(bookID: fixture.book.id, attemptID: prepared.id) }
        XCTAssertEqual(try environment.manuscriptState(fixture.book.id), before)
        let pending = try XCTUnwrap(environment.packets.loadFactChecklist(bookId: fixture.book.id).sourceContinuation)
        XCTAssertEqual(pending.phase, .readyToPublish)
        let candidate = try XCTUnwrap(pending.candidate)
        let review = try XCTUnwrap(candidate.sourceReview)
        let firstCalls = await ai.snapshot()
        XCTAssertEqual(firstCalls.writes.count, 1)
        XCTAssertEqual(firstCalls.reviews.count, 1)
        facts = try environment.packets.loadFactChecklist(bookId: fixture.book.id)
        facts.claims.removeAll { $0.id == blockedClaim.id } // Remove only this test-owned gate fixture.
        try environment.packets.saveFactChecklist(facts)
        let resumed = try ContinuationEnvironment(root: environment.root).service(ai: ai)
        let published = try await resumed.runSourceContinuation(bookID: fixture.book.id, attemptID: prepared.id)
        XCTAssertEqual(published.blocks, candidate.blocks)
        XCTAssertEqual(published.sourceReview, review)
        let calls = await ai.snapshot()
        XCTAssertEqual(calls.writes.count, 1)
        XCTAssertEqual(calls.reviews.count, 1)
        XCTAssertEqual(calls.legacy, 0)
    }

    func testChangedInputCannotReplacePendingCandidateOrSpendAnotherRequest() async throws {
        let environment = try ContinuationEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.root) }
        let fixture = try await environment.publishFixture()
        let ai = ContinuationCountingAI(assessments: [.unsupported])
        let service = try environment.service(ai: ai)
        let request = try fixture.request()
        let prepared = try await service.prepareSourceContinuation(request: request)
        await expectFailure { _ = try await service.runSourceContinuation(bookID: fixture.book.id, attemptID: prepared.id) }
        let before = try environment.factsState(fixture.book.id)
        var changedText = request; changedText.freeText = "Different instructions must create an explicit new attempt"
        var changedSelection = request; changedSelection.anchor.utf16OffsetInBlock = 0; changedSelection.anchor.word = "River"
        var changedPreferences = request; changedPreferences.readerPreferencesSummary = "A different reader preference"
        for changed in [changedText, changedSelection, changedPreferences] {
            await expectFailure { _ = try await service.prepareSourceContinuation(request: changed) }
            XCTAssertEqual(try environment.factsState(fixture.book.id), before)
        }
        await expectFailure { _ = try await service.runSourceContinuation(bookID: fixture.book.id, attemptID: UUID()) }
        XCTAssertEqual(try environment.factsState(fixture.book.id), before)
        let calls = await ai.snapshot()
        XCTAssertEqual(calls.writes.count, 1)
        XCTAssertEqual(calls.reviews.count, 1)
    }

    func testInvalidSelectionAndUnsupportedOptionsRejectBeforeAnyProviderWork() async throws {
        let environment = try ContinuationEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.root) }
        let fixture = try await environment.publishFixture()
        let ai = ContinuationCountingAI()
        let service = try environment.service(ai: ai)
        let valid = try fixture.request()
        var requests: [WordForwardRegenerationRequest] = []
        for block in [fixture.base.blocks[0], fixture.base.blocks[fixture.base.blocks.count - 2], fixture.base.blocks.last!] {
            var request = valid; request.anchor.blockId = block.id; request.anchor.utf16OffsetInBlock = 0
            requests.append(request)
        }
        var lastWord = valid
        lastWord.anchor.blockId = fixture.base.blocks[2].id
        lastWord.anchor.utf16OffsetInBlock = (fixture.base.blocks[2].text as NSString).range(of: "journeys", options: .backwards).location
        lastWord.anchor.word = "journeys"
        requests.append(lastWord)
        var marker = valid
        marker.anchor.utf16OffsetInBlock = (fixture.base.blocks[1].text as NSString).length - 2
        requests.append(marker)
        var followOn = valid; followOn.maxFollowOnChapters = 1; requests.append(followOn)
        var chapterStart = valid; chapterStart.anchor.boundary = .chapterStart; requests.append(chapterStart)
        for intent: RegenerationIntent in [.moreImages, .moreStories, .morePlaces] {
            var request = valid; request.intents = [intent]; requests.append(request)
        }
        let before = try environment.manuscriptState(fixture.book.id)
        for request in requests {
            await expectFailure { _ = try await service.prepareSourceContinuation(request: request) }
        }
        XCTAssertEqual(try environment.manuscriptState(fixture.book.id), before)
        let pending = try await service.sourceContinuation(bookID: fixture.book.id)
        XCTAssertNil(pending)
        let calls = await ai.snapshot()
        XCTAssertTrue(calls.writes.isEmpty)
        XCTAssertTrue(calls.reviews.isEmpty)
        XCTAssertEqual(calls.legacy, 0)
    }

    func testPersistedInterruptedWritingNeverAutomaticallyReplaysWriter() async throws {
        let environment = try ContinuationEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.root) }
        let fixture = try await environment.publishFixture()
        let ai = ContinuationCountingAI()
        let prepared = try await environment.service(ai: ai).prepareSourceContinuation(request: fixture.request())
        var interrupted = prepared; interrupted.phase = .writing
        try environment.packets.transitionSourceContinuation(bookId: fixture.book.id, expected: prepared, next: interrupted)
        let resumed = try ContinuationEnvironment(root: environment.root).service(ai: ai)
        let before = try environment.manuscriptState(fixture.book.id)
        await expectFailure { _ = try await resumed.runSourceContinuation(bookID: fixture.book.id, attemptID: prepared.id) }
        let pending = try await resumed.sourceContinuation(bookID: fixture.book.id)
        XCTAssertEqual(pending?.id, prepared.id)
        XCTAssertEqual(pending?.phase, .uncertain)
        XCTAssertNil(pending?.candidate)
        XCTAssertEqual(try environment.manuscriptState(fixture.book.id), before)
        let calls = await ai.snapshot()
        XCTAssertTrue(calls.writes.isEmpty)
        XCTAssertTrue(calls.reviews.isEmpty)
    }

    func testTwoServiceAndStoreInstancesAdmitOnlyOneWriterWhileFirstOperationIsSuspended() async throws {
        let environment = try ContinuationEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.root) }
        let fixture = try await environment.publishFixture()
        let otherEnvironment = try ContinuationEnvironment(root: environment.root)
        let otherAI = ContinuationCountingAI()
        let otherService = try otherEnvironment.service(ai: otherAI)
        let ai = ContinuationCountingAI(onWrite: { _ in
            let saved = try XCTUnwrap(otherEnvironment.packets.loadFactChecklist(bookId: fixture.book.id).sourceContinuation)
            XCTAssertEqual(saved.phase, .writing)
            do {
                _ = try await otherService.runSourceContinuation(bookID: fixture.book.id, attemptID: saved.id)
                XCTFail("A second service must not acquire an in-flight writing attempt")
            } catch {
                XCTAssertTrue(error is SourceGroundingError)
            }
            let after = try XCTUnwrap(environment.packets.loadFactChecklist(bookId: fixture.book.id).sourceContinuation)
            XCTAssertEqual(try SourceGrounding.hash(after), try SourceGrounding.hash(saved),
                "Reentry must not relabel the live owner's work uncertain")
        })
        let service = try environment.service(ai: ai)
        let prepared = try await service.prepareSourceContinuation(request: fixture.request())
        let published = try await service.runSourceContinuation(bookID: fixture.book.id, attemptID: prepared.id)
        let winnerCalls = await ai.snapshot(), otherCalls = await otherAI.snapshot()
        XCTAssertEqual(winnerCalls.writes.count, 1)
        XCTAssertEqual(winnerCalls.reviews.count, 1)
        XCTAssertTrue(otherCalls.writes.isEmpty)
        XCTAssertTrue(otherCalls.reviews.isEmpty)
        let readable = try await otherEnvironment.versioning.readableRevision(bookId: fixture.book.id, chapterId: fixture.chapterID)
        XCTAssertEqual(readable.id, published.id)
    }

    func testStaleOrConsumedBaseBeforeRunRejectsWithoutWriterAndNeverRebasesTheCut() async throws {
        for consumed in [false, true] {
            let environment = try ContinuationEnvironment()
            defer { try? FileManager.default.removeItem(at: environment.root) }
            let fixture = try await environment.publishFixture()
            let ai = ContinuationCountingAI()
            let service = try environment.service(ai: ai)
            let prepared = try await service.prepareSourceContinuation(request: fixture.request())
            if consumed {
                try await environment.versioning.consume(bookId: fixture.book.id, chapterId: fixture.chapterID,
                    revisionId: fixture.base.id)
            } else {
                // Exact text restore still creates a different authoritative base identity.
                _ = try await environment.versioning.restoreRevision(bookId: fixture.book.id,
                    chapterId: fixture.chapterID, sourceRevisionId: fixture.base.id)
            }
            let before = try environment.manuscriptState(fixture.book.id)
            await expectFailure { _ = try await service.runSourceContinuation(bookID: fixture.book.id, attemptID: prepared.id) }
            XCTAssertEqual(try environment.manuscriptState(fixture.book.id), before)
            let state = try XCTUnwrap(environment.packets.loadFactChecklist(bookId: fixture.book.id).sourceContinuation)
            XCTAssertEqual(state.id, prepared.id)
            XCTAssertEqual(state.cut, prepared.cut)
            XCTAssertEqual(state.cut.baseRevisionID, fixture.base.id)
            let calls = await ai.snapshot()
            XCTAssertTrue(calls.writes.isEmpty)
            XCTAssertTrue(calls.reviews.isEmpty)
        }
    }

    func testRestoreDuringWriterStopsBeforeReviewAndPreservesTheNewReadableRevision() async throws {
        let environment = try ContinuationEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.root) }
        let fixture = try await environment.publishFixture()
        let recorder = ContinuationRevisionRecorder()
        let ai = ContinuationCountingAI(onWrite: { _ in
            let restored = try await environment.versioning.restoreRevision(bookId: fixture.book.id,
                chapterId: fixture.chapterID, sourceRevisionId: fixture.base.id)
            await recorder.record(restored)
        })
        let service = try environment.service(ai: ai)
        let prepared = try await service.prepareSourceContinuation(request: fixture.request())
        await expectFailure { _ = try await service.runSourceContinuation(bookID: fixture.book.id, attemptID: prepared.id) }
        let intervening = await recorder.value()
        let restored = try XCTUnwrap(intervening)
        let readable = try await environment.versioning.readableRevision(bookId: fixture.book.id, chapterId: fixture.chapterID)
        XCTAssertEqual(readable.id, restored.id)
        XCTAssertEqual(readable.blocks, restored.blocks)
        let book = try await environment.versioning.loadBook(id: fixture.book.id)
        XCTAssertEqual(book?.chapters[0].revisions.count, 3)
        let pending = try XCTUnwrap(environment.packets.loadFactChecklist(bookId: fixture.book.id).sourceContinuation)
        XCTAssertEqual(pending.id, prepared.id)
        XCTAssertEqual(pending.cut, prepared.cut)
        let calls = await ai.snapshot()
        XCTAssertEqual(calls.writes.count, 1)
        XCTAssertTrue(calls.reviews.isEmpty, "A changed base must be detected before another request")
    }

    func testConsumptionDuringReviewKeepsSavedCandidateAndCannotPublish() async throws {
        let environment = try ContinuationEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.root) }
        let fixture = try await environment.publishFixture()
        let ai = ContinuationCountingAI(onReview: { _ in
            try await environment.versioning.consume(bookId: fixture.book.id, chapterId: fixture.chapterID,
                revisionId: fixture.base.id)
        })
        let service = try environment.service(ai: ai)
        let prepared = try await service.prepareSourceContinuation(request: fixture.request())
        await expectFailure { _ = try await service.runSourceContinuation(bookID: fixture.book.id, attemptID: prepared.id) }
        let pending = try XCTUnwrap(environment.packets.loadFactChecklist(bookId: fixture.book.id).sourceContinuation)
        let candidate = try XCTUnwrap(pending.candidate)
        XCTAssertEqual(candidate.origin?.sourceWordCut, prepared.cut)
        let pinned = try await environment.versioning.retrieveConsumedRevision(bookId: fixture.book.id, chapterId: fixture.chapterID)
        XCTAssertEqual(pinned?.id, fixture.base.id)
        XCTAssertEqual(pinned?.blocks, fixture.base.blocks)
        let book = try await environment.versioning.loadBook(id: fixture.book.id)
        XCTAssertEqual(book?.chapters[0].revisions.count, 2)
        let ledgerBefore = try ContinuationFileState(environment.root.appendingPathComponent("Ledger/consumed-ledger.json"))
        let manuscriptBefore = try environment.manuscriptState(fixture.book.id)
        let reopened = try ContinuationEnvironment(root: environment.root).service(ai: ai)
        await expectFailure { _ = try await reopened.runSourceContinuation(bookID: fixture.book.id, attemptID: prepared.id) }
        XCTAssertEqual(try environment.manuscriptState(fixture.book.id), manuscriptBefore)
        XCTAssertEqual(try ContinuationFileState(environment.root.appendingPathComponent("Ledger/consumed-ledger.json")), ledgerBefore)
        let calls = await ai.snapshot()
        XCTAssertEqual(calls.writes.count, 1)
        XCTAssertEqual(calls.reviews.count, 1)
    }

    func testArchiveRetainsFailedCandidateAndRequiresExplicitNewAttempt() async throws {
        let environment = try ContinuationEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.root) }
        let fixture = try await environment.publishFixture()
        let ai = ContinuationCountingAI(assessments: [.unsupported])
        let service = try environment.service(ai: ai)
        let prepared = try await service.prepareSourceContinuation(request: fixture.request())
        await expectFailure { _ = try await service.runSourceContinuation(bookID: fixture.book.id, attemptID: prepared.id) }
        let pending = try XCTUnwrap(environment.packets.loadFactChecklist(bookId: fixture.book.id).sourceContinuation)
        XCTAssertNotNil(pending.candidate)
        let before = try environment.manuscriptState(fixture.book.id)
        await expectFailure { try await service.archiveSourceContinuation(bookID: fixture.book.id, attemptID: UUID()) }
        try await service.archiveSourceContinuation(bookID: fixture.book.id, attemptID: prepared.id)
        let reopened = try ContinuationEnvironment(root: environment.root)
        let archivedFacts = try reopened.packets.loadFactChecklist(bookId: fixture.book.id)
        XCTAssertNil(archivedFacts.sourceContinuation)
        XCTAssertEqual(archivedFacts.sourceContinuationArchive?.count, 1)
        XCTAssertEqual(archivedFacts.sourceContinuationArchive?.first?.candidate, pending.candidate)
        XCTAssertEqual(archivedFacts.sourceContinuationArchive?.first?.cut, pending.cut)
        XCTAssertEqual(archivedFacts.sourceContinuationArchive?.first?.id, pending.id)
        let resumed = try reopened.service(ai: ai)
        var request = try fixture.request(); request.freeText = "A new explicit attempt"
        let next = try await resumed.prepareSourceContinuation(request: request)
        XCTAssertNotEqual(next.id, prepared.id)
        XCTAssertNil(next.candidate)
        let preserved = try reopened.packets.loadFactChecklist(bookId: fixture.book.id)
        XCTAssertEqual(preserved.sourceContinuationArchive, archivedFacts.sourceContinuationArchive)
        XCTAssertEqual(try environment.manuscriptState(fixture.book.id), before)
        let calls = await ai.snapshot()
        XCTAssertEqual(calls.writes.count, 1)
        XCTAssertEqual(calls.reviews.count, 1)
    }

    func testContinuationTransitionsPreserveLegacyCreateStateAndNewerUnrelatedFacts() async throws {
        let environment = try ContinuationEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.root) }
        let fixture = try await environment.publishFixture()
        let legacyFacts = try environment.packets.loadFactChecklist(bookId: fixture.book.id)
        var wire = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONCoding.encoder.encode(legacyFacts)) as? [String: Any])
        wire.removeValue(forKey: "sourceContinuation")
        wire.removeValue(forKey: "sourceContinuationArchive")
        let decoded = try JSONCoding.decoder.decode(FactChecklist.self, from: JSONSerialization.data(withJSONObject: wire))
        XCTAssertNil(decoded.sourceContinuation)
        XCTAssertNil(decoded.sourceContinuationArchive)
        XCTAssertEqual(try SourceGrounding.hash(decoded.sourcePilot), try SourceGrounding.hash(legacyFacts.sourcePilot))
        let ai = ContinuationCountingAI()
        let service = try environment.service(ai: ai)
        let prepared = try await service.prepareSourceContinuation(request: fixture.request())
        let otherStore = try FilePEPacketStore(rootDirectory: environment.root)
        var newer = try otherStore.loadFactChecklist(bookId: fixture.book.id)
        let claim = FactClaim(chapterId: fixture.chapterID, statement: "Unrelated authored supporting note",
            importance: .supporting, status: .unverified, evidenceIds: ["fixture-evidence"], updatedAt: ContinuationFixture.date)
        newer.claims.append(claim)
        try otherStore.saveFactChecklist(newer)
        var next = prepared; next.phase = .writing
        try environment.packets.transitionSourceContinuation(bookId: fixture.book.id, expected: prepared, next: next)
        let current = try otherStore.loadFactChecklist(bookId: fixture.book.id)
        XCTAssertEqual(current.claims, newer.claims)
        XCTAssertEqual(current.evidence, legacyFacts.evidence)
        XCTAssertEqual(try SourceGrounding.hash(current.sourcePilot), try SourceGrounding.hash(legacyFacts.sourcePilot))
        XCTAssertEqual(current.sourceContinuation?.phase, .writing)
        let before = try environment.factsState(fixture.book.id)
        XCTAssertThrowsError(try otherStore.transitionSourceContinuation(bookId: fixture.book.id, expected: prepared, next: nil))
        XCTAssertEqual(try environment.factsState(fixture.book.id), before)
        // An older ordinary whole-checklist save cannot clear the separately owned attempt.
        try otherStore.saveFactChecklist(newer)
        XCTAssertEqual(try otherStore.loadFactChecklist(bookId: fixture.book.id).sourceContinuation?.phase, .writing)
    }

    func testReviewOnlyStateWithMissingCandidateFailsClosedWithoutWriterReplay() async throws {
        let environment = try ContinuationEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.root) }
        let fixture = try await environment.publishFixture()
        let ai = ContinuationCountingAI()
        let service = try environment.service(ai: ai)
        let prepared = try await service.prepareSourceContinuation(request: fixture.request())
        var missing = prepared; missing.phase = .needsReview; missing.candidate = nil
        try environment.packets.transitionSourceContinuation(bookId: fixture.book.id, expected: prepared, next: missing)
        let resumed = try ContinuationEnvironment(root: environment.root).service(ai: ai)
        let before = try environment.manuscriptState(fixture.book.id)
        await expectFailure { _ = try await resumed.runSourceContinuation(bookID: fixture.book.id, attemptID: prepared.id) }
        XCTAssertEqual(try environment.manuscriptState(fixture.book.id), before)
        let calls = await ai.snapshot()
        XCTAssertTrue(calls.writes.isEmpty)
        XCTAssertTrue(calls.reviews.isEmpty)
    }

    func testPublishedCandidateRecoversAfterCleanupInterruptionWithoutDuplicateRevisionOrProviderCalls() async throws {
        let environment = try ContinuationEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.root) }
        let fixture = try await environment.publishFixture()
        var facts = try environment.packets.loadFactChecklist(bookId: fixture.book.id)
        let claim = FactClaim(chapterId: fixture.chapterID, statement: "Temporary authored publication blocker",
            importance: .essential, status: .unverified, evidenceIds: ["fixture-evidence"], updatedAt: ContinuationFixture.date)
        facts.claims.append(claim)
        try environment.packets.saveFactChecklist(facts)
        let ai = ContinuationCountingAI()
        let service = try environment.service(ai: ai)
        let prepared = try await service.prepareSourceContinuation(request: fixture.request())
        await expectFailure { _ = try await service.runSourceContinuation(bookID: fixture.book.id, attemptID: prepared.id) }
        facts = try environment.packets.loadFactChecklist(bookId: fixture.book.id)
        let ready = try XCTUnwrap(facts.sourceContinuation)
        XCTAssertEqual(ready.phase, .readyToPublish)
        let candidate = try XCTUnwrap(ready.candidate)
        XCTAssertNotNil(candidate.sourceReview)
        facts.claims.removeAll { $0.id == claim.id }
        try environment.packets.saveFactChecklist(facts)
        var publishing = ready; publishing.phase = .publishing
        try environment.packets.transitionSourceContinuation(bookId: fixture.book.id, expected: ready, next: publishing)
        try await environment.versioning.stageCandidate(candidate)
        let alreadyPublished = try await environment.versioning.activateCandidate(id: candidate.id,
            expectedRevisionId: fixture.base.id)
        // Simulate termination after manuscript publication but before the final
        // continuation-state update. Nothing invokes a real provider here.
        let before = try environment.manuscriptState(fixture.book.id)
        let reopened = try ContinuationEnvironment(root: environment.root)
        let resumed = try reopened.service(ai: ai)
        let recovered = try await resumed.runSourceContinuation(bookID: fixture.book.id, attemptID: ready.id)
        XCTAssertEqual(recovered.id, alreadyPublished.id)
        XCTAssertEqual(try environment.manuscriptState(fixture.book.id), before)
        let state = try await resumed.sourceContinuation(bookID: fixture.book.id)
        XCTAssertEqual(state?.phase, .published)
        let book = try await reopened.versioning.loadBook(id: fixture.book.id)
        XCTAssertEqual(book?.chapters[0].revisions.count, 3)
        let calls = await ai.snapshot()
        XCTAssertEqual(calls.writes.count, 1)
        XCTAssertEqual(calls.reviews.count, 1)
        let repeated = try await resumed.runSourceContinuation(bookID: fixture.book.id, attemptID: ready.id)
        XCTAssertEqual(repeated.id, alreadyPublished.id)
        XCTAssertEqual(try environment.manuscriptState(fixture.book.id), before)
    }

    func testChangedPendingStateDuringReviewIsNotOverwrittenBySuspendedOperation() async throws {
        let environment = try ContinuationEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.root) }
        let fixture = try await environment.publishFixture()
        let other = try FilePEPacketStore(rootDirectory: environment.root)
        let recorder = ContinuationStateRecorder()
        let ai = ContinuationCountingAI(onReview: { _ in
            let pending = try XCTUnwrap(other.loadFactChecklist(bookId: fixture.book.id).sourceContinuation)
            var changed = pending
            changed.errorMessage = "Authored intervening state change must survive"
            try other.transitionSourceContinuation(bookId: fixture.book.id, expected: pending, next: changed)
            let persisted = try XCTUnwrap(other.loadFactChecklist(bookId: fixture.book.id).sourceContinuation)
            await recorder.record(persisted)
        })
        let service = try environment.service(ai: ai)
        let prepared = try await service.prepareSourceContinuation(request: fixture.request())
        let before = try environment.manuscriptState(fixture.book.id)
        await expectFailure { _ = try await service.runSourceContinuation(bookID: fixture.book.id, attemptID: prepared.id) }
        let intervening = await recorder.value()
        let saved = try environment.packets.loadFactChecklist(bookId: fixture.book.id).sourceContinuation
        XCTAssertNotNil(intervening)
        XCTAssertEqual(saved, intervening, "The losing operation cannot overwrite newer state with its retry snapshot")
        XCTAssertEqual(try environment.manuscriptState(fixture.book.id), before)
        let calls = await ai.snapshot()
        XCTAssertEqual(calls.writes.count, 1)
        XCTAssertEqual(calls.reviews.count, 1)
    }

    func testCorruptSavedCandidateRejectsBeforeReviewWithoutReturningToWriter() async throws {
        let environment = try ContinuationEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.root) }
        let fixture = try await environment.publishFixture()
        let firstAI = ContinuationCountingAI(assessments: [.unsupported])
        let service = try environment.service(ai: firstAI)
        let prepared = try await service.prepareSourceContinuation(request: fixture.request())
        await expectFailure { _ = try await service.runSourceContinuation(bookID: fixture.book.id, attemptID: prepared.id) }
        let pending = try XCTUnwrap(environment.packets.loadFactChecklist(bookId: fixture.book.id).sourceContinuation)
        let candidate = try XCTUnwrap(pending.candidate)
        var variants: [CandidateRevision] = []
        var otherID = candidate; otherID.id = UUID(); variants.append(otherID)
        var otherBook = candidate; otherBook.bookId = UUID(); variants.append(otherBook)
        var noCut = candidate; noCut.origin?.sourceWordCut = nil; variants.append(noCut)
        var changedPrefix = candidate; changedPrefix.blocks[1].text = "Changed already-read prefix. [1]"; variants.append(changedPrefix)
        var changedTail = candidate
        changedTail.blocks[2].text = "Another structurally valid but altered saved tail. [1]"
        // The cut and source layout still validate; the saved candidate fingerprint must catch this edit.
        XCTAssertNoThrow(try SourceGrounding.validateWordCut(prepared.cut, base: fixture.base,
            blocks: changedTail.blocks, source: fixture.source))
        variants.append(changedTail)
        let ai = ContinuationCountingAI()
        let reopened = try ContinuationEnvironment(root: environment.root).service(ai: ai)
        let before = try environment.manuscriptState(fixture.book.id)
        for damaged in variants {
            let current = try environment.packets.loadFactChecklist(bookId: fixture.book.id).sourceContinuation
            var altered = pending; altered.candidate = damaged
            try environment.packets.transitionSourceContinuation(bookId: fixture.book.id, expected: current, next: altered)
            let packetBefore = try environment.factsState(fixture.book.id)
            await expectFailure { _ = try await reopened.runSourceContinuation(bookID: fixture.book.id, attemptID: prepared.id) }
            XCTAssertEqual(try environment.manuscriptState(fixture.book.id), before)
            XCTAssertEqual(try environment.factsState(fixture.book.id), packetBefore)
        }
        let calls = await ai.snapshot()
        XCTAssertTrue(calls.writes.isEmpty)
        XCTAssertTrue(calls.reviews.isEmpty)
    }

    func testExistingSourceConformerDefaultsToUnsupportedContinuationWithoutFallback() async throws {
        let environment = try ContinuationEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.root) }
        let fixture = try await environment.publishFixture()
        let ai = LegacyOnlyContinuationAI()
        let service = try environment.service(ai: ai)
        let prepared = try await service.prepareSourceContinuation(request: fixture.request())
        let before = try environment.manuscriptState(fixture.book.id)
        do {
            _ = try await service.runSourceContinuation(bookID: fixture.book.id, attemptID: prepared.id)
            XCTFail("A preview-only conformer must not inherit ordinary writing as a fallback")
        } catch {
            XCTAssertTrue(error is SourceGroundingError)
        }
        let calls = await ai.callCount()
        XCTAssertEqual(calls, 0, "Neither preview writing, review nor legacy AI routes may be invoked")
        XCTAssertEqual(try environment.manuscriptState(fixture.book.id), before)
    }

    func testPreviewOnlyConformerCannotReviewSavedContinuationThroughDefaultOptIn() async throws {
        let environment = try ContinuationEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.root) }
        let fixture = try await environment.publishFixture()
        let writer = ContinuationCountingAI(assessments: [.unsupported])
        let service = try environment.service(ai: writer)
        let prepared = try await service.prepareSourceContinuation(request: fixture.request())
        await expectFailure { _ = try await service.runSourceContinuation(bookID: fixture.book.id, attemptID: prepared.id) }
        let before = try environment.manuscriptState(fixture.book.id)
        let pending = try environment.packets.loadFactChecklist(bookId: fixture.book.id).sourceContinuation
        XCTAssertNotNil(pending?.candidate)
        let closed = LegacyOnlyContinuationAI()
        let resumed = try ContinuationEnvironment(root: environment.root).service(ai: closed)
        await expectFailure { _ = try await resumed.runSourceContinuation(bookID: fixture.book.id, attemptID: prepared.id) }
        let calls = await closed.callCount()
        XCTAssertEqual(calls, 0, "A preview-only/trial conformer must not acquire a continuation review route")
        XCTAssertEqual(try environment.manuscriptState(fixture.book.id), before)
        XCTAssertEqual(try environment.packets.loadFactChecklist(bookId: fixture.book.id).sourceContinuation?.candidate, pending?.candidate)
    }

    func testTamperedPendingAnchorRejectsBeforeAnyWriterOrReviewerCall() async throws {
        let environment = try ContinuationEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.root) }
        let fixture = try await environment.publishFixture()
        let ai = ContinuationCountingAI()
        let service = try environment.service(ai: ai)
        let prepared = try await service.prepareSourceContinuation(request: fixture.request())
        var variants: [SourceContinuationState] = []
        var block = prepared; block.anchor.blockId = UUID(); variants.append(block)
        var word = prepared; word.anchor.word = "changed-word"; variants.append(word)
        var boundary = prepared; boundary.anchor.boundary = .chapterStart; variants.append(boundary)
        var count = prepared; count.frozenPrefixWordCount += 1; variants.append(count)
        let before = try environment.manuscriptState(fixture.book.id)
        for changed in variants {
            let current = try environment.packets.loadFactChecklist(bookId: fixture.book.id).sourceContinuation
            try environment.packets.transitionSourceContinuation(bookId: fixture.book.id, expected: current, next: changed)
            let stateBefore = try environment.factsState(fixture.book.id)
            await expectFailure { _ = try await service.runSourceContinuation(bookID: fixture.book.id, attemptID: prepared.id) }
            XCTAssertEqual(try environment.factsState(fixture.book.id), stateBefore)
            XCTAssertEqual(try environment.manuscriptState(fixture.book.id), before)
        }
        let calls = await ai.snapshot()
        XCTAssertTrue(calls.writes.isEmpty)
        XCTAssertTrue(calls.reviews.isEmpty)
    }

    private func expectFailure(file: StaticString = #filePath, line: UInt = #line,
                               _ operation: () async throws -> Void) async {
        do {
            try await operation()
            XCTFail("An invalid, stale or unreviewed continuation unexpectedly succeeded", file: file, line: line)
        } catch { }
    }
}

private struct ContinuationFileState: Equatable {
    let bytes: Data
    let modifiedAt: Date?
    init(_ url: URL) throws {
        bytes = try Data(contentsOf: url)
        modifiedAt = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
    }
}

private struct ContinuationEnvironment: Sendable {
    let root: URL
    let packets: FilePEPacketStore
    let versioning: ManuscriptVersioningService
    init(root: URL? = nil) throws {
        self.root = root ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("SourceContinuationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
        packets = try FilePEPacketStore(rootDirectory: self.root)
        versioning = try ManuscriptVersioningService(rootDirectory: self.root, packets: packets)
    }
    func service(ai: any AIService, packets override: (any PEPacketStoring)? = nil) throws -> LivingBookAdaptationService {
        LivingBookAdaptationService(versioning: versioning,
            feedbackStore: try FileFeedbackStore(rootDirectory: root),
            preferenceStore: try FileReaderPreferenceStore(rootDirectory: root), ai: ai, packets: override ?? packets)
    }
    func manuscriptState(_ id: UUID) throws -> ContinuationFileState {
        try ContinuationFileState(root.appendingPathComponent("Manuscripts/\(id.uuidString).json"))
    }
    func factsState(_ id: UUID) throws -> ContinuationFileState {
        try ContinuationFileState(root.appendingPathComponent("Packets/\(id.uuidString)-facts.json"))
    }
    func publishFixture() async throws -> ContinuationFixture {
        let source = ContinuationFixture.source()
        let bookID = UUID(), chapterID = UUID(), outlineID = UUID()
        let outlineBlocks = [ContentBlock(id: UUID(), kind: .paragraph, text: "Authored river-records outline.", orderIndex: 0)]
        let requirement = SourceGroundingRequirement(source: source, outlineRevisionID: outlineID,
            outlineContentHash: try SourceGrounding.contentHash(outlineBlocks), approvedBriefHash: "authored-continuation-brief")
        let outline = ChapterRevision(id: outlineID, chapterId: chapterID, revisionIndex: 1,
            createdAt: ContinuationFixture.date, blocks: outlineBlocks, isConsumed: false)
        let chapter = Chapter(id: chapterID, bookId: bookID, title: "River Records", orderIndex: 0,
            activeRevisionId: outlineID, revisions: [outline], manuscriptStatus: .polished, sourceGrounding: requirement)
        let initialBook = Book(id: bookID, title: "River Records", author: "Authored test fixture", chapters: [chapter])
        try await versioning.saveBook(initialBook)
        let blocks = try SourceGrounding.blocks(title: chapter.title, paragraphs: ContinuationFixture.paragraphs(), source: source)
        XCTAssertEqual(try SourceGrounding.proseWordCount(blocks, source: source), 400)
        let response = ContinuationFixture.review(paragraphs: try SourceGrounding.prose(blocks, source: source))
        let receipt = try SourceGrounding.receipt(bookID: bookID, chapterID: chapterID, baseRevisionID: outlineID,
            blocks: blocks, source: source, model: "gpt-6-astra", response: response)
        let candidate = CandidateRevision(id: UUID(), bookId: bookID, chapterId: chapterID, proposedRevisionIndex: 2,
            createdAt: ContinuationFixture.date, blocks: blocks, status: .staged, rejectionReason: nil,
            origin: .generated(style: "Authored fixture"), sourceReview: receipt)
        try await versioning.stageCandidate(candidate)
        _ = try await versioning.activateCandidate(id: candidate.id)
        let saved = try await versioning.loadBook(id: bookID)
        let book = try XCTUnwrap(saved)
        let base = try XCTUnwrap(book.chapters[0].activeRevision)
        var facts = try packets.loadFactChecklist(bookId: bookID)
        facts.sourcePilot = SourcePilotState(approvedBriefHash: requirement.approvedBriefHash,
            chapterID: chapterID, expectedRevisionID: outlineID, candidate: candidate)
        facts.evidence = [FactEvidenceItem(id: "fixture-evidence", sourceLabel: "Authored retained source",
            digest: source.text, recordedAt: ContinuationFixture.date)]
        try packets.saveFactChecklist(facts)
        return ContinuationFixture(book: book, base: base, source: source)
    }
}

private struct ContinuationFixture: Sendable {
    let book: Book
    let base: ChapterRevision
    let source: RetrievedResearchSource
    var chapterID: UUID { book.chapters[0].id }
    static let date = Date(timeIntervalSince1970: 1_800_000_000)
    static let firstQuote = "River communities kept careful records of shared boats, seasonal harvests, nearby trade, council meetings, and journeys between their home settlements."
    static let secondQuote = "Local councils described seasonal travel, preserved written accounts of exchanges, and used public gatherings to organize supplies for river journeys."
    func request() throws -> WordForwardRegenerationRequest {
        let block = base.blocks[1]
        let prose = String(block.text.dropLast(4))
        let range = try XCTUnwrap(prose.range(of: "settlements", options: .backwards))
        let anchor = RegenerationWordAnchor(bookId: book.id, chapterId: chapterID, chapterTitle: book.chapters[0].title,
            revisionId: base.id, blockId: block.id, utf16OffsetInBlock: NSRange(range, in: prose).location,
            word: "settlements", createdAt: Self.date)
        return WordForwardRegenerationRequest(anchor: anchor, intents: [.lessDetail],
            freeText: "Use clear prose while keeping only supported details.", maxFollowOnChapters: 0)
    }
    static func source() -> RetrievedResearchSource {
        let text = [Array(repeating: firstQuote, count: 5).joined(separator: " "),
            Array(repeating: secondQuote, count: 5).joined(separator: " ")].joined(separator: "\n\n")
        return RetrievedResearchSource(requestedTitle: "River Records", title: "River Records",
            canonicalURL: URL(string: "https://en.wikipedia.org/wiki/River_Records")!, pageID: 47, revisionID: 9012,
            revisionURL: URL(string: "https://en.wikipedia.org/w/index.php?oldid=9012")!,
            revisionTimestamp: date, retrievedAt: date, scope: .wikipediaOpeningExcerpt,
            text: text, textSHA256: SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined(),
            attribution: "Authored fixture only; no Wikipedia retrieval occurred.",
            attributionURL: URL(string: "https://en.wikipedia.org/w/index.php?title=River_Records&action=history")!,
            licenseName: "Fixture CC BY-SA 4.0", licenseURL: URL(string: "https://creativecommons.org/licenses/by-sa/4.0/")!,
            extractionMetadata: .init(extractionVersion: "wikipedia-opening-paragraphs-v1", paragraphLocators: [
                .init(sectionAnchor: nil, sectionTitle: "Introduction", paragraphIndex: 1),
                .init(sectionAnchor: "Records", sectionTitle: "Records", paragraphIndex: 1)
            ]))
    }
    static func paragraphs() -> [SourceDraftParagraph] {
        [.init(text: Array(repeating: firstQuote, count: 10).joined(separator: " "), citations: ["source1"]),
         .init(text: Array(repeating: secondQuote, count: 10).joined(separator: " "), citations: ["source1"])]
    }
    static func tail() -> [SourceDraftParagraph] {
        [.init(text: Array(repeating: secondQuote + " " + firstQuote, count: 5).joined(separator: " "), citations: ["source1"])]
    }
    static func review(paragraphs: [String], assessment: SourceReviewUnit.Assessment = .supported) -> SourceReviewResponse {
        SourceReviewResponse(units: paragraphs.indices.map {
            .init(index: $0, assessment: $0 == 0 ? assessment : .supported, quotes: [firstQuote, secondQuote])
        })
    }
}

private enum ContinuationTestError: Error { case unexpectedLegacyCall, injectedPersistenceFailure }

private actor ContinuationRevisionRecorder {
    private var revision: ChapterRevision?
    func record(_ value: ChapterRevision) { revision = value }
    func value() -> ChapterRevision? { revision }
}

private actor ContinuationStateRecorder {
    private var state: SourceContinuationState?
    func record(_ value: SourceContinuationState) { state = value }
    func value() -> SourceContinuationState? { state }
}

/// Intentionally omits writeSourceContinuation, exercising its default rejection.
private actor LegacyOnlyContinuationAI: AIService, SourceGroundedAI {
    nonisolated var sourceReviewModelID: String { "gpt-6-astra" }
    private var calls = 0
    func callCount() -> Int { calls }
    func writeSourcePreview(_ request: SourceWritingRequest) async throws -> [SourceDraftParagraph] {
        calls += 1; throw ContinuationTestError.unexpectedLegacyCall
    }
    func reviewSourcePreview(_ request: SourceReviewRequest) async throws -> SourceReviewResponse {
        calls += 1; throw ContinuationTestError.unexpectedLegacyCall
    }
    func adaptChapter(chapterId: UUID, promptContext: String) async throws -> ChapterRevision {
        calls += 1; throw ContinuationTestError.unexpectedLegacyCall
    }
    func makeAdaptationPlan(_ request: AdaptationPlanRequest) async throws -> AdaptationPlan {
        calls += 1; throw ContinuationTestError.unexpectedLegacyCall
    }
    func generateAdaptedChapter(_ request: AdaptationGenerateRequest) async throws -> [ContentBlock] {
        calls += 1; throw ContinuationTestError.unexpectedLegacyCall
    }
    func ask(_ request: AskRequest) async throws -> AskResponse {
        calls += 1; throw ContinuationTestError.unexpectedLegacyCall
    }
}

private actor ContinuationCountingAI: AIService, SourceGroundedAI {
    struct Calls: Sendable {
        let writes: [SourceContinuationWritingRequest]
        let reviews: [SourceReviewRequest]
        let legacy: Int
    }
    nonisolated var sourceReviewModelID: String { "gpt-6-astra" }
    nonisolated var supportsSourceContinuation: Bool { true }
    private var writes: [SourceContinuationWritingRequest] = []
    private var reviews: [SourceReviewRequest] = []
    private var legacy = 0
    private var assessments: [SourceReviewUnit.Assessment]
    private let onWrite: (@Sendable (SourceContinuationWritingRequest) async throws -> Void)?
    private let onReview: (@Sendable (SourceReviewRequest) async throws -> Void)?
    init(assessments: [SourceReviewUnit.Assessment] = [.supported],
         onWrite: (@Sendable (SourceContinuationWritingRequest) async throws -> Void)? = nil,
         onReview: (@Sendable (SourceReviewRequest) async throws -> Void)? = nil) {
        self.assessments = assessments; self.onWrite = onWrite; self.onReview = onReview
    }
    func writeSourceContinuation(_ request: SourceContinuationWritingRequest) async throws -> [SourceDraftParagraph] {
        writes.append(request)
        try await onWrite?(request)
        return ContinuationFixture.tail()
    }
    func reviewSourcePreview(_ request: SourceReviewRequest) async throws -> SourceReviewResponse {
        reviews.append(request)
        try await onReview?(request)
        let assessment = assessments.isEmpty ? .supported : assessments.removeFirst()
        return ContinuationFixture.review(paragraphs: request.paragraphs, assessment: assessment)
    }
    func snapshot() -> Calls { Calls(writes: writes, reviews: reviews, legacy: legacy) }
    func writeSourcePreview(_ request: SourceWritingRequest) async throws -> [SourceDraftParagraph] {
        legacy += 1; throw ContinuationTestError.unexpectedLegacyCall
    }
    func adaptChapter(chapterId: UUID, promptContext: String) async throws -> ChapterRevision {
        legacy += 1; throw ContinuationTestError.unexpectedLegacyCall
    }
    func makeAdaptationPlan(_ request: AdaptationPlanRequest) async throws -> AdaptationPlan {
        legacy += 1; throw ContinuationTestError.unexpectedLegacyCall
    }
    func generateAdaptedChapter(_ request: AdaptationGenerateRequest) async throws -> [ContentBlock] {
        legacy += 1; throw ContinuationTestError.unexpectedLegacyCall
    }
    func ask(_ request: AskRequest) async throws -> AskResponse {
        legacy += 1; throw ContinuationTestError.unexpectedLegacyCall
    }
}
