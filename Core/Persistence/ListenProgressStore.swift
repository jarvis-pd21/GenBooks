import Foundation

protocol ListenProgressStoring: Sendable {
    func loadProgress(bookId: UUID) throws -> [ListenProgress]
    func progress(bookId: UUID, chapterId: UUID) throws -> ListenProgress?
    func save(_ progress: ListenProgress) throws
    func clear(bookId: UUID, chapterId: UUID) throws
}

private struct ListenProgressPayload: Codable, Equatable, Sendable {
    var entries: [ListenProgress]
}

/// Where listening stopped, one entry per chapter, one file per book.
///
/// Intentionally a separate store from `ReadingCheckpoint`: listening must never
/// move the reader's place or advance the consumed ledger, so it does not share
/// storage with the things that do.
final class FileListenProgressStore: ListenProgressStoring, @unchecked Sendable {
    let directory: URL
    private let queue = DispatchQueue(label: "com.jarvis.livingreader.listen.progress")

    init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    convenience init(rootDirectory: URL) {
        self.init(directory: rootDirectory.appendingPathComponent("Listen", isDirectory: true))
    }

    func loadProgress(bookId: UUID) throws -> [ListenProgress] {
        try queue.sync { try loadPayloadUnlocked(bookId: bookId).entries }
    }

    func progress(bookId: UUID, chapterId: UUID) throws -> ListenProgress? {
        try loadProgress(bookId: bookId).first { $0.chapterId == chapterId }
    }

    func save(_ progress: ListenProgress) throws {
        try queue.sync {
            var payload = try loadPayloadUnlocked(bookId: progress.bookId)
            if let idx = payload.entries.firstIndex(where: { $0.chapterId == progress.chapterId }) {
                payload.entries[idx] = progress
            } else {
                payload.entries.append(progress)
            }
            try writePayloadUnlocked(payload, bookId: progress.bookId)
        }
    }

    func clear(bookId: UUID, chapterId: UUID) throws {
        try queue.sync {
            var payload = try loadPayloadUnlocked(bookId: bookId)
            payload.entries.removeAll { $0.chapterId == chapterId }
            try writePayloadUnlocked(payload, bookId: bookId)
        }
    }

    private func loadPayloadUnlocked(bookId: UUID) throws -> ListenProgressPayload {
        let url = fileURL(bookId: bookId)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return ListenProgressPayload(entries: [])
        }
        let data = try Data(contentsOf: url)
        return try JSONCoding.decoder.decode(ListenProgressPayload.self, from: data)
    }

    private func writePayloadUnlocked(_ payload: ListenProgressPayload, bookId: UUID) throws {
        let data = try JSONCoding.encoder.encode(payload)
        try AtomicFileWriter.writeAtomically(data, to: fileURL(bookId: bookId))
    }

    private func fileURL(bookId: UUID) -> URL {
        directory.appendingPathComponent("\(bookId.uuidString).json")
    }
}
