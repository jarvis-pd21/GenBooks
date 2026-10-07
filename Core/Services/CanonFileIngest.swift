import Foundation

#if canImport(PDFKit)
import PDFKit
#endif

/// Classifies a shared/opened file, fails closed on DRM, then extracts verbatim
/// text for `ManuscriptImporter`. EPUB/PDF stay ingest-only.
enum CanonFileIngest {
    struct Payload: Equatable, Sendable {
        var title: String?
        var author: String?
        var plainText: String
        var sourceKind: ImportSourceKind
        var filename: String
    }

    static func classify(url: URL, filename: String? = nil) throws -> ImportSourceKind {
        let name = (filename ?? url.lastPathComponent).lowercased()
        let ext = URL(fileURLWithPath: name).pathExtension
        if ext == "epub" { return .epubExtract }
        if ext == "pdf" { return .pdfExtract }
        if let data = try? Data(contentsOf: url, options: .mappedIfSafe) {
            return try classify(data: data, filename: name)
        }
        throw CreateBookError.unsupportedImportType
    }

    static func classify(data: Data, filename: String) throws -> ImportSourceKind {
        let ext = URL(fileURLWithPath: filename.lowercased()).pathExtension
        if ext == "epub" { return .epubExtract }
        if ext == "pdf" { return .pdfExtract }
        if data.starts(with: [0x50, 0x4B, 0x03, 0x04]) || data.starts(with: [0x50, 0x4B, 0x05, 0x06]) {
            return .epubExtract
        }
        if data.starts(with: Array("%PDF".utf8)) {
            return .pdfExtract
        }
        throw CreateBookError.unsupportedImportType
    }

    static func prepare(from url: URL) throws -> Payload {
        let readable = try readableCopy(of: url)
        let data = try Data(contentsOf: readable)
        return try prepare(data: data, filename: url.lastPathComponent)
    }

    static func prepare(data: Data, filename: String) throws -> Payload {
        let kind = try classify(data: data, filename: filename)
        switch kind {
        case .epubExtract:
            let extract = try EPUBTextExtractor.extract(from: data)
            return Payload(
                title: extract.title,
                author: extract.author,
                plainText: extract.plainText,
                sourceKind: .epubExtract,
                filename: filename
            )
        case .pdfExtract:
            try assertPDFNotEncrypted(data)
            let text = try extractPDFText(from: data)
            return Payload(
                title: nil,
                author: nil,
                plainText: text,
                sourceKind: .pdfExtract,
                filename: filename
            )
        case .pastedText:
            throw CreateBookError.unsupportedImportType
        }
    }

    /// Security-scoped Files URLs are copied so ingest can finish after scope ends.
    static func readableCopy(of url: URL, fileManager: FileManager = .default) throws -> URL {
        #if canImport(UIKit) || canImport(AppKit)
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }
        #endif
        guard fileManager.fileExists(atPath: url.path) else {
            throw CreateBookError.emptySource
        }
        let ext = url.pathExtension.isEmpty ? "bin" : url.pathExtension
        let dest = fileManager.temporaryDirectory
            .appendingPathComponent("canon-open-\(UUID().uuidString)")
            .appendingPathExtension(ext)
        if fileManager.fileExists(atPath: dest.path) {
            try fileManager.removeItem(at: dest)
        }
        try fileManager.copyItem(at: url, to: dest)
        return dest
    }

    static func assertPDFNotEncrypted(_ data: Data) throws {
        #if canImport(PDFKit)
        if let document = PDFDocument(data: data), document.isEncrypted || document.isLocked {
            throw CreateBookError.drmProtected
        }
        #endif
        // Fail closed on the PDF `/Encrypt` name even without PDFKit (Linux tests).
        let window = data.prefix(1_048_576)
        if let latin = String(data: window, encoding: .isoLatin1), latin.contains("/Encrypt") {
            throw CreateBookError.drmProtected
        }
    }

    private static func extractPDFText(from data: Data) throws -> String {
        #if canImport(PDFKit)
        guard let document = PDFDocument(data: data) else {
            throw CreateBookError.emptySource
        }
        var pages: [String] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index), let text = page.string else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { pages.append(trimmed) }
        }
        let joined = pages.joined(separator: "\n\n")
        if joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw CreateBookError.emptySource
        }
        return joined
        #else
        throw CreateBookError.generationFailed("PDF extract needs PDFKit (iOS). Paste the text instead.")
        #endif
    }
}
