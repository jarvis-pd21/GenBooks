import Foundation

/// A word-level cut inside a chapter.
///
/// The selected word and all text before it are frozen. Regeneration begins after
/// the complete word and its following punctuation/spacing, never inside that word.
/// The anchor is semantic (chapter + revision + block + UTF-16 offset), never screen coordinates.
struct RegenerationWordAnchor: Codable, Equatable, Hashable, Sendable {
    var bookId: UUID
    var chapterId: UUID
    var chapterTitle: String
    /// Revision the anchor was captured against. Regeneration refuses to run if the chapter moved on.
    var revisionId: UUID
    var blockId: UUID
    /// UTF-16 offset of the first character of the nearest word, within the block's text.
    var utf16OffsetInBlock: Int
    var word: String
    var createdAt: Date
    /// Missing in older encoded anchors: ordinary selections default to after-word.
    /// Chapter-start is only for redirecting a finished selection to unread content.
    var boundary: RegenerationAnchorBoundary? = nil

    var effectiveBoundary: RegenerationAnchorBoundary { boundary ?? .afterWord }

    var displayWord: String {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "this point" : trimmed
    }
}

enum RegenerationAnchorBoundary: String, Codable, Sendable {
    case afterWord
    case chapterStart
}

/// What the reader asked for after the selected word.
enum RegenerationIntent: String, Codable, CaseIterable, Identifiable, Sendable {
    case moreImages
    case moreStories
    case moreExplanation
    case morePlaces
    case lessDetail

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .moreImages: return "More images"
        case .moreStories: return "More stories"
        case .moreExplanation: return "More explanation"
        case .morePlaces: return "More places"
        case .lessDetail: return "Less detail"
        }
    }

    var systemImage: String {
        switch self {
        case .moreImages: return "photo.on.rectangle"
        case .moreStories: return "text.book.closed"
        case .moreExplanation: return "lightbulb"
        case .morePlaces: return "map"
        case .lessDetail: return "scissors"
        }
    }

    var promptLine: String {
        switch self {
        case .moreImages: return "Include more visual moments — add image placeholders with concrete captions."
        case .moreStories: return "Tell more of it through scenes and people rather than summary."
        case .moreExplanation: return "Explain cause and effect more plainly."
        case .morePlaces: return "Ground it in places the reader could visit."
        case .lessDetail: return "Trim name and date density; keep the through-line."
        }
    }

    /// Extra visual placeholders this intent asks for in the regenerated stretch.
    var extraVisuals: Int {
        self == .moreImages ? 2 : 0
    }
}

/// One "regenerate after this word" request, ready for preview.
struct WordForwardRegenerationRequest: Equatable, Sendable {
    var anchor: RegenerationWordAnchor
    var intents: [RegenerationIntent]
    var freeText: String
    var readerPreferencesSummary: String
    /// Unread chapters after the anchor chapter that Apply may also replace.
    var maxFollowOnChapters: Int

    init(
        anchor: RegenerationWordAnchor,
        intents: [RegenerationIntent] = [],
        freeText: String = "",
        readerPreferencesSummary: String = "",
        maxFollowOnChapters: Int = 1
    ) {
        self.anchor = anchor
        self.intents = intents
        self.freeText = freeText
        self.readerPreferencesSummary = readerPreferencesSummary
        self.maxFollowOnChapters = max(0, maxFollowOnChapters)
    }

    /// Human-readable request line shown in the sheet and sent to the model.
    var summaryLine: String {
        var parts = intents.map(\.displayName)
        let free = freeText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !free.isEmpty { parts.append(free) }
        if parts.isEmpty { parts.append("Rewrite the rest in the same voice") }
        return parts.joined(separator: " · ")
    }

    var promptLines: [String] {
        var lines = intents.map(\.promptLine)
        let free = freeText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !free.isEmpty { lines.append("Reader’s own words: \(free)") }
        return lines
    }

    var extraVisuals: Int {
        intents.reduce(0) { $0 + $1.extraVisuals }
    }
}

/// Everything the model needs to continue a chapter mid-sentence without touching read text.
struct WordAnchorPromptContext: Equatable, Sendable {
    var anchorWord: String
    /// Tail of the frozen prefix (~400–800 words) so the continuation reads seamlessly.
    var frozenPrefixTail: String
    var frozenPrefixWordCount: Int
    var userRequest: String
    var requestLines: [String]
    var readerPreferencesSummary: String
    var plannedVisualCount: Int
}

/// Result of splitting a chapter's blocks at a word anchor.
struct ChapterAnchorSplit: Equatable, Sendable {
    /// Blocks (and the leading half of the anchor block) that must survive byte-for-byte.
    var frozenPrefix: [ContentBlock]
    /// Blocks eligible for regeneration, strictly after the selected word.
    var regenerableSuffix: [ContentBlock]
    var anchorWord: String
    /// Block divided by the cut, when the anchor landed inside a block's text.
    var dividedBlockId: UUID?
    var prefixWordCount: Int
    var suffixWordCount: Int
    var suffixVisualCount: Int

