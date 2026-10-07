import XCTest
@testable import LivingReader

final class FactClaimReferenceTests: XCTestCase {
    func testArbitraryIDReferencePreservesVettedRecordsWithoutDecoderGrantingVerification() throws {
        let request = try makeRequest()
        let stored = try XCTUnwrap(request.packet?.facts)
        let existing = try XCTUnwrap(stored.claims.first)
        XCTAssertNotEqual(existing.id, FactClaim.stableId(chapterId: request.chapterId, statement: existing.statement))

        for status in ["verified", "unverified", "disputed", "invented"] {
            let generated = try decode(["claimId": existing.id.uuidString, "status": status], request: request)
            var expected = existing
            expected.status = .unverified
            expected.updatedAt = decodedAt
            XCTAssertEqual(generated.proposedClaims, [expected])
            XCTAssertTrue(generated.proposedEvidence.isEmpty)
            let merged = merge(generated, into: stored)
            XCTAssertEqual(merged.claims, stored.claims)
            XCTAssertEqual(merged.evidence, stored.evidence)
            XCTAssertNoThrow(try gate(merged, request: request))
        }
    }

    func testBoundedPromptExposesActualIDsAndLongStatementReferenceResolvesExactly() throws {
        let statement = String(repeating: "Checked details. ", count: 40) + "Exact final clause."
        let request = try makeRequest(statement: statement)
        let existing = try XCTUnwrap(request.packet?.facts.claims.first)
        let prompt = PEPacketPromptAssembler.render(request.packet, focusChapterId: request.chapterId)
        XCTAssertTrue(prompt.contains("claimId=\(existing.id.uuidString)"))
        XCTAssertTrue(prompt.contains("chapterId=\(request.chapterId.uuidString) preview: "))
        XCTAssertFalse(prompt.contains("Exact final clause."), "The preview remains bounded")
        let generated = try decode(["claimId": existing.id.uuidString], request: request)
        XCTAssertEqual(generated.proposedClaims.first?.statement, statement)
        for system in [AdaptationLivePrompts.generateSystem, AdaptationLivePrompts.continueFromWordSystem] {
            XCTAssertTrue(system.contains("\"claimId\""))
            XCTAssertTrue(system.contains("Do not recreate its evidence"))
        }
    }

    func testReferenceAcceptsSuppliedExactIdentityButRejectsMutationsAndNulls() throws {
        let request = try makeRequest()
        let stored = try XCTUnwrap(request.packet?.facts)
        let existing = try XCTUnwrap(stored.claims.first)
        let exact: [String: Any] = [
            "claimId": existing.id.uuidString, "bookId": request.book.id.uuidString,
            "chapterId": existing.chapterId.uuidString, "statement": existing.statement,
            "importance": existing.importance.rawValue, "evidenceIds": existing.evidenceIds
        ]
        XCTAssertNoThrow(try gate(merge(decode(exact, request: request), into: stored), request: request))
        let mutations: [String: Any] = [
            "claimId": UUID().uuidString, "bookId": UUID().uuidString,
            "chapterId": UUID().uuidString, "statement": existing.statement + " ",
            "importance": "supporting", "evidenceIds": ["different-source"]
        ]
        for (field, mutation) in mutations {
            var changed = exact
            changed[field] = mutation
            XCTAssertThrowsError(try decode(changed, request: request), "Changed \(field) must reject")
            changed[field] = NSNull()
            XCTAssertThrowsError(try decode(changed, request: request), "Null \(field) must reject")
        }
    }

    func testUnknownMalformedUnvettedAndOutOfScopeReferencesReject() throws {
        let request = try makeRequest()
        let existing = try XCTUnwrap(request.packet?.facts.claims.first)
        for invalidID: Any in ["", "not-a-uuid", UUID().uuidString, 42, NSNull()] {
            XCTAssertThrowsError(try decode(["claimId": invalidID], request: request))
        }
        var missingPacket = request
        missingPacket.packet = nil
        var wrongBook = request
        wrongBook.packet?.facts.bookId = UUID()
        var wrongChapter = request
        wrongChapter.packet?.facts.claims[0].chapterId = UUID()
        var unknownClaim = request
        unknownClaim.packet?.facts.claims = []
        var unverified = request
        unverified.packet?.facts.claims[0].status = .unverified
        var disputed = request
        disputed.packet?.facts.claims[0].status = .disputed
        for invalidRequest in [missingPacket, wrongBook, wrongChapter, unknownClaim, unverified, disputed] {
            XCTAssertThrowsError(try decode(["claimId": existing.id.uuidString], request: invalidRequest))
        }
        XCTAssertThrowsError(try decode([:], request: request), "A proposal without an ID still needs a statement")
    }

    func testNoIDDeterministicCompatibilityAndNewEssentialClaimsRemainUnverified() throws {
        var request = try makeRequest()
        let statement = try XCTUnwrap(request.packet?.facts.claims.first?.statement)
        let stableID = FactClaim.stableId(chapterId: request.chapterId, statement: statement)
        request.packet?.facts.claims[0].id = stableID
        let stored = try XCTUnwrap(request.packet?.facts)
        let generated = try decode([
            "statement": statement, "importance": "essential", "status": "verified",
            "evidenceIds": stored.claims[0].evidenceIds
        ], request: request)
        XCTAssertEqual(generated.proposedClaims.first?.id, stableID)
        XCTAssertEqual(generated.proposedClaims.first?.status, .unverified)
        let merged = merge(generated, into: stored)
        XCTAssertEqual(merged.claims, stored.claims)
        XCTAssertNoThrow(try gate(merged, request: request))

        let newClaim = try decode([
            "statement": "A new unchecked assertion.", "importance": "essential", "status": "verified",
            "evidenceIds": ["invented"]
        ], evidence: [["id": "invented", "digest": "A fabricated digest."]], request: request)
        XCTAssertEqual(newClaim.proposedClaims.first?.status, .unverified)
        XCTAssertThrowsError(try gate(merge(newClaim, into: stored), request: request))

        let legacyOptionalNulls = try decode(["statement": statement, "importance": NSNull(),
            "status": NSNull(), "evidenceIds": NSNull()], request: request)
        XCTAssertEqual(legacyOptionalNulls.proposedClaims.first?.id, stableID)
        XCTAssertEqual(legacyOptionalNulls.proposedClaims.first?.status, .unverified)
        XCTAssertEqual(legacyOptionalNulls.proposedClaims.first?.importance, .essential)
    }

