import Foundation

/// File-backed Create/New Book drafts, beside preference + packet stores.
protocol CreateBookDraftStoring: Sendable {
    func load(id: UUID) throws -> CreateBookDraft?
    func save(_ draft: CreateBookDraft) throws
    func delete(id: UUID) throws
    func list() throws -> [CreateBookDraft]
}

final class FileCreateBookDraftStore: CreateBookDraftStoring, @unchecked Sendable {
    let directory: URL
    private let queue = DispatchQueue(label: "com.jarvis.livingreader.create-drafts")

    init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    convenience init(rootDirectory: URL) throws {
        try self.init(directory: rootDirectory.appendingPathComponent("CreateDrafts", isDirectory: true))
    }

    func load(id: UUID) throws -> CreateBookDraft? {
        try queue.sync {
            let url = fileURL(id: id)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let data = try Data(contentsOf: url)
            return try JSONCoding.decoder.decode(CreateBookDraft.self, from: data)
        }
    }

    func save(_ draft: CreateBookDraft) throws {
        try queue.sync {
            var stored = draft
            stored.updatedAt = Date()
            let data = try JSONCoding.encoder.encode(stored)
            try AtomicFileWriter.writeAtomically(data, to: fileURL(id: stored.id))
        }
    }

    func delete(id: UUID) throws {
        try queue.sync {
            let url = fileURL(id: id)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    func list() throws -> [CreateBookDraft] {
        try queue.sync {
            let urls = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ).filter { $0.pathExtension == "json" }
            var drafts: [CreateBookDraft] = []
            for url in urls {
                let data = try Data(contentsOf: url)
                drafts.append(try JSONCoding.decoder.decode(CreateBookDraft.self, from: data))
            }
            return drafts.sorted { $0.updatedAt > $1.updatedAt }
        }
    }

    private func fileURL(id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }
}