    var hasRegenerableSuffix: Bool { !regenerableSuffix.isEmpty }
}

enum ChapterAnchorSplitError: Error, Equatable, LocalizedError, Sendable {
    case blockNotFound(UUID)
    case prefixMutated

    var errorDescription: String? {
        switch self {
        case .blockNotFound(let id):
            return "The anchored passage \(id) is no longer part of this chapter."
        case .prefixMutated:
            return "Generation tried to rewrite text you already read — nothing was saved."
        }
    }
}

/// Splits a chapter at a word so the read past can be frozen while the future is regenerated.
enum ChapterAnchorSplitter {
    static let minimumPromptTailWords = 400
    static let maximumPromptTailWords = 800

    /// Snaps an arbitrary UTF-16 offset to the start of the nearest word.
    ///
    /// This is a locator, not the regeneration cut: split advances past the word.
    static func nearestWordStart(in text: String, utf16Offset: Int) -> (utf16Offset: Int, word: String) {
        let ns = text as NSString
        guard ns.length > 0 else { return (0, "") }
        let clamped = min(max(0, utf16Offset), ns.length - 1)
        let pin = BookmarkAnchorResolver.nearestWordPin(
            blockText: text,
            selectionStartUtf16: clamped,
            selectedText: ""
        )
        return (min(max(0, pin.utf16Offset), ns.length), pin.word)
    }

    /// Inclusive read boundary. Use the existing nearest-word locator, then move
    /// forward by complete graphemes; never treat a UTF-16 code unit as a letter.
    /// Keep punctuation/spacing with the frozen word so an end-of-chapter period
    /// does not become an otherwise empty generation request.
    static func nearestWordEnd(in text: String, utf16Offset: Int) -> (utf16Offset: Int, word: String) {
        let ns = text as NSString
        guard ns.length > 0 else { return (0, "") }
        let pin = nearestWordStart(in: text, utf16Offset: utf16Offset)
        if utf16Offset >= ns.length { return (ns.length, pin.word) }
        // Start with one complete source grapheme. A legacy pin can include the
        // digit of an adjacent keycap emoji; its string length is not a safe end.
        let range = ns.rangeOfComposedCharacterSequence(at: pin.utf16Offset)
        var end = NSMaxRange(range)
        var wordBases = CharacterSet.letters.union(.decimalDigits)
        wordBases.formUnion(CharacterSet(charactersIn: "'’"))
        wordBases.subtract(.nonBaseCharacters)
        let isLexical: (String) -> Bool = { grapheme in
            let scalars = grapheme.unicodeScalars
            return !scalars.contains(where: { $0.value == 0x20E3 })
                && scalars.contains(where: wordBases.contains)
        }
        if isLexical(ns.substring(with: range)) {
            // A legacy locator can stop at a combining mark or supplementary
            // letter. Include the rest of that same lexical word, not half of it.
            while end < ns.length {
                let next = ns.rangeOfComposedCharacterSequence(at: end)
                let part = ns.substring(with: next)
                guard isLexical(part) else { break }
                end = NSMaxRange(next)
            }
        }
        let word = ns.substring(with: NSRange(location: range.location, length: end - range.location))
        let separators = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        while end < ns.length {
            let next = ns.rangeOfComposedCharacterSequence(at: end)
            guard ns.substring(with: next).unicodeScalars.allSatisfy({ separators.contains($0) }) else { break }
            end = NSMaxRange(next)
        }
        return (end, word)
    }

