import Foundation

#if canImport(PDFKit)
import PDFKit
#endif

/// PDF is ingest only. Callers pass the extracted string to `ManuscriptImporter`.
enum PDFTextExtractor {
    static func extractPlainText(from url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        try CanonFileIngest.assertPDFNotEncrypted(data)
        #if canImport(PDFKit)
        guard let document = PDFDocument(url: url) else {
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
