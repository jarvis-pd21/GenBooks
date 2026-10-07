import Foundation

/// Turns pasted text or extracted PDF text into a structured Living manuscript.
///
/// PDF/plain text are ingest sources only. The canonical store is always
/// `Book → Chapter → ChapterRevision → ContentBlock` (GOAL non-negotiable #6).
enum ManuscriptImporter {
    /// Soft ceiling for a fallback chapter so long pastes still get honest splits.
    static let fallbackChapterWordBudget = 1_000
    /// Below this, a source without headings stays a single chapter.
    static let singleChapterWordCeiling = 400

    static func importPlainText(
        text: String,
        title: String?,
        author: String?,
        sourceKind: ImportSourceKind,
        bookId: UUID = UUID(),
        at date: Date = Date()
    ) throws -> Book {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CreateBookError.emptySource }
        if bookId == ArgentinaFixtureIDs.book {
            throw CreateBookError.argentinaProtected
        }
        if bookId == QuranFixtureIDs.book {
            throw CreateBookError.quranProtected
        }

        let splits = splitChapters(from: trimmed)
        guard !splits.isEmpty else { throw CreateBookError.noChapters }

        let resolvedTitle = resolvedBookTitle(explicit: title, firstChapter: splits[0].title, source: trimmed)
        let resolvedAuthor: String = {
            let a = author?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return a.isEmpty ? "Unknown" : a
        }()

        var chapters: [Chapter] = []
        for (index, split) in splits.enumerated() {
            let chapterId = UUID()
            let revisionId = UUID()
            var blocks = blocks(from: split.body)
            if blocks.first?.kind != .heading {
                blocks.insert(
                    ContentBlock(id: UUID(), kind: .heading, text: split.title, orderIndex: 0),
                    at: 0
                )
                for i in blocks.indices { blocks[i].orderIndex = i }
            }
            let revision = ChapterRevision(
                id: revisionId,
                chapterId: chapterId,
                revisionIndex: 1,
                createdAt: date,
                blocks: blocks,
                isConsumed: false,
                origin: .imported(source: sourceKind.provenanceLabel)
            )
            chapters.append(
                Chapter(
                    id: chapterId,
                    bookId: bookId,
                    title: split.title,
                    orderIndex: index + 1,
                    activeRevisionId: revisionId,
                    revisions: [revision],
                    manuscriptStatus: .polished,
                    eraLabel: nil,
                    outlineBeats: nil
                )
            )
        }