    static func split(
        blocks: [ContentBlock],
        blockId: UUID,
        utf16OffsetInBlock: Int,
        boundary: RegenerationAnchorBoundary = .afterWord
    ) throws -> ChapterAnchorSplit {
        let ordered = blocks.sorted { $0.orderIndex < $1.orderIndex }
        guard let index = ordered.firstIndex(where: { $0.id == blockId }) else {
            throw ChapterAnchorSplitError.blockNotFound(blockId)
        }

        if boundary == .chapterStart {
            var suffix = ordered
            for i in suffix.indices { suffix[i].orderIndex = i }
            return ChapterAnchorSplit(
                frozenPrefix: [], regenerableSuffix: suffix, anchorWord: "", dividedBlockId: nil,
                prefixWordCount: 0,
                suffixWordCount: AdaptationPlanValidator.wordCount(of: suffix.filter { $0.kind != .imagePlaceholder }),
                suffixVisualCount: suffix.filter { $0.kind == .imagePlaceholder }.count
            )
        }

        var prefix = Array(ordered[..<index])
        var suffix = Array(ordered[(index + 1)...])
        let anchorBlock = ordered[index]
        let ns = anchorBlock.text as NSString

        let rawCut: Int
        let word: String
        if anchorBlock.kind == .imagePlaceholder || ns.length == 0 {
            // A selected visual is atomic and stays frozen in its entirety.
            rawCut = ns.length
            word = anchorBlock.text
        } else {
            let snapped = nearestWordEnd(in: anchorBlock.text, utf16Offset: utf16OffsetInBlock)
            rawCut = snapped.utf16Offset
            word = snapped.word
        }

        // A half made only of whitespace cannot be its own block (candidate validation
        // rejects blank text), so the cut collapses to the nearest block boundary.
        let headMeaningful = rawCut > 0 && !isBlank(ns.substring(to: rawCut))
        let tailMeaningful = rawCut < ns.length && !isBlank(ns.substring(from: rawCut))
        let cut: Int
        if !headMeaningful {
            cut = 0
        } else if !tailMeaningful {
            cut = ns.length
        } else {
            cut = rawCut
        }

        var dividedBlockId: UUID?
        if cut > 0 {
            var head = anchorBlock
            head.text = ns.substring(to: cut)
            prefix.append(head)
        }
        if cut < ns.length {
            var tail = anchorBlock
            // The head keeps the original block id so highlights, notes and the saved
            // reading place that live in already-read text keep resolving after Apply.
            if cut > 0 {
                tail.id = UUID()
                dividedBlockId = anchorBlock.id
            }
            tail.text = ns.substring(from: cut)
            suffix.insert(tail, at: 0)
        }

        for i in prefix.indices { prefix[i].orderIndex = i }
        for i in suffix.indices { suffix[i].orderIndex = i }

        return ChapterAnchorSplit(
            frozenPrefix: prefix,
            regenerableSuffix: suffix,
            anchorWord: word,
            dividedBlockId: dividedBlockId,
            prefixWordCount: AdaptationPlanValidator.wordCount(of: prefix.filter { $0.kind != .imagePlaceholder }),
            suffixWordCount: AdaptationPlanValidator.wordCount(of: suffix.filter { $0.kind != .imagePlaceholder }),
            suffixVisualCount: suffix.filter { $0.kind == .imagePlaceholder }.count
        )
    }

    /// Frozen prefix followed by regenerated future, re-indexed as one revision body.
    static func assemble(frozenPrefix: [ContentBlock], regenerated: [ContentBlock]) -> [ContentBlock] {
        var result = frozenPrefix + regenerated
        for i in result.indices { result[i].orderIndex = i }
        return result
    }

    /// Last-line defence before staging: the new revision must open with the exact frozen text.
    static func assertPrefixPreserved(_ frozenPrefix: [ContentBlock], in blocks: [ContentBlock]) throws {
        guard blocks.count >= frozenPrefix.count else {
            throw ChapterAnchorSplitError.prefixMutated
        }
        for (index, frozen) in frozenPrefix.enumerated() {
            let candidate = blocks[index]
            // Swift String equality allows Unicode normalization. Exact source bytes
            // must survive: normalization can shift saved UTF-16 annotation offsets.
            guard candidate.id == frozen.id,
                  candidate.kind == frozen.kind,
                  candidate.text.utf8.elementsEqual(frozen.text.utf8)
            else {
                throw ChapterAnchorSplitError.prefixMutated
            }
        }
    }

    /// Tail of the frozen text, so the model can continue a sentence it cannot rewrite.
    static func frozenPrefixTail(_ blocks: [ContentBlock], words: Int = 600) -> String {
        let budget = min(maximumPromptTailWords, max(minimumPromptTailWords, words))
        let joined = blocks
            .filter { $0.kind != .imagePlaceholder }
            .map(\.text)
            .joined(separator: " ")
        let tokens = joined.split { $0.isWhitespace || $0.isNewline }
        guard tokens.count > budget else { return tokens.joined(separator: " ") }
        return tokens.suffix(budget).joined(separator: " ")
    }

    private static func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Preview shown before Apply for a word-forward regeneration.
struct WordForwardRegenerationPreview: Equatable, Sendable {
    var anchor: RegenerationWordAnchor
    var requestSummary: String
    var requestLines: [String]
    /// Words through and including the anchor that Apply must not touch.
    var frozenPrefixWordCount: Int
    /// Words after the anchor that Apply replaces.
    var regeneratingWordCount: Int
    var suffixTargetWordCount: Int
    var plannedVisualCount: Int
    var followOnChapters: [RegenChapterSummary]
    var lockedSkippedCount: Int
    var baselineRemaining: ReadingTimeEstimate
    var plannedRemaining: ReadingTimeEstimate
    var plan: AdaptationPlan
    var preferences: ReadingTimePreferences
    var readerPreferencesSummary: String

    var regeneratesAnchorChapter: Bool {
        plan.affectedChapterIds.contains(anchor.chapterId)
    }

    var frozenSummary: String {
        anchor.effectiveBoundary == .chapterStart
            ? "Finished chapters stay unchanged; this unread chapter starts from its beginning"
            : "\(frozenPrefixWordCount) words through “\(anchor.displayWord)” stay exactly as you read them"
    }
}
