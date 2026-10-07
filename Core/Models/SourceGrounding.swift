import Foundation
import CryptoKit

/// A deliberately narrow research preview, not full-book factual verification.
struct SourcePilotPlan: Codable, Equatable, Hashable, Sendable {
    let articleTitle: String
    let approvedBriefHash: String
    /// Absent on previously approved introduction previews; never reinterpret those.
    var sourceScope: RetrievedResearchSource.Scope? = nil
    var selectedScope: RetrievedResearchSource.Scope { sourceScope ?? .wikipediaIntroduction }
    static let targetWords = 400
    static let disclosure = "AI-checked against one Wikipedia introduction, not independently fact-checked."

    static func disclosure(for scope: RetrievedResearchSource.Scope) -> String {
        scope == .wikipediaIntroduction ? disclosure
            : "AI-checked against an opening Wikipedia excerpt, not the full article or an independent fact-check."
    }

    static func approved(articleTitle: String, draft: CreateBookDraft,
                         scope: RetrievedResearchSource.Scope = .wikipediaIntroduction) throws -> Self {
        Self(articleTitle: articleTitle.trimmingCharacters(in: .whitespacesAndNewlines),
             approvedBriefHash: try briefHash(draft, scope: scope),
             sourceScope: scope == .wikipediaIntroduction ? nil : scope)
    }

    static func briefHash(_ draft: CreateBookDraft, scope: RetrievedResearchSource.Scope? = nil) throws -> String {
        let selected = scope ?? draft.sourcePilot?.selectedScope ?? .wikipediaIntroduction
        var copy = draft
        copy.sourcePilot = nil
        copy.updatedAt = Date(timeIntervalSince1970: 0)
        if selected == .wikipediaIntroduction { return try SourceGrounding.hash(copy) }
        struct ScopedBrief: Encodable { let draft: CreateBookDraft; let scope: RetrievedResearchSource.Scope }
        return try SourceGrounding.hash(ScopedBrief(draft: copy, scope: selected))
    }
}

/// Lives on the chapter, so subsequent adaptation cannot drop its source policy.
struct SourceGroundingRequirement: Codable, Equatable, Hashable, Sendable {
    let source: RetrievedResearchSource
    let outlineRevisionID: UUID
    let outlineContentHash: String
    let approvedBriefHash: String
}

struct SourceDraftParagraph: Codable, Equatable, Hashable, Sendable {
    let text: String
    let citations: [String]
}

struct SourceReviewUnit: Codable, Equatable, Hashable, Sendable {
    enum Assessment: String, Codable, Hashable, Sendable { case supported, unsupported, contradictory }
    let index: Int
    let assessment: Assessment
    let quotes: [String]
}

struct SourceReviewResponse: Codable, Equatable, Hashable, Sendable {
    let units: [SourceReviewUnit]
}

/// App-owned binding of an independent review to exact text, chapter and source.
/// This is a fallible source-support assessment; it never sets FactClaim.verified.
struct SourceReviewReceipt: Codable, Equatable, Hashable, Sendable {
    let bookID: UUID
    let chapterID: UUID
    let baseRevisionID: UUID
    let contentHash: String
    let sourceHash: String
    let model: String
    let promptVersion: String
    let reviewedAt: Date
    let response: SourceReviewResponse
    /// Binds the selected boundary as well as final prose. Absent in legacy reviews.
    var wordCutHash: String? = nil
}

struct SourcePilotState: Codable, Equatable, Hashable, Sendable {
    let approvedBriefHash: String
    let chapterID: UUID
    let expectedRevisionID: UUID
    var candidate: CandidateRevision?
}

struct SourceWritingRequest: Sendable {
    let title: String
    let topic: String
    let voice: String
    let source: RetrievedResearchSource
}

struct SourceReviewRequest: Sendable {
    let paragraphs: [String]
    let source: RetrievedResearchSource
}

/// The writer receives the immutable context separately from the replaceable tail.
struct SourceContinuationWritingRequest: Sendable {
    let title: String
    let instructions: String
    let frozenParagraphs: [String]
    let oldSuffix: [String]
    let source: RetrievedResearchSource
    var joinsSelectedParagraph: Bool = false
    var minimumTailParagraphs: Int = 2
    var maximumTailParagraphs: Int = 6
}

