import Foundation

protocol ReadingCheckpointStoring: Sendable {
    func loadCheckpoint(bookId: UUID) throws -> ReadingCheckpoint?
    func saveCheckpoint(_ checkpoint: ReadingCheckpoint) throws
    func clearCheckpoint(bookId: UUID) throws
}

/// File-backed checkpoints in Application Support. Atomic writes; offline; no AI.
final class FileReadingCheckpointStore: ReadingCheckpointStoring, @unchecked Sendable {
    let directory: URL
    private let queue = DispatchQueue(label: "com.jarvis.livingreader.checkpoints")

    init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    convenience init(rootDirectory: URL) throws {
        try self.init(directory: rootDirectory.appendingPathComponent("Checkpoints", isDirectory: true))
    }

    func loadCheckpoint(bookId: UUID) throws -> ReadingCheckpoint? {
        try queue.sync {
            let url = fileURL(bookId: bookId)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let data = try Data(contentsOf: url)
            return try JSONCoding.decoder.decode(ReadingCheckpoint.self, from: data)
        }
    }

    func saveCheckpoint(_ checkpoint: ReadingCheckpoint) throws {
        try queue.sync {
            let data = try JSONCoding.encoder.encode(checkpoint)
            try AtomicFileWriter.writeAtomically(data, to: fileURL(bookId: checkpoint.bookId))
        }
    }

    func clearCheckpoint(bookId: UUID) throws {
        try queue.sync {
            let url = fileURL(bookId: bookId)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    private func fileURL(bookId: UUID) -> URL {
        directory.appendingPathComponent("\(bookId.uuidString).json")
    }
}
