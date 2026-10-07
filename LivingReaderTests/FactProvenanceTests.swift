import XCTest
@testable import LivingReader

final class FactProvenanceTests: XCTestCase {
    private let bookId = UUID()
    private let chapterId = UUID()
    private let savedAt = Date(timeIntervalSince1970: 1)

    func testNewSelfVerifiedEssentialClaimIsBlockedDespiteNonemptyInventedEvidence() throws {
        let stored = FactChecklist.empty(bookId: bookId)
        let merged = FactChecklistMerge.merge(claims: [claim()], evidence: [evidence()], into: stored)
        XCTAssertEqual(merged.claims.first?.status, .unverified)
        assertBlocked(merged, chapter: chapterId)
        XCTAssertTrue(stored.claims.isEmpty)
    }

    func testModelCannotUpgradeStoredUnverifiedOrDisputedClaim() throws {
        for status in [FactVerificationStatus.unverified, .disputed] {
            var stored = vettedChecklist()
            stored.claims[0].status = status
            let merged = FactChecklistMerge.merge(claims: [claim(id: stored.claims[0].id)],
                                                  evidence: [evidence()], into: stored)
            XCTAssertEqual(merged.claims.count, 1)
            XCTAssertEqual(merged.claims[0].status, status)
            assertBlocked(merged, chapter: chapterId)
        }
    }

    func testUnchangedVettedClaimAndEvidenceRemainExactlyEqualAndPass() throws {
        let stored = vettedChecklist()
        var proposal = stored.claims[0]
        proposal.status = .unverified
        proposal.notes = "The model suggests a different note"
        var source = stored.evidence[0]
        source.recordedAt = Date()
        let merged = FactChecklistMerge.merge(claims: [proposal], evidence: [source], into: stored)
        XCTAssertEqual(merged.claims, stored.claims)
        XCTAssertEqual(merged.evidence, stored.evidence)
        XCTAssertNoThrow(try PEContinuityGate.assertActivationAllowed(
            checklist: merged, bookId: bookId, chapterId: chapterId))
    }

    func testSameIDChangedStatementChapterCitationsOrImportanceCannotInheritVerification() throws {
        let stored = vettedChecklist()
        var changedStatement = stored.claims[0]
        changedStatement.statement = "A different assertion."
        var changedChapter = stored.claims[0]
        changedChapter.chapterId = UUID()
        var changedCitations = stored.claims[0]
        changedCitations.evidenceIds = ["invented-source"]
        var weakenedImportance = stored.claims[0]
        weakenedImportance.importance = .supporting
        for proposal in [changedStatement, changedChapter, changedCitations, weakenedImportance] {
            var newSource = evidence()
            newSource.id = "invented-source"
            let merged = FactChecklistMerge.merge(claims: [proposal], evidence: [newSource], into: stored)
            XCTAssertEqual(merged.claims.first, stored.claims[0], "Vetted record must remain unchanged")
            let conflict = try XCTUnwrap(merged.claims.first { $0.id != stored.claims[0].id })
            XCTAssertEqual(conflict.status, .unverified)
            XCTAssertEqual(conflict.importance, .essential)
            XCTAssertEqual(conflict.statement, proposal.statement)
            XCTAssertEqual(conflict.chapterId, proposal.chapterId)
            assertBlocked(merged, chapter: proposal.chapterId)
        }
    }

    func testSameEvidenceIDChangedDigestSourceOrLocatorBlocksWithoutOverwritingVettedRecords() throws {
        let stored = vettedChecklist()
        var changedDigest = stored.evidence[0]
        changedDigest.digest = "Invented replacement digest."
        var changedLabel = stored.evidence[0]
        changedLabel.sourceLabel = "Invented replacement source"
        var changedLocator = stored.evidence[0]
        changedLocator.locator = "https://example.invalid/replacement"
        for source in [changedDigest, changedLabel, changedLocator] {
            for proposedClaims in [[], stored.claims] {
                let merged = FactChecklistMerge.merge(claims: proposedClaims, evidence: [source], into: stored)
                XCTAssertEqual(merged.evidence, stored.evidence)
                XCTAssertEqual(merged.claims.first, stored.claims.first)
                XCTAssertEqual(merged.claims.filter { $0.status == .unverified }.count, 1)
                assertBlocked(merged, chapter: chapterId)
            }
        }
    }

    func testBlankEvidenceEchoDoesNotEraseOrInvalidateTheStoredSource() throws {
        let stored = vettedChecklist()
        var blank = evidence()
        blank.digest = " \n "
        let merged = FactChecklistMerge.merge(claims: stored.claims, evidence: [blank], into: stored)
        XCTAssertEqual(merged.claims, stored.claims)
        XCTAssertEqual(merged.evidence, stored.evidence)
        XCTAssertNoThrow(try PEContinuityGate.assertActivationAllowed(
            checklist: merged, bookId: bookId, chapterId: chapterId))
    }