struct SourceContinuationState: Codable, Equatable, Hashable, Sendable {
    enum Phase: String, Codable, Sendable {
        case prepared, writing, needsReview, reviewing, readyToPublish, publishing, published, uncertain
    }
    var id: UUID
    var bookID: UUID
    var chapterID: UUID
    var anchor: RegenerationWordAnchor
    var cut: SourceWordCut
    var source: RetrievedResearchSource
    var requestHash: String
    var requestSummary: String
    var instructions: String
    var frozenPrefixWordCount: Int
    var replacingWordCount: Int
    var createdAt: Date = Date()
    var phase: Phase = .prepared
    var candidate: CandidateRevision? = nil
    var candidateFingerprint: String? = nil
    var errorMessage: String? = nil
}

/// In-process ownership lasts across all suspensions. Register before the disk
/// phase transition so another reader cannot call a live writer "interrupted".
/// A process restart clears owners, but never the persisted attempt/candidate.
enum SourceContinuationOperations {
    private static let lock = NSLock()
    private static var active: Set<UUID> = []
    static func acquire(_ id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        guard active.insert(id).inserted else {
            throw SourceGroundingError.invalid("This rewrite is already running. Its saved draft is unchanged.")
        }
    }
    static func release(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        active.remove(id)
    }
}

protocol SourceGroundedAI: Sendable {
    var sourceReviewModelID: String { get }
    var supportsSourceContinuation: Bool { get }
    func writeSourcePreview(_ request: SourceWritingRequest) async throws -> [SourceDraftParagraph]
    func reviewSourcePreview(_ request: SourceReviewRequest) async throws -> SourceReviewResponse
    func writeSourceContinuation(_ request: SourceContinuationWritingRequest) async throws -> [SourceDraftParagraph]
}

extension SourceGroundedAI {
    var supportsSourceContinuation: Bool { false }
    /// Existing paid-trial wrappers must opt in rather than inherit a live route.
    func writeSourceContinuation(_ request: SourceContinuationWritingRequest) async throws -> [SourceDraftParagraph] {
        throw SourceGroundingError.invalid("This AI connection does not support source continuations. No writing request was sent.")
    }
}

enum SourceGroundingError: Error, LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        if case .invalid(let reason) = self { return "Source-checked preview: " + reason }
        return nil
    }
}

enum SourceGrounding {
    static let promptVersion = "source-preview-1"

