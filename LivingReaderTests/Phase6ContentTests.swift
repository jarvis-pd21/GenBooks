import XCTest
@testable import LivingReader

final class Phase6ContentTests: XCTestCase {
    func testChronologyTimelineCoversRequiredEras() throws {
        let book = try BundleFixtureLoader.loadArgentinaMinimal()
        let hay = (book.timeline.map { $0.title + " " + $0.summary + " " + $0.yearLabel }
            + book.chapters.map(\.title)
            + book.chapters.compactMap(\.eraLabel)
            + book.chapters.flatMap { $0.outlineBeats ?? [] }
            + book.provenanceNotes)
            .joined(separator: " ")
            .lowercased()
        let folded = hay.folding(options: .diacriticInsensitive, locale: .current)
        for needle in [
            "indigenous", "spanish", "british", "may revolution", "independence", "san martin",
            "rosas", "pampas", "patagonia", "immigra", "peron", "dirty", "malvinas",
            "alfonsin", "menem", "2001", "kirchner", "macri", "milei", "inflat"
        ] {
            XCTAssertTrue(folded.contains(needle), "Timeline/outline missing era signal: \(needle)")
        }
    }

    func testOutlineExpansionPathwayProducesFullerProse() async throws {
        let book = try BundleFixtureLoader.loadArgentinaMinimal()
        let outline = try XCTUnwrap(book.chapters.first { $0.isOutlineStub })
        let revision = try XCTUnwrap(outline.activeRevision)
        let plain = revision.blocks.map(\.text).joined(separator: "\n")
        let beforeWC = AdaptationPlanValidator.wordCount(of: plain)
        XCTAssertLessThan(beforeWC, 400)

        let profile = ReaderPreferenceProfile.empty(bookId: book.id)
        let feedback = ChapterFeedback(
            id: UUID(),
            bookId: book.id,
            chapterId: ArgentinaFixtureIDs.chapter1,
            revisionId: ArgentinaFixtureIDs.chapter1Revision1,
            overall: .excellent,
            moreOf: [.stories, .placesIllVisit, .economics],
            lessOf: [.repetition],
            freeText: "Expand outline",
            createdAt: Date()
        )
        let unread = UnreadChapterSnapshot(
            id: outline.id,
            title: outline.title,
            orderIndex: outline.orderIndex,
            currentWordCount: beforeWC,
            plainText: plain
        )
        let planReq = AdaptationPlanRequest(
            book: book,
            feedback: feedback,
            profile: profile,
            lockedChapterIds: [ArgentinaFixtureIDs.chapter1],
            unreadChapters: [unread],
            maxChaptersToAdapt: 1
        )
        let plan = try DeterministicAdaptationSynthesizer.makePlan(planReq)
        let target = try XCTUnwrap(plan.chapterTargets.first)
        let gen = AdaptationGenerateRequest(
            book: book,
            plan: plan,
            chapterId: outline.id,
            chapterTitle: outline.title,
            currentPlainText: plain,
            target: target,
            profile: profile,
            continuityNotes: plan.continuityNotes
        )
        let blocks = DeterministicAdaptationSynthesizer.generate(gen)
        let afterWC = AdaptationPlanValidator.wordCount(of: blocks)
        XCTAssertGreaterThan(afterWC, beforeWC * 3)
        let joined = blocks.map(\.text).joined(separator: " ")
        XCTAssertTrue(joined.contains("[Adapted]"))
        XCTAssertFalse(joined.lowercased().contains("lorem"))
        XCTAssertFalse(joined.contains("[Outline —"), "Expanded prose should not keep outline banner")
    }

