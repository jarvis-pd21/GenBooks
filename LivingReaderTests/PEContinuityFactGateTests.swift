import XCTest
@testable import LivingReader

/// PE continuity packet + fact gate for Astra generation / adaptation.
/// RDR-910…913.
final class PEContinuityFactGateTests: XCTestCase {
    private var root: URL!
    private var versioning: ManuscriptVersioningService!
    private var feedbackStore: FileFeedbackStore!
    private var preferenceStore: FileReaderPreferenceStore!
    private var packets: FilePEPacketStore!
    private var ai: MockAIService!
    private var service: LivingBookAdaptationService!
    private var book: Book!

    private let ch1 = ArgentinaFixtureIDs.chapter1
    private let ch2 = ArgentinaFixtureIDs.chapter2
    private let v1 = ArgentinaFixtureIDs.chapter1Revision1

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PEContinuity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        packets = try FilePEPacketStore(rootDirectory: root)
        versioning = try ManuscriptVersioningService(rootDirectory: root, packets: packets)
        feedbackStore = try FileFeedbackStore(rootDirectory: root)
        preferenceStore = try FileReaderPreferenceStore(rootDirectory: root)
        ai = MockAIService()
        service = LivingBookAdaptationService(
            versioning: versioning,
            feedbackStore: feedbackStore,
            preferenceStore: preferenceStore,
            ai: ai,
            packets: packets
        )
        book = try BundleFixtureLoader.loadArgentinaMinimal()
        try await versioning.saveBook(book)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        root = nil
        versioning = nil
        feedbackStore = nil
        preferenceStore = nil
        packets = nil
        ai = nil
        service = nil
        book = nil
    }

    // MARK: - Codable + store

    /// RDR-910: all three packets round-trip and survive a store reopen.
    func testPacketsRoundTripAndSurviveStoreReopen() throws {
        let profile = ReaderPreferenceEngine.apply(feedback: feedback(overall: .fine), to: .empty(bookId: book.id))
        let brief = try packets.refreshBrief(book: book, profile: profile)

        let entry = ContinuityEntry(
            id: UUID(),
            chapterId: ch1,
            chapterTitle: "Before the Nation",
            chapterOrderIndex: 1,
            revisionId: v1,
            digest: "The river plate settlements bargain with the interior.",
            establishedFacts: ["buenos aires"],
            openThreads: ["Who controls the customs house?"],
            isConsumed: true,
            recordedAt: Date()
        )
        try packets.saveContinuity(
            ContinuityState(
                bookId: book.id,
                timeline: [entry],
                carriedThreads: ["Who controls the customs house?"],
                updatedAt: Date()
            )
        )
        try packets.saveFactChecklist(
            FactChecklist(
                bookId: book.id,
                claims: [claim(chapterId: ch2, statement: "The Cabildo met in 1810.", status: .verified, evidenceIds: ["ev-cabildo"])],
                evidence: [evidence(id: "ev-cabildo", digest: "Cabildo abierto convened 22 May 1810.")],
                updatedAt: Date()
            )
        )

        let reopened = try FilePEPacketStore(rootDirectory: root)
        let packet = try reopened.loadPacket(bookId: book.id)
        let reloadedBrief = try XCTUnwrap(packet.brief)
        XCTAssertEqual(reloadedBrief.bookId, brief.bookId)
        XCTAssertEqual(reloadedBrief.voice, brief.voice)
        XCTAssertEqual(reloadedBrief.moreOfEmphasis, brief.moreOfEmphasis)
        XCTAssertEqual(reloadedBrief.lessOfEmphasis, brief.lessOfEmphasis)
        XCTAssertEqual(reloadedBrief.readerNotes, brief.readerNotes)
        XCTAssertEqual(reloadedBrief.nonNegotiables, ReaderBrief.standingNonNegotiables)
        XCTAssertFalse(reloadedBrief.isStale(against: profile), "Whole-second storage must not fake staleness")
        XCTAssertEqual(packet.continuity.timeline.count, 1)
        XCTAssertTrue(packet.continuity.timeline[0].isConsumed)
        XCTAssertEqual(packet.facts.claims.count, 1)
        XCTAssertEqual(packet.facts.evidence.first?.id, "ev-cabildo")
    }

    /// RDR-910: the brief is a projection of `ReaderPreferenceProfile`, not a
    /// second preference store — it goes stale until the engine's profile is re-read.
    func testReaderBriefIsProjectionOfPreferenceProfile() throws {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let applied = ReaderPreferenceEngine.apply(
            feedback: feedback(overall: .excellent, moreOf: [.stories, .economics], lessOf: [.dates]),
            to: .empty(bookId: book.id, at: t0),
            at: t0.addingTimeInterval(60)
        )
        let brief = ReaderBrief.make(book: book, profile: applied)

        XCTAssertEqual(brief.voice, applied.overallTone)
        XCTAssertTrue(brief.moreOfEmphasis.contains(FeedbackMoreTopic.stories.rawValue))
        XCTAssertTrue(brief.lessOfEmphasis.contains(FeedbackLessTopic.dates.rawValue))
        XCTAssertFalse(brief.isStale(against: applied))

        let evolved = ReaderPreferenceEngine.apply(
            feedback: feedback(overall: .needsImprovement),
            to: applied,
            at: t0.addingTimeInterval(120)
        )
        XCTAssertTrue(brief.isStale(against: evolved), "Brief must follow the profile, never lead it")

        let refreshed = try packets.refreshBrief(book: book, profile: evolved)
        XCTAssertEqual(refreshed.voice, "substantive_rewrite_unread")
        XCTAssertEqual(
            refreshed.sourceProfileUpdatedAt.timeIntervalSince1970,
            evolved.updatedAt.timeIntervalSince1970,
            accuracy: 1
        )
    }

    // MARK: - Continuity merge

    /// RDR-911: a delta appends unseen chapters and updates unread ones.
    func testContinuityMergeAppendsAndUpdatesUnreadEntries() throws {
        let state = ContinuityState.empty(bookId: book.id)
        let first = try ContinuityMerge.merge(
            ContinuityDelta(bookId: book.id, entries: [entry(chapterId: ch2, order: 2, digest: "First pass")]),
            into: state
        )
        XCTAssertEqual(first.appendedChapterIds, [ch2])
        XCTAssertTrue(first.updatedChapterIds.isEmpty)

        let second = try ContinuityMerge.merge(
            ContinuityDelta(bookId: book.id, entries: [entry(chapterId: ch2, order: 2, digest: "Second pass")]),
            into: first.state
        )
        XCTAssertEqual(second.updatedChapterIds, [ch2])
        XCTAssertTrue(second.appendedChapterIds.isEmpty)
        XCTAssertEqual(second.state.timeline.count, 1, "One entry per chapter")
        XCTAssertEqual(second.state.timeline[0].digest, "Second pass")
        XCTAssertEqual(
            second.state.timeline[0].id,
            first.state.timeline[0].id,
            "Updating an unread entry keeps its identity"
        )
    }

    /// RDR-911: a consumed timeline entry is never rewritten by a later delta.
    func testContinuityMergePreservesConsumedEntryVerbatim() throws {
        var consumed = entry(chapterId: ch1, order: 1, digest: "As the reader actually read it")
        consumed.isConsumed = true
        consumed.establishedFacts = ["buenos aires"]
        let state = ContinuityState(
            bookId: book.id,
            timeline: [consumed],
            carriedThreads: [],
            updatedAt: Date()
        )

        let result = try ContinuityMerge.merge(
            ContinuityDelta(
                bookId: book.id,
                entries: [
                    entry(chapterId: ch1, order: 1, digest: "Rewritten history"),
                    entry(chapterId: ch2, order: 2, digest: "Fresh unread chapter")
                ]
            ),
            into: state
        )

        XCTAssertEqual(result.preservedConsumedChapterIds, [ch1])
        XCTAssertEqual(result.appendedChapterIds, [ch2])
        let survivor = try XCTUnwrap(result.state.entry(chapterId: ch1))
        XCTAssertEqual(survivor, consumed, "Consumed entry must be byte-identical after a merge")
        XCTAssertEqual(result.state.entry(chapterId: ch2)?.digest, "Fresh unread chapter")
    }

    /// RDR-911: threads opened by merged entries carry forward; resolved ones drop.
    func testContinuityMergeCarriesAndResolvesThreads() throws {
        var opening = entry(chapterId: ch2, order: 2, digest: "Opens a question")
        opening.openThreads = ["Who pays for the port?"]
        let opened = try ContinuityMerge.merge(
            ContinuityDelta(bookId: book.id, entries: [opening], newThreads: ["Does the interior revolt?"]),
            into: .empty(bookId: book.id)
        )
        XCTAssertEqual(opened.state.carriedThreads.count, 2)

        let resolved = try ContinuityMerge.merge(
            ContinuityDelta(
                bookId: book.id,
                entries: [entry(chapterId: ch2, order: 2, digest: "Answers it")],
                resolvedThreads: ["who pays for the port?"]
            ),
            into: opened.state
        )
        XCTAssertEqual(resolved.state.carriedThreads, ["Does the interior revolt?"])
    }

    /// RDR-911: a delta for a different book is refused outright.
    func testContinuityMergeRejectsBookMismatch() {
        let foreign = ContinuityDelta(bookId: UUID(), entries: [entry(chapterId: ch2, order: 2, digest: "x")])
        XCTAssertThrowsError(try ContinuityMerge.merge(foreign, into: .empty(bookId: book.id))) { error in
            guard case PEGateError.bookMismatch = error else {
                return XCTFail("Expected bookMismatch, got \(error)")
            }
        }
    }

    /// RDR-911: finishing a chapter pins its continuity entry as immutable.
    func testFinishChapterPinsConsumedContinuityEntry() async throws {
        try await service.finishChapter(bookId: book.id, chapterId: ch1, revisionId: v1)

        let state = try packets.loadContinuity(bookId: book.id)
        let pinned = try XCTUnwrap(state.entry(chapterId: ch1))
        XCTAssertTrue(pinned.isConsumed)
        XCTAssertEqual(pinned.revisionId, v1)
        XCTAssertFalse(pinned.digest.isEmpty)
    }

    // MARK: - Fact gate reject paths

    /// RDR-912: a claim citing an evidence id that does not resolve blocks activation.
    func testGateRejectsMissingEvidenceIds() {
        let checklist = FactChecklist(
            bookId: book.id,
            claims: [claim(chapterId: ch2, statement: "Rosas fell in 1852.", status: .verified, evidenceIds: ["ev-absent"])],
            evidence: [],
            updatedAt: Date()
        )
        assertGate(checklist, chapterId: ch2) { error in
            guard case PEGateError.missingEvidenceIds(_, let ids) = error else {
                return XCTFail("Expected missingEvidenceIds, got \(error)")
            }
            XCTAssertEqual(ids, ["ev-absent"])
        }
    }

    /// RDR-912: an essential claim that cites nothing at all is missing evidence.
    func testGateRejectsEssentialClaimWithNoEvidenceIds() {
        let checklist = FactChecklist(
            bookId: book.id,
            claims: [claim(chapterId: ch2, statement: "The port financed the war.", status: .verified, evidenceIds: [])],
            evidence: [],
            updatedAt: Date()
        )
        assertGate(checklist, chapterId: ch2) { error in
            guard case PEGateError.missingEvidenceIds(_, let ids) = error else {
                return XCTFail("Expected missingEvidenceIds, got \(error)")
            }
            XCTAssertTrue(ids.isEmpty)
        }
    }

    /// RDR-912: evidence recorded without a digest is a stub, not a source.
    func testGateRejectsEmptyEvidenceDigest() {
        let checklist = FactChecklist(
            bookId: book.id,
            claims: [claim(chapterId: ch2, statement: "Immigration reshaped the litoral.", status: .verified, evidenceIds: ["ev-stub"])],
            evidence: [evidence(id: "ev-stub", digest: "   ")],
            updatedAt: Date()
        )
        assertGate(checklist, chapterId: ch2) { error in
            guard case PEGateError.emptyEvidenceDigest(let id) = error else {
                return XCTFail("Expected emptyEvidenceDigest, got \(error)")
            }
            XCTAssertEqual(id, "ev-stub")
        }
    }

    /// RDR-912: essential claims may not go live while still unverified.
    func testGateRejectsUnverifiedEssentialClaim() {
        let checklist = FactChecklist(
            bookId: book.id,
            claims: [claim(chapterId: ch2, statement: "Inflation began in 1948.", status: .unverified, evidenceIds: ["ev-ok"])],
            evidence: [evidence(id: "ev-ok", digest: "Central bank series, 1946–1952.")],
            updatedAt: Date()
        )
        assertGate(checklist, chapterId: ch2) { error in
            guard case PEGateError.unverifiedEssentialClaim(_, let status) = error else {
                return XCTFail("Expected unverifiedEssentialClaim, got \(error)")
            }
            XCTAssertEqual(status, .unverified)
        }
    }

    /// RDR-912: supporting claims may ship unverified; the gate only holds essentials.
    func testGateAllowsUnverifiedSupportingClaimAndCompleteEssentials() throws {
        let checklist = FactChecklist(
            bookId: book.id,
            claims: [
                claim(chapterId: ch2, statement: "Cafés argued about trade.", importance: .supporting, status: .unverified, evidenceIds: ["ev-ok"]),
                claim(chapterId: ch2, statement: "The Cabildo met in 1810.", status: .verified, evidenceIds: ["ev-ok"])
            ],
            evidence: [evidence(id: "ev-ok", digest: "Cabildo abierto convened 22 May 1810.")],
            updatedAt: Date()
        )
        XCTAssertNoThrow(
            try PEContinuityGate.assertActivationAllowed(checklist: checklist, bookId: book.id, chapterId: ch2)
        )
    }

    /// RDR-912: the gate is scoped to the chapter being activated.
    func testGateIgnoresOtherChaptersProblems() throws {
        let checklist = FactChecklist(
            bookId: book.id,
            claims: [claim(chapterId: ch1, statement: "Unverified essential elsewhere.", status: .unverified, evidenceIds: ["ev-absent"])],
            evidence: [],
            updatedAt: Date()
        )
        XCTAssertNoThrow(
            try PEContinuityGate.assertActivationAllowed(checklist: checklist, bookId: book.id, chapterId: ch2)
        )
        assertGate(checklist, chapterId: ch1) { _ in }
    }

    // MARK: - Activation gate (versioning choke point)

    /// RDR-912: the gate runs where `activeRevisionId` flips, so a structurally
    /// valid candidate is still refused and the prior revision stays readable.
    func testActivateCandidateRejectedByStoredChecklistLeavesPriorRevisionReadable() async throws {
        try packets.saveFactChecklist(
            FactChecklist(
                bookId: book.id,
                claims: [claim(chapterId: ch2, statement: "Unbacked essential.", status: .unverified, evidenceIds: ["ev-absent"])],
                evidence: [],
                updatedAt: Date()
            )
        )

        let before = try JSONCoding.encoder.encode(try await versioning.loadBook(id: book.id)!)
        let candidate = CandidateRevision(
            id: UUID(),
            bookId: book.id,
            chapterId: ch2,
            proposedRevisionIndex: 2,
            createdAt: Date(),
            blocks: [ContentBlock(id: UUID(), kind: .paragraph, text: "Structurally fine prose.", orderIndex: 0)],
            status: .staged,
            rejectionReason: nil
        )
        try await versioning.stageCandidate(candidate)

        do {
            _ = try await versioning.activateCandidate(id: candidate.id)
            XCTFail("Fact gate should have refused activation")
        } catch let error as PEGateError {
            guard case .missingEvidenceIds = error else {
                return XCTFail("Expected missingEvidenceIds, got \(error)")
            }
        }

        let after = try JSONCoding.encoder.encode(try await versioning.loadBook(id: book.id)!)
        XCTAssertEqual(after, before, "Manuscript bytes must be untouched by a gate rejection")
        let readable = try await versioning.readableRevision(bookId: book.id, chapterId: ch2)
        XCTAssertEqual(readable.id, ArgentinaFixtureIDs.chapter2Revision1)
    }

    // MARK: - Apply-path reject + consumed past

    /// RDR-913: model self-verification cannot authorize an essential claim —
    /// the book is unchanged and the consumed past is still exactly v1.
    func testModelVerifiedEssentialClaimBlocksApplyAndLeavesConsumedPastUnchanged() async throws {
        try await service.finishChapter(bookId: book.id, chapterId: ch1, revisionId: v1)
        let plan = try await service.submitFeedbackAndPlan(book: book, feedback: feedback(overall: .fine))

        let before = try JSONCoding.encoder.encode(try await versioning.loadBook(id: book.id)!)
        let continuityBefore = try packets.loadContinuity(bookId: book.id)

        ai.stubGeneratedPacket { request in
            GeneratedChapter(
                blocks: [],
                proposedClaims: [
                    FactClaim(
                        id: FactClaim.stableId(chapterId: request.chapterId, statement: "Perón nationalised the railways in 1948."),
                        chapterId: request.chapterId,
                        statement: "Perón nationalised the railways in 1948.",
                        importance: .essential,
                        status: .verified,
                        evidenceIds: ["ev-rail"]
                    )
                ],
                proposedEvidence: [self.evidence(id: "ev-rail", digest: "Ferrocarriles Argentinos founding decree.")]
            )
        }

        do {
            _ = try await service.applyPlan(book: book, plan: plan)
            XCTFail("Apply should have been blocked by the fact gate")
        } catch let error as PEGateError {
            guard case .unverifiedEssentialClaim = error else {
                return XCTFail("Expected unverifiedEssentialClaim, got \(error)")
            }
        }

        let after = try JSONCoding.encoder.encode(try await versioning.loadBook(id: book.id)!)
        XCTAssertEqual(after, before, "Soft-fail must leave the readable book byte-identical")

        let consumed = try await versioning.retrieveConsumedRevision(bookId: book.id, chapterId: ch1)
        XCTAssertEqual(consumed?.id, v1)
        let ch1Readable = try await versioning.readableRevision(bookId: book.id, chapterId: ch1)
        XCTAssertEqual(ch1Readable.id, v1)
        let ch2Readable = try await versioning.readableRevision(bookId: book.id, chapterId: ch2)
        XCTAssertEqual(
            ch2Readable.id,
            ArgentinaFixtureIDs.chapter2Revision1,
            "Prior unread revision stays readable"
        )

        let checklistAfter = try packets.loadFactChecklist(bookId: book.id)
        XCTAssertTrue(checklistAfter.claims.isEmpty, "A blocked Apply must not record its own claims")
        XCTAssertEqual(
            try packets.loadContinuity(bookId: book.id).timeline.map(\.revisionId),
            continuityBefore.timeline.map(\.revisionId),
            "Continuity must not advance for a revision that never activated"
        )
        let state = await service.currentState()
        XCTAssertEqual(state, .failed)
    }

    /// RDR-913: a claim citing evidence the checklist has never seen blocks Apply.
    func testMissingEvidenceIdBlocksApplyAndKeepsBookUnchanged() async throws {
        try await service.finishChapter(bookId: book.id, chapterId: ch1, revisionId: v1)
        let plan = try await service.submitFeedbackAndPlan(book: book, feedback: feedback(overall: .needsImprovement))
        let before = try JSONCoding.encoder.encode(try await versioning.loadBook(id: book.id)!)

        ai.stubGeneratedPacket { request in
            GeneratedChapter(
                blocks: [],
                proposedClaims: [
                    FactClaim(
                        chapterId: request.chapterId,
                        statement: "The 1853 constitution settled federalism.",
                        importance: .essential,
                        status: .verified,
                        evidenceIds: ["ev-never-recorded"]
                    )
                ]
            )
        }

        do {
            _ = try await service.applyPlan(book: book, plan: plan)
            XCTFail("Apply should have been blocked by the fact gate")
        } catch let error as PEGateError {
            guard case .missingEvidenceIds = error else {
                return XCTFail("Expected missingEvidenceIds, got \(error)")
            }
        }

        let after = try JSONCoding.encoder.encode(try await versioning.loadBook(id: book.id)!)
        XCTAssertEqual(after, before)
        XCTAssertTrue(try packets.loadFactChecklist(bookId: book.id).evidence.isEmpty)
    }

    /// RDR-913: a complete checklist activates, records the claims, and advances
    /// continuity for the adapted chapter without touching the consumed entry.
    func testCompleteChecklistActivatesAndAdvancesContinuity() async throws {
        try await service.finishChapter(bookId: book.id, chapterId: ch1, revisionId: v1)
        let plan = try await service.submitFeedbackAndPlan(book: book, feedback: feedback(overall: .fine))
        let consumedBefore = try XCTUnwrap(try packets.loadContinuity(bookId: book.id).entry(chapterId: ch1))
        try seedVerifiedCabildoClaims(for: plan)

        ai.stubGeneratedPacket { request in
            GeneratedChapter(
                blocks: [],
                continuityDelta: ContinuityDelta(
                    bookId: self.book.id,
                    entries: [
                        ContinuityEntry(
                            id: UUID(),
                            chapterId: request.chapterId,
                            chapterTitle: request.chapterTitle,
                            chapterOrderIndex: 0,
                            revisionId: UUID(),
                            digest: "The adapted chapter carries the port/interior bargain forward.",
                            establishedFacts: ["buenos aires"],
                            openThreads: ["Who pays for the port?"],
                            isConsumed: false,
                            recordedAt: Date()
                        )
                    ]
                ),
                proposedClaims: [
                    FactClaim(
                        id: FactClaim.stableId(chapterId: request.chapterId, statement: "The Cabildo abierto met in May 1810."),
                        chapterId: request.chapterId,
                        statement: "The Cabildo abierto met in May 1810.",
                        importance: .essential,
                        status: .unverified,
                        evidenceIds: ["ev-cabildo"]
                    )
                ],
                proposedEvidence: [self.evidence(id: "ev-cabildo", digest: "Cabildo abierto convened 22 May 1810.")]
            )
        }

        let activated = try await service.applyPlan(book: book, plan: plan)
        let adapted = try XCTUnwrap(activated.first)

        let checklist = try packets.loadFactChecklist(bookId: book.id)
        XCTAssertEqual(checklist.claims(chapterId: adapted.chapterId).count, 1)
        XCTAssertEqual(checklist.evidence.count, 1, "A shared evidence id upserts instead of duplicating")
        XCTAssertEqual(checklist.evidence.first?.id, "ev-cabildo")

        let continuity = try packets.loadContinuity(bookId: book.id)
        let advanced = try XCTUnwrap(continuity.entry(chapterId: adapted.chapterId))
        XCTAssertEqual(advanced.revisionId, adapted.id, "Entry is pinned to the revision that activated")
        XCTAssertFalse(advanced.isConsumed)
        XCTAssertTrue(continuity.carriedThreads.contains("Who pays for the port?"))

        XCTAssertEqual(
            continuity.entry(chapterId: ch1),
            consumedBefore,
            "Consumed continuity entry unchanged by a successful Apply"
        )
        let ch1Readable = try await versioning.readableRevision(bookId: book.id, chapterId: ch1)
        XCTAssertEqual(ch1Readable.id, v1)
    }

    /// RDR-912: a model proposal can never downgrade a claim a human verified.
    func testProposalCannotRegressVerifiedClaimOrBlankRecordedDigest() throws {
        let claimId = FactClaim.stableId(chapterId: ch2, statement: "The Cabildo met in 1810.")
        let stored = FactChecklist(
            bookId: book.id,
            claims: [
                FactClaim(
                    id: claimId,
                    chapterId: ch2,
                    statement: "The Cabildo met in 1810.",
                    importance: .essential,
                    status: .verified,
                    evidenceIds: ["ev-cabildo"]
                )
            ],
            evidence: [evidence(id: "ev-cabildo", digest: "Cabildo abierto convened 22 May 1810.")],
            updatedAt: Date()
        )

        let merged = FactChecklistMerge.merge(
            claims: [
                FactClaim(
                    id: claimId,
                    chapterId: ch2,
                    statement: "The Cabildo met in 1810.",
                    importance: .essential,
                    status: .unverified,
                    evidenceIds: ["ev-cabildo"]
                )
            ],
            evidence: [evidence(id: "ev-cabildo", digest: "")],
            into: stored
        )

        XCTAssertEqual(merged.claims.count, 1)
        XCTAssertEqual(merged.claims[0].status, .verified)
        XCTAssertEqual(merged.evidence[0].digest, "Cabildo abierto convened 22 May 1810.")
        XCTAssertNoThrow(
            try PEContinuityGate.assertActivationAllowed(checklist: merged, bookId: book.id, chapterId: ch2)
        )
    }

    // MARK: - Prompt assembly

    /// RDR-910: packet sections render in the documented assembly order and mark
    /// consumed continuity as immutable.
    func testPacketRendersSectionsInAssemblyOrder() throws {
        var consumed = entry(chapterId: ch1, order: 1, digest: "Consumed digest")
        consumed.isConsumed = true
        let packet = PEContinuityPacket(
            brief: ReaderBrief.make(book: book, profile: .empty(bookId: book.id)),
            continuity: ContinuityState(
                bookId: book.id,
                timeline: [consumed, entry(chapterId: ch2, order: 2, digest: "Unread digest")],
                carriedThreads: ["Who pays for the port?"],
                updatedAt: Date()
            ),
            facts: FactChecklist(
                bookId: book.id,
                claims: [claim(chapterId: ch2, statement: "The Cabildo met in 1810.", status: .verified, evidenceIds: ["ev-cabildo"])],
                evidence: [evidence(id: "ev-cabildo", digest: "Cabildo abierto convened 22 May 1810.")],
                updatedAt: Date()
            )
        )

        let rendered = PEPacketPromptAssembler.render(packet, focusChapterId: ch2)
        XCTAssertEqual(
            PEPacketSection.allCases.map(\.header),
            ["[PACKET A — READER BRIEF]", "[PACKET B — CONTINUITY STATE]", "[PACKET C — FACT CHECKLIST]"]
        )

        var previous: String.Index?
        for section in PEPacketSection.allCases {
            let found = try XCTUnwrap(
                rendered.range(of: section.header),
                "Packet \(section.rawValue) missing from the rendered prompt"
            )
            if let previous {
                XCTAssertLessThan(previous, found.lowerBound, "Packet \(section.rawValue) out of order")
            }
            previous = found.lowerBound
        }

        XCTAssertTrue(rendered.contains("CONSUMED (immutable)"))
        XCTAssertTrue(rendered.contains("ev-cabildo"))
        XCTAssertTrue(rendered.contains("non-negotiable:"))
        XCTAssertEqual(PEPacketPromptAssembler.render(nil), "")
    }

    /// RDR-910: an empty packet still renders every section, so a first-run book
    /// tells Astra there is nothing to build on rather than silently omitting it.
    func testEmptyPacketStillRendersAllThreeSections() {
        let rendered = PEPacketPromptAssembler.render(.empty(bookId: book.id))
        XCTAssertFalse(rendered.contains(PEPacketSection.readerBrief.header), "No brief yet → no Packet A")
        XCTAssertTrue(rendered.contains(PEPacketSection.continuityState.header))
        XCTAssertTrue(rendered.contains("(no continuity recorded yet)"))
        XCTAssertTrue(rendered.contains(PEPacketSection.factChecklist.header))
        XCTAssertTrue(rendered.contains("do not assert new essential facts"))
    }

    /// Gen / adapt / evidence all ride the Astra generation model; Ask stays Luna.
    func testGenerationAndEvidenceRouteToAstraWhileAskStaysLuna() async throws {
        XCTAssertEqual(OpenAIModelOption.defaultGeneration, .gpt6Astra)
        XCTAssertEqual(OpenAIModelOption.defaultAsk, .gpt56Luna)

        try await service.finishChapter(bookId: book.id, chapterId: ch1, revisionId: v1)
        let plan = try await service.submitFeedbackAndPlan(book: book, feedback: feedback(overall: .fine))
        try seedVerifiedCabildoClaims(for: plan)
        ai.stubGeneratedPacket { request in
            GeneratedChapter(
                blocks: [],
                proposedClaims: [
                    FactClaim(
                        id: FactClaim.stableId(chapterId: request.chapterId, statement: "The Cabildo abierto met in May 1810."),
                        chapterId: request.chapterId,
                        statement: "The Cabildo abierto met in May 1810.",
                        importance: .essential,
                        status: .unverified,
                        evidenceIds: ["ev-cabildo"]
                    )
                ],
                proposedEvidence: [self.evidence(id: "ev-cabildo", digest: "Cabildo abierto convened 22 May 1810.")]
            )
        }
        _ = try await service.applyPlan(book: book, plan: plan)

        // Claims and evidence arrive on the same generate call as the prose, so
        // they cannot be produced by the Ask (Luna) service.
        XCTAssertNotNil(ai.lastGenerateRequest, "Evidence rides the generation request")
        XCTAssertEqual(ai.askCallCount, 0, "Ask must not be involved in generation or evidence")
        XCTAssertFalse(try packets.loadFactChecklist(bookId: book.id).evidence.isEmpty)
    }

    /// Soft-fail: when generation falls back to prose only it proposes no claims,
    /// so Apply still activates. A missing packet must never block adaptation.
    func testProseOnlySoftFailStillActivatesWithoutClaims() async throws {
        try await service.finishChapter(bookId: book.id, chapterId: ch1, revisionId: v1)
        let plan = try await service.submitFeedbackAndPlan(book: book, feedback: feedback(overall: .fine))

        // No stubGeneratedPacket: the mock returns blocks only, matching the
        // LiveOpenAIService soft-fail path.
        let activated = try await service.applyPlan(book: book, plan: plan)
        XCTAssertFalse(activated.isEmpty)

        let checklist = try packets.loadFactChecklist(bookId: book.id)
        XCTAssertTrue(checklist.claims.isEmpty, "A soft-failed generation asserts nothing")

        // Continuity still advances from a locally derived delta.
        let adapted = try XCTUnwrap(activated.first)
        let entry = try XCTUnwrap(try packets.loadContinuity(bookId: book.id).entry(chapterId: adapted.chapterId))
        XCTAssertEqual(entry.revisionId, adapted.id)
        XCTAssertFalse(entry.digest.isEmpty)

        let state = await service.currentState()
        XCTAssertEqual(state, .applied)
    }

    /// RDR-910: the packet reaches the Astra plan / generate prompts ahead of the task.
    func testAstraPromptsCarryPacketBeforeTask() async throws {
        try await service.finishChapter(bookId: book.id, chapterId: ch1, revisionId: v1)
        let plan = try await service.submitFeedbackAndPlan(
            book: book,
            feedback: feedback(overall: .fine, moreOf: [.stories])
        )
        _ = try await service.applyPlan(book: book, plan: plan)

        let planRequest = try XCTUnwrap(ai.lastPlanRequest)
        let planPacket = try XCTUnwrap(planRequest.packet)
        XCTAssertEqual(planPacket.brief?.bookId, book.id)
        XCTAssertTrue(
            planPacket.continuity.consumedEntries.contains { $0.chapterId == ch1 },
            "Plan packet must carry the consumed chapter as immutable continuity"
        )

        let planPrompt = AdaptationLivePrompts.planUser(planRequest)
        let planPacketAt = try XCTUnwrap(planPrompt.range(of: PEPacketSection.readerBrief.header))
        let planTaskAt = try XCTUnwrap(planPrompt.range(of: "[TASK — PLAN]"))
        XCTAssertLessThan(planPacketAt.lowerBound, planTaskAt.lowerBound)

        let generateRequest = try XCTUnwrap(ai.lastGenerateRequest)
        XCTAssertNotNil(generateRequest.packet)
        let generatePrompt = AdaptationLivePrompts.generateUser(generateRequest)
        let generatePacketAt = try XCTUnwrap(generatePrompt.range(of: PEPacketSection.readerBrief.header))
        let generateTaskAt = try XCTUnwrap(generatePrompt.range(of: "[TASK — GENERATE]"))
        XCTAssertLessThan(generatePacketAt.lowerBound, generateTaskAt.lowerBound)

        XCTAssertTrue(AdaptationLivePrompts.generateSystem.contains("factClaims"))
        XCTAssertTrue(AdaptationLivePrompts.planSystem.contains("PE packet contract"))
        XCTAssertTrue(AdaptationLivePrompts.generateSystem.contains("Packet C"))
    }

    /// RDR-910: Astra's JSON becomes a continuity delta plus gated claims, and an
    /// unrecognised importance is treated as essential so the gate errs toward blocking.
    func testDecodeGenerationBuildsDeltaAndDefaultsUnknownImportanceToEssential() throws {
        let target = AdaptationChapterTarget(
            chapterId: ch2,
            chapterTitle: "A Nation Invents Itself",
            currentWordCount: 400,
            targetWordCount: 460,
            desiredChanges: [],
            mustRemainConcepts: ["argentina"]
        )
        let request = AdaptationGenerateRequest(
            book: book,
            plan: AdaptationPlan(
                id: UUID(),
                bookId: book.id,
                createdAt: Date(),
                sourceFeedbackId: UUID(),
                preferenceUpdatesSummary: [],
                affectedChapterIds: [ch2],
                chapterTargets: [target],
                continuityNotes: [],
                reasonsFromFeedback: [],
                lockedChapterIds: [ch1],
                isValidated: true
            ),
            chapterId: ch2,
            chapterTitle: target.chapterTitle,
            currentPlainText: "current",
            target: target,
            profile: .empty(bookId: book.id),
            continuityNotes: []
        )

        let json = """
        {
          "blocks": [{"kind": "paragraph", "text": "[Adapted] Argentina invents itself."}],
          "continuityDelta": {
            "digest": "The nation argues itself into being.",
            "openThreads": ["Who pays for the port?"],
            "resolvedThreads": ["Who controls the customs house?"]
          },
          "factClaims": [
            {"statement": "The 1853 constitution settled federalism.", "importance": "wishful", "evidenceIds": ["ev-const"]}
          ],
          "evidence": [{"id": "ev-const", "sourceLabel": "Constitution of 1853", "digest": "Articles 1–5."}]
        }
        """

        let generated = try AdaptationLivePrompts.decodeGeneration(json, request: request)
        XCTAssertEqual(generated.blocks.count, 1)

        let delta = try XCTUnwrap(generated.continuityDelta)
        XCTAssertEqual(delta.bookId, book.id)
        XCTAssertEqual(delta.entries.first?.chapterId, ch2)
        XCTAssertEqual(delta.resolvedThreads, ["Who controls the customs house?"])

        let claim = try XCTUnwrap(generated.proposedClaims.first)
        XCTAssertEqual(claim.importance, .essential)
        XCTAssertEqual(claim.status, .unverified)
        XCTAssertEqual(
            claim.id,
            FactClaim.stableId(chapterId: ch2, statement: "The 1853 constitution settled federalism."),
            "Claim identity is stable so regeneration upserts instead of duplicating"
        )
        XCTAssertEqual(generated.proposedEvidence.first?.id, "ev-const")

        // Same claim, no verification and no recorded evidence status change → blocked.
        let merged = FactChecklistMerge.merge(
            claims: generated.proposedClaims,
            evidence: generated.proposedEvidence,
            into: .empty(bookId: book.id)
        )
        assertGate(merged, chapterId: ch2) { error in
            guard case PEGateError.unverifiedEssentialClaim = error else {
                return XCTFail("Expected unverifiedEssentialClaim, got \(error)")
            }
        }
    }

    /// RDR-912: readiness notes give the existing Plan → Apply sheet something to show.
    func testPlanCarriesFactGateReadinessNotes() async throws {
        try packets.saveFactChecklist(
            FactChecklist(
                bookId: book.id,
                claims: [claim(chapterId: ch2, statement: "Unbacked essential.", status: .unverified, evidenceIds: ["ev-absent"])],
                evidence: [],
                updatedAt: Date()
            )
        )
        try await service.finishChapter(bookId: book.id, chapterId: ch1, revisionId: v1)
        let plan = try await service.submitFeedbackAndPlan(book: book, feedback: feedback(overall: .fine))

        let notes = try XCTUnwrap(plan.factGateNotes)
        XCTAssertTrue(notes.contains { $0.contains("Unknown evidence ids") })
        XCTAssertTrue(notes.contains { $0.contains("will block Apply") })
    }

    // MARK: - Helpers

    private func seedVerifiedCabildoClaims(for plan: AdaptationPlan) throws {
        // Verification belongs to the pre-existing stored record, never the
        // generated packet used by these successful Apply-path tests.
        let statement = "The Cabildo abierto met in May 1810."
        try packets.saveFactChecklist(FactChecklist(
            bookId: book.id,
            claims: plan.chapterTargets.map { target in
                FactClaim(id: FactClaim.stableId(chapterId: target.chapterId, statement: statement),
                          chapterId: target.chapterId, statement: statement, importance: .essential,
                          status: .verified, evidenceIds: ["ev-cabildo"])
            },
            evidence: [evidence(id: "ev-cabildo", digest: "Cabildo abierto convened 22 May 1810.")],
            updatedAt: Date()
        ))
    }

    private func assertGate(
        _ checklist: FactChecklist,
        chapterId: UUID,
        _ verify: (Error) -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            try PEContinuityGate.assertActivationAllowed(
                checklist: checklist,
                bookId: book.id,
                chapterId: chapterId
            )
            XCTFail("Fact gate should have rejected activation", file: file, line: line)
        } catch {
            verify(error)
        }
    }

    private func feedback(
        overall: FeedbackOverallRating,
        moreOf: [FeedbackMoreTopic] = [.stories],
        lessOf: [FeedbackLessTopic] = [.repetition]
    ) -> ChapterFeedback {
        ChapterFeedback(
            id: UUID(),
            bookId: book.id,
            chapterId: ch1,
            revisionId: v1,
            overall: overall,
            moreOf: moreOf,
            lessOf: lessOf,
            freeText: "Keep the traveller's eye",
            createdAt: Date()
        )
    }

    private func entry(chapterId: UUID, order: Int, digest: String) -> ContinuityEntry {
        ContinuityEntry(
            id: UUID(),
            chapterId: chapterId,
            chapterTitle: "Chapter \(order)",
            chapterOrderIndex: order,
            revisionId: UUID(),
            digest: digest,
            establishedFacts: [],
            openThreads: [],
            isConsumed: false,
            recordedAt: Date()
        )
    }

    private func claim(
        chapterId: UUID,
        statement: String,
        importance: FactClaimImportance = .essential,
        status: FactVerificationStatus,
        evidenceIds: [String]
    ) -> FactClaim {
        FactClaim(
            id: FactClaim.stableId(chapterId: chapterId, statement: statement),
            chapterId: chapterId,
            statement: statement,
            importance: importance,
            status: status,
            evidenceIds: evidenceIds
        )
    }

    private func evidence(id: String, digest: String) -> FactEvidenceItem {
        FactEvidenceItem(id: id, sourceLabel: "Fixture source", digest: digest)
    }
}
