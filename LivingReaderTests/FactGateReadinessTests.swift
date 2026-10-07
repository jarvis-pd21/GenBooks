import XCTest
@testable import LivingReader

/// The plan's evidence-readiness explanation must agree with the activation gate.
final class FactGateReadinessTests: XCTestCase {
    private let bookId = UUID()
    private let chapterId = UUID()
    private let otherChapterId = UUID()
    private let ready = "Fact gate ready — Apply may activate"
    private let blocked = "Fact gate will block Apply until these are resolved"
    private let noClaims = "No fact claims recorded yet for the planned chapters"

    func testVerifiedEssentialWithoutCitationsIsNotReady() {
        let facts = checklist(claims: [claim(evidenceIds: [])])
        let notes = PEContinuityGate.readinessNotes(checklist: facts, chapterIds: [chapterId])

        XCTAssertTrue(notes.contains("Essential claims verified: 1 of 1"))
        XCTAssertTrue(notes.contains("Essential claims missing evidence citations: 1"))
        XCTAssertTrue(notes.contains(blocked))
        XCTAssertFalse(notes.contains(ready), "Verified status alone cannot satisfy the evidence contract")
        XCTAssertThrowsError(try PEContinuityGate.assertActivationAllowed(
            checklist: facts, bookId: bookId, chapterId: chapterId
        )) { error in
            guard case PEGateError.missingEvidenceIds(_, let ids) = error else {
                return XCTFail("Expected missingEvidenceIds, got \(error)")
            }
            XCTAssertTrue(ids.isEmpty)
        }
    }

    func testMissingCitationCountIncludesOnlyScopedEssentialClaims() {
        let facts = checklist(claims: [
            claim(evidenceIds: []),
            claim(status: .unverified, evidenceIds: []),
            claim(importance: .supporting, evidenceIds: []),
            claim(chapter: otherChapterId, evidenceIds: []),
            claim(evidenceIds: ["ev-ok"])
        ], evidence: [evidence()])
        let notes = PEContinuityGate.readinessNotes(checklist: facts, chapterIds: [chapterId, chapterId])

        XCTAssertTrue(notes.contains("Essential claims missing evidence citations: 2"))
        XCTAssertTrue(notes.contains("Essential claims verified: 2 of 3"))
        XCTAssertTrue(notes.contains(blocked))
        XCTAssertFalse(notes.contains(ready))
    }

    func testOtherChapterProblemsDoNotBlockReadyPlannedChapter() throws {
        let facts = checklist(claims: [
            claim(evidenceIds: ["ev-ok"]),
            claim(chapter: otherChapterId, evidenceIds: []),
            claim(chapter: otherChapterId, status: .disputed, evidenceIds: ["ev-unknown"])
        ], evidence: [evidence()])
        let notes = PEContinuityGate.readinessNotes(checklist: facts, chapterIds: [chapterId])

        XCTAssertEqual(notes, ["Essential claims verified: 1 of 1", ready])
        XCTAssertNoThrow(try PEContinuityGate.assertActivationAllowed(
            checklist: facts, bookId: bookId, chapterId: chapterId
        ))
    }

    func testEmptyReadinessScopeStillIncludesAllRecordedChapters() {
        let facts = checklist(claims: [
            claim(evidenceIds: ["ev-ok"]),
            claim(chapter: otherChapterId, evidenceIds: [])
        ], evidence: [evidence()])
        let notes = PEContinuityGate.readinessNotes(checklist: facts, chapterIds: [])

        XCTAssertEqual(notes, PEContinuityGate.readinessNotes(
            checklist: facts, chapterIds: [chapterId, otherChapterId]
        ))
        XCTAssertTrue(notes.contains("Essential claims missing evidence citations: 1"))
        XCTAssertFalse(notes.contains(ready))
        // Readiness uses an empty scope to mean all claims. The activation
        // overload checks only the chapters supplied, so enumerate them here.
        XCTAssertThrowsError(try PEContinuityGate.assertActivationAllowed(
            checklist: facts, bookId: bookId, chapterIds: [chapterId, otherChapterId]
        ))
    }