    func testSeedUpgradeAppendsMissingChaptersAndPreservesGeneratedFutureWithEmptyLedger() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Phase6Seed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let service = try ManuscriptVersioningService(rootDirectory: root)
        // Tiny legacy seed
        var legacy = Book(
            id: ArgentinaFixtureIDs.book,
            title: "A Little History of Argentina",
            author: "Living Reader",
            chapters: [
                Chapter(
                    id: ArgentinaFixtureIDs.chapter1,
                    bookId: ArgentinaFixtureIDs.book,
                    title: "Before the Nation",
                    orderIndex: 0,
                    activeRevisionId: ArgentinaFixtureIDs.chapter1Revision1,
                    revisions: [
                        ChapterRevision(
                            id: ArgentinaFixtureIDs.chapter1Revision1,
                            chapterId: ArgentinaFixtureIDs.chapter1,
                            revisionIndex: 1,
                            createdAt: Date(),
                            blocks: [
                                ContentBlock(id: ArgentinaFixtureIDs.block1Heading, kind: .heading, text: "Before the Nation", orderIndex: 0)
                            ],
                            isConsumed: false
                        )
                    ]
                )
            ]
        )
        legacy.title = "Reader-retained title"
        legacy.author = "Reader-retained author"
        legacy.synopsis = "Reader-retained synopsis"
        legacy.provenanceNotes = ["Reader-retained provenance"]
        try await service.saveBook(legacy)
        let generated = try await service.createRevision(bookId: legacy.id, chapterId: legacy.chapters[0].id,
            blocks: [ContentBlock(id: UUID(), kind: .paragraph,
                text: "Reader-generated future: café, cafe\u{301}, 👩🏽‍🚀. Preserve these exact bytes.", orderIndex: 0)],
            origin: .regeneratedFromChapter)
        let saved = try await service.loadBook(id: legacy.id)
        let before = try XCTUnwrap(saved)
        let existingChapter = try XCTUnwrap(before.chapters.first)
        let existingBytes = try JSONCoding.encoder.encode(existingChapter)
        let ledgerBefore = try await service.ledgerSnapshot()
        XCTAssertTrue(ledgerBefore.isEmpty)
        let upgraded = try await BundleFixtureLoader.seedIfNeeded(into: service)
        let fixture = try BundleFixtureLoader.loadArgentinaMinimal()
        XCTAssertNil(upgraded.subtitle, "An existing nil subtitle must not be replaced by bundled metadata")
        var expectedMetadata = before
        expectedMetadata.chapters = upgraded.chapters
        XCTAssertEqual(try JSONCoding.encoder.encode(upgraded), try JSONCoding.encoder.encode(expectedMetadata))
        XCTAssertEqual(Set(upgraded.chapters.map(\.id)), Set(fixture.chapters.map(\.id)))
        XCTAssertEqual(upgraded.chapters.count, fixture.chapters.count)
        let retained = try XCTUnwrap(upgraded.chapters.first { $0.id == existingChapter.id })
        XCTAssertEqual(try JSONCoding.encoder.encode(retained), existingBytes)
        XCTAssertEqual(retained.activeRevisionId, generated.id)
        XCTAssertEqual(retained.revisions.map(\.id), existingChapter.revisions.map(\.id))
        for chapter in fixture.chapters where chapter.id != existingChapter.id {
            let appended = try XCTUnwrap(upgraded.chapters.first { $0.id == chapter.id })
            XCTAssertEqual(try JSONCoding.encoder.encode(appended), try JSONCoding.encoder.encode(chapter))
        }
        let reopened = try ManuscriptVersioningService(rootDirectory: root)
        let readable = try await reopened.readableRevision(bookId: legacy.id, chapterId: existingChapter.id)
        XCTAssertEqual(try JSONCoding.encoder.encode(readable), try JSONCoding.encoder.encode(generated))
        let ledgerAfter = try await reopened.ledgerSnapshot()
        XCTAssertEqual(ledgerAfter, ledgerBefore)
    }

    func testSeedExpansionPreservesConsumedAndGeneratedChaptersAndLedgerOnReopen() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Phase6ProtectedSeed-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = try ManuscriptVersioningService(rootDirectory: root)
        var legacy = try BundleFixtureLoader.loadArgentinaMinimal()
        legacy.chapters = Array(legacy.chapters.prefix(2))
        XCTAssertEqual(legacy.chapters.count, 2)
        try await service.saveBook(legacy)
        let first = legacy.chapters[0], future = legacy.chapters[1]
        let consumed = try XCTUnwrap(first.activeRevision)
        try await service.consume(bookId: legacy.id, chapterId: first.id, revisionId: consumed.id)
        _ = try await service.createRevision(bookId: legacy.id, chapterId: future.id,
            blocks: [ContentBlock(id: UUID(), kind: .paragraph, text: "Keep this custom future.", orderIndex: 0)])
        let loaded = try await service.loadBook(id: legacy.id)
        let before = try XCTUnwrap(loaded)
        let ledgerURL = root.appendingPathComponent("Ledger/consumed-ledger.json")
        let ledgerBytes = try Data(contentsOf: ledgerURL)
        _ = try await BundleFixtureLoader.seedIfNeeded(into: service)
        let reopened = try ManuscriptVersioningService(rootDirectory: root)
        let reopenedBook = try await reopened.loadBook(id: legacy.id)
        let after = try XCTUnwrap(reopenedBook)
        XCTAssertGreaterThan(after.chapters.count, before.chapters.count)
        for oldChapter in before.chapters {
            let retained = try XCTUnwrap(after.chapters.first { $0.id == oldChapter.id })
            XCTAssertEqual(try JSONCoding.encoder.encode(retained), try JSONCoding.encoder.encode(oldChapter))
        }
        XCTAssertEqual(try Data(contentsOf: ledgerURL), ledgerBytes)
        let readable = try await reopened.readableRevision(bookId: legacy.id, chapterId: first.id)
        XCTAssertEqual(readable.id, consumed.id)
    }

    func testSeedFindsMissingChapterIDsAtEqualCountAndRetainsExistingEqualOrderFirst() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Phase6IDSeed-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = try ManuscriptVersioningService(rootDirectory: root)
        var existing = try BundleFixtureLoader.loadArgentinaMinimal()
        let missing = try XCTUnwrap(existing.chapters.last)
        existing.chapters.removeLast()
        let customID = UUID(), revisionID = UUID()
        let custom = Chapter(id: customID, bookId: existing.id, title: "Reader custom chapter",
            orderIndex: missing.orderIndex, activeRevisionId: revisionID,
            revisions: [ChapterRevision(id: revisionID, chapterId: customID, revisionIndex: 1,
                createdAt: Date(timeIntervalSince1970: 123),
                blocks: [ContentBlock(id: UUID(), kind: .paragraph, text: "Keep this custom chapter.", orderIndex: 0)],
                isConsumed: false)])
        existing.chapters.append(custom)
        try await service.saveBook(existing)
        let upgraded = try await BundleFixtureLoader.seedIfNeeded(into: service)
        XCTAssertEqual(upgraded.chapters.count, existing.chapters.count + 1)
        XCTAssertEqual(Set(upgraded.chapters.map(\.id)).count, upgraded.chapters.count)
        for original in existing.chapters {
            let retained = try XCTUnwrap(upgraded.chapters.first { $0.id == original.id })
            XCTAssertEqual(try JSONCoding.encoder.encode(retained), try JSONCoding.encoder.encode(original))
        }
        let appended = try XCTUnwrap(upgraded.chapters.first { $0.id == missing.id })
        XCTAssertEqual(try JSONCoding.encoder.encode(appended), try JSONCoding.encoder.encode(missing))
        let ties = upgraded.chapters.filter { $0.orderIndex == missing.orderIndex }.map(\.id)
        XCTAssertEqual(ties, [custom.id, missing.id], "Equal-order existing chapters precede newly appended chapters")
        let url = root.appendingPathComponent("Manuscripts/\(existing.id.uuidString).json")
        let bytes = try Data(contentsOf: url)
        _ = try await BundleFixtureLoader.seedIfNeeded(into: service)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }
}
