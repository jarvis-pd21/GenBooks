import Foundation

protocol VocabularyStoring: Sendable {
    func loadAll() throws -> [VocabularyEntry]
    func load(bookId: UUID) throws -> [VocabularyEntry]
    func save(_ entry: VocabularyEntry) throws
    func delete(id: UUID) throws
    func markKnown(id: UUID, isKnown: Bool) throws
}

/// File-backed vocabulary list (no spaced repetition).
final class FileVocabularyStore: VocabularyStoring, @unchecked Sendable {
    let directory: URL
    private let queue = DispatchQueue(label: "com.jarvis.livingreader.vocabulary")
    private let fileName = "vocabulary.json"

    init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    convenience init(rootDirectory: URL) throws {
        try self.init(directory: rootDirectory.appendingPathComponent("Vocabulary", isDirectory: true))
    }

    func loadAll() throws -> [VocabularyEntry] {
        try queue.sync { try loadUnlocked().sorted { $0.createdAt > $1.createdAt } }
    }

    func load(bookId: UUID) throws -> [VocabularyEntry] {
        try loadAll().filter { $0.bookId == bookId }
    }

    func save(_ entry: VocabularyEntry) throws {
        try queue.sync {
            var items = try loadUnlocked()
            if let idx = items.firstIndex(where: { $0.id == entry.id }) {
                items[idx] = entry
            } else if let dup = items.firstIndex(where: {
                $0.bookId == entry.bookId
                    && $0.phrase.compare(entry.phrase, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
                    && $0.blockId == entry.blockId
            }) {
                var merged = items[dup]
                merged.definition = entry.definition
                merged.originalSentence = entry.originalSentence
                merged.surroundingContext = entry.surroundingContext
                merged.revisionId = entry.revisionId
                merged.note = entry.note ?? merged.note
                merged.updatedAt = Date()
                items[dup] = merged
            } else {
                items.append(entry)
            }
            try writeUnlocked(items)
        }
    }

    func delete(id: UUID) throws {
        try queue.sync {
            var items = try loadUnlocked()
            items.removeAll { $0.id == id }
            try writeUnlocked(items)
        }
    }

    func markKnown(id: UUID, isKnown: Bool) throws {
        try queue.sync {
            var items = try loadUnlocked()
            guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
            items[idx].isKnown = isKnown
            items[idx].updatedAt = Date()
            try writeUnlocked(items)
        }
    }

    private func fileURL() -> URL {
        directory.appendingPathComponent(fileName)
    }

    private func loadUnlocked() throws -> [VocabularyEntry] {
        let url = fileURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        return try JSONCoding.decoder.decode([VocabularyEntry].self, from: data)
    }

    private func writeUnlocked(_ items: [VocabularyEntry]) throws {
        let data = try JSONCoding.encoder.encode(items)
        try AtomicFileWriter.writeAtomically(data, to: fileURL())
    }
}
