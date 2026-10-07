import Foundation
import UIKit

/// One rendered span in the continuous document, mapped back to manuscript identity.
struct ReaderBlockAnchor: Equatable, Hashable, Sendable {
    var chapterId: UUID
    var chapterTitle: String
    var chapterOrderIndex: Int
    var revisionId: UUID
    var block: ContentBlock
    /// UTF-16 range of this block's text in the flattened attributed string (excluding trailing separators owned by layout).
    var utf16Range: Range<Int>
}

/// Flattened continuous document built from readable chapter revisions.
/// Renderer-agnostic: any ContinuousReaderRendering implementation can consume this.
struct ReaderDocument {
    var bookId: UUID
    var title: String
    var author: String
    var attributedText: NSAttributedString
    var anchors: [ReaderBlockAnchor]
    var chapterStarts: [(chapterId: UUID, title: String, utf16Location: Int)]

    var length: Int { attributedText.length }

    func anchor(containingUtf16Location location: Int) -> ReaderBlockAnchor? {
        guard !anchors.isEmpty else { return nil }
        if let exact = anchors.first(where: { $0.utf16Range.contains(location) }) {
            return exact
        }
        // Between blocks / trailing newlines: map to nearest preceding block.
        return anchors.last(where: { $0.utf16Range.lowerBound <= location }) ?? anchors.first
    }

    func anchor(blockId: UUID) -> ReaderBlockAnchor? {
        anchors.first { $0.block.id == blockId }
    }

    /// Book progress in the same space the scrubber seeks through: UTF-16 offset / (length - 1).
    /// Viewport scroll fraction is a different space and must not drive the slider, or release snaps back.
    func progressFraction(atUtf16 utf16: Int) -> Double {
        let denom = max(1, length - 1)
        let clamped = min(max(0, utf16), denom)
        return Double(clamped) / Double(denom)
    }

    func utf16Location(forProgress progress: Double) -> Int {
        let clamped = min(1, max(0, progress))
        return Int((Double(max(0, length - 1)) * clamped).rounded())
    }

    func location(atUtf16 utf16: Int, visibleProgress: Double? = nil) -> ReaderLocation? {
        guard let anchor = anchor(containingUtf16Location: utf16) else { return nil }
        let offset = max(0, min(utf16 - anchor.utf16Range.lowerBound, max(0, anchor.utf16Range.count - 1)))
        return ReaderLocation(
            chapterId: anchor.chapterId,
            blockId: anchor.block.id,
            characterOffset: offset,
            progress: min(1, max(0, visibleProgress ?? progressFraction(atUtf16: utf16)))
        )
    }

    func utf16Location(for location: ReaderLocation) -> Int? {
        guard let anchor = anchor(blockId: location.blockId) else { return nil }
        let clamped = max(0, min(location.characterOffset, max(0, anchor.utf16Range.count - 1)))
        return anchor.utf16Range.lowerBound + clamped
    }

    /// Returns an exclusive, whole-word boundary no later than the supplied
    /// UTF-16 reading position. Search can use this without exposing the unread
    /// remainder of the word (or block) containing a checkpoint.
    func searchBoundary(atOrBeforeUtf16 location: Int) -> Int {
        let full = attributedText.string as NSString
        let clamped = min(full.length, max(0, location))
        guard clamped > 0 else { return 0 }
        let separator = full.rangeOfCharacter(
            from: .whitespacesAndNewlines,
            options: .backwards,
            range: NSRange(location: 0, length: clamped)
        )
        return separator.location == NSNotFound ? 0 : NSMaxRange(separator)
    }