    func testSupportingClaimsWithoutCitationsRemainReady() throws {
        let facts = checklist(claims: FactVerificationStatus.allCases.map {
            claim(importance: .supporting, status: $0, evidenceIds: [])
        })
        let notes = PEContinuityGate.readinessNotes(checklist: facts, chapterIds: [chapterId])

        XCTAssertEqual(notes, ["Essential claims verified: 0 of 0", ready])
        XCTAssertNoThrow(try PEContinuityGate.assertActivationAllowed(
            checklist: facts, bookId: bookId, chapterId: chapterId
        ))
    }

    func testReadinessMatchesGateForImportanceStatusAndEvidenceMatrix() {
        let evidenceCases: [(name: String, ids: [String], items: [FactEvidenceItem])] = [
            ("uncited", [], [evidence()]),
            ("unknown", ["ev-unknown"], [evidence()]),
            ("blank digest", ["ev-ok"], [evidence(digest: " \n\t ")]),
            ("usable", ["ev-ok"], [evidence()])
        ]

        for importance in FactClaimImportance.allCases {
            for status in FactVerificationStatus.allCases {
                for sample in evidenceCases {
                    let context = "\(importance.rawValue), \(status.rawValue), \(sample.name)"
                    let facts = checklist(claims: [claim(
                        importance: importance, status: status, evidenceIds: sample.ids
                    )], evidence: sample.items)
                    let notes = PEContinuityGate.readinessNotes(checklist: facts, chapterIds: [chapterId])
                    let allowed = (importance == .supporting || status == .verified)
                        && (sample.name == "usable" || (sample.name == "uncited" && importance == .supporting))

                    XCTAssertEqual(notes.contains(ready), allowed, context)
                    XCTAssertEqual(notes.contains(blocked), !allowed, context)
                    XCTAssertEqual(notes.contains("Essential claims missing evidence citations: 1"),
                                   importance == .essential && sample.ids.isEmpty, context)
                    do {
                        try PEContinuityGate.assertActivationAllowed(
                            checklist: facts, bookId: bookId, chapterId: chapterId
                        )
                        XCTAssertTrue(allowed, "Activation unexpectedly allowed: \(context)")
                    } catch {
                        XCTAssertFalse(allowed, "Activation unexpectedly blocked: \(context): \(error)")
                    }
                }
            }
        }
    }

    func testNoClaimsMessageAndEmptyScopeBehaviorStayUnchanged() {
        let empty = FactChecklist.empty(bookId: bookId)
        XCTAssertEqual(PEContinuityGate.readinessNotes(checklist: empty, chapterIds: []), [noClaims])
        XCTAssertEqual(PEContinuityGate.readinessNotes(checklist: empty, chapterIds: [chapterId]), [noClaims])

        let elsewhere = checklist(claims: [claim(chapter: otherChapterId, evidenceIds: [])])
        XCTAssertEqual(PEContinuityGate.readinessNotes(checklist: elsewhere, chapterIds: [chapterId]), [noClaims])
    }

