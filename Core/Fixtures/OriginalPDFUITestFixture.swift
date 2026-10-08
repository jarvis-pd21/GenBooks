#if DEBUG
import Foundation
import UIKit
import PDFKit

/// A private, generated fixture, reachable only with both explicit UI-test arguments.
/// No source PDF is bundled, and normal app launches never create this book.
@MainActor
enum OriginalPDFUITestFixture {
    static let bookID = UUID(uuidString: "B79FB544-5B90-4C76-BC44-404099444001")!
    static let chapterID = UUID(uuidString: "B79FB544-5B90-4C76-BC44-404099444002")!
    static let title = "Original pages sample"
    static let diagramChapterID = UUID(uuidString: "B79FB544-5B90-4C76-BC44-404099445002")!
    static let practiceChapterID = UUID(uuidString: "B79FB544-5B90-4C76-BC44-404099446002")!
    static let noteID = UUID(uuidString: "B79FB544-5B90-4C76-BC44-404099444006")!
    static let noteBody = "Keep the table and its explanation together. My note stays attached to this passage."

    static func installIfRequested(rootDirectory: URL, versioning: ManuscriptVersioningService) async throws {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-uitesting"), arguments.contains("-original-pdf-fixture") else { return }
        if var existing = try await versioning.loadBook(id: bookID) {
            guard existing.title == title, existing.author == "GenBooks synthetic fixture" else {
                throw CocoaError(.fileWriteFileExists)
            }
            // Append only: previous fixture runs may already pin revisions or save notes.
            // Never replace the existing first chapter, reset the ledger, or change its IDs.
            let additions = extendedChapters().filter { candidate in !existing.chapters.contains { $0.id == candidate.id } }
            if !additions.isEmpty {
                existing.chapters.append(contentsOf: additions)
                try await versioning.saveBook(existing)
            }
        } else {
            let revisionID = UUID(uuidString: "B79FB544-5B90-4C76-BC44-404099444003")!
            let revision = ChapterRevision(id: revisionID, chapterId: chapterID, revisionIndex: 1,
                createdAt: Date(timeIntervalSince1970: 0), blocks: [
                    ContentBlock(id: UUID(uuidString: "B79FB544-5B90-4C76-BC44-404099444004")!, kind: .heading,
                        text: "Reading the original", orderIndex: 0),
                    ContentBlock(id: UUID(uuidString: "B79FB544-5B90-4C76-BC44-404099444005")!, kind: .paragraph,
                        text: "This synthetic text edition keeps its own reading position. The preserved PDF contains a table, a diagram, and a practice passage. Switch to Original pages to inspect their original layout.", orderIndex: 1)
                ], isConsumed: false, origin: .imported(source: "Synthetic PDF fixture"))
            let book = Book(id: bookID, title: title, author: "GenBooks synthetic fixture", subtitle: "Synthetic test document",
                coverAccent: "imported", chapters: [Chapter(id: chapterID, bookId: bookID, title: "Reading the original",
                    orderIndex: 1, activeRevisionId: revisionID, revisions: [revision])] + extendedChapters())
            try await versioning.saveBook(book)
        }
        let annotations = try FileAnnotationStore(rootDirectory: rootDirectory)
        if try !annotations.loadNotes(bookId: bookID).contains(where: { $0.id == noteID }) {
            let excerpt = "This synthetic text edition keeps its own reading position."
            try annotations.saveNote(NoteAnnotation(id: noteID, bookId: bookID, chapterId: chapterID,
                chapterTitle: "Reading the original", revisionId: UUID(uuidString: "B79FB544-5B90-4C76-BC44-404099444003")!,
                range: ContentRangeAnchor(blockId: UUID(uuidString: "B79FB544-5B90-4C76-BC44-404099444005")!,
                    utf16Start: 0, utf16Length: (excerpt as NSString).length),
                selectedText: excerpt, body: noteBody, createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0)))
        }
        let store = try OriginalDocumentStore(rootDirectory: rootDirectory)
        let loaded: LoadedOriginalDocument
        if let existing = try store.load(bookID: bookID) {
            // Reuse exact bytes; regenerated PDF metadata can change its hash across launches.
            loaded = existing
        } else {
            loaded = try store.attach(data: makePDF(), filename: "Original-pages-sample.pdf", bookID: bookID,
                chapters: [OriginalChapterLocation(chapterID: chapterID, title: "Reading the original", pageIndex: 0)])
        }
        if arguments.contains("-reset-original-pdf-fixture") {
            try store.savePosition(bookID: bookID, sourceSHA256: loaded.attachment.source.sha256, pageIndex: 0)
            UserDefaults.standard.removeObject(forKey: "livingreader.original.mode.\(bookID.uuidString)")
        }
    }

    /// Deliberately long invented prose exercises real viewport movement after a chapter/search jump.
    /// These are text-only fixture exercises; they do not claim additional PDF source locations.
    private static func extendedChapters() -> [Chapter] {
        [(diagramChapterID, 2, "Following the practice diagram", "445"),
         (practiceChapterID, 3, "Keeping a reading place", "446")].map { id, order, heading, suffix in
            let revisionID = UUID(uuidString: "B79FB544-5B90-4C76-BC44-404099\(suffix)003")!
            var blocks = [ContentBlock(id: UUID(uuidString: "B79FB544-5B90-4C76-BC44-404099\(suffix)004")!,
                kind: .heading, text: heading, orderIndex: 0)]
            for index in 1...18 {
                let marker = order == 3 && index == 2 ? "Sapphire waypoint. " : ""
                let paragraph = "\(marker)Exercise \(index). This is an invented passage for testing a reading experience. Imagine explaining a small process to a colleague who has not seen the diagram. Describe each step in its original order, then check how the labels connect. Pause to compare your explanation with the table. Keep the context available while moving between the source page and this text. After returning, continue from this paragraph instead of starting the chapter again."
                let identifier = String(format: "B79FB544-5B90-4C76-BC44-404099%@%03d", suffix, 100 + index)
                blocks.append(ContentBlock(id: UUID(uuidString: identifier)!, kind: .paragraph, text: paragraph, orderIndex: index))
            }
            let revision = ChapterRevision(id: revisionID, chapterId: id, revisionIndex: 1,
                createdAt: Date(timeIntervalSince1970: 0), blocks: blocks, isConsumed: false,
                origin: .imported(source: "Synthetic text fixture"))
            return Chapter(id: id, bookId: bookID, title: heading, orderIndex: order,
                activeRevisionId: revisionID, revisions: [revision])
        }
    }

    private static func makePDF() throws -> Data {
        let bounds = CGRect(x: 0, y: 0, width: 420, height: 560)
        let renderer = UIGraphicsPDFRenderer(bounds: bounds)
        let bytes = renderer.pdfData { context in
            context.beginPage()
            heading("A table worth preserving", subtitle: "Synthetic source • PDF page 1")
            let x: CGFloat = 28, y: CGFloat = 128, width: CGFloat = 364, rowHeight: CGFloat = 52
            UIColor(red: 0.90, green: 0.94, blue: 0.98, alpha: 1).setFill()
            UIBezierPath(rect: CGRect(x: x, y: y, width: width, height: rowHeight)).fill()
            let grid = UIBezierPath(rect: CGRect(x: x, y: y, width: width, height: rowHeight * 4))
            for row in 1..<4 {
                grid.move(to: CGPoint(x: x, y: y + CGFloat(row) * rowHeight))
                grid.addLine(to: CGPoint(x: x + width, y: y + CGFloat(row) * rowHeight))
            }
            grid.move(to: CGPoint(x: 207, y: y)); grid.addLine(to: CGPoint(x: 207, y: y + rowHeight * 4))
            UIColor.darkGray.setStroke(); grid.lineWidth = 1; grid.stroke()
            let rows = [("Session", "Activity"), ("First reading", "Read and explain"), ("Tomorrow", "Recall an example"), ("Next week", "Try it in practice")]
            for (index, row) in rows.enumerated() {
                text(row.0, at: CGPoint(x: 40, y: y + CGFloat(index) * rowHeight + 17), bold: index == 0)
                text(row.1, at: CGPoint(x: 220, y: y + CGFloat(index) * rowHeight + 17), bold: index == 0)
            }
            text("Table 1. A fictional practice schedule.", at: CGPoint(x: 28, y: 360), size: 12)
            text("The rows, columns, shading and caption belong together.", at: CGPoint(x: 28, y: 405), size: 12)
            text("1", at: CGPoint(x: 205, y: 522), size: 11)

            context.beginPage()
            heading("A diagram worth preserving", subtitle: "Synthetic source • PDF page 2")
            let colors = [UIColor(red: 0.18, green: 0.42, blue: 0.66, alpha: 1), UIColor(red: 0.75, green: 0.38, blue: 0.15, alpha: 1)]
            for (index, label) in ["READ", "APPLY"].enumerated() {
                let rect = CGRect(x: 37 + CGFloat(index) * 223, y: 178, width: 123, height: 105)
                colors[index].setFill(); UIBezierPath(roundedRect: rect, cornerRadius: 16).fill()
                text(label, at: CGPoint(x: rect.minX + 32, y: rect.minY + 42), size: 16, bold: true, color: .white)
            }
            let arrow = UIBezierPath()
            arrow.move(to: CGPoint(x: 167, y: 230)); arrow.addLine(to: CGPoint(x: 252, y: 230))
            arrow.move(to: CGPoint(x: 239, y: 219)); arrow.addLine(to: CGPoint(x: 252, y: 230)); arrow.addLine(to: CGPoint(x: 239, y: 241))
            UIColor.darkGray.setStroke(); arrow.lineWidth = 3; arrow.stroke()
            text("Figure 1. Connect reading with a real attempt.", at: CGPoint(x: 28, y: 335), size: 12)
            text("Shapes, colors, direction and labels remain in their source positions.", at: CGPoint(x: 28, y: 388), size: 11)
            text("2", at: CGPoint(x: 205, y: 522), size: 11)

            context.beginPage()
            heading("Practice and footnotes", subtitle: "Synthetic source • PDF page 3")
            text("Retained knowledge grows through practice.", at: CGPoint(x: 28, y: 142), size: 16)
            text("Explain an idea, try it, and revisit what was difficult.", at: CGPoint(x: 28, y: 183), size: 14)
            text("These are invented example pages, not excerpts from a book.", at: CGPoint(x: 28, y: 230), size: 12)
            text("See the table on PDF page 1.", at: CGPoint(x: 28, y: 302), size: 14, color: .systemBlue)
            text("1. A fictional footnote remains attached to its page.", at: CGPoint(x: 28, y: 455), size: 12)
            text("3", at: CGPoint(x: 205, y: 522), size: 11)
        }
        guard let document = PDFDocument(data: bytes), let first = document.page(at: 0), let last = document.page(at: 2) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let root = PDFOutline()
        for (index, label) in ["Table: study sessions", "Diagram: practice loop", "Practice and footnotes"].enumerated() {
            guard let page = document.page(at: index) else { throw CocoaError(.fileReadCorruptFile) }
            let entry = PDFOutline(); entry.label = label
            entry.destination = PDFDestination(page: page, at: CGPoint(x: 0, y: 560))
            root.insertChild(entry, at: index)
        }
        document.outlineRoot = root
        let link = PDFAnnotation(bounds: CGRect(x: 28, y: 239, width: 300, height: 24), forType: .link, withProperties: nil)
        link.action = PDFActionGoTo(destination: PDFDestination(page: first, at: CGPoint(x: 0, y: 560)))
        last.addAnnotation(link)
        guard let complete = document.dataRepresentation() else { throw CocoaError(.fileWriteUnknown) }
        return complete
    }

    private static func heading(_ title: String, subtitle: String) {
        text(title, at: CGPoint(x: 28, y: 37), size: 22, bold: true)
        text(subtitle, at: CGPoint(x: 28, y: 76), size: 11, color: .darkGray)
    }
    private static func text(_ value: String, at point: CGPoint, size: CGFloat = 13, bold: Bool = false, color: UIColor = .black) {
        (value as NSString).draw(at: point, withAttributes: [
            .font: bold ? UIFont.boldSystemFont(ofSize: size) : UIFont.systemFont(ofSize: size), .foregroundColor: color
        ])
    }
}
#endif
