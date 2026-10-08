import Foundation
import CryptoKit
import PDFKit

/// The filename is display metadata only. Disk paths are derived from a validated hash.
struct OriginalDocumentReference: Codable, Equatable, Hashable, Sendable {
    var sha256: String
    var filename: String
    var pageCount: Int
    var hasExtractedText: Bool
}

/// A verified zero-based PDF page index; never a guessed printed page number.
struct OriginalChapterLocation: Codable, Equatable, Hashable, Sendable {
    var chapterID: UUID
    var title: String
    var pageIndex: Int
}

struct OriginalDocumentAttachment: Codable, Equatable, Sendable {
    var schemaVersion: Int = 1
    var bookID: UUID
    var source: OriginalDocumentReference
    var chapters: [OriginalChapterLocation]
}

struct LoadedOriginalDocument: Sendable {
    var attachment: OriginalDocumentAttachment
    var url: URL
}

/// PDF coordinates remain independent of text UTF-16 checkpoints and consumed revisions.
struct OriginalReadingPosition: Codable, Equatable, Sendable {
    var bookID: UUID
    var sourceSHA256: String
    var pageIndex: Int
    var pagePointX: Double?
    var pagePointY: Double?
}

enum OriginalDocumentError: LocalizedError, Equatable {
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let reason): return "Original pages couldn’t be opened: \(reason) Your saved text and notes are unchanged."
        }
    }
}

/// Additive private assets: no manuscript, text checkpoint, or consumed-ledger writes.
/// A process-wide lock also serializes independent store instances used by import and reading.
final class OriginalDocumentStore: @unchecked Sendable {
    let directory: URL
    private static let lock = NSRecursiveLock()
    private let fileManager = FileManager.default

