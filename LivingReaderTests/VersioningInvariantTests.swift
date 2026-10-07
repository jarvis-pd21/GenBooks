import XCTest
@testable import LivingReader

final class VersioningInvariantTests: XCTestCase {
    private var root: URL!
    private var service: ManuscriptVersioningService!
    private var book: Book!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LivingReaderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        service = try ManuscriptVersioningService(rootDirectory: root)
        book = try BundleFixtureLoader.loadArgentinaMinimal()
        try await service.saveBook(book)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        root = nil
        service = nil
        book = nil
    }

    // CONV-001: A missing book seeds, but an existing book is never rewritten merely by opening.
    func testMissingBookSeedsAndReopensWithoutCreatingConsumption() async throws {
        let emptyRoot = root.appendingPathComponent("missing-book", isDirectory: true)
        let fresh = try ManuscriptVersioningService(rootDirectory: emptyRoot)
        let before = try await fresh.loadBook(id: book.id)
        XCTAssertNil(before)
        let seeded = try await BundleFixtureLoader.seedIfNeeded(into: fresh)
        XCTAssertEqual(try JSONCoding.encoder.encode(seeded), try JSONCoding.encoder.encode(book))
        let reopened = try ManuscriptVersioningService(rootDirectory: emptyRoot)
        let loaded = try await reopened.loadBook(id: book.id)
        XCTAssertEqual(loaded, seeded)
        let ledger = try await reopened.ledgerSnapshot()
        XCTAssertTrue(ledger.isEmpty)
    }

    func testRepeatedSeedLeavesExistingBytesAndModificationDateUntouched() async throws {
        let url = root.appendingPathComponent("Manuscripts/\(book.id.uuidString).json")
        // Valid noncanonical whitespace makes a decode/re-encode replacement observable.
        var original = try Data(contentsOf: url)
        original.append(Data("\n  \n".utf8))
        try original.write(to: url)
        let fixedDate = Date(timeIntervalSince1970: 1_234_567_890)
        try FileManager.default.setAttributes([.modificationDate: fixedDate], ofItemAtPath: url.path)
        let beforeDate = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        let ledgerURL = root.appendingPathComponent("Ledger/consumed-ledger.json")
        let ledgerBytes = Data("[]\n \n".utf8)
        try ledgerBytes.write(to: ledgerURL)
        for _ in 0..<2 {
            let reopened = try ManuscriptVersioningService(rootDirectory: root)
            let seeded = try await BundleFixtureLoader.seedIfNeeded(into: reopened)
            XCTAssertEqual(seeded, book)
            XCTAssertEqual(try Data(contentsOf: url), original)
            let afterDate = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
            XCTAssertEqual(afterDate, beforeDate, "Opening must not even rewrite identical existing bytes")
            XCTAssertEqual(try Data(contentsOf: ledgerURL), ledgerBytes)
        }
    }

    func testMissingManuscriptWithConsumedLedgerThrowsWithoutReseeding() async throws {
        let chapter = try XCTUnwrap(book.chapters.first)
        let revision = try XCTUnwrap(chapter.activeRevision)
        try await service.consume(bookId: book.id, chapterId: chapter.id, revisionId: revision.id)
        let ledgerURL = root.appendingPathComponent("Ledger/consumed-ledger.json")
        let ledgerBytes = try Data(contentsOf: ledgerURL)
        let url = root.appendingPathComponent("Manuscripts/\(book.id.uuidString).json")
        try FileManager.default.removeItem(at: url) // Deliberately missing file in this test's temporary directory.
        do {
            _ = try await BundleFixtureLoader.seedIfNeeded(into: service)
            XCTFail("Consumed history without its manuscript requires recovery, never silent reseeding")
        } catch { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try Data(contentsOf: ledgerURL), ledgerBytes)
    }

    func testMissingManuscriptWithUnreadableLedgerThrowsWithoutReplacingEither() async throws {
        let url = root.appendingPathComponent("Manuscripts/\(book.id.uuidString).json")
        try FileManager.default.removeItem(at: url)
        let ledgerURL = root.appendingPathComponent("Ledger/consumed-ledger.json")
        let ledgerBytes = Data("{incompatible-ledger".utf8)
        try ledgerBytes.write(to: ledgerURL)
        do {
            _ = try await BundleFixtureLoader.seedIfNeeded(into: service)
            XCTFail("An unreadable ledger cannot establish that reseeding is safe")
        } catch { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try Data(contentsOf: ledgerURL), ledgerBytes)
    }

    // RDR-108: Completing/consuming Chapter v1 stores exact v1 identity
    func testConsumeChapterV1StoresExactIdentityInLedger() async throws {
        let chapterId = ArgentinaFixtureIDs.chapter1
        let revisionId = ArgentinaFixtureIDs.chapter1Revision1

        try await service.consume(bookId: book.id, chapterId: chapterId, revisionId: revisionId)

        let ledger = try await service.ledgerSnapshot()
        XCTAssertEqual(ledger.count, 1)
        XCTAssertEqual(ledger[0].revisionId, revisionId)
        XCTAssertEqual(ledger[0].chapterId, chapterId)
        XCTAssertEqual(ledger[0].revisionIndex, 1)

        let retrieved = try await service.retrieveConsumedRevision(bookId: book.id, chapterId: chapterId)
        XCTAssertEqual(retrieved?.id, revisionId)
        XCTAssertGreaterThanOrEqual(retrieved?.blocks.count ?? 0, 3)
    }

    // RDR-109: Creating v2 cannot overwrite consumed v1; v1 remains retrievable
    func testCreateV2DoesNotOverwriteConsumedV1() async throws {
        let chapterId = ArgentinaFixtureIDs.chapter1
        let v1Id = ArgentinaFixtureIDs.chapter1Revision1

        try await service.consume(bookId: book.id, chapterId: chapterId, revisionId: v1Id)

        let v2Blocks = [
            ContentBlock(id: UUID(), kind: .paragraph, text: "Adapted future prose v2.", orderIndex: 0)
        ]
        let v2 = try await service.createRevision(bookId: book.id, chapterId: chapterId, blocks: v2Blocks)

        let reloaded = try await service.loadBook(id: book.id)!
        let chapter = reloaded.chapters.first { $0.id == chapterId }!
        XCTAssertEqual(chapter.revisions.count, 2)
        XCTAssertTrue(chapter.revisions.contains { $0.id == v1Id })
        XCTAssertTrue(chapter.revisions.contains { $0.id == v2.id })

        let consumed = try await service.retrieveConsumedRevision(bookId: book.id, chapterId: chapterId)
        XCTAssertEqual(consumed?.id, v1Id)
        XCTAssertEqual(consumed?.blocks.first?.text, "Before the Nation")

        let readable = try await service.readableRevision(bookId: book.id, chapterId: chapterId)
        XCTAssertEqual(readable.id, v1Id, "Readable past must stay pinned to consumed v1")
    }

    // RDR-110: Adaptation/activation cannot modify locked/consumed chapters
    func testActivateCandidateRejectedForConsumedChapter() async throws {
        let chapterId = ArgentinaFixtureIDs.chapter1
        let v1Id = ArgentinaFixtureIDs.chapter1Revision1
        try await service.consume(bookId: book.id, chapterId: chapterId, revisionId: v1Id)

        let before = try await service.loadBook(id: book.id)!
        let beforeData = try JSONCoding.encoder.encode(before)

        let candidate = CandidateRevision(
            id: UUID(),
            bookId: book.id,
            chapterId: chapterId,
            proposedRevisionIndex: 2,
            createdAt: Date(),
            blocks: [ContentBlock(id: UUID(), kind: .paragraph, text: "Should not apply", orderIndex: 0)],
            status: .staged,
            rejectionReason: nil
        )
        try await service.stageCandidate(candidate)

        do {
            _ = try await service.activateCandidate(id: candidate.id)
            XCTFail("Expected cannotMutateConsumedChapter")
        } catch ManuscriptError.cannotMutateConsumedChapter(let id) {
            XCTAssertEqual(id, chapterId)
        }

        let after = try await service.loadBook(id: book.id)!
        let afterData = try JSONCoding.encoder.encode(after)
        XCTAssertEqual(beforeData, afterData, "Previous readable book must be unchanged")
        XCTAssertEqual(after.chapters.first { $0.id == chapterId }?.revisions.count, 1)
    }

    // RDR-111: Invalid/malformed candidate rejected
    func testMalformedCandidateRejectedWithoutCorruptingBook() async throws {
        let before = try await service.loadBook(id: book.id)!
        let beforeData = try JSONCoding.encoder.encode(before)

        let badId = UUID()
        try await service.plantRawCandidate(id: badId, data: Data("{not-json".utf8))

        do {
            _ = try await service.activateCandidate(id: badId)
            XCTFail("Expected malformed candidate rejection")
        } catch ManuscriptError.malformedCandidate {
            // expected
        } catch ManuscriptError.candidateNotFound {
            // activate loads via decode path — malformed throws malformedCandidate
        }

        // Also reject empty-block structured candidate
        let empty = CandidateRevision(
            id: UUID(),
            bookId: book.id,
            chapterId: ArgentinaFixtureIDs.chapter2,
            proposedRevisionIndex: 2,
            createdAt: Date(),
            blocks: [],
            status: .staged,
            rejectionReason: nil
        )
        do {
            try await service.stageCandidate(empty)
            XCTFail("Expected stage to reject empty blocks")
        } catch ManuscriptError.malformedCandidate {
            // expected
        }

        let after = try await service.loadBook(id: book.id)!
        XCTAssertEqual(try JSONCoding.encoder.encode(after), beforeData)
    }

    // RDR-112: Valid candidate atomically activates for unread future only
    func testValidCandidateAtomicallyActivatesForUnreadChapter() async throws {
        let chapterId = ArgentinaFixtureIDs.chapter2
        let alreadyConsumed = try await service.isChapterConsumed(bookId: book.id, chapterId: chapterId)
        XCTAssertFalse(alreadyConsumed)

        let candidate = CandidateRevision(
            id: UUID(),
            bookId: book.id,
            chapterId: chapterId,
            proposedRevisionIndex: 2,
            createdAt: Date(),
            blocks: [
                ContentBlock(id: UUID(), kind: .heading, text: "Independence Sparks (adapted)", orderIndex: 0),
                ContentBlock(id: UUID(), kind: .paragraph, text: "A clearer telling of the cabildo debates.", orderIndex: 1)
            ],
            status: .staged,
            rejectionReason: nil
        )
        try await service.stageCandidate(candidate)
        let activated = try await service.activateCandidate(id: candidate.id)

        let reloaded = try await service.loadBook(id: book.id)!
        let chapter = reloaded.chapters.first { $0.id == chapterId }!
        XCTAssertEqual(chapter.revisions.count, 2)
        XCTAssertEqual(chapter.activeRevisionId, activated.id)
        XCTAssertEqual(activated.revisionIndex, 2)

        let readable = try await service.readableRevision(bookId: book.id, chapterId: chapterId)
        XCTAssertEqual(readable.id, activated.id)
        XCTAssertTrue(readable.blocks.contains { $0.text.contains("adapted") })
    }

    // RDR-113: Relaunch/reopen preserves consumed ledger
    func testRelaunchReopenPreservesConsumedLedger() async throws {
        let chapterId = ArgentinaFixtureIDs.chapter1
        let v1Id = ArgentinaFixtureIDs.chapter1Revision1
        try await service.consume(bookId: book.id, chapterId: chapterId, revisionId: v1Id)
        _ = try await service.createRevision(
            bookId: book.id,
            chapterId: chapterId,
            blocks: [ContentBlock(id: UUID(), kind: .paragraph, text: "v2 after consume", orderIndex: 0)]
        )

        // Simulate relaunch: new service instance on same root
        let relaunched = try ManuscriptVersioningService(rootDirectory: root)
        let ledger = try await relaunched.ledgerSnapshot()
        XCTAssertEqual(ledger.count, 1)
        XCTAssertEqual(ledger[0].revisionId, v1Id)

        let consumed = try await relaunched.retrieveConsumedRevision(bookId: book.id, chapterId: chapterId)
        XCTAssertEqual(consumed?.id, v1Id)

        let readable = try await relaunched.readableRevision(bookId: book.id, chapterId: chapterId)
        XCTAssertEqual(readable.id, v1Id)

        let reloadedBook = try await relaunched.loadBook(id: book.id)!
        XCTAssertEqual(reloadedBook.chapters.first { $0.id == chapterId }?.revisions.count, 2)
    }

    // RDR-105/106: Offline fixture load; MockAIService call count 0
    func testOfflineFixtureLoadDoesNotCallAI() async throws {
        let ai = MockAIService()
        ai.resetCallCount()
        let loaded = try BundleFixtureLoader.loadArgentinaMinimal()
        XCTAssertEqual(loaded.id, ArgentinaFixtureIDs.book)
        XCTAssertGreaterThanOrEqual(loaded.chapters.count, 2)
        let totalBlocks = loaded.chapters.flatMap { $0.revisions }.flatMap(\.blocks).count
        XCTAssertGreaterThanOrEqual(totalBlocks, 4)
        XCTAssertEqual(ai.adaptCallCount, 0)

        let seeded = try await BundleFixtureLoader.seedIfNeeded(into: service)
        XCTAssertEqual(seeded.title, "A Little History of Argentina")
        XCTAssertEqual(ai.adaptCallCount, 0)
    }

    // Partial/malformed candidate does not corrupt known-good (crash-safety)
    func testPartialMalformedCandidateDoesNotCorruptKnownGood() async throws {
        let knownGood = try await service.loadBook(id: book.id)!
        let knownData = try JSONCoding.encoder.encode(knownGood)

        let junkId = UUID()
        try await service.plantRawCandidate(id: junkId, data: Data("<html>nope</html>".utf8))

        do {
            _ = try await service.activateCandidate(id: junkId)
            XCTFail("should reject")
        } catch {
            // any error OK
        }

        let after = try await service.loadBook(id: book.id)!
        XCTAssertEqual(try JSONCoding.encoder.encode(after), knownData)
        let ledgerCount = try await service.ledgerSnapshot().count
        XCTAssertEqual(ledgerCount, 0)
    }

    // Idempotent consume of same revision is OK; different revision is not
    func testCannotRebindConsumedChapterToDifferentRevision() async throws {
        let chapterId = ArgentinaFixtureIDs.chapter1
        let v1Id = ArgentinaFixtureIDs.chapter1Revision1
        try await service.consume(bookId: book.id, chapterId: chapterId, revisionId: v1Id)

        // idempotent
        try await service.consume(bookId: book.id, chapterId: chapterId, revisionId: v1Id)

        let v2 = try await service.createRevision(
            bookId: book.id,
            chapterId: chapterId,
            blocks: [ContentBlock(id: UUID(), kind: .paragraph, text: "v2", orderIndex: 0)]
        )
        do {
            try await service.consume(bookId: book.id, chapterId: chapterId, revisionId: v2.id)
            XCTFail("must not rebind")
        } catch ManuscriptError.chapterAlreadyConsumed(_, let locked) {
            XCTAssertEqual(locked, v1Id)
        }
    }

    func testExpectedSourceRevisionAllowsAnUnchangedCandidateToActivate() async throws {
        let chapterId = ArgentinaFixtureIDs.chapter2
        let source = try await service.readableRevision(bookId: book.id, chapterId: chapterId)
        let candidate = makeCandidate(chapterId: chapterId, text: "Current-source continuation.")
        try await service.stageCandidate(candidate)

        let activated = try await service.activateCandidate(id: candidate.id, expectedRevisionId: source.id)

        let readable = try await service.readableRevision(bookId: book.id, chapterId: chapterId)
        let saved = try await service.loadBook(id: book.id)
        let reloaded = try XCTUnwrap(saved)
        let chapter = try XCTUnwrap(reloaded.chapters.first { $0.id == chapterId })
        XCTAssertEqual(readable.id, activated.id)
        XCTAssertEqual(activated.revisionIndex, source.revisionIndex + 1)
        XCTAssertEqual(chapter.revisions.count, 2)
        XCTAssertEqual(try JSONCoding.encoder.encode(chapter.revision(id: source.id)),
                       try JSONCoding.encoder.encode(Optional(source)))
        XCTAssertEqual(try storedCandidate(id: candidate.id).status, .activated)
    }

    func testStaleCandidateDoesNotRewriteManuscriptOrCandidateBytesOrModificationDates() async throws {
        try await assertStaleCandidateLeavesFilesUntouched(invalidStructure: false)
    }

    func testStaleAdmissionPrecedesInvalidCandidateRejectionAndLeavesFilesUntouched() async throws {
        try await assertStaleCandidateLeavesFilesUntouched(invalidStructure: true)
    }

    func testConcurrentCandidatesFromOneSourcePublishOnlyOneRevision() async throws {
        let chapterId = ArgentinaFixtureIDs.chapter2
        let source = try await service.readableRevision(bookId: book.id, chapterId: chapterId)
        let candidates = [
            makeCandidate(chapterId: chapterId, text: "First generated continuation."),
            makeCandidate(chapterId: chapterId, text: "Second generated continuation.")
        ]
        for candidate in candidates { try await service.stageCandidate(candidate) }
        let versioning = try XCTUnwrap(service)

        let outcomes = await withTaskGroup(of: ActivationOutcome.self) { group in
            for candidate in candidates {
                group.addTask {
                    await Self.activate(versioning, id: candidate.id, expectedRevisionId: source.id)
                }
            }
            var results: [ActivationOutcome] = []
            for await result in group { results.append(result) }
            return results
        }

        let winners = outcomes.compactMap { outcome -> UUID? in
            guard case .activated(let id) = outcome else { return nil }
            return id
        }
        XCTAssertEqual(winners.count, 1, "Exactly one candidate may publish against the captured source: \(outcomes)")
        let winner = try XCTUnwrap(winners.first)
        XCTAssertEqual(outcomes.filter { $0 == .stale(expected: source.id, actual: winner) }.count, 1)
        let saved = try await versioning.loadBook(id: book.id)
        let reloaded = try XCTUnwrap(saved)
        let chapter = try XCTUnwrap(reloaded.chapters.first { $0.id == chapterId })
        XCTAssertEqual(chapter.revisions.map(\.revisionIndex), [source.revisionIndex, source.revisionIndex + 1])
        XCTAssertEqual(chapter.activeRevisionId, winner)
        XCTAssertEqual(try JSONCoding.encoder.encode(chapter.revision(id: source.id)),
                       try JSONCoding.encoder.encode(Optional(source)))
        let statuses = try candidates.map { try storedCandidate(id: $0.id).status }
        XCTAssertEqual(statuses.filter { $0 == .activated }.count, 1)
        XCTAssertEqual(statuses.filter { $0 == .staged }.count, 1, "Stale admission must not reject or rewrite the losing candidate")
    }

    func testConcurrentActivationOfOneCandidatePublishesItOnlyOnce() async throws {
        let chapterId = ArgentinaFixtureIDs.chapter2
        let source = try await service.readableRevision(bookId: book.id, chapterId: chapterId)
        let candidate = makeCandidate(chapterId: chapterId, text: "Publish this candidate only once.")
        try await service.stageCandidate(candidate)
        let versioning = try XCTUnwrap(service)

        let outcomes = await withTaskGroup(of: ActivationOutcome.self) { group in
            for _ in 0..<2 {
                group.addTask { await Self.activate(versioning, id: candidate.id, expectedRevisionId: nil) }
            }
            var results: [ActivationOutcome] = []
            for await result in group { results.append(result) }
            return results
        }

        let activated = outcomes.compactMap { outcome -> UUID? in
            guard case .activated(let id) = outcome else { return nil }
            return id
        }
        XCTAssertEqual(activated.count, 1, "A handled candidate cannot publish twice: \(outcomes)")
        XCTAssertEqual(outcomes.filter { $0 == .handled(candidate.id) }.count, 1)
        let saved = try await versioning.loadBook(id: book.id)
        let reloaded = try XCTUnwrap(saved)
        let chapter = try XCTUnwrap(reloaded.chapters.first { $0.id == chapterId })
        XCTAssertEqual(chapter.revisions.count, 2)
        XCTAssertEqual(chapter.revisions.map(\.revisionIndex), [source.revisionIndex, source.revisionIndex + 1])
        XCTAssertEqual(chapter.activeRevisionId, activated.first)
        XCTAssertEqual(try storedCandidate(id: candidate.id).status, .activated)
    }

    func testConcurrentRevisionCreationRetainsEveryAppendWithUniqueIncreasingIndices() async throws {
        let chapterId = ArgentinaFixtureIDs.chapter2
        let original = try XCTUnwrap(book.chapters.first { $0.id == chapterId })
        let originalBytes = try JSONCoding.encoder.encode(original.revisions)
        let versioning = try XCTUnwrap(service)
        let bookId = book.id
        let count = 12

        let created = try await withThrowingTaskGroup(of: ChapterRevision.self) { group in
            for index in 0..<count {
                group.addTask {
                    try await versioning.createRevision(
                        bookId: bookId,
                        chapterId: chapterId,
                        blocks: [ContentBlock(id: UUID(), kind: .paragraph, text: "Concurrent revision \(index).", orderIndex: 0)]
                    )
                }
            }
            var revisions: [ChapterRevision] = []
            for try await revision in group { revisions.append(revision) }
            return revisions
        }

        let saved = try await versioning.loadBook(id: bookId)
        let reloaded = try XCTUnwrap(saved)
        let chapter = try XCTUnwrap(reloaded.chapters.first { $0.id == chapterId })
        let firstNewIndex = (original.revisions.map(\.revisionIndex).max() ?? -1) + 1
        XCTAssertEqual(created.count, count)
        XCTAssertEqual(Set(created.map(\.id)).count, count)
        XCTAssertEqual(created.map(\.revisionIndex).sorted(), Array(firstNewIndex..<(firstNewIndex + count)))
        XCTAssertEqual(chapter.revisions.count, original.revisions.count + count)
        XCTAssertEqual(Set(chapter.revisions.map(\.id)), Set(original.revisions.map(\.id) + created.map(\.id)))
        XCTAssertEqual(chapter.revisions.map(\.revisionIndex), chapter.revisions.map(\.revisionIndex).sorted())
        XCTAssertEqual(chapter.activeRevisionId, chapter.revisions.last?.id)
        XCTAssertEqual(try JSONCoding.encoder.encode(Array(chapter.revisions.prefix(original.revisions.count))), originalBytes)
    }

    func testDelayedPolishedMetadataCannotOverwriteANewerRevisionOrItsOutlineStatus() async throws {
        let chapterId = ArgentinaFixtureIDs.chapter2
        let index = try XCTUnwrap(book.chapters.firstIndex { $0.id == chapterId })
        book.chapters[index].manuscriptStatus = .outline
        try await service.saveBook(book)
        let old = try await service.readableRevision(bookId: book.id, chapterId: chapterId)
        let newer = try await service.createRevision(
            bookId: book.id, chapterId: chapterId,
            blocks: [ContentBlock(id: UUID(), kind: .paragraph, text: "A newer draft is still an outline.", orderIndex: 0)]
        )
        let path = root.appendingPathComponent("Manuscripts/\(book.id.uuidString).json")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_600_000_000)],
                                              ofItemAtPath: path.path)
        let before = try snapshotFile(at: path)

        try await service.markChapterPolished(bookId: book.id, chapterId: chapterId, expectedRevisionId: old.id)

        let after = try snapshotFile(at: path)
        XCTAssertEqual(after.data, before.data)
        XCTAssertEqual(after.modified, before.modified)
        let saved = try await service.loadBook(id: book.id)
        let reloaded = try XCTUnwrap(saved)
        let chapter = try XCTUnwrap(reloaded.chapters.first { $0.id == chapterId })
        XCTAssertEqual(chapter.manuscriptStatus, .outline)
        XCTAssertEqual(chapter.activeRevisionId, newer.id)
        XCTAssertEqual(chapter.revisions.map(\.id), [old.id, newer.id])
    }

    func testCurrentRevisionCanMarkItsOutlinePolishedWithoutChangingRevisionHistory() async throws {
        let chapterId = ArgentinaFixtureIDs.chapter2
        let index = try XCTUnwrap(book.chapters.firstIndex { $0.id == chapterId })
        book.chapters[index].manuscriptStatus = .outline
        try await service.saveBook(book)
        let source = try await service.readableRevision(bookId: book.id, chapterId: chapterId)
        let historyBytes = try JSONCoding.encoder.encode(book.chapters[index].revisions)

        try await service.markChapterPolished(bookId: book.id, chapterId: chapterId, expectedRevisionId: source.id)

        let saved = try await service.loadBook(id: book.id)
        let reloaded = try XCTUnwrap(saved)
        let chapter = try XCTUnwrap(reloaded.chapters.first { $0.id == chapterId })
        XCTAssertEqual(chapter.manuscriptStatus, .polished)
        XCTAssertEqual(chapter.activeRevisionId, source.id)
        XCTAssertEqual(try JSONCoding.encoder.encode(chapter.revisions), historyBytes)
    }

    private func assertStaleCandidateLeavesFilesUntouched(invalidStructure: Bool) async throws {
        let chapterId = ArgentinaFixtureIDs.chapter2
        let source = try await service.readableRevision(bookId: book.id, chapterId: chapterId)
        var candidate = makeCandidate(chapterId: chapterId, text: "Outdated continuation must not publish.")
        if invalidStructure {
            candidate.blocks = []
            // Bypass staging validation to exercise admission before rejection metadata writes.
            try await service.plantRawCandidate(id: candidate.id, data: JSONCoding.encoder.encode(candidate))
        } else {
            try await service.stageCandidate(candidate)
        }
        let newer = try await service.createRevision(
            bookId: book.id,
            chapterId: chapterId,
            blocks: [ContentBlock(id: UUID(), kind: .paragraph, text: "Keep this newer revision.", orderIndex: 0)]
        )
        let paths = [
            root.appendingPathComponent("Manuscripts/\(book.id.uuidString).json"),
            root.appendingPathComponent("Candidates/\(candidate.id.uuidString).json")
        ]
        // A past timestamp catches same-byte rewrites without relying on filesystem clock precision.
        for path in paths {
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_600_000_000)],
                                                  ofItemAtPath: path.path)
        }
        let before = try paths.map { try snapshotFile(at: $0) }

        do {
            _ = try await service.activateCandidate(id: candidate.id, expectedRevisionId: source.id)
            XCTFail("Expected stale revision admission failure")
        } catch ManuscriptError.staleRevision(let expected, let actual) {
            XCTAssertEqual(expected, source.id)
            XCTAssertEqual(actual, newer.id)
        }

        for (path, prior) in zip(paths, before) {
            let after = try snapshotFile(at: path)
            XCTAssertEqual(after.data, prior.data, "Stale admission changed \(path.lastPathComponent)")
            XCTAssertEqual(after.modified, prior.modified, "Stale admission rewrote \(path.lastPathComponent)")
        }
        let readable = try await service.readableRevision(bookId: book.id, chapterId: chapterId)
        XCTAssertEqual(readable.id, newer.id)
        XCTAssertEqual(try storedCandidate(id: candidate.id).status, .staged)
        let ledger = try await service.ledgerSnapshot()
        XCTAssertTrue(ledger.isEmpty)
    }

    private func makeCandidate(chapterId: UUID, text: String) -> CandidateRevision {
        CandidateRevision(
            id: UUID(), bookId: book.id, chapterId: chapterId,
            proposedRevisionIndex: 2, createdAt: Date(),
            blocks: [ContentBlock(id: UUID(), kind: .paragraph, text: text, orderIndex: 0)],
            status: .staged, rejectionReason: nil
        )
    }

    private func storedCandidate(id: UUID) throws -> CandidateRevision {
        let data = try Data(contentsOf: root.appendingPathComponent("Candidates/\(id.uuidString).json"))
        return try JSONCoding.decoder.decode(CandidateRevision.self, from: data)
    }

    private func snapshotFile(at url: URL) throws -> (data: Data, modified: Date) {
        let data = try Data(contentsOf: url)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let modified = try XCTUnwrap(attributes[.modificationDate] as? Date)
        return (data, modified)
    }

    private enum ActivationOutcome: Equatable, Sendable {
        case activated(UUID)
        case stale(expected: UUID, actual: UUID)
        case handled(UUID)
        case unexpected(String)
    }

    private static func activate(
        _ versioning: ManuscriptVersioningService,
        id: UUID,
        expectedRevisionId: UUID?
    ) async -> ActivationOutcome {
        do {
            return .activated(try await versioning.activateCandidate(id: id, expectedRevisionId: expectedRevisionId).id)
        } catch ManuscriptError.staleRevision(let expected, let actual) {
            return .stale(expected: expected, actual: actual)
        } catch ManuscriptError.candidateAlreadyHandled(let id) {
            return .handled(id)
        } catch {
            return .unexpected(String(describing: error))
        }
    }
}