    func testInventedEvidenceCannotCompleteAnInvalidStoredVerification() throws {
        var blank = evidence()
        blank.digest = ""
        for priorEvidence in [[], [blank]] {
            var stored = vettedChecklist()
            stored.evidence = priorEvidence
            let merged = FactChecklistMerge.merge(claims: stored.claims, evidence: [evidence()], into: stored)
            XCTAssertEqual(merged.claims.first, stored.claims.first)
            XCTAssertThrowsError(try PEContinuityGate.assertActivationAllowed(
                checklist: merged, bookId: bookId, chapterId: chapterId))
        }
    }

    func testUnverifiedSupportingResearchStillMergesWithoutGrantingVerification() throws {
        var proposal = claim()
        proposal.importance = .supporting
        proposal.status = .unverified
        let first = FactChecklistMerge.merge(claims: [proposal], evidence: [evidence()],
                                             into: .empty(bookId: bookId))
        var updatedResearch = evidence()
        updatedResearch.digest = "Updated reader research notes."
        let merged = FactChecklistMerge.merge(claims: [proposal], evidence: [updatedResearch], into: first)
        XCTAssertEqual(merged.claims.first?.status, .unverified)
        XCTAssertEqual(merged.evidence.first?.digest, updatedResearch.digest)
        XCTAssertNoThrow(try PEContinuityGate.assertActivationAllowed(
            checklist: merged, bookId: bookId, chapterId: chapterId))
    }

    func testGenerationDecoderNeverTrustsModelVerifiedStatus() throws {
        let book = try BundleFixtureLoader.loadArgentinaMinimal()
        let chapter = try XCTUnwrap(book.chapters.first)
        let target = AdaptationChapterTarget(chapterId: chapter.id, chapterTitle: chapter.title,
            currentWordCount: 100, targetWordCount: 100, desiredChanges: [], mustRemainConcepts: [])
        let plan = AdaptationPlan(id: UUID(), bookId: book.id, createdAt: Date(), sourceFeedbackId: UUID(),
            preferenceUpdatesSummary: [], affectedChapterIds: [chapter.id], chapterTargets: [target],
            continuityNotes: [], reasonsFromFeedback: [], lockedChapterIds: [], isValidated: true)
        let request = AdaptationGenerateRequest(book: book, plan: plan, chapterId: chapter.id,
            chapterTitle: chapter.title, currentPlainText: "Current text", target: target,
            profile: .empty(bookId: book.id), continuityNotes: [])
        for status in ["verified", "unverified", "disputed", "invented"] {
            let json = """
            {"blocks":[{"kind":"paragraph","text":"Generated prose."}],
             "factClaims":[{"statement":"A fabricated essential assertion.","importance":"essential",
               "status":"\(status)","evidenceIds":["fake"]}],
             "evidence":[{"id":"fake","sourceLabel":"Invented","digest":"A nonempty invented digest."}]}
            """
            let generated = try AdaptationLivePrompts.decodeGeneration(json, request: request)
            XCTAssertEqual(generated.proposedClaims.first?.status, status == "disputed" ? .disputed : .unverified)
            let merged = FactChecklistMerge.merge(claims: generated.proposedClaims,
                evidence: generated.proposedEvidence, into: .empty(bookId: book.id))
            XCTAssertThrowsError(try PEContinuityGate.assertActivationAllowed(
                checklist: merged, bookId: book.id, chapterId: chapter.id))
        }
    }

    private func vettedChecklist() -> FactChecklist {
        FactChecklist(bookId: bookId, claims: [claim()], evidence: [evidence()], updatedAt: savedAt)
    }

    private func claim(id: UUID = UUID()) -> FactClaim {
        FactClaim(id: id, chapterId: chapterId, statement: "A checked fixture assertion.",
                  importance: .essential, status: .verified, evidenceIds: ["checked-source"],
                  notes: "Reviewed outside generation", updatedAt: savedAt)
    }

    private func evidence() -> FactEvidenceItem {
        FactEvidenceItem(id: "checked-source", sourceLabel: "Checked fixture source",
                         digest: "Previously reviewed source excerpt.", locator: "fixture:1", recordedAt: savedAt)
    }

    private func assertBlocked(_ checklist: FactChecklist, chapter: UUID,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try PEContinuityGate.assertActivationAllowed(
            checklist: checklist, bookId: bookId, chapterId: chapter), file: file, line: line) { error in
            guard case PEGateError.unverifiedEssentialClaim = error else {
                return XCTFail("Expected unverified essential claim, got \(error)", file: file, line: line)
            }
        }
    }
}
