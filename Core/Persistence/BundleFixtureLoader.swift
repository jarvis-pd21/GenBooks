import Foundation

enum BundleFixtureLoader {
    static func loadArgentinaMinimal(from bundle: Bundle = .main) throws -> Book {
        try loadFixture(named: "argentina_minimal", from: bundle)
    }

    static func loadQuranPickthall(from bundle: Bundle = .main) throws -> Book {
        try loadFixture(named: "quran_pickthall", from: bundle)
    }

    /// Seeds bundled first-run books (Argentina, then Quran). Returns Argentina so
    /// existing callers and seed-preserve tests keep the same contract.
    /// Existing manuscript values and consumed history are never replaced.
    /// Incomplete Quran installs (e.g. only Al-Fatihah) expand via `seedBookIfNeeded`
    /// appending missing surah IDs — Argentina/user books are never wiped.
    /// Cover accents map to Assets.xcassets covers via `BookCoverAssets`.
    /// Call during serialized library bootstrap; this is not a concurrent-writer transaction.
    @discardableResult
    static func seedIfNeeded(
        into service: ManuscriptVersioningService,
        bundle: Bundle = .main
    ) async throws -> Book {
        let argentina = try await seedBookIfNeeded(try loadArgentinaMinimal(from: bundle), into: service)
        if (try? urlForFixtureFile(named: "quran_pickthall", ext: "json", from: bundle)) != nil {
            _ = try await seedBookIfNeeded(try loadQuranPickthall(from: bundle), into: service)
        }
        return argentina
    }

    /// Library bootstrap isolates each bundled seed failure. A corrupt saved
    /// book still throws inside seedBookIfNeeded and is never replaced.
    static func seedLibraryBooksIfNeeded(
        into service: ManuscriptVersioningService,
        bundle: Bundle = .main
    ) async -> [LibraryLoadIssue] {
        var issues: [LibraryLoadIssue] = []
        for resource in ["argentina_minimal", "quran_pickthall"] {
            // The optional translation is omitted from the open-source distribution.
            // Absence is not corruption; a present but invalid sample still reports an issue.
            if resource == "quran_pickthall",
               (try? urlForFixtureFile(named: resource, ext: "json", from: bundle)) == nil { continue }
            var bookID: UUID?
            var expectedChapterIDs: Set<UUID>?
            do {
                let book = try loadFixture(named: resource, from: bundle)
                bookID = book.id
                expectedChapterIDs = Set(book.chapters.map(\.id))
                _ = try await seedBookIfNeeded(book, into: service)
            } catch {
                issues.append(LibraryLoadIssue(
                    filename: bookID.map { "\($0.uuidString).json" } ?? "\(resource).json",
                    bookID: bookID, reason: error.localizedDescription, expectedChapterIDs: expectedChapterIDs))
            }
        }
        return issues
    }

    /// Seeds a genuinely new book, or appends missing bundled chapters to an existing one.
    @discardableResult
    static func seedBookIfNeeded(
        _ book: Book,
        into service: ManuscriptVersioningService
    ) async throws -> Book {
        // Only nil means absent. Read/decode errors must reach Library's error state,
        // leaving the original bytes available for recovery rather than silently reseeding.
        if let existing = try await service.loadBook(id: book.id) {
            guard existing.id == book.id else {
                throw DecodingError.dataCorrupted(.init(codingPath: [],
                    debugDescription: "Stored manuscript identity does not match its filename; no files were changed."))
            }
            var knownIDs = Set(existing.chapters.map(\.id))
            let missing = book.chapters.filter { knownIDs.insert($0.id).inserted }
            guard !missing.isEmpty else { return existing }

            // An empty ledger does not mean this book is disposable: it may contain
            // generated future revisions and annotation/bookmark anchors. Preserve all
            // existing metadata, chapter order, revision IDs, blocks and active pointers.
            var merged = existing
            merged.chapters.append(contentsOf: missing)
            try await service.saveBook(merged)
            return merged
        }

        // A missing manuscript with recorded history needs recovery, not a fresh seed
        // that could make the old pinned revisions unavailable. A ledger read error also throws.
        let history = try await service.ledgerSnapshot().filter { $0.bookId == book.id }
        guard history.isEmpty else { throw ManuscriptError.bookNotFound(book.id) }
        try await service.saveBook(book)
        return book
    }

    /// Tiny friend-demo EPUB (STORE zip). Not Quran; original Plaza Evening text.
    static func urlForFriendCanonEPUB(from bundle: Bundle = .main) throws -> URL {
        try urlForFixtureFile(named: "friend_canon", ext: "epub", from: bundle)
    }

    static func urlForFixtureFile(named resource: String, ext: String, from bundle: Bundle = .main) throws -> URL {
        if let bundled = bundle.url(forResource: resource, withExtension: ext, subdirectory: "Fixtures") {
            return bundled
        }
        if let flat = bundle.url(forResource: resource, withExtension: ext) {
            return flat
        }
        let thisFile = URL(fileURLWithPath: #filePath)
        let repoRoot = thisFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fallback = repoRoot.appendingPathComponent("Resources/Fixtures/\(resource).\(ext)")
        guard FileManager.default.fileExists(atPath: fallback.path) else {
            throw ManuscriptError.malformedCandidate("\(resource).\(ext) not found in bundle or repo")
        }
        return fallback
    }

    private static func loadFixture(named resource: String, from bundle: Bundle) throws -> Book {
        let url: URL
        if let bundled = bundle.url(forResource: resource, withExtension: "json", subdirectory: "Fixtures") {
            url = bundled
        } else if let flat = bundle.url(forResource: resource, withExtension: "json") {
            url = flat
        } else {
            // Unit-test host may not copy Resources; fall back to source-relative path via #file.
            let thisFile = URL(fileURLWithPath: #filePath)
            let repoRoot = thisFile
                .deletingLastPathComponent() // Persistence
                .deletingLastPathComponent() // Core
                .deletingLastPathComponent() // repo
            let fallback = repoRoot.appendingPathComponent("Resources/Fixtures/\(resource).json")
            guard FileManager.default.fileExists(atPath: fallback.path) else {
                throw ManuscriptError.malformedCandidate("\(resource).json not found in bundle or repo")
            }
            url = fallback
        }
        let data = try Data(contentsOf: url)
        return try JSONCoding.decoder.decode(Book.self, from: data)
    }
}
