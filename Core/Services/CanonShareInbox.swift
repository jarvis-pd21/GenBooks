import Foundation

/// App Group handshake used by the Share Extension → host `genbooks://import` path.
///
/// The extension writes one payload; the host takes it and deletes the inbox copy.
/// Tests pass a temp directory instead of the real App Group container.
enum CanonShareInbox {
    static let applicationGroupID = "group.com.jarvis.livingreader"
    static let directoryName = "IncomingCanon"
    static let payloadFileName = "payload"
    static let metaFileName = "meta.json"

    struct Meta: Codable, Equatable, Sendable {
        var filename: String
        var createdAt: Date
    }

    static func containerURL(fileManager: FileManager = .default) -> URL? {
        #if os(iOS) || os(macOS) || os(tvOS) || os(watchOS)
        return fileManager.containerURL(forSecurityApplicationGroupIdentifier: applicationGroupID)
        #else
        return nil
        #endif
    }

    static func write(
        data: Data,
        filename: String,
        container: URL,
        fileManager: FileManager = .default,
        at date: Date = Date()
    ) throws {
        let folder = container.appendingPathComponent(directoryName, isDirectory: true)
        if fileManager.fileExists(atPath: folder.path) {
            try fileManager.removeItem(at: folder)
        }
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let payload = folder.appendingPathComponent(payloadFileName)
        try data.write(to: payload, options: .atomic)
        let meta = Meta(filename: filename, createdAt: date)
        let encoded = try JSONEncoder().encode(meta)
        try encoded.write(to: folder.appendingPathComponent(metaFileName), options: .atomic)
    }

    /// Moves the inbox payload to a unique temp URL and clears the inbox.
    static func take(
        container: URL,
        fileManager: FileManager = .default
    ) throws -> (url: URL, filename: String)? {
        let folder = container.appendingPathComponent(directoryName, isDirectory: true)
        let payload = folder.appendingPathComponent(payloadFileName)
        let metaURL = folder.appendingPathComponent(metaFileName)
        guard fileManager.fileExists(atPath: payload.path) else { return nil }

        let filename: String
        if let data = try? Data(contentsOf: metaURL),
           let name = Self.filename(fromMeta: data) {
            filename = name
        } else {
            filename = "shared.epub"
        }

        let ext = URL(fileURLWithPath: filename).pathExtension
        let dest = fileManager.temporaryDirectory
            .appendingPathComponent("canon-inbox-\(UUID().uuidString)")
            .appendingPathExtension(ext.isEmpty ? "epub" : ext)
        if fileManager.fileExists(atPath: dest.path) {
            try fileManager.removeItem(at: dest)
        }
        try fileManager.copyItem(at: payload, to: dest)
        try? fileManager.removeItem(at: folder)
        return (dest, filename)
    }

    /// Host `JSONEncoder` Meta and the Share Extension's `{ "filename": ... }` both work.
    private static func filename(fromMeta data: Data) -> String? {
        if let meta = try? JSONDecoder().decode(Meta.self, from: data),
           !meta.filename.isEmpty {
            return meta.filename
        }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let name = object["filename"] as? String,
           !name.isEmpty {
            return name
        }
        return nil
    }
}
