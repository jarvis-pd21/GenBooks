import Foundation

protocol ReaderPreferenceStoring: Sendable {
    func load(bookId: UUID) throws -> ReaderPreferenceProfile
    /// Persist a profile already mutated via `ReaderPreferenceEngine` (inspectable process).
    func save(_ profile: ReaderPreferenceProfile) throws
    /// Convenience: apply feedback through the engine, persist, return updated profile.
    func applyFeedback(_ feedback: ChapterFeedback) throws -> ReaderPreferenceProfile
}

final class FileReaderPreferenceStore: ReaderPreferenceStoring, @unchecked Sendable {
    let directory: URL
    private let queue = DispatchQueue(label: "com.jarvis.livingreader.prefs")

    init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    convenience init(rootDirectory: URL) throws {
        try self.init(directory: rootDirectory.appendingPathComponent("Preferences", isDirectory: true))
    }

    func load(bookId: UUID) throws -> ReaderPreferenceProfile {
        try queue.sync {
            if let existing = try loadUnlocked(bookId: bookId) {
                return existing
            }
            return .empty(bookId: bookId)
        }
    }

    func save(_ profile: ReaderPreferenceProfile) throws {
        try queue.sync {
            try writeUnlocked(profile)
        }
    }

    func applyFeedback(_ feedback: ChapterFeedback) throws -> ReaderPreferenceProfile {
        try queue.sync {
            let current = try loadUnlocked(bookId: feedback.bookId) ?? .empty(bookId: feedback.bookId)
            let updated = ReaderPreferenceEngine.apply(feedback: feedback, to: current)
            try writeUnlocked(updated)
            return updated
        }
    }

    private func fileURL(bookId: UUID) -> URL {
        directory.appendingPathComponent("\(bookId.uuidString).json")
    }

    private func loadUnlocked(bookId: UUID) throws -> ReaderPreferenceProfile? {
        let url = fileURL(bookId: bookId)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONCoding.decoder.decode(ReaderPreferenceProfile.self, from: data)
    }

    private func writeUnlocked(_ profile: ReaderPreferenceProfile) throws {
        let data = try JSONCoding.encoder.encode(profile)
        try AtomicFileWriter.writeAtomically(data, to: fileURL(bookId: profile.bookId))
    }
}