        return Book(
            id: bookId,
            title: resolvedTitle,
            author: resolvedAuthor,
            subtitle: sourceKind.canonSubtitle,
            synopsis: synopsis(from: trimmed),
            coverAccent: "imported",
            edition: BookEdition(
                id: UUID(),
                bookId: bookId,
                label: "Canon",
                localeIdentifier: "en"
            ),
            timeline: [],
            provenanceNotes: [
                "Canon import from \(sourceKind.provenanceLabel) on \(ISO8601DateFormatter().string(from: date)).",
                "Exact text — no AI rewrite. Ingest only; canonical store is the Codable manuscript."
            ],
            chapters: chapters
        )
    }

    /// Honest chapter splits: headings first, then numbered Chapter lines,
    /// then `---` / form-feed separators, then word-budget fallback.
    static func splitChapters(from text: String) -> [(title: String, body: String)] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        if let markdown = splitMarkdownHeadings(normalized), markdown.count >= 1 {
            if markdown.count >= 2 || hasExplicitHeading(normalized) {
                return markdown
            }
        }
        if let numbered = splitNumberedChapters(normalized), numbered.count >= 2 {
            return numbered
        }
        if let separated = splitExplicitSeparators(normalized), separated.count >= 2 {
            return separated
        }
        return splitByWordBudget(normalized)
    }

    static func blocks(from body: String) -> [ContentBlock] {
        let paragraphs = body
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if paragraphs.isEmpty {
            let fallback = body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !fallback.isEmpty else { return [] }
            return [ContentBlock(id: UUID(), kind: .paragraph, text: fallback, orderIndex: 0)]
        }
        return paragraphs.enumerated().map { index, paragraph in
            let kind: ContentBlockKind
            if index == 0, looksLikeHeading(paragraph) {
                kind = .heading
            } else if paragraph.hasPrefix(">") {
                kind = .quote
            } else {
                kind = .paragraph
            }
            let text = paragraph.hasPrefix(">")
                ? paragraph.drop(while: { $0 == ">" || $0 == " " }).trimmingCharacters(in: .whitespacesAndNewlines)
                : paragraph
            return ContentBlock(id: UUID(), kind: kind, text: text, orderIndex: index)
        }
    }

    // MARK: - Splitters

    private static func splitMarkdownHeadings(_ text: String) -> [(title: String, body: String)]? {
        let pattern = #"(?m)^#{1,3}\s+(.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return nil }

        var chapters: [(title: String, body: String)] = []
        if matches[0].range.location > 0 {
            let preface = ns.substring(with: NSRange(location: 0, length: matches[0].range.location))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !preface.isEmpty, AdaptationPlanValidator.wordCount(of: preface) >= 20 {
                chapters.append((title: "Preface", body: preface))
            }
        }
        for (index, match) in matches.enumerated() {
            let titleRange = match.range(at: 1)
            guard titleRange.location != NSNotFound else { continue }
            let title = ns.substring(with: titleRange).trimmingCharacters(in: .whitespacesAndNewlines)
            let bodyStart = match.range.location + match.range.length
            let bodyEnd = index + 1 < matches.count ? matches[index + 1].range.location : ns.length
            let body = ns.substring(with: NSRange(location: bodyStart, length: max(0, bodyEnd - bodyStart)))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            chapters.append((title: title.isEmpty ? "Chapter \(chapters.count + 1)" : title, body: body))
        }
        return chapters.isEmpty ? nil : chapters
    }

    private static func splitNumberedChapters(_ text: String) -> [(title: String, body: String)]? {
        let pattern = #"(?m)^(Chapter|CHAPTER|Part|PART)\s+(\d+|[IVXLCDM]+)(?:\s*[:.\-—]\s*|\s+)(.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard matches.count >= 2 else { return nil }

        var chapters: [(title: String, body: String)] = []
        for (index, match) in matches.enumerated() {
            let title: String
            if match.numberOfRanges >= 4, match.range(at: 3).location != NSNotFound {
                title = ns.substring(with: match.range(at: 3)).trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                title = "Chapter \(index + 1)"
            }
            let bodyStart = match.range.location + match.range.length
            let bodyEnd = index + 1 < matches.count ? matches[index + 1].range.location : ns.length
            let body = ns.substring(with: NSRange(location: bodyStart, length: max(0, bodyEnd - bodyStart)))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            chapters.append((title: title.isEmpty ? "Chapter \(index + 1)" : title, body: body))
        }
        return chapters
    }

    private static func splitExplicitSeparators(_ text: String) -> [(title: String, body: String)]? {
        let parts = text
            .components(separatedBy: CharacterSet(charactersIn: "\u{000C}"))
            .flatMap { $0.components(separatedBy: "\n---\n") }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard parts.count >= 2 else { return nil }
        return parts.enumerated().map { index, part in
            titledBody(part, fallback: "Chapter \(index + 1)")
        }
    }

    private static func splitByWordBudget(_ text: String) -> [(title: String, body: String)] {
        let words = AdaptationPlanValidator.wordCount(of: text)
        if words <= singleChapterWordCeiling {
            return [titledBody(text, fallback: "Chapter 1")]
        }
        let paragraphs = text
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard paragraphs.count >= 2 else {
            return [titledBody(text, fallback: "Chapter 1")]
        }

        var chapters: [(title: String, body: String)] = []
        var buffer: [String] = []
        var bufferWords = 0
        for paragraph in paragraphs {
            let wc = AdaptationPlanValidator.wordCount(of: paragraph)
            if bufferWords + wc > fallbackChapterWordBudget, !buffer.isEmpty {
                let joined = buffer.joined(separator: "\n\n")
                chapters.append(titledBody(joined, fallback: "Chapter \(chapters.count + 1)"))
                buffer = [paragraph]
                bufferWords = wc
            } else {
                buffer.append(paragraph)
                bufferWords += wc
            }
        }
        if !buffer.isEmpty {
            let joined = buffer.joined(separator: "\n\n")
            chapters.append(titledBody(joined, fallback: "Chapter \(chapters.count + 1)"))
        }
        return chapters
    }

    // MARK: - Helpers

    private static func titledBody(_ text: String, fallback: String) -> (title: String, body: String) {
        let lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let first = lines.first, looksLikeHeading(first) {
            let rest = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return (title: stripHeadingMarks(first), body: rest)
        }
        return (title: fallback, body: text)
    }

    private static func looksLikeHeading(_ line: String) -> Bool {
        let trimmed = stripHeadingMarks(line)
        guard !trimmed.isEmpty, trimmed.count <= 80, !trimmed.contains("\n") else { return false }
        return trimmed.split(separator: " ").count <= 10
    }

    private static func stripHeadingMarks(_ line: String) -> String {
        var text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasPrefix("#") {
            text.removeFirst()
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func hasExplicitHeading(_ text: String) -> Bool {
        text.range(of: #"(?m)^#{1,3}\s+\S+"#, options: .regularExpression) != nil
    }

    private static func resolvedBookTitle(explicit: String?, firstChapter: String, source: String) -> String {
        if let explicit, !explicit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return explicit.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if firstChapter != "Chapter 1", firstChapter != "Preface" {
            return firstChapter
        }
        if let firstLine = source.split(whereSeparator: \.isNewline).first.map(String.init) {
            let cleaned = stripHeadingMarks(firstLine)
            if looksLikeHeading(cleaned) { return cleaned }
        }
        return "Imported manuscript"
    }

    private static func synopsis(from text: String) -> String {
        let collapsed = text.split { $0.isWhitespace || $0.isNewline }.joined(separator: " ")
        guard collapsed.count > 220 else { return collapsed }
        return String(collapsed.prefix(220)) + "…"
    }
}

/// Parses the optional ChatGPT / other-AI paste-back into editable cards.
enum CreateProfileCardParser {
    static func parse(_ paste: String) -> [CreateProfileCard] {
        let trimmed = paste.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let pattern = #"(?m)^##\s+(.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return [CreateProfileCard(title: "Notes", body: trimmed)]
        }
        let ns = trimmed as NSString
        let matches = regex.matches(in: trimmed, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else {
            return [CreateProfileCard(title: "Notes", body: trimmed)]
        }

        var cards: [CreateProfileCard] = []
        for (index, match) in matches.enumerated() {
            let title = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            let bodyStart = match.range.location + match.range.length
            let bodyEnd = index + 1 < matches.count ? matches[index + 1].range.location : ns.length
            let body = ns.substring(with: NSRange(location: bodyStart, length: max(0, bodyEnd - bodyStart)))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            cards.append(CreateProfileCard(title: title.isEmpty ? "Notes" : title, body: body))
        }
        return cards
    }

    /// Folds a `## Voice` / `## Outline` paste-back from another AI into the draft.
    /// Returns the card count so the caller can acknowledge it. Nothing is overwritten
    /// when the paste has no cards.
    @discardableResult
    static func importCards(from paste: String, into draft: inout CreateBookDraft) -> Int {
        let cards = parse(paste)
        guard !cards.isEmpty else { return 0 }
        draft.profileCards = cards
        let outlines = outlineTitles(from: cards)
        if !outlines.isEmpty { draft.outlineTitles = outlines }
        for card in cards {
            let body = card.body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            if card.title.localizedCaseInsensitiveContains("voice") {
                draft.voice = body
            }
            if card.title.localizedCaseInsensitiveContains("research") {
                draft.researchNotes = body
            }
            if card.title.localizedCaseInsensitiveContains("reference") {
                draft.referenceStyles = body
                    .components(separatedBy: CharacterSet(charactersIn: ",\n"))
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            }
        }
        return cards.count
    }

    static func outlineTitles(from cards: [CreateProfileCard]) -> [String] {
        cards
            .filter { $0.title.localizedCaseInsensitiveContains("outline") }
            .flatMap { card in
                card.body.components(separatedBy: .newlines).compactMap { line -> String? in
                    var text = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return nil }
                    if text.hasPrefix("-") || text.hasPrefix("*") {
                        text = String(text.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    if let range = text.range(of: #"^\d+\.\s+"#, options: .regularExpression) {
                        text = String(text[range.upperBound...])
                    }
                    return text.isEmpty ? nil : text
                }
            }
    }
}
