import Foundation

protocol FeedbackStoring: Sendable {
    func loadAll(bookId: UUID) throws -> [ChapterFeedback]
    func save(_ feedback: ChapterFeedback) throws
}

final class FileFeedbackStore: FeedbackStoring, @unchecked Sendable {
    let directory: URL
    private let queue = DispatchQueue(label: "com.jarvis.livingreader.feedback")

    init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    convenience init(rootDirectory: URL) throws {
        try self.init(directory: rootDirectory.appendingPathComponent("Feedback", isDirectory: true))
    }

    func loadAll(bookId: UUID) throws -> [ChapterFeedback] {
        try queue.sync {
            try loadUnlocked()
                .filter { $0.bookId == bookId }
                .sorted { $0.createdAt > $1.createdAt }
        }
    }

    func save(_ feedback: ChapterFeedback) throws {
        try queue.sync {
            var items = try loadUnlocked()
            if let idx = items.firstIndex(where: { $0.id == feedback.id }) {
                items[idx] = feedback
            } else {
                items.append(feedback)
            }
            try writeUnlocked(items)
        }
    }

    private func fileURL() -> URL {
        directory.appendingPathComponent("chapter_feedback.json")
    }

    private func loadUnlocked() throws -> [ChapterFeedback] {
        let url = fileURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        return try JSONCoding.decoder.decode([ChapterFeedback].self, from: data)
    }

    private func writeUnlocked(_ items: [ChapterFeedback]) throws {
        let data = try JSONCoding.encoder.encode(items)
        try AtomicFileWriter.writeAtomically(data, to: fileURL())
    }
}