    func testPlanReportsUncitedEssentialAndRejectedApplyPreservesStoredBookAndPackets() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FactGateReadiness-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let packets = try FilePEPacketStore(rootDirectory: root)
        let versioning = try ManuscriptVersioningService(rootDirectory: root, packets: packets)
        let feedbackStore = try FileFeedbackStore(rootDirectory: root)
        let preferenceStore = try FileReaderPreferenceStore(rootDirectory: root)
        let ai = MockAIService()
        let service = LivingBookAdaptationService(
            versioning: versioning,
            feedbackStore: feedbackStore,
            preferenceStore: preferenceStore,
            ai: ai,
            packets: packets
        )
        let book = try BundleFixtureLoader.loadArgentinaMinimal()
        let consumedChapter = ArgentinaFixtureIDs.chapter1
        let consumedRevision = ArgentinaFixtureIDs.chapter1Revision1
        let unreadChapter = ArgentinaFixtureIDs.chapter2
        try await versioning.saveBook(book)
        try await service.finishChapter(bookId: book.id, chapterId: consumedChapter, revisionId: consumedRevision)
        let uncited = FactClaim(
            chapterId: unreadChapter,
            statement: "This stored essential claim has no cited evidence.",
            importance: .essential,
            status: .verified,
            evidenceIds: []
        )
        try packets.saveFactChecklist(FactChecklist(
            bookId: book.id, claims: [uncited], evidence: [], updatedAt: Date()
        ))

        let plan = try await service.submitFeedbackAndPlan(book: book, feedback: ChapterFeedback(
            id: UUID(), bookId: book.id, chapterId: consumedChapter, revisionId: consumedRevision,
            overall: .fine, moreOf: [.stories], lessOf: [.repetition],
            freeText: "Keep the traveller's eye", createdAt: Date()
        ))
        XCTAssertTrue(plan.affectedChapterIds.contains(unreadChapter))
        let notes = try XCTUnwrap(plan.factGateNotes)
        XCTAssertTrue(notes.contains("Essential claims missing evidence citations: 1"))
        XCTAssertTrue(notes.contains(blocked))
        XCTAssertFalse(notes.contains(ready))
        let before = try storedFiles(at: root)
        XCTAssertFalse(before.isEmpty)

        do {
            _ = try await service.applyPlan(book: book, plan: plan)
            XCTFail("Apply must reject the same missing citation reported by the plan")
        } catch let error as PEGateError {
            guard case .missingEvidenceIds(let claimId, let ids) = error else {
                return XCTFail("Expected missingEvidenceIds, got \(error)")
            }
            XCTAssertEqual(claimId, uncited.id)
            XCTAssertTrue(ids.isEmpty)
        }

        XCTAssertEqual(try storedFiles(at: root), before,
                       "Rejected Apply must not change manuscript, consumed ledger, candidates, or packets")
        let past = try await versioning.readableRevision(bookId: book.id, chapterId: consumedChapter)
        let future = try await versioning.readableRevision(bookId: book.id, chapterId: unreadChapter)
        XCTAssertEqual(past.id, consumedRevision)
        XCTAssertEqual(future.id, ArgentinaFixtureIDs.chapter2Revision1)
        let state = await service.currentState()
        XCTAssertEqual(state, .failed)
        XCTAssertEqual(ai.askCallCount, 0)
        XCTAssertNotNil(ai.lastGenerateRequest, "Exercise Apply's real post-generation fact gate")
    }

    private func claim(
        chapter: UUID? = nil,
        importance: FactClaimImportance = .essential,
        status: FactVerificationStatus = .verified,
        evidenceIds: [String]
    ) -> FactClaim {
        FactClaim(chapterId: chapter ?? chapterId, statement: "A fixture claim",
                  importance: importance, status: status, evidenceIds: evidenceIds)
    }

    private func evidence(digest: String = "A nonempty source digest.") -> FactEvidenceItem {
        FactEvidenceItem(id: "ev-ok", sourceLabel: "Fixture source", digest: digest)
    }

    private func checklist(claims: [FactClaim], evidence: [FactEvidenceItem] = []) -> FactChecklist {
        FactChecklist(bookId: bookId, claims: claims, evidence: evidence, updatedAt: Date())
    }

    private func storedFiles(at root: URL) throws -> [String: Data] {
        let entries = try XCTUnwrap(FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey]
        ))
        var files: [String: Data] = [:]
        for case let url as URL in entries {
            if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                files[String(url.path.dropFirst(root.path.count + 1))] = try Data(contentsOf: url)
            }
        }
        return files
    }
}