    static func hash<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // Match file persistence: fractional seconds are not stored by JSONCoding.
        encoder.dateEncodingStrategy = .iso8601
        return SHA256.hash(data: try encoder.encode(value)).map { String(format: "%02x", $0) }.joined()
    }

    /// Deliberately excludes block UUIDs: exact-content restore may give blocks new IDs.
    static func contentHash(_ blocks: [ContentBlock]) throws -> String {
        struct Unit: Encodable { let kind: ContentBlockKind; let text: String; let order: Int }
        return try hash(blocks.map { Unit(kind: $0.kind, text: $0.text, order: $0.orderIndex) })
    }

    static func validateSource(_ source: RetrievedResearchSource) throws {
        let actual = SHA256.hash(data: Data(source.text.utf8)).map { String(format: "%02x", $0) }.joined()
        guard actual == source.textSHA256,
              source.canonicalURL.scheme == "https", source.canonicalURL.host == "en.wikipedia.org",
              source.pageID > 0, source.revisionID > 0, !source.title.isEmpty,
              !source.attribution.isEmpty, !source.licenseName.isEmpty,
              source.licenseURL.scheme == "https" else {
            throw SourceGroundingError.invalid("The saved source identity or fingerprint changed.")
        }
        switch source.scope {
        case .wikipediaIntroduction:
            guard source.extractionMetadata == nil else {
                throw SourceGroundingError.invalid("An introduction cannot inherit an excerpt's source scope.")
            }
        case .wikipediaOpeningExcerpt:
            guard let metadata = source.extractionMetadata,
                  metadata.isValid(for: source.text) else {
                throw SourceGroundingError.invalid("The opening excerpt has missing or changed paragraph locators.")
            }
        }
        guard source.text.count <= 8_000,
              source.text.split(whereSeparator: \.isWhitespace).count >= 160 else {
            throw SourceGroundingError.invalid("This source has insufficient or excessive material for the 400-word preview. No prose was published.")
        }
    }

    static func sourceFooter(_ source: RetrievedResearchSource) -> String {
        "[1] \(source.attribution)\n\(source.revisionURL.absoluteString)\nContributors: \(source.attributionURL.absoluteString)\n\(source.licenseName): \(source.licenseURL.absoluteString)\nAdapted with AI; source text is retained with this book."
    }

    static func blocks(title: String, paragraphs: [SourceDraftParagraph], source: RetrievedResearchSource) throws -> [ContentBlock] {
        try validateSource(source)
        guard (2...12).contains(paragraphs.count), paragraphs.allSatisfy({
            $0.citations == ["source1"] && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && $0.text.count <= 4_000 && !$0.text.contains("[1]")
        }) else { throw SourceGroundingError.invalid("The writer returned missing or unknown source citations.") }
        var blocks = [ContentBlock(id: UUID(), kind: .heading, text: title, orderIndex: 0)]
        blocks += paragraphs.enumerated().map { index, paragraph in
            ContentBlock(id: UUID(), kind: .paragraph, text: paragraph.text + " [1]", orderIndex: index + 1)
        }
        blocks.append(ContentBlock(id: UUID(), kind: .callout, text: SourcePilotPlan.disclosure(for: source.scope), orderIndex: blocks.count))
        blocks.append(ContentBlock(id: UUID(), kind: .paragraph, text: sourceFooter(source), orderIndex: blocks.count))
        try AdaptationPlanValidator.assertWordCountSanity(
            actual: AdaptationPlanValidator.wordCount(of: paragraphs.map(\.text).joined(separator: " ")),
            target: SourcePilotPlan.targetWords)
        return blocks
    }

    static func prose(_ blocks: [ContentBlock], source: RetrievedResearchSource) throws -> [String] {
        guard (5...15).contains(blocks.count), blocks.first?.kind == .heading,
              blocks[blocks.count - 2].kind == .callout,
              blocks[blocks.count - 2].text == SourcePilotPlan.disclosure(for: source.scope),
              blocks.last?.kind == .paragraph, blocks.last?.text == sourceFooter(source),
              blocks.enumerated().allSatisfy({ $0.offset == $0.element.orderIndex }) else {
            throw SourceGroundingError.invalid("The reviewed preview structure or source disclosure changed.")
        }
        let body = blocks.dropFirst().dropLast(2)
        guard body.allSatisfy({ $0.kind == .paragraph && $0.text.hasSuffix(" [1]") }) else {
            throw SourceGroundingError.invalid("An unreviewed content block was introduced.")
        }
        return body.map(\.text)
    }

    /// Display count: whitespace-delimited prose words, excluding the app's
    /// trailing citation markers, heading, scope callout and source footer.
    /// This does not change the receipt version or any saved content.
    static func proseWordCount(_ blocks: [ContentBlock], source: RetrievedResearchSource) throws -> Int {
        let paragraphs = try prose(blocks, source: source)
        return AdaptationPlanValidator.wordCount(of: paragraphs.map { String($0.dropLast(4)) }.joined(separator: " "))
    }

    /// Only genuine body prose is eligible. The source footer never creates a suffix.
    static func wordCut(base: ChapterRevision, blockID: UUID, utf16Offset: Int,
                        source: RetrievedResearchSource) throws -> SourceWordCut? {
        _ = try prose(base.blocks, source: source)
        guard Set(base.blocks.map(\.id)).count == base.blocks.count,
              let index = base.blocks.firstIndex(where: { $0.id == blockID }),
              index > 0, index < base.blocks.count - 2 else {
            throw SourceGroundingError.invalid("Select a word in the preview's prose, not its heading or source notes.")
        }
        let text = String(base.blocks[index].text.dropLast(4))
        let ns = text as NSString
        guard utf16Offset >= 0, utf16Offset < ns.length,
              ns.rangeOfComposedCharacterSequence(at: utf16Offset).location == utf16Offset else {
            throw SourceGroundingError.invalid("The selected location is outside the prose or splits a character.")
        }
        let start = ChapterAnchorSplitter.nearestWordStart(in: text, utf16Offset: utf16Offset)
        let end = ChapterAnchorSplitter.nearestWordEnd(in: text, utf16Offset: start.utf16Offset)
        guard !start.word.isEmpty, end.utf16Offset > start.utf16Offset,
              end.word.unicodeScalars.contains(where: { CharacterSet.letters.union(.decimalDigits).contains($0) }) else {
            throw SourceGroundingError.invalid("The selected location does not identify a prose word.")
        }
        if index == base.blocks.count - 3 {
            let tail = ns.substring(from: end.utf16Offset)
            if BookmarkAnchorResolver.nearestWordPin(blockText: tail, selectionStartUtf16: 0, selectedText: "").word.isEmpty {
                return nil
            }
        }
        return SourceWordCut(baseRevisionID: base.id, blockID: blockID,
            wordStartUTF16: start.utf16Offset, endUTF16: end.utf16Offset, word: end.word)
    }

    /// Joins the new tail inside the selected paragraph, retaining its identity.
    /// The caller must review ALL resulting paragraphs before staging the result.
    static func assembleContinuation(base: ChapterRevision, cut: SourceWordCut,
                                     paragraphs: [SourceDraftParagraph], source: RetrievedResearchSource) throws -> [ContentBlock] {
        guard (1...12).contains(paragraphs.count), paragraphs.allSatisfy({
            $0.citations == ["source1"] && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && $0.text.count <= 4_000 && !$0.text.contains("[1]")
        }) else { throw SourceGroundingError.invalid("The continuation has missing or unknown source citations.") }
        guard let canonical = try wordCut(base: base, blockID: cut.blockID,
                                          utf16Offset: cut.wordStartUTF16, source: source),
              try hash(canonical) == hash(cut),
              let index = base.blocks.firstIndex(where: { $0.id == cut.blockID }) else {
            throw SourceGroundingError.invalid("The selected prose boundary changed or has no remaining prose.")
        }
        let original = base.blocks[index]
        let text = String(original.text.dropLast(4)) as NSString
        var result = Array(base.blocks.prefix(index))
        var remaining = paragraphs
        if cut.endUTF16 < text.length {
            var joined = original
            joined.text = text.substring(to: cut.endUTF16) + remaining.removeFirst().text + " [1]"
            result.append(joined)
        } else {
            result.append(original)
        }
        result += remaining.map { ContentBlock(id: UUID(), kind: .paragraph, text: $0.text + " [1]", orderIndex: 0) }
        result += base.blocks.suffix(2)
        for index in result.indices { result[index].orderIndex = index }
        try validateWordCut(cut, base: base, blocks: result, source: source)
        return result
    }

    /// Reconstruct the cut from the immutable base, then compare exact frozen bytes.
    static func validateWordCut(_ cut: SourceWordCut, base: ChapterRevision,
                                blocks: [ContentBlock], source: RetrievedResearchSource) throws {
        guard let canonical = try wordCut(base: base, blockID: cut.blockID,
                                          utf16Offset: cut.wordStartUTF16, source: source),
              try hash(canonical) == hash(cut),
              let index = base.blocks.firstIndex(where: { $0.id == cut.blockID }) else {
            throw SourceGroundingError.invalid("The saved selected-word boundary is missing, stale or changed.")
        }
        _ = try prose(blocks, source: source)
        guard Set(blocks.map(\.id)).count == blocks.count, blocks.count > index + 2 else {
            throw SourceGroundingError.invalid("The continuation lost a frozen paragraph or reused a block identity.")
        }
        for i in 0..<index {
            guard try hash(base.blocks[i]) == hash(blocks[i]) else {
                throw SourceGroundingError.invalid("The continuation changed a paragraph before your selected word.")
            }
        }
        let old = base.blocks[index], new = blocks[index]
        let text = String(old.text.dropLast(4)) as NSString
        let prefix = text.substring(to: cut.endUTF16)
        guard new.id == old.id, new.kind == old.kind, new.orderIndex == old.orderIndex,
              new.text.utf8.starts(with: prefix.utf8),
              cut.endUTF16 < text.length || new.text.utf8.elementsEqual(old.text.utf8) else {
            throw SourceGroundingError.invalid("The continuation changed text or identity through your selected word.")
        }
        for offset in 1...2 {
            let old = base.blocks[base.blocks.count - offset], new = blocks[blocks.count - offset]
            guard old.id == new.id, old.kind == new.kind, old.text.utf8.elementsEqual(new.text.utf8) else {
                throw SourceGroundingError.invalid("The continuation changed the retained source disclosure.")
            }
        }
    }

    static func validateResponse(_ response: SourceReviewResponse, paragraphs: [String], source: RetrievedResearchSource) throws {
        guard response.units.count == paragraphs.count,
              Set(response.units.map(\.index)) == Set(paragraphs.indices) else {
            throw SourceGroundingError.invalid("The independent review did not cover every prose paragraph.")
        }
        for unit in response.units {
            guard unit.assessment == .supported, (1...8).contains(unit.quotes.count),
                  unit.quotes.allSatisfy({ $0.count >= 12 && $0.count <= 4_000 && source.text.range(of: $0) != nil }) else {
                throw SourceGroundingError.invalid("A paragraph is unsupported, contradictory or cites an invented source passage. The writing draft is kept.")
            }
        }
    }

    static func receipt(bookID: UUID, chapterID: UUID, baseRevisionID: UUID, blocks: [ContentBlock], source: RetrievedResearchSource,
                        model: String, response: SourceReviewResponse, wordCut: SourceWordCut? = nil) throws -> SourceReviewReceipt {
        try validateSource(source)
        try validateResponse(response, paragraphs: prose(blocks, source: source), source: source)
        guard model == OpenAIModelOption.defaultGeneration.rawValue else {
            throw SourceGroundingError.invalid("This preview requires the selected frontier reviewer.")
        }
        guard wordCut == nil || wordCut?.baseRevisionID == baseRevisionID else {
            throw SourceGroundingError.invalid("The review's selected word belongs to a different base revision.")
        }
        return SourceReviewReceipt(bookID: bookID, chapterID: chapterID, baseRevisionID: baseRevisionID, contentHash: try contentHash(blocks),
            sourceHash: try hash(source), model: model, promptVersion: promptVersion, reviewedAt: Date(), response: response,
            wordCutHash: try wordCut.map { try hash($0) })
    }

    static func validate(receipt: SourceReviewReceipt?, bookID: UUID, chapterID: UUID,
                         blocks: [ContentBlock], requirement: SourceGroundingRequirement, baseRevisionID: UUID? = nil) throws {
        guard let receipt, receipt.bookID == bookID, receipt.chapterID == chapterID,
              receipt.contentHash == (try contentHash(blocks)), receipt.sourceHash == (try hash(requirement.source)),
              receipt.model == OpenAIModelOption.defaultGeneration.rawValue, receipt.promptVersion == promptVersion,
              baseRevisionID == nil || receipt.baseRevisionID == baseRevisionID else {
            throw SourceGroundingError.invalid("This revision needs a source review for its exact text; an older approval cannot be reused.")
        }
        try validateSource(requirement.source)
        try validateResponse(receipt.response, paragraphs: prose(blocks, source: requirement.source), source: requirement.source)
    }

    /// Classify from ancestry and exact assessment, never from a permissive label.
    /// History must contain only revisions preceding this transition.
    static func validateTransition(receipt: SourceReviewReceipt?, origin: RevisionOrigin?, blocks: [ContentBlock],
                                   bookID: UUID, chapter: Chapter, history: [ChapterRevision]) throws {
        guard let requirement = chapter.sourceGrounding, let base = history.max(by: { $0.revisionIndex < $1.revisionIndex }) else {
            throw SourceGroundingError.invalid("The preview's prior revision is missing.")
        }
        try validate(receipt: receipt, bookID: bookID, chapterID: chapter.id, blocks: blocks,
                     requirement: requirement, baseRevisionID: base.id)
        guard let receipt else { throw SourceGroundingError.invalid("The source review is missing.") }
        if base.id == requirement.outlineRevisionID {
            guard origin?.sourceWordCut == nil, receipt.wordCutHash == nil else {
                throw SourceGroundingError.invalid("An outline has no reviewed prose word to preserve.")
            }
            return
        }
        // Exact restores reuse only the historical assessment, including its cut
        // binding; fresh block UUIDs and current-base rebinding are legitimate.
        let exactRestore = try history.contains { historical in
            guard historical.id != requirement.outlineRevisionID,
                  var assessment = historical.sourceReview,
                  try contentHash(historical.blocks) == contentHash(blocks),
                  try hash(historical.origin?.sourceWordCut) == hash(origin?.sourceWordCut) else { return false }
            assessment = SourceReviewReceipt(bookID: assessment.bookID, chapterID: assessment.chapterID,
                baseRevisionID: receipt.baseRevisionID, contentHash: assessment.contentHash, sourceHash: assessment.sourceHash,
                model: assessment.model, promptVersion: assessment.promptVersion, reviewedAt: assessment.reviewedAt,
                response: assessment.response, wordCutHash: assessment.wordCutHash)
            guard try hash(assessment) == hash(receipt) else { return false }
            return origin?.kind != .restore || origin?.restoredFromRevisionIndex == historical.revisionIndex
        }
        if exactRestore { return }
        guard origin?.kind != .restore, let cut = origin?.sourceWordCut,
              receipt.wordCutHash == (try hash(cut)) else {
            throw SourceGroundingError.invalid("Changed source prose needs its selected-word boundary and a matching new review.")
        }
        try validateWordCut(cut, base: base, blocks: blocks, source: requirement.source)
    }

    /// All raw-store writers share this guard, including metadata saves and consume.
    static func validateSave(_ next: Book, previous: Book?) throws {
        if let previous, previous.chapters.contains(where: { $0.sourceGrounding != nil }) {
            guard next.chapters.map(\.id) == previous.chapters.map(\.id) else {
                throw SourceGroundingError.invalid("A protected preview cannot lose or silently add chapters.")
            }
        }
        for old in previous?.chapters ?? [] where old.sourceGrounding != nil {
            guard let chapter = next.chapters.first(where: { $0.id == old.id }),
                  try hash(chapter.sourceGrounding) == hash(old.sourceGrounding) else {
                throw SourceGroundingError.invalid("The saved source requirement cannot be removed or replaced.")
            }
            for oldRevision in old.revisions {
                guard let retained = chapter.revision(id: oldRevision.id),
                      try hash(retained.blocks) == hash(oldRevision.blocks), try hash(retained.sourceReview) == hash(oldRevision.sourceReview),
                      retained.revisionIndex == oldRevision.revisionIndex, try hash(retained.origin) == hash(oldRevision.origin),
                      !oldRevision.isConsumed || retained.isConsumed,
                      retained.chapterId == oldRevision.chapterId,
                      try hash(retained.createdAt) == hash(oldRevision.createdAt) else {
                    throw SourceGroundingError.invalid("Previously saved source-reviewed history must remain unchanged.")
                }
            }
            let additions = chapter.revisions.filter { old.revision(id: $0.id) == nil }
            guard additions.count <= 1, additions.allSatisfy({ $0.sourceReview?.baseRevisionID == old.activeRevision?.id }) else {
                throw SourceGroundingError.invalid("A save must publish one continuation from the current readable revision.")
            }
            if old.revisions.contains(where: \.isConsumed) {
                guard additions.isEmpty, chapter.activeRevisionId == old.activeRevisionId else {
                    throw SourceGroundingError.invalid("A consumed source preview cannot publish replacement prose.")
                }
            }
            if chapter.activeRevisionId != old.activeRevisionId {
                guard let active = chapter.activeRevision, chapter.activeRevisionId == active.id,
                      old.revision(id: active.id) == nil,
                      active.sourceReview?.baseRevisionID == old.activeRevision?.id else {
                    throw SourceGroundingError.invalid("A stale save or unreviewed pointer change cannot replace the readable revision.")
                }
            }
        }
        for chapter in next.chapters {
            guard let requirement = chapter.sourceGrounding else { continue }
            try validateSource(requirement.source)
            guard chapter.bookId == next.id, let activeID = chapter.activeRevisionId,
                  chapter.revisions.max(by: { $0.revisionIndex < $1.revisionIndex })?.id == activeID,
                  Set(chapter.revisions.map(\.id)).count == chapter.revisions.count,
                  Set(chapter.revisions.map(\.revisionIndex)).count == chapter.revisions.count,
                  chapter.revisions.allSatisfy({ $0.chapterId == chapter.id }),
                  chapter.revisions.min(by: { $0.revisionIndex < $1.revisionIndex })?.id == requirement.outlineRevisionID else {
                throw SourceGroundingError.invalid("A protected chapter must retain an explicit readable revision.")
            }
            for revision in chapter.revisions {
                if revision.id == requirement.outlineRevisionID {
                    guard try contentHash(revision.blocks) == requirement.outlineContentHash else {
                        throw SourceGroundingError.invalid("The original outline was changed.")
                    }
                } else {
                    guard revision.blocks.first?.text == chapter.title else {
                        throw SourceGroundingError.invalid("The reviewed chapter title changed.")
                    }
                    try validateTransition(receipt: revision.sourceReview, origin: revision.origin, blocks: revision.blocks,
                        bookID: next.id, chapter: chapter,
                        history: chapter.revisions.filter { $0.revisionIndex < revision.revisionIndex })
                }
            }
        }
    }
}
