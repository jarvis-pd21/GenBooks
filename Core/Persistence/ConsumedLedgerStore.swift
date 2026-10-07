import Foundation

/// Append-stable consumed ledger. Identity of a consumed chapter revision is permanent.
protocol ConsumedLedgerStore: Sendable {
    func allEntries() async throws -> [ConsumedChapterRevision]
    func entry(bookId: UUID, chapterId: UUID) async throws -> ConsumedChapterRevision?
    func record(_ entry: ConsumedChapterRevision) async throws
}

struct FileConsumedLedgerStore: ConsumedLedgerStore {
    let fileURL: URL

    init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.fileURL = directory.appendingPathComponent("consumed-ledger.json")
    }

    func allEntries() throws -> [ConsumedChapterRevision] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        return try JSONCoding.decoder.decode([ConsumedChapterRevision].self, from: data)
    }

    func entry(bookId: UUID, chapterId: UUID) throws -> ConsumedChapterRevision? {
        try allEntries().first { $0.bookId == bookId && $0.chapterId == chapterId }
    }

    func record(_ entry: ConsumedChapterRevision) throws {
        var entries = try allEntries()
        if let existing = entries.first(where: { $0.bookId == entry.bookId && $0.chapterId == entry.chapterId }) {
            // Immutable: refuse identity change; allow idempotent re-record of same revision.
            guard existing.revisionId == entry.revisionId else {
                throw ManuscriptError.chapterAlreadyConsumed(
                    chapterId: entry.chapterId,
                    lockedRevisionId: existing.revisionId
                )
            }
            return
        }
        entries.append(entry)
        let data = try JSONCoding.encoder.encode(entries)
        try AtomicFileWriter.writeAtomically(data, to: fileURL)
    }
}
