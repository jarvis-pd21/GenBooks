import Foundation

/// What has been synthesized for one `ListenCacheKey`.
struct ListenManifest: Codable, Equatable, Sendable {
    var key: ListenCacheKey
    var chapterTitle: String
    var chunkCount: Int
    var completedChunkIndices: [Int]
    var createdAt: Date
    var updatedAt: Date

    var isComplete: Bool {
        chunkCount > 0 && completedChunkIndices.count >= chunkCount
    }
}

protocol ListenAudioCaching: Sendable {
    func directory(for key: ListenCacheKey) -> URL
    /// Where chunk audio lives, whether or not it exists yet.
    func audioURL(for key: ListenCacheKey, chunkIndex: Int) -> URL
    /// Non-nil only when the file is on disk and plausibly playable.
    func cachedAudioURL(for key: ListenCacheKey, chunkIndex: Int) -> URL?
    func store(_ data: Data, for key: ListenCacheKey, chunkIndex: Int) throws -> URL
    func manifest(for key: ListenCacheKey) -> ListenManifest?
    func saveManifest(_ manifest: ListenManifest) throws
    func cachedChunkCount(for document: ListenDocument) -> Int
    func removeAudio(for key: ListenCacheKey) throws
    func removeAll(bookId: UUID) throws
}

extension ListenAudioCaching {
    /// True when every chunk of this document plays without a network call.
    func isFullyDownloaded(_ document: ListenDocument) -> Bool {
        !document.isEmpty && cachedChunkCount(for: document) == document.chunkCount
    }
}

/// File-backed narration cache.
///
/// Layout: `ListenAudio/<bookId>/<chapterId>/<revisionId>-<voice>-<plan>/chunk-000.mp3`
///
/// The revision id in the path is the whole point: after Living adaptation
/// rewrites a chapter, the new revision looks at a directory that does not exist
/// yet, so a listener can never hear last week's prose over this week's text.
/// Older revisions' audio is left alone — deleting it is an explicit user action.
final class FileListenAudioCache: ListenAudioCaching, @unchecked Sendable {
    let directory: URL
    private let queue = DispatchQueue(label: "com.jarvis.livingreader.listen.audio")

    /// Non-throwing on purpose: opening the Listen sheet must not fail because a
    /// directory could not be pre-created. Writes create their own parents.
    init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    convenience init(rootDirectory: URL) {
        self.init(directory: rootDirectory.appendingPathComponent("ListenAudio", isDirectory: true))
    }

    func directory(for key: ListenCacheKey) -> URL {
        directory
            .appendingPathComponent(key.bookId.uuidString, isDirectory: true)
            .appendingPathComponent(key.chapterId.uuidString, isDirectory: true)
            .appendingPathComponent(key.storageKey, isDirectory: true)
    }

    func audioURL(for key: ListenCacheKey, chunkIndex: Int) -> URL {
        directory(for: key).appendingPathComponent(key.fileName(chunkIndex: chunkIndex))
    }

    func cachedAudioURL(for key: ListenCacheKey, chunkIndex: Int) -> URL? {
        let url = audioURL(for: key, chunkIndex: chunkIndex)
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size >= ListenAudioValidator.minimumByteCount else {
            return nil
        }
        return url
    }

    func store(_ data: Data, for key: ListenCacheKey, chunkIndex: Int) throws -> URL {
        try queue.sync {
            let url = audioURL(for: key, chunkIndex: chunkIndex)
            try AtomicFileWriter.writeAtomically(data, to: url)
            return url
        }
    }

    func manifest(for key: ListenCacheKey) -> ListenManifest? {
        queue.sync {
            let url = manifestURL(for: key)
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONCoding.decoder.decode(ListenManifest.self, from: data)
        }
    }

    func saveManifest(_ manifest: ListenManifest) throws {
        try queue.sync {
            let data = try JSONCoding.encoder.encode(manifest)
            try AtomicFileWriter.writeAtomically(data, to: manifestURL(for: manifest.key))
        }
    }

    func cachedChunkCount(for document: ListenDocument) -> Int {
        let key = document.cacheKey
        return document.chunks.reduce(into: 0) { count, chunk in
            if cachedAudioURL(for: key, chunkIndex: chunk.index) != nil {
                count += 1
            }
        }
    }

    func removeAudio(for key: ListenCacheKey) throws {
        try queue.sync {
            let url = directory(for: key)
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            try FileManager.default.removeItem(at: url)
        }
    }

    func removeAll(bookId: UUID) throws {
        try queue.sync {
            let url = directory.appendingPathComponent(bookId.uuidString, isDirectory: true)
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            try FileManager.default.removeItem(at: url)
        }
    }

    private func manifestURL(for key: ListenCacheKey) -> URL {
        directory(for: key).appendingPathComponent("manifest.json")
    }
}