    init(rootDirectory: URL? = nil) throws {
        let root: URL
        if let rootDirectory { root = rootDirectory }
        else {
            root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true).appendingPathComponent("LivingReader", isDirectory: true)
        }
        directory = root.standardizedFileURL.resolvingSymlinksInPath()
            .appendingPathComponent("OriginalDocuments", isDirectory: true)
        try synchronized { try ensureDirectories() }
    }

    /// Staging is durable so a persisted import draft never depends on a Files URL or temp file.
    func stage(data: Data, filename: String) throws -> OriginalDocumentReference {
        try synchronized {
            try ensureDirectories()
            try validateFilename(filename)
            let document = try validatedPDF(data)
            let reference = OriginalDocumentReference(sha256: Self.hash(data), filename: filename,
                pageCount: document.pageCount,
                hasExtractedText: (0..<document.pageCount).contains {
                    !(document.page(at: $0)?.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                })
            let url = try assetURL(reference.sha256)
            if fileManager.fileExists(atPath: url.path) {
                // A corrupt or redirected file is never silently overwritten with a good copy.
                _ = try validatedAsset(reference)
            } else {
                try AtomicFileWriter.writeAtomically(data, to: url)
            }
            return reference
        }
    }

    @discardableResult
    func attach(data: Data, filename: String, bookID: UUID,
                chapters: [OriginalChapterLocation] = []) throws -> LoadedOriginalDocument {
        try synchronized {
            let source = try stage(data: data, filename: filename)
            return try attach(bookID: bookID, source: source, chapters: chapters)
        }
    }

    @discardableResult
    func attach(bookID: UUID, source: OriginalDocumentReference,
                chapters: [OriginalChapterLocation] = []) throws -> LoadedOriginalDocument {
        try synchronized {
            try ensureDirectories()
            let attachment = OriginalDocumentAttachment(bookID: bookID, source: source, chapters: chapters)
            try validate(attachment, expectedBookID: bookID)
            let url = try validatedAsset(source)
            if let existing = try load(bookID: bookID), existing.attachment.source.sha256 != source.sha256 {
                throw OriginalDocumentError.invalid("this book already has a different preserved PDF")
            }
            let manifestURL = manifestURL(bookID)
            try rejectRedirectedFile(manifestURL, mayBeMissing: true)
            try AtomicFileWriter.writeAtomically(try JSONCoding.encoder.encode(attachment), to: manifestURL)
            return LoadedOriginalDocument(attachment: attachment, url: url)
        }
    }

    /// Absence of a manifest returns nil; a damaged attachment is a visible error, never absence.
    func load(bookID: UUID) throws -> LoadedOriginalDocument? {
        try synchronized {
            guard let attachment = try readAttachment(bookID: bookID) else { return nil }
            return LoadedOriginalDocument(attachment: attachment, url: try validatedAsset(attachment.source))
        }
    }

    private func readAttachment(bookID: UUID) throws -> OriginalDocumentAttachment? {
        try ensureDirectories()
        let url = manifestURL(bookID)
        guard fileManager.fileExists(atPath: url.path) else {
            try rejectRedirectedFile(url, mayBeMissing: true)
            return nil
        }
        try rejectRedirectedFile(url)
        let attachment: OriginalDocumentAttachment
        do { attachment = try JSONCoding.decoder.decode(OriginalDocumentAttachment.self, from: Data(contentsOf: url)) }
        catch { throw OriginalDocumentError.invalid("the saved PDF attachment record is unreadable") }
        try validate(attachment, expectedBookID: bookID)
        return attachment
    }

    /// Validate a staged reference before creating a manuscript from its extracted text.
    func validateStaged(_ source: OriginalDocumentReference) throws {
        try synchronized { try ensureDirectories(); _ = try validatedAsset(source) }
    }

    func savePosition(bookID: UUID, sourceSHA256: String, pageIndex: Int,
                      pagePointX: Double? = nil, pagePointY: Double? = nil) throws {
        try synchronized {
            let attachment = try positionAttachment(bookID: bookID, sourceSHA256: sourceSHA256)
            let position = OriginalReadingPosition(bookID: bookID, sourceSHA256: sourceSHA256,
                pageIndex: pageIndex, pagePointX: pagePointX, pagePointY: pagePointY)
            try validate(position, attachment: attachment)
            let url = try positionURL(bookID: bookID, sourceSHA256: sourceSHA256)
            try rejectRedirectedFile(url, mayBeMissing: true)
            try AtomicFileWriter.writeAtomically(try JSONCoding.encoder.encode(position), to: url)
        }
    }

    func loadPosition(bookID: UUID, sourceSHA256: String) throws -> OriginalReadingPosition? {
        try synchronized {
            let attachment = try positionAttachment(bookID: bookID, sourceSHA256: sourceSHA256)
            let url = try positionURL(bookID: bookID, sourceSHA256: sourceSHA256)
            guard fileManager.fileExists(atPath: url.path) else {
                try rejectRedirectedFile(url, mayBeMissing: true)
                return nil
            }
            try rejectRedirectedFile(url)
            let position: OriginalReadingPosition
            do { position = try JSONCoding.decoder.decode(OriginalReadingPosition.self, from: Data(contentsOf: url)) }
            catch { throw OriginalDocumentError.invalid("the saved PDF reading position is unreadable") }
            try validate(position, attachment: attachment)
            return position
        }
    }

    private func positionAttachment(bookID: UUID, sourceSHA256: String) throws -> OriginalDocumentAttachment {
        try validateHash(sourceSHA256)
        // Position writes validate identity and bounds without hashing a large PDF on every page turn.
        // `load(bookID:)` validates the actual source before the reader opens it.
        guard let attachment = try readAttachment(bookID: bookID), attachment.source.sha256 == sourceSHA256 else {
            throw OriginalDocumentError.invalid("the reading position belongs to a different or missing PDF")
        }
        return attachment
    }

    private func validate(_ position: OriginalReadingPosition, attachment: OriginalDocumentAttachment) throws {
        guard position.bookID == attachment.bookID, position.sourceSHA256 == attachment.source.sha256,
              (0..<attachment.source.pageCount).contains(position.pageIndex),
              (position.pagePointX == nil) == (position.pagePointY == nil),
              position.pagePointX?.isFinite ?? true, position.pagePointY?.isFinite ?? true else {
            throw OriginalDocumentError.invalid("the PDF reading position is invalid")
        }
    }

    private func validate(_ attachment: OriginalDocumentAttachment, expectedBookID: UUID) throws {
        try validateHash(attachment.source.sha256)
        try validateFilename(attachment.source.filename)
        guard attachment.schemaVersion == 1, attachment.bookID == expectedBookID,
              attachment.source.pageCount > 0,
              Set(attachment.chapters.map(\.chapterID)).count == attachment.chapters.count,
              attachment.chapters.allSatisfy({ (0..<attachment.source.pageCount).contains($0.pageIndex) }) else {
            throw OriginalDocumentError.invalid("the PDF attachment identity or page map is invalid")
        }
    }

    private func validatedAsset(_ source: OriginalDocumentReference) throws -> URL {
        try validateFilename(source.filename)
        let url = try assetURL(source.sha256)
        try rejectRedirectedFile(url)
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard Self.hash(data) == source.sha256 else {
            throw OriginalDocumentError.invalid("the preserved PDF has changed or is damaged")
        }
        guard try validatedPDF(data).pageCount == source.pageCount else {
            throw OriginalDocumentError.invalid("the PDF page count does not match its attachment")
        }
        return url
    }

    private func validatedPDF(_ data: Data) throws -> PDFDocument {
        guard let document = PDFDocument(data: data), document.pageCount > 0 else {
            throw OriginalDocumentError.invalid("the file is not a readable PDF")
        }
        guard !document.isEncrypted, !document.isLocked else { throw CreateBookError.drmProtected }
        return document
    }

    private func validateHash(_ hash: String) throws {
        guard hash.count == 64, hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw OriginalDocumentError.invalid("the PDF identifier is invalid")
        }
    }

    private func validateFilename(_ filename: String) throws {
        guard !filename.isEmpty, filename != ".", filename != "..",
              !filename.contains("/"), !filename.contains("\\"), !filename.contains("\0") else {
            throw OriginalDocumentError.invalid("the PDF display filename is invalid")
        }
    }

    private func assetURL(_ hash: String) throws -> URL {
        try validateHash(hash)
        return directory.appendingPathComponent("\(hash).pdf")
    }

    private func manifestURL(_ bookID: UUID) -> URL {
        directory.appendingPathComponent("Attachments", isDirectory: true).appendingPathComponent("\(bookID.uuidString).json")
    }

    private func positionURL(bookID: UUID, sourceSHA256: String) throws -> URL {
        try validateHash(sourceSHA256)
        return directory.appendingPathComponent("Positions", isDirectory: true)
            .appendingPathComponent("\(bookID.uuidString)-\(sourceSHA256).json")
    }

    private func ensureDirectories() throws {
        for url in [directory, directory.appendingPathComponent("Attachments", isDirectory: true),
                    directory.appendingPathComponent("Positions", isDirectory: true)] {
            if let attributes = try? fileManager.attributesOfItem(atPath: url.path) {
                guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                    throw OriginalDocumentError.invalid("its storage directory has been redirected or damaged")
                }
            } else { try fileManager.createDirectory(at: url, withIntermediateDirectories: true) }
        }
    }

    private func rejectRedirectedFile(_ url: URL, mayBeMissing: Bool = false) throws {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else {
            if mayBeMissing { return }
            throw OriginalDocumentError.invalid("the preserved PDF or saved record is missing")
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw OriginalDocumentError.invalid("a saved PDF or record has been redirected or damaged")
        }
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func synchronized<T>(_ action: () throws -> T) rethrows -> T {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        return try action()
    }
}
