import Foundation

/// Explicit, inspectable continuity merges — the only sanctioned mutator for
/// `ContinuityState`.
///
/// The single hard rule: an entry whose chapter is consumed is immutable. A
/// delta touching such a chapter is preserved-not-applied and reported back in
/// `ContinuityMergeResult.preservedConsumedChapterIds`, so the merge still
/// succeeds for every other chapter instead of failing the whole batch.
enum ContinuityMerge {
    static func merge(
        _ delta: ContinuityDelta,
        into state: ContinuityState,
        at date: Date = Date()
    ) throws -> ContinuityMergeResult {
        guard delta.bookId == state.bookId else {
            throw PEGateError.bookMismatch(expected: state.bookId, found: delta.bookId)
        }

        var timeline = state.timeline
        var appended: [UUID] = []
        var updated: [UUID] = []
        var preserved: [UUID] = []

        for incoming in delta.entries {
            guard let existingIndex = timeline.firstIndex(where: { $0.chapterId == incoming.chapterId }) else {
                var entry = incoming
                entry.digest = clipDigest(entry.digest)
                entry.recordedAt = date
                timeline.append(entry)
                appended.append(entry.chapterId)
                continue
            }

            if timeline[existingIndex].isConsumed {
                preserved.append(incoming.chapterId)
                continue
            }

            // Reuse the existing entry identity so annotations / diffs keep a stable key.
            var entry = incoming
            entry.id = timeline[existingIndex].id
            entry.isConsumed = false
            entry.digest = clipDigest(entry.digest)
            entry.recordedAt = date
            timeline[existingIndex] = entry
            updated.append(entry.chapterId)
        }

        timeline.sort { lhs, rhs in
            lhs.chapterOrderIndex == rhs.chapterOrderIndex
                ? lhs.recordedAt < rhs.recordedAt
                : lhs.chapterOrderIndex < rhs.chapterOrderIndex
        }

        let appliedChapterIds = Set(appended + updated)
        let openedByApplied = timeline
            .filter { appliedChapterIds.contains($0.chapterId) }
            .flatMap(\.openThreads)

        let merged = ContinuityState(
            bookId: state.bookId,
            timeline: timeline,
            carriedThreads: mergeThreads(
                existing: state.carriedThreads,
                adding: openedByApplied + delta.newThreads,
                resolving: delta.resolvedThreads
            ),
            updatedAt: date
        )

        return ContinuityMergeResult(
            state: merged,
            appendedChapterIds: appended,
            updatedChapterIds: updated,
            preservedConsumedChapterIds: preserved
        )
    }

    /// Pins a chapter's entry as immutable once the reader has consumed it.
    /// Creates the entry when the chapter was consumed before continuity existed.
    static func markConsumed(
        chapterId: UUID,
        in state: ContinuityState,
        creating fallback: ContinuityEntry? = nil,
        at date: Date = Date()
    ) -> ContinuityState {
        var next = state
        if let index = next.timeline.firstIndex(where: { $0.chapterId == chapterId }) {
            next.timeline[index].isConsumed = true
        } else if let fallback {
            var entry = fallback
            entry.isConsumed = true
            entry.digest = clipDigest(entry.digest)
            next.timeline.append(entry)
            next.timeline.sort { $0.chapterOrderIndex < $1.chapterOrderIndex }
        } else {
            return next
        }
        next.updatedAt = date
        return next
    }

    /// Order-stable union minus resolved threads. Resolving a thread only edits
    /// the carried set; a consumed entry's own `openThreads` stay as written.
    private static func mergeThreads(
        existing: [String],
        adding: [String],
        resolving: [String]
    ) -> [String] {
        let resolved = Set(resolving.map(normalized))
        var seen = Set<String>()
        var result: [String] = []
        for thread in existing + adding {
            let key = normalized(thread)
            guard !key.isEmpty, !resolved.contains(key), !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(thread.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if result.count > ContinuityState.maxCarriedThreads {
            result = Array(result.suffix(ContinuityState.maxCarriedThreads))
        }
        return result
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func clipDigest(_ digest: String) -> String {
        let trimmed = digest.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > ContinuityEntry.maxDigestCharacters else { return trimmed }
        return String(trimmed.prefix(ContinuityEntry.maxDigestCharacters)) + "…"
    }
}

/// Derives a continuity delta locally from activated prose, so continuity keeps
/// advancing even when the model returns nothing but blocks.
enum ContinuityDeltaBuilder {
    static func derive(
        bookId: UUID,
        chapter: Chapter,
        revision: ChapterRevision,
        plan: AdaptationPlan? = nil,
        at date: Date = Date()
    ) -> ContinuityDelta {
        let prose = revision.blocks
            .filter { $0.kind != .imagePlaceholder }
            .map(\.text)
            .joined(separator: " ")

        let target = plan?.chapterTargets.first { $0.chapterId == chapter.id }
        let facts = target?.mustRemainConcepts.isEmpty == false
            ? target!.mustRemainConcepts
            : DeterministicAdaptationSynthesizer.mustRemainConcepts(from: prose, title: chapter.title)

        let entry = ContinuityEntry(
            id: UUID(),
            chapterId: chapter.id,
            chapterTitle: chapter.title,
            chapterOrderIndex: chapter.orderIndex,
            revisionId: revision.id,
            digest: digest(from: prose),
            establishedFacts: facts,
            openThreads: [],
            isConsumed: false,
            recordedAt: date
        )
        return ContinuityDelta(bookId: bookId, entries: [entry])
    }

    /// Continuity entry for a chapter the reader just finished, pinned to the
    /// exact revision the consumed ledger recorded.
    static func consumedEntry(
        chapter: Chapter,
        revision: ChapterRevision,
        at date: Date = Date()
    ) -> ContinuityEntry {
        let prose = revision.blocks
            .filter { $0.kind != .imagePlaceholder }
            .map(\.text)
            .joined(separator: " ")
        return ContinuityEntry(
            id: UUID(),
            chapterId: chapter.id,
            chapterTitle: chapter.title,
            chapterOrderIndex: chapter.orderIndex,
            revisionId: revision.id,
            digest: digest(from: prose),
            establishedFacts: DeterministicAdaptationSynthesizer.mustRemainConcepts(
                from: prose,
                title: chapter.title
            ),
            openThreads: [],
            isConsumed: true,
            recordedAt: date
        )
    }

    private static func digest(from prose: String) -> String {
        let collapsed = prose
            .split { $0.isWhitespace || $0.isNewline }
            .joined(separator: " ")
        guard collapsed.count > ContinuityEntry.maxDigestCharacters else { return collapsed }
        return String(collapsed.prefix(ContinuityEntry.maxDigestCharacters)) + "…"
    }
}