    func testCurrentStoredChecklistStillDecidesWhetherReferenceRemainsVetted() throws {
        let request = try makeRequest()
        let stored = try XCTUnwrap(request.packet?.facts)
        let generated = try decode(["claimId": stored.claims[0].id.uuidString], request: request)
        var removed = stored
        removed.claims = []
        var unverified = stored
        unverified.claims[0].status = .unverified
        var disputed = stored
        disputed.claims[0].status = .disputed
        var changedStatement = stored
        changedStatement.claims[0].statement = "Newly checked replacement statement."
        var changedChapter = stored
        changedChapter.claims[0].chapterId = UUID()
        var changedCitations = stored
        changedCitations.claims[0].evidenceIds = []
        var changedImportance = stored
        changedImportance.claims[0].importance = .supporting
        for latest in [removed, unverified, disputed, changedStatement, changedChapter, changedCitations, changedImportance] {
            XCTAssertThrowsError(try gate(merge(generated, into: latest), request: request))
        }
    }

    func testReferencedClaimCannotReplaceVettedEvidenceOrCompleteMissingSources() throws {
        let request = try makeRequest()
        let stored = try XCTUnwrap(request.packet?.facts)
        let reference = ["claimId": stored.claims[0].id.uuidString]
        let source = stored.evidence[0]
        let exact: [String: Any] = ["id": source.id, "sourceLabel": source.sourceLabel,
                                   "digest": source.digest, "locator": try XCTUnwrap(source.locator)]
        for field in ["digest", "sourceLabel", "locator"] {
            var replacement = exact
            replacement[field] = "Invented replacement"
            let generated = try decode(reference, evidence: [replacement], request: request)
            let merged = merge(generated, into: stored)
            XCTAssertEqual(merged.claims.first, stored.claims.first)
            XCTAssertEqual(merged.evidence, stored.evidence)
            XCTAssertThrowsError(try gate(merged, request: request))
        }
        var missing = request
        missing.packet?.facts.evidence = []
        var blank = request
        blank.packet?.facts.evidence[0].digest = ""
        for invalid in [missing, blank] {
            let generated = try decode(reference, evidence: [exact], request: invalid)
            XCTAssertThrowsError(try gate(merge(generated, into: XCTUnwrap(invalid.packet?.facts)), request: invalid))
        }
    }

    private let decodedAt = Date(timeIntervalSince1970: 20)

    private func makeRequest(statement: String = "A previously checked assertion.") throws -> AdaptationGenerateRequest {
        let book = try BundleFixtureLoader.loadArgentinaMinimal()
        let chapter = try XCTUnwrap(book.chapters.first)
        let target = AdaptationChapterTarget(chapterId: chapter.id, chapterTitle: chapter.title,
            currentWordCount: 100, targetWordCount: 100, desiredChanges: [], mustRemainConcepts: [])
        let plan = AdaptationPlan(id: UUID(), bookId: book.id, createdAt: decodedAt, sourceFeedbackId: UUID(),
            preferenceUpdatesSummary: [], affectedChapterIds: [chapter.id], chapterTargets: [target],
            continuityNotes: [], reasonsFromFeedback: [], lockedChapterIds: [], isValidated: true)
        var packet = PEContinuityPacket.empty(bookId: book.id)
        packet.facts.claims = [FactClaim(id: UUID(), chapterId: chapter.id, statement: statement,
            importance: .essential, status: .verified, evidenceIds: ["checked-source"],
            notes: "Checked independently of generation", updatedAt: Date(timeIntervalSince1970: 1))]
        packet.facts.evidence = [FactEvidenceItem(id: "checked-source", sourceLabel: "Checked fixture source",
            digest: "A previously reviewed excerpt.", locator: "fixture:1", recordedAt: Date(timeIntervalSince1970: 1))]
        return AdaptationGenerateRequest(book: book, plan: plan, chapterId: chapter.id,
            chapterTitle: chapter.title, currentPlainText: "Current text", target: target,
            profile: .empty(bookId: book.id), continuityNotes: [], packet: packet)
    }

    private func decode(_ claim: [String: Any], evidence: [[String: Any]] = [],
                        request: AdaptationGenerateRequest) throws -> GeneratedChapter {
        let payload: [String: Any] = ["blocks": [["kind": "paragraph", "text": "Generated prose."]],
                                      "factClaims": [claim], "evidence": evidence]
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try AdaptationLivePrompts.decodeGeneration(String(decoding: data, as: UTF8.self),
                                                          request: request, at: decodedAt)
    }

    private func merge(_ generated: GeneratedChapter, into checklist: FactChecklist) -> FactChecklist {
        FactChecklistMerge.merge(claims: generated.proposedClaims, evidence: generated.proposedEvidence,
                                 into: checklist, at: decodedAt)
    }

    private func gate(_ checklist: FactChecklist, request: AdaptationGenerateRequest) throws {
        try PEContinuityGate.assertActivationAllowed(checklist: checklist, bookId: request.book.id,
                                                     chapterId: request.chapterId)
    }
}
