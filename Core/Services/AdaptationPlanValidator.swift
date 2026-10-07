import Foundation

enum AdaptationPlanValidator {
    /// Structural + legal-ID validation. Does not mutate the book.
    static func validate(
        _ plan: AdaptationPlan,
        book: Book,
        lockedChapterIds: Set<UUID>
    ) throws {
        if plan.bookId != book.id {
            throw AdaptationError.invalidPlan("plan bookId mismatch")
        }
        if plan.affectedChapterIds.isEmpty {
            throw AdaptationError.invalidPlan("no affected chapters")
        }
        if plan.chapterTargets.isEmpty {
            throw AdaptationError.invalidPlan("no chapter targets")
        }
        let legalIds = Set(book.chapters.map(\.id))
        for id in plan.affectedChapterIds {
            if !legalIds.contains(id) {
                throw AdaptationError.illegalChapterId(id)
            }
            if lockedChapterIds.contains(id) {
                throw AdaptationError.lockedChapter(id)
            }
        }
        for target in plan.chapterTargets {
            if !legalIds.contains(target.chapterId) {
                throw AdaptationError.illegalChapterId(target.chapterId)
            }
            if lockedChapterIds.contains(target.chapterId) {
                throw AdaptationError.lockedChapter(target.chapterId)
            }
            if target.targetWordCount < 20 {
                throw AdaptationError.invalidPlan("target word count too small for \(target.chapterTitle)")
            }
            if !plan.affectedChapterIds.contains(target.chapterId) {
                throw AdaptationError.invalidPlan("target not listed in affectedChapterIds")
            }
        }
        // Locked set on plan must include all actually locked chapters referenced.
        for locked in plan.lockedChapterIds where !lockedChapterIds.contains(locked) {
            // Plan may over-declare locks; that's OK. Under-declaring is checked via affected ∩ locked.
            _ = locked
        }
        for id in plan.affectedChapterIds where plan.lockedChapterIds.contains(id) {
            throw AdaptationError.invalidPlan("affected chapter also marked locked: \(id)")
        }
    }

    /// Word-count sanity: allow 50%…220% of target (generous for mock + live drafts).
    static func assertWordCountSanity(actual: Int, target: Int) throws {
        let lower = max(10, Int(Double(target) * 0.5))
        let upper = max(lower + 1, Int(Double(target) * 2.2))
        if actual < lower || actual > upper {
            throw AdaptationError.wordCountOutOfRange(expected: target, actual: actual)
        }
    }

    static func assertContinuity(text: String, mustRemain: [String]) throws {
        let hay = text.lowercased()
        let missing = mustRemain.filter { concept in
            let needle = concept.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !needle.isEmpty else { return false }
            return !hay.contains(needle.lowercased())
        }
        if !missing.isEmpty {
            throw AdaptationError.continuityMissing(missing)
        }
    }

    static func wordCount(of text: String) -> Int {
        text.split { $0.isWhitespace || $0.isNewline }.filter { !$0.isEmpty }.count
    }

    static func wordCount(of blocks: [ContentBlock]) -> Int {
        wordCount(of: blocks.map(\.text).joined(separator: " "))
    }
}