    /// Searches a caller-supplied UTF-16 region. Snippets are clipped to the same
    /// region so a read-so-far result cannot leak text beyond its spoiler boundary.
    func search(
        query: String,
        in utf16Range: Range<Int>? = nil,
        options: NSString.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
    ) -> [ReaderSearchHit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let full = attributedText.string as NSString
        let requested = utf16Range ?? 0..<full.length
        let lowerBound = min(full.length, max(0, requested.lowerBound))
        let upperBound = min(full.length, max(lowerBound, requested.upperBound))
        var hits: [ReaderSearchHit] = []
        var searchRange = NSRange(location: lowerBound, length: upperBound - lowerBound)
        while searchRange.length > 0 {
            let found = full.range(of: trimmed, options: options, range: searchRange)
            if found.location == NSNotFound { break }
            if let anchor = anchor(containingUtf16Location: found.location) {
                let snippetStart = max(lowerBound, found.location - 72)
                let snippetEnd = min(upperBound, found.location + found.length + 72)
                let snippet = full.substring(with: NSRange(location: snippetStart, length: snippetEnd - snippetStart))
                hits.append(
                    ReaderSearchHit(
                        range: found,
                        chapterId: anchor.chapterId,
                        chapterTitle: anchor.chapterTitle,
                        blockId: anchor.block.id,
                        snippet: snippet.replacingOccurrences(of: "\n", with: " ")
                    )
                )
            }
            let next = found.location + max(found.length, 1)
            searchRange = NSRange(location: next, length: max(0, upperBound - next))
        }
        return hits
    }
}

struct ReaderSearchHit: Equatable, Hashable, Identifiable, Sendable {
    var id: String { "\(range.location)-\(range.length)-\(blockId.uuidString)" }
    var range: NSRange
    var chapterId: UUID
    var chapterTitle: String
    var blockId: UUID
    var snippet: String
}

enum ReaderDocumentBuilder {
    /// Builds a continuous vertical document from a book using caller-supplied readable revisions
    /// (typically from `ManuscriptVersioningService.readableRevision` — never invents AI content).
    static func build(
        book: Book,
        readableRevisions: [UUID: ChapterRevision],
        typography: ReaderTypography
    ) -> ReaderDocument {
        let chapters = book.chapters.sorted { $0.orderIndex < $1.orderIndex }
        let result = NSMutableAttributedString()
        var anchors: [ReaderBlockAnchor] = []
        var chapterStarts: [(chapterId: UUID, title: String, utf16Location: Int)] = []

        for (chapterIndex, chapter) in chapters.enumerated() {
            guard let revision = readableRevisions[chapter.id] ?? chapter.activeRevision else { continue }
            var blocks = revision.blocks.sorted { $0.orderIndex < $1.orderIndex }
            // Phase 6: keep outline stubs light in the continuous scroll (full expand via adaptation).
            if chapter.isOutlineStub, blocks.count > 4 {
                blocks = Array(blocks.prefix(4))
            }
            if chapterIndex > 0 {
                result.append(NSAttributedString(string: "\n\n", attributes: typography.bodyAttributes))
            }
            chapterStarts.append((chapter.id, chapter.title, result.length))

            for (blockIndex, block) in blocks.enumerated() {
                if blockIndex > 0 {
                    result.append(NSAttributedString(string: "\n\n", attributes: typography.bodyAttributes))
                }
                let attrs = typography.attributes(for: block.kind)
                let start = result.length
                let text = displayText(for: block)
                result.append(NSAttributedString(string: text, attributes: attrs))
                let end = result.length
                anchors.append(
                    ReaderBlockAnchor(
                        chapterId: chapter.id,
                        chapterTitle: chapter.title,
                        chapterOrderIndex: chapter.orderIndex,
                        revisionId: revision.id,
                        block: block,
                        utf16Range: start..<end
                    )
                )
            }
        }

        // Trailing padding so the last lines can scroll above the home indicator / chrome.
        result.append(NSAttributedString(string: "\n\n\n", attributes: typography.bodyAttributes))

        return ReaderDocument(
            bookId: book.id,
            title: book.title,
            author: book.author,
            attributedText: result,
            anchors: anchors,
            chapterStarts: chapterStarts
        )
    }

    /// UTF-16 characters the renderer inserts before a block's stored text, so a rendered
    /// offset (a tapped word) can be mapped back onto the manuscript.
    static func displayPrefixLength(for block: ContentBlock) -> Int {
        switch block.kind {
        case .quote: return 1
        case .heading, .paragraph, .callout, .imagePlaceholder: return 0
        }
    }

    private static func displayText(for block: ContentBlock) -> String {
        switch block.kind {
        case .quote:
            return "“\(block.text)”"
        case .callout:
            return block.text
        case .imagePlaceholder:
            return block.text.isEmpty ? "[Image]" : block.text
        case .heading, .paragraph:
            return block.text
        }
    }
}
