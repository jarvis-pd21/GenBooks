import Foundation

protocol BookmarkStoring: Sendable {
    func loadBookmarks(bookId: UUID) throws -> [NamedBookmark]
    func loadAllBookmarks() throws -> [NamedBookmark]
    func saveBookmark(_ bookmark: NamedBookmark) throws
    func deleteBookmark(id: UUID, bookId: UUID) throws
    func renameBookmark(id: UUID, bookId: UUID, title: String) throws
}

private struct BookmarkBookPayload: Codable, Equatable, Sendable {
    var bookmarks: [NamedBookmark]
}

/// File-backed named bookmarks. Keys are semantic (revision + block + UTF-16 offset), not pixels.
final class FileBookmarkStore: BookmarkStoring, @unchecked Sendable {
    let directory: URL
    private let queue = DispatchQueue(label: "com.jarvis.livingreader.bookmarks")

    init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    convenience init(rootDirectory: URL) throws {
        try self.init(directory: rootDirectory.appendingPathComponent("Bookmarks", isDirectory: true))
    }

    func loadBookmarks(bookId: UUID) throws -> [NamedBookmark] {
        try loadPayload(bookId: bookId).bookmarks.sorted { $0.createdAt > $1.createdAt }
    }

    func loadAllBookmarks() throws -> [NamedBookmark] {
        try queue.sync {
            var all: [NamedBookmark] = []
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            for url in files where url.pathExtension == "json" {
                let data = try Data(contentsOf: url)
                let payload = try JSONCoding.decoder.decode(BookmarkBookPayload.self, from: data)
                all.append(contentsOf: payload.bookmarks)
            }
            return all.sorted { $0.createdAt > $1.createdAt }
        }
    }

    func saveBookmark(_ bookmark: NamedBookmark) throws {
        try queue.sync {
            var payload = try loadPayloadUnlocked(bookId: bookmark.bookId)
            if let idx = payload.bookmarks.firstIndex(where: { $0.id == bookmark.id }) {
                payload.bookmarks[idx] = bookmark
            } else {
                payload.bookmarks.append(bookmark)
            }
            try writePayloadUnlocked(payload, bookId: bookmark.bookId)
        }
    }

    func deleteBookmark(id: UUID, bookId: UUID) throws {
        try queue.sync {
            var payload = try loadPayloadUnlocked(bookId: bookId)
            payload.bookmarks.removeAll { $0.id == id }
            try writePayloadUnlocked(payload, bookId: bookId)
        }
    }

    func renameBookmark(id: UUID, bookId: UUID, title: String) throws {
        try queue.sync {
            var payload = try loadPayloadUnlocked(bookId: bookId)
            guard let idx = payload.bookmarks.firstIndex(where: { $0.id == id }) else { return }
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            payload.bookmarks[idx].title = trimmed
            payload.bookmarks[idx].updatedAt = Date()
            try writePayloadUnlocked(payload, bookId: bookId)
        }
    }

    private func loadPayload(bookId: UUID) throws -> BookmarkBookPayload {
        try queue.sync { try loadPayloadUnlocked(bookId: bookId) }
    }

    private func loadPayloadUnlocked(bookId: UUID) throws -> BookmarkBookPayload {
        let url = fileURL(bookId: bookId)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return BookmarkBookPayload(bookmarks: [])
        }
        let data = try Data(contentsOf: url)
        return try JSONCoding.decoder.decode(BookmarkBookPayload.self, from: data)
    }

    private func writePayloadUnlocked(_ payload: BookmarkBookPayload, bookId: UUID) throws {
        let data = try JSONCoding.encoder.encode(payload)
        try AtomicFileWriter.writeAtomically(data, to: fileURL(bookId: bookId))
    }

    private func fileURL(bookId: UUID) -> URL {
        directory.appendingPathComponent("\(bookId.uuidString).json")
    }
}
