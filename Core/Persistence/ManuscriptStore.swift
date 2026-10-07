import Foundation

/// Codable manuscript files live under Application Support.
/// User ledger/checkpoints: file-based in Phase 1 (invariants); SwiftData remains Phase 3+ per DECISIONS.md.
protocol ManuscriptStore: Sendable {
    func loadBook(id: UUID) async throws -> Book?
    func saveBook(_ book: Book) async throws
    func listBookSummaries() async throws -> [(id: UUID, title: String, author: String)]
}

/// Shelf-only error reporting. An issue never stands in for an absent manuscript
/// in a read, save, seed, or activation operation.
struct LibraryLoadIssue: Identifiable, Equatable, Sendable {
    let filename: String
    let bookID: UUID?
    let reason: String
    let expectedChapterIDs: Set<UUID>?
    var id: String { filename }

    init(filename: String, bookID: UUID?, reason: String, expectedChapterIDs: Set<UUID>? = nil) {
        self.filename = filename
        self.bookID = bookID
        self.reason = reason
        self.expectedChapterIDs = expectedChapterIDs
    }
}

struct LibrarySnapshot: Sendable {
    let books: [Book]
    let issues: [LibraryLoadIssue]
}

struct FileManuscriptStore: ManuscriptStore {
    let directory: URL

    init(directory: URL? = nil) throws {
        if let directory {
            self.directory = directory
        } else {
            let base = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            self.directory = base.appendingPathComponent("LivingReader/Manuscripts", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    func bookURL(id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    func loadBook(id: UUID) throws -> Book? {
        let url = bookURL(id: id)
        // Resolve the actual directory entry, not just the caller's spelling.
        // Case-insensitive filesystems otherwise let a noncanonical file pass
        // direct read/save even though the shelf correctly rejects that entry.
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        guard names.contains(url.lastPathComponent) else {
            if names.contains(where: { $0.lowercased() == url.lastPathComponent.lowercased() }) {
                throw DecodingError.dataCorrupted(.init(codingPath: [],
                    debugDescription: "The saved book filename uses a noncanonical spelling; no files were changed."))
            }
            return nil
        }
        return try readBook(at: url, expectedID: id)
    }

    private func readBook(at url: URL, expectedID: UUID?) throws -> Book {
        guard let expectedID, url.lastPathComponent == bookURL(id: expectedID).lastPathComponent else {
            throw DecodingError.dataCorrupted(.init(codingPath: [],
                debugDescription: "The saved book filename is not a canonical book ID; no files were changed."))
        }
        let data = try Data(contentsOf: url)
        let book = try JSONCoding.decoder.decode(Book.self, from: data)
        guard book.id == expectedID else {
            throw DecodingError.dataCorrupted(.init(codingPath: [],
                debugDescription: "Stored manuscript identity does not match its filename; no files were changed."))
        }
        try SourceGrounding.validateSave(book, previous: nil)
        return book
    }

    /// Read each file independently for Library presentation only. A directory
    /// failure still throws; individual failed books remain untouched on disk.
    func loadLibrarySnapshot() throws -> LibrarySnapshot {
        var books: [Book] = []
        var issues: [LibraryLoadIssue] = []
        for url in try manuscriptURLs() {
            let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent)
            do {
                books.append(try readBook(at: url, expectedID: id))
            } catch {
                issues.append(LibraryLoadIssue(filename: url.lastPathComponent, bookID: id,
                    reason: error.localizedDescription))
            }
        }
        return LibrarySnapshot(books: books.sorted {
            $0.title == $1.title ? $0.id.uuidString < $1.id.uuidString : $0.title < $1.title
        }, issues: issues)
    }

    private func manuscriptURLs() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func saveBook(_ book: Book) throws {
        try SourceGrounding.validateSave(book, previous: loadBook(id: book.id))
        let data = try JSONCoding.encoder.encode(book)
        try AtomicFileWriter.writeAtomically(data, to: bookURL(id: book.id))
    }

    func listBookSummaries() throws -> [(id: UUID, title: String, author: String)] {
        var summaries: [(id: UUID, title: String, author: String)] = []
        for url in try manuscriptURLs() {
            let book = try readBook(at: url, expectedID: UUID(uuidString: url.deletingPathExtension().lastPathComponent))
            summaries.append((book.id, book.title, book.author))
        }
        return summaries.sorted { $0.title < $1.title }
    }
}
