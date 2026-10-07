import Foundation

/// Two-stage Living Book adaptation loop.
/// Stage 1 PLAN: structured AdaptationPlan — validate — present (no book mutation).
/// Stage 2 GENERATE after Apply: next 1–2 unread chapters → stage → validate → activate.
/// Source continuation separately retains writer/review state. A cleanup failure
/// after publication is recovered by matching the exact already-published revision.
actor LivingBookAdaptationService {
    private let versioning: ManuscriptVersioningService
    private let feedbackStore: FeedbackStoring
    private let preferenceStore: ReaderPreferenceStoring
    private var ai: any AIService
    private let packetsOverride: PEPacketStoring?
    private var resolvedPackets: PEPacketStoring?

    private var state: AdaptationPhaseState = .idle
    private var currentPlan: AdaptationPlan?
    private var lastError: String?
    private var inFlightTask: Task<Void, Never>?
    private var cancelRequested = false

    init(
        versioning: ManuscriptVersioningService,
        feedbackStore: FeedbackStoring,
        preferenceStore: ReaderPreferenceStoring,
        ai: any AIService,
        packets: PEPacketStoring? = nil
    ) {
        self.versioning = versioning
        self.feedbackStore = feedbackStore
        self.preferenceStore = preferenceStore
        self.ai = ai
        self.packetsOverride = packets
    }

    /// Defaults to the same packet store the versioning service gates against,
    /// resolved lazily because that store lives behind the versioning actor.
    private func packets() async -> PEPacketStoring {
        if let resolvedPackets { return resolvedPackets }
        let store: PEPacketStoring
        if let packetsOverride {
            store = packetsOverride
        } else {
            store = await versioning.packetStore
        }
        resolvedPackets = store
        return store
    }

    /// Swap AI backend without dropping an in-progress plan (key save / model change).
    func updateAI(_ service: any AIService) {
        ai = service
    }

    func currentState() -> AdaptationPhaseState { state }
    func readyPlan() -> AdaptationPlan? { currentPlan }
    func errorMessage() -> String? { lastError }

    // MARK: - Source-reviewed word continuation

    func sourceContinuation(bookID: UUID) async throws -> SourceContinuationState? {
        let store = await packets()
        return try store.loadFactChecklist(bookId: bookID).sourceContinuation
    }

    /// Local preparation only. Existing attempts are immutable until explicitly
    /// archived; repeated selection of the same word/request recovers that attempt.
    func prepareSourceContinuation(request: WordForwardRegenerationRequest) async throws -> SourceContinuationState {
        let anchor = request.anchor
        guard anchor.effectiveBoundary == .afterWord, request.maxFollowOnChapters == 0,
              request.intents.allSatisfy({ $0 == .moreExplanation || $0 == .lessDetail }),
              request.freeText.count <= 1_000, request.readerPreferencesSummary.count <= 2_000 else {
            throw SourceGroundingError.invalid("This preview supports text-only changes after a prose word, no later chapters, and up to 1,000 instruction characters.")
        }
        guard let book = try await versioning.loadBook(id: anchor.bookId),
              let chapter = book.chapters.first(where: { $0.id == anchor.chapterId }),
              let source = chapter.sourceGrounding?.source, let base = chapter.activeRevision,
              base.id == anchor.revisionId, base.sourceReview != nil else {
            throw SourceGroundingError.invalid("Select a word in the current source-reviewed preview.")
        }
        guard let cut = try SourceGrounding.wordCut(base: base, blockID: anchor.blockId,
                utf16Offset: anchor.utf16OffsetInBlock, source: source) else {
            throw SourceGroundingError.invalid("There is no prose after this word. Source notes are not rewritten.")
        }
        let instructions = request.intents.map { $0 == .moreExplanation
            ? "Explain the supported details more plainly without inventing causes."
            : "Use less detail while preserving the source's qualifications." }.joined(separator: "\n")
            + "\n" + request.freeText.trimmingCharacters(in: .whitespacesAndNewlines)
            + "\nReader preferences: " + request.readerPreferencesSummary
        var canonicalAnchor = anchor
        canonicalAnchor.word = cut.word
        canonicalAnchor.utf16OffsetInBlock = cut.wordStartUTF16
        let sections = try sourceContinuationSections(base: base, cut: cut, source: source)
        var proposed = SourceContinuationState(id: UUID(), bookID: book.id, chapterID: chapter.id,
            anchor: canonicalAnchor, cut: cut, source: source, requestHash: "",
            requestSummary: request.summaryLine, instructions: instructions,
            frozenPrefixWordCount: AdaptationPlanValidator.wordCount(of: sections.frozen.joined(separator: " ")),
            replacingWordCount: AdaptationPlanValidator.wordCount(of: sections.suffix.joined(separator: " ")))
        proposed.requestHash = try sourceContinuationIdentity(proposed)
        _ = try await sourceContinuationBase(proposed)
        let store = await packets()
        if let pending = try store.loadFactChecklist(bookId: book.id).sourceContinuation {
            guard pending.requestHash == proposed.requestHash else {
                throw SourceGroundingError.invalid("A different rewrite is saved. Reopen it or choose Start new to archive it first.")
            }
            return pending
        }
        try store.transitionSourceContinuation(bookId: book.id, expected: nil, next: proposed)
        return proposed
    }

    /// Explicit user action. Retains the complete attempt/candidate in the packet archive.
    func archiveSourceContinuation(bookID: UUID, attemptID: UUID) async throws {
        try SourceContinuationOperations.acquire(attemptID)
        defer { SourceContinuationOperations.release(attemptID) }
        let store = await packets()
        guard let saved = try store.loadFactChecklist(bookId: bookID).sourceContinuation,
              saved.id == attemptID else { throw SourceGroundingError.invalid("The saved rewrite changed.") }
        try store.transitionSourceContinuation(bookId: bookID, expected: saved, next: nil)
    }

    /// Each invocation is explicitly requested by the reader. Phase decides what
    /// can run: an existing candidate never returns to the writer.
    func runSourceContinuation(bookID: UUID, attemptID: UUID) async throws -> ChapterRevision {
        try SourceContinuationOperations.acquire(attemptID)
        defer { SourceContinuationOperations.release(attemptID) }
        let store = await packets()
        guard var saved = try store.loadFactChecklist(bookId: bookID).sourceContinuation,
              saved.id == attemptID, saved.bookID == bookID,
              saved.requestHash == (try sourceContinuationIdentity(saved)) else {
            throw SourceGroundingError.invalid("The saved rewrite identity is missing or changed. No request was sent.")
        }
        if saved.candidate != nil { try validateSourceDraftFingerprint(saved) }
        if let published = try await recoveredSourcePublication(saved) {
            try assertSourceAttempt(saved, store: store)
            var complete = saved
            complete.phase = .published
            complete.errorMessage = nil
            try store.transitionSourceContinuation(bookId: bookID, expected: saved, next: complete)
            return published
        }
        guard saved.phase != .published else {
            throw SourceGroundingError.invalid("This rewrite was already published. Its active version has since changed; choose Start new.")
        }
        if saved.phase == .writing || saved.phase == .uncertain {
            var uncertain = saved
            uncertain.phase = .uncertain
            uncertain.errorMessage = "Writing was interrupted before a complete draft was saved. It will not be sent again automatically. Choose Start new to archive this attempt."
            try store.transitionSourceContinuation(bookId: bookID, expected: saved, next: uncertain)
            throw SourceGroundingError.invalid(uncertain.errorMessage!)
        }
        // No live owner exists (we acquired it). Review can safely retry the same
        // saved draft; publication can retry the same already-reviewed candidate.
        if saved.phase == .reviewing || saved.phase == .publishing {
            var recover = saved
            recover.phase = saved.phase == .reviewing ? .needsReview : .readyToPublish
            try store.transitionSourceContinuation(bookId: bookID, expected: saved, next: recover)
            saved = recover
        }
        var base = try await sourceContinuationBase(saved)
        try assertSourceAttempt(saved, store: store)
        try Task.checkCancellation()

        if saved.phase == .prepared {
            guard saved.candidate == nil, let writer = ai as? any SourceGroundedAI,
                  writer.supportsSourceContinuation,
                  writer.sourceReviewModelID == OpenAIModelOption.defaultGeneration.rawValue else {
                throw SourceGroundingError.invalid("Choose an Astra connection that supports source continuation.")
            }
            let sections = try sourceContinuationSections(base: base, cut: saved.cut, source: saved.source)
            var writing = saved
            writing.phase = .writing
            writing.errorMessage = nil
            try store.transitionSourceContinuation(bookId: bookID, expected: saved, next: writing)
            saved = writing
            do {
                let paragraphs = try await writer.writeSourceContinuation(SourceContinuationWritingRequest(
                    title: saved.anchor.chapterTitle, instructions: saved.instructions,
                    frozenParagraphs: sections.frozen, oldSuffix: sections.suffix, source: saved.source,
                    joinsSelectedParagraph: sections.joins,
                    minimumTailParagraphs: sections.minimum, maximumTailParagraphs: sections.maximum))
                try Task.checkCancellation()
                base = try await sourceContinuationBase(saved)
                try assertSourceAttempt(saved, store: store)
                guard (sections.minimum...sections.maximum).contains(paragraphs.count) else {
                    throw SourceGroundingError.invalid("The writer did not return the requested paragraph count. No prose was published.")
                }
                let blocks = try SourceGrounding.assembleContinuation(base: base, cut: saved.cut,
                    paragraphs: paragraphs, source: saved.source)
                var origin = RevisionOrigin.regeneratedFromWord(word: saved.cut.word,
                    request: saved.requestSummary, frozenPrefixWordCount: saved.frozenPrefixWordCount)
                origin.sourceWordCut = saved.cut
                var drafted = saved
                drafted.candidate = CandidateRevision(id: saved.id, bookId: bookID, chapterId: saved.chapterID,
                    proposedRevisionIndex: base.revisionIndex + 1, createdAt: Date(), blocks: blocks,
                    status: .staged, rejectionReason: nil, origin: origin)
                drafted.candidateFingerprint = try sourceDraftFingerprint(drafted.candidate!)
                drafted.phase = .needsReview
                // This durable save MUST precede every reviewer call.
                try store.transitionSourceContinuation(bookId: bookID, expected: saved, next: drafted)
                saved = drafted
            } catch {
                var uncertain = saved
                uncertain.phase = .uncertain
                uncertain.errorMessage = "No complete draft was confirmed saved. Writing will not automatically retry. " + error.localizedDescription
                try? store.transitionSourceContinuation(bookId: bookID, expected: saved, next: uncertain)
                throw error
            }
        }

        if saved.phase == .needsReview {
            guard let reviewer = ai as? any SourceGroundedAI,
                  reviewer.supportsSourceContinuation,
                  reviewer.sourceReviewModelID == OpenAIModelOption.defaultGeneration.rawValue else {
                throw SourceGroundingError.invalid("The saved draft needs a separate Astra source review.")
            }
            base = try await sourceContinuationBase(saved)
            try validateSourceCandidate(saved, base: base)
            try assertSourceAttempt(saved, store: store)
            var reviewing = saved
            reviewing.phase = .reviewing
            reviewing.errorMessage = nil
            try store.transitionSourceContinuation(bookId: bookID, expected: saved, next: reviewing)
            saved = reviewing
            do {
                try Task.checkCancellation()
                let response = try await reviewer.reviewSourcePreview(SourceReviewRequest(
                    paragraphs: try SourceGrounding.prose(saved.candidate!.blocks, source: saved.source), source: saved.source))
                try Task.checkCancellation()
                base = try await sourceContinuationBase(saved)
                try assertSourceAttempt(saved, store: store)
                try validateSourceCandidate(saved, base: base)
                var reviewed = saved
                reviewed.candidate!.sourceReview = try SourceGrounding.receipt(bookID: bookID,
                    chapterID: saved.chapterID, baseRevisionID: base.id, blocks: saved.candidate!.blocks,
                    source: saved.source, model: reviewer.sourceReviewModelID, response: response, wordCut: saved.cut)
                reviewed.phase = .readyToPublish
                try store.transitionSourceContinuation(bookId: bookID, expected: saved, next: reviewed)
                saved = reviewed
            } catch {
                var retry = saved
                retry.phase = .needsReview
                retry.errorMessage = "Draft saved; retry reviews this exact text without writing again. " + error.localizedDescription
                try? store.transitionSourceContinuation(bookId: bookID, expected: saved, next: retry)
                throw error
            }
        }

        guard saved.phase == .readyToPublish else {
            throw SourceGroundingError.invalid("This saved rewrite cannot be published from its current state.")
        }
        base = try await sourceContinuationBase(saved)
        try validateSourceCandidate(saved, base: base)
        guard saved.candidate?.sourceReview != nil else {
            throw SourceGroundingError.invalid("The saved draft has no valid review. No publication occurred.")
        }
        try assertSourceAttempt(saved, store: store)
        var publishing = saved
        publishing.phase = .publishing
        publishing.errorMessage = nil
        try store.transitionSourceContinuation(bookId: bookID, expected: saved, next: publishing)
        saved = publishing
        do {
            try Task.checkCancellation()
            try await versioning.stageCandidate(saved.candidate!)
            _ = try await sourceContinuationBase(saved)
            try assertSourceAttempt(saved, store: store)
            try Task.checkCancellation()
            let revision = try await versioning.activateCandidate(id: saved.id, expectedRevisionId: saved.cut.baseRevisionID)
            try assertSourceAttempt(saved, store: store)
            var complete = saved
            complete.phase = .published
            complete.errorMessage = nil
            try store.transitionSourceContinuation(bookId: bookID, expected: saved, next: complete)
            return revision
        } catch {
            var retry = saved
            retry.phase = .readyToPublish
            retry.errorMessage = "The reviewed draft is saved. Retry checks publication without writing or reviewing again. " + error.localizedDescription
            try? store.transitionSourceContinuation(bookId: bookID, expected: saved, next: retry)
            throw error
        }
    }

    private func sourceContinuationIdentity(_ saved: SourceContinuationState) throws -> String {
        struct Identity: Encodable {
            let book: UUID; let chapter: UUID; let cut: SourceWordCut
            let source: RetrievedResearchSource; let instructions: String; let summary: String
            let anchor: RegenerationWordAnchor; let frozen: Int; let replacing: Int
        }
        var anchor = saved.anchor
        anchor.createdAt = Date(timeIntervalSince1970: 0)
        return try SourceGrounding.hash(Identity(book: saved.bookID, chapter: saved.chapterID,
            cut: saved.cut, source: saved.source, instructions: saved.instructions, summary: saved.requestSummary,
            anchor: anchor, frozen: saved.frozenPrefixWordCount, replacing: saved.replacingWordCount))
    }

    private func assertSourceAttempt(_ expected: SourceContinuationState, store: PEPacketStoring) throws {
        let current = try store.loadFactChecklist(bookId: expected.bookID).sourceContinuation
        guard try SourceGrounding.hash(current) == SourceGrounding.hash(Optional(expected)) else {
            throw SourceGroundingError.invalid("Another operation changed this saved rewrite; its result was not applied.")
        }
    }

    private func sourceContinuationBase(_ saved: SourceContinuationState) async throws -> ChapterRevision {
        guard !(try await versioning.isChapterConsumed(bookId: saved.bookID, chapterId: saved.chapterID)) else {
            throw ManuscriptError.cannotMutateConsumedChapter(saved.chapterID)
        }
        guard let book = try await versioning.loadBook(id: saved.bookID),
              let chapter = book.chapters.first(where: { $0.id == saved.chapterID }),
              let requirement = chapter.sourceGrounding, let base = chapter.activeRevision,
              base.id == saved.cut.baseRevisionID, base.id == saved.anchor.revisionId,
              saved.anchor.bookId == saved.bookID, saved.anchor.chapterId == saved.chapterID,
              saved.anchor.chapterTitle == chapter.title, saved.anchor.effectiveBoundary == .afterWord,
              saved.anchor.blockId == saved.cut.blockID, saved.anchor.utf16OffsetInBlock == saved.cut.wordStartUTF16,
              saved.anchor.word.utf8.elementsEqual(saved.cut.word.utf8),
              !chapter.revisions.contains(where: { $0.isConsumed }),
              try SourceGrounding.hash(requirement.source) == SourceGrounding.hash(saved.source) else {
            throw SourceGroundingError.invalid("The source, active version or read boundary changed. The saved draft was not applied.")
        }
        try SourceGrounding.validate(receipt: base.sourceReview, bookID: book.id, chapterID: chapter.id,
            blocks: base.blocks, requirement: requirement)
        guard let cut = try SourceGrounding.wordCut(base: base, blockID: saved.cut.blockID,
            utf16Offset: saved.cut.wordStartUTF16, source: saved.source),
              try SourceGrounding.hash(cut) == SourceGrounding.hash(saved.cut) else {
            throw SourceGroundingError.invalid("The selected word no longer identifies remaining prose.")
        }
        return base
    }

    private func sourceContinuationSections(base: ChapterRevision, cut: SourceWordCut,
                                            source: RetrievedResearchSource) throws -> (frozen: [String], suffix: [String], joins: Bool, minimum: Int, maximum: Int) {
        _ = try SourceGrounding.prose(base.blocks, source: source)
        guard let index = base.blocks.firstIndex(where: { $0.id == cut.blockID }) else {
            throw SourceGroundingError.invalid("The selected paragraph is missing.")
        }
        let prose = String(base.blocks[index].text.dropLast(4)) as NSString
        var frozen = base.blocks[1..<index].map { String($0.text.dropLast(4)) }
        frozen.append(prose.substring(to: cut.endUTF16))
        var suffix: [String] = []
        if cut.endUTF16 < prose.length { suffix.append(prose.substring(from: cut.endUTF16)) }
        suffix += base.blocks[(index + 1)..<(base.blocks.count - 2)].map { String($0.text.dropLast(4)) }
        let joins = cut.endUTF16 < prose.length
        let retained = index - (joins ? 1 : 0)
        return (frozen, suffix, joins, max(1, 2 - retained), min(6, 12 - retained))
    }

    private func validateSourceCandidate(_ saved: SourceContinuationState, base: ChapterRevision) throws {
        try validateSourceDraftFingerprint(saved)
        guard let candidate = saved.candidate, candidate.id == saved.id,
              candidate.bookId == saved.bookID, candidate.chapterId == saved.chapterID,
              try SourceGrounding.hash(candidate.origin?.sourceWordCut) == SourceGrounding.hash(Optional(saved.cut)) else {
            throw SourceGroundingError.invalid("The saved draft is missing or belongs to a different rewrite; it will not be regenerated automatically.")
        }
        try SourceGrounding.validateWordCut(saved.cut, base: base, blocks: candidate.blocks, source: saved.source)
    }

    private func sourceDraftFingerprint(_ candidate: CandidateRevision) throws -> String {
        // Receipt/status change during review/publication; writer output never does.
        struct Draft: Encodable {
            let id: UUID; let book: UUID; let chapter: UUID; let index: Int
            let date: Date; let blocks: [ContentBlock]; let origin: RevisionOrigin?
        }
        return try SourceGrounding.hash(Draft(id: candidate.id, book: candidate.bookId,
            chapter: candidate.chapterId, index: candidate.proposedRevisionIndex, date: candidate.createdAt,
            blocks: candidate.blocks, origin: candidate.origin))
    }

    private func validateSourceDraftFingerprint(_ saved: SourceContinuationState) throws {
        guard let candidate = saved.candidate, let fingerprint = saved.candidateFingerprint,
              fingerprint == (try sourceDraftFingerprint(candidate)) else {
            throw SourceGroundingError.invalid("The saved writer draft is missing or changed. It will not be reviewed or regenerated automatically.")
        }
    }

    /// Publication generates a new revision UUID. Recover by exact block IDs,
    /// bytes, origin, receipt and the preceding base, never by content hash alone.
    private func recoveredSourcePublication(_ saved: SourceContinuationState) async throws -> ChapterRevision? {
        guard let candidate = saved.candidate, let receipt = candidate.sourceReview,
              let book = try await versioning.loadBook(id: saved.bookID),
              let chapter = book.chapters.first(where: { $0.id == saved.chapterID }) else { return nil }
        let history = chapter.revisions.sorted { $0.revisionIndex < $1.revisionIndex }
        for index in history.indices where index > 0 {
            let revision = history[index]
            if history[index - 1].id == saved.cut.baseRevisionID,
               try SourceGrounding.hash(revision.blocks) == SourceGrounding.hash(candidate.blocks),
               try SourceGrounding.hash(revision.origin) == SourceGrounding.hash(candidate.origin),
               try SourceGrounding.hash(revision.sourceReview) == SourceGrounding.hash(Optional(receipt)) {
                guard chapter.activeRevisionId == revision.id else {
                    throw SourceGroundingError.invalid("This saved rewrite was already published, but a newer version is active. Choose Start new; no text was replaced.")
                }
                return revision
            }
        }
        return nil
    }

    /// Finish Chapter: transactionally consume the exact revision just read, persist feedback later via UI.
    func finishChapter(
        bookId: UUID,
        chapterId: UUID,
        revisionId: UUID
    ) async throws {
        try await versioning.consume(bookId: bookId, chapterId: chapterId, revisionId: revisionId)

        // Pin this chapter's continuity entry as immutable, matching the ledger.
        // Continuity bookkeeping is never on the critical reading path, so a
        // failure here must not undo a consume that already succeeded.
        if let book = try? await versioning.loadBook(id: bookId),
           let chapter = book.chapters.first(where: { $0.id == chapterId }),
           let revision = chapter.revision(id: revisionId) {
            let store = await packets()
            _ = try? store.recordConsumedContinuity(
                bookId: bookId,
                chapter: chapter,
                revision: revision
            )
        }

        state = .awaitingFeedback
        lastError = nil
        cancelRequested = false
    }

    /// Persist feedback + update preferences through the inspectable engine, then Stage 1 PLAN.
    @discardableResult
    func submitFeedbackAndPlan(
        book: Book,
        feedback: ChapterFeedback,
        length: AdaptationLengthPreset = .full
    ) async throws -> AdaptationPlan {
        cancelRequested = false
        state = .planning
        lastError = nil
        currentPlan = nil

        try feedbackStore.save(feedback)
        let profile = try preferenceStore.applyFeedback(feedback)

        // The brief is a projection of the profile the engine just updated —
        // re-derive it here so Astra never reads stale taste.
        let store = await packets()
        _ = try? store.refreshBrief(book: book, profile: profile)
        let packet = (try? store.loadPacket(bookId: book.id)) ?? .empty(bookId: book.id)

        if let latest = try await versioning.loadBook(id: book.id),
           latest.chapters.contains(where: { $0.sourceGrounding != nil }) {
            state = .failed
            lastError = "Feedback saved. Further adaptation of this source preview is not available yet; no planning request was sent."
            throw SourceGroundingError.invalid(lastError!)
        }

        if cancelRequested {
            state = .cancelled
            throw AdaptationError.cancelled
        }

        let locked = try await lockedChapterIds(bookId: book.id)
        let ordered = book.chapters.sorted { $0.orderIndex < $1.orderIndex }
        var unread: [UnreadChapterSnapshot] = []
        for chapter in ordered {
            if locked.contains(chapter.id) { continue }
            let revision = try await versioning.readableRevision(bookId: book.id, chapterId: chapter.id)
            let plain = revision.blocks.map(\.text).joined(separator: "\n")
            unread.append(
                UnreadChapterSnapshot(
                    id: chapter.id,
                    title: chapter.title,
                    orderIndex: chapter.orderIndex,
                    currentWordCount: AdaptationPlanValidator.wordCount(of: plain),
                    plainText: plain
                )
            )
        }
        if unread.isEmpty {
            state = .failed
            lastError = AdaptationError.nothingToAdapt.errorDescription
            throw AdaptationError.nothingToAdapt
        }

        let request = AdaptationPlanRequest(
            book: book,
            feedback: feedback,
            profile: profile,
            lockedChapterIds: Array(locked),
            unreadChapters: unread,
            maxChaptersToAdapt: 2,
            packet: packet,
            lengthPreset: length
        )
        let plan: AdaptationPlan
        do {
            try Task.checkCancellation()
            if cancelRequested {
                state = .cancelled
                throw AdaptationError.cancelled
            }
            plan = try await ai.makeAdaptationPlan(request)
            if cancelRequested || Task.isCancelled {
                state = .cancelled
                throw AdaptationError.cancelled
            }
        } catch is CancellationError {
            state = .cancelled
            throw AdaptationError.cancelled
        }
        try AdaptationPlanValidator.validate(plan, book: book, lockedChapterIds: locked)

        if cancelRequested {
            state = .cancelled
            throw AdaptationError.cancelled
        }

        var validated = plan
        validated.isValidated = true
        validated.factGateNotes = PEContinuityGate.readinessNotes(
            checklist: packet.facts,
            chapterIds: plan.affectedChapterIds
        )
        validated.lengthPreset = length
        currentPlan = validated
        state = .planReady
        return validated
    }

    /// Stage 2: Apply plan — generate candidates for planned chapters (prefer next 1–2), activate atomically.
    @discardableResult
    func applyPlan(book: Book, plan: AdaptationPlan) async throws -> [ChapterRevision] {
        if let latest = try await versioning.loadBook(id: book.id),
           latest.chapters.contains(where: { chapter in
               chapter.sourceGrounding != nil && plan.chapterTargets.contains(where: { $0.chapterId == chapter.id })
           }) {
            throw SourceGroundingError.invalid("Further adaptation of this preview needs a new source review and is not available yet. Its saved text is unchanged; no generation request was sent.")
        }
        cancelRequested = false
        state = .applying
        lastError = nil

        let locked = try await lockedChapterIds(bookId: book.id)
        try AdaptationPlanValidator.validate(plan, book: book, lockedChapterIds: locked)
        // Half-length Apply intentionally shortens remaining time; Full keeps the band.
        if plan.resolvedLengthPreset == .full, plan.readingTimeBaselineMinutes != nil {
            try await assertReadingTimeGuardrail(
                book: book,
                plan: plan,
                preferences: plan.readingTimePreferences ?? .default
            )
        }

        let profile = try preferenceStore.load(bookId: book.id)
        let store = await packets()
        let packet = (try? store.loadPacket(bookId: book.id)) ?? .empty(bookId: book.id)
        var activated: [ChapterRevision] = []

        // Prefer next 1–2 only (already constrained in plan; re-slice for safety).
        let targets = Array(plan.chapterTargets.prefix(2))
        for target in targets {
            if cancelRequested {
                state = .cancelled
                throw AdaptationError.cancelled
            }
            if locked.contains(target.chapterId) {
                throw AdaptationError.lockedChapter(target.chapterId)
            }

            let current = try await versioning.readableRevision(bookId: book.id, chapterId: target.chapterId)
            let currentPlain = current.blocks.map(\.text).joined(separator: "\n")
            let genRequest = AdaptationGenerateRequest(
                book: book,
                plan: plan,
                chapterId: target.chapterId,
                chapterTitle: target.chapterTitle,
                currentPlainText: currentPlain,
                target: target,
                profile: profile,
                continuityNotes: plan.continuityNotes,
                packet: packet
            )

            let generated: GeneratedChapter
            do {
                try Task.checkCancellation()
                if cancelRequested {
                    state = .cancelled
                    throw AdaptationError.cancelled
                }
                generated = try await ai.generateAdaptedChapterWithPacket(genRequest)
                // Mid-generation terminate: honor cancel after await returns without staging.
                if cancelRequested || Task.isCancelled {
                    state = .cancelled
                    throw AdaptationError.cancelled
                }
            } catch let error as AdaptationError {
                if case .cancelled = error {
                    state = .cancelled
                    lastError = error.errorDescription
                    throw error
                }
                state = .failed
                lastError = error.localizedDescription
                throw error
            } catch is CancellationError {
                state = .cancelled
                lastError = AdaptationError.cancelled.errorDescription
                throw AdaptationError.cancelled
            } catch {
                state = .failed
                lastError = error.localizedDescription
                // Book untouched — generation never staged.
                throw AdaptationError.malformedGeneration(error.localizedDescription)
            }

            let generatedBlocks = generated.blocks
            let blocks = plan.readingTimeBaselineMinutes == nil
                ? generatedBlocks
                : Self.preservingVisualPlaceholders(from: current.blocks, in: generatedBlocks)

            do {
                try validateGeneratedBlocks(blocks, target: target, chapterId: target.chapterId, book: book, locked: locked)
                if plan.resolvedLengthPreset == .full, plan.readingTimeBaselineMinutes != nil {
                    try ReadingTimeGuardrail.assertPreservesRemainingTime(
                        baseline: ReadingTimeEstimator.estimate(
                            blocks: current.blocks,
                            preferences: plan.readingTimePreferences ?? .default
                        ),
                        planned: ReadingTimeEstimator.estimate(
                            blocks: blocks,
                            preferences: plan.readingTimePreferences ?? .default
                        ),
                        preferences: plan.readingTimePreferences ?? .default
                    )
                }
            } catch {
                state = .failed
                lastError = error.localizedDescription
                throw error
            }

            // PE fact gate: fold the generation's proposed claims / evidence into
            // the checklist and refuse to activate on missing evidence ids, stub
            // digests, or unverified essential claims. Nothing has been written
            // yet, so the prior revision simply stays readable.
            let priorChecklist: FactChecklist
            let mergedChecklist: FactChecklist
            do {
                priorChecklist = try store.loadFactChecklist(bookId: book.id)
                mergedChecklist = FactChecklistMerge.merge(
                    claims: generated.proposedClaims,
                    evidence: generated.proposedEvidence,
                    into: priorChecklist
                )
                try PEContinuityGate.assertActivationAllowed(
                    checklist: mergedChecklist,
                    bookId: book.id,
                    chapterId: target.chapterId
                )
                try store.saveFactChecklist(mergedChecklist)
            } catch {
                state = .failed
                lastError = error.localizedDescription
                throw error
            }

            let candidate = CandidateRevision(
                id: UUID(),
                bookId: book.id,
                chapterId: target.chapterId,
                proposedRevisionIndex: (current.revisionIndex + 1),
                createdAt: Date(),
                blocks: blocks,
                status: .staged,
                rejectionReason: nil,
                origin: plan.readingTimeBaselineMinutes == nil ? .adapted : .regeneratedFromChapter
            )

            do {
                try await versioning.stageCandidate(candidate)
                let revision = try await versioning.activateCandidate(id: candidate.id, expectedRevisionId: current.id)
                activated.append(revision)
                // Phase 6: outline stubs become polished once expanded prose is activated.
                try await versioning.markChapterPolished(
                    bookId: book.id, chapterId: target.chapterId, expectedRevisionId: revision.id
                )
                await mergeContinuity(
                    store: store,
                    book: book,
                    plan: plan,
                    chapterId: target.chapterId,
                    revision: revision,
                    proposed: generated.continuityDelta
                )
            } catch {
                // Roll the checklist back so a failed Apply leaves no trace.
                try? store.saveFactChecklist(priorChecklist)
                state = .failed
                lastError = error.localizedDescription
                // Versioning service restores prior manuscript on activation failure.
                throw error
            }
        }

        state = .applied
        currentPlan = plan
        try await promoteCanonImportToLivingIfNeeded(bookId: book.id)
        return activated
    }

    /// Metadata-only: Canon import becomes Living after a successful unread-future Apply.
    /// Chapter bodies are not rewritten here — only edition / subtitle / provenance.
    @discardableResult
    func promoteCanonImportToLivingIfNeeded(bookId: UUID, at date: Date = Date()) async throws -> Book? {
        guard var latest = try await versioning.loadBook(id: bookId) else { return nil }
        guard latest.canMakeLivingFromCanon else { return latest }
        latest = latest.promotedToLivingFromCanon(at: date)
        try await versioning.saveBook(latest)
        return latest
    }

    /// Soft-cancel mid-planning / mid-apply. Never mutates the readable book; staged work is abandoned.
    func cancel() {
        cancelRequested = true
        switch state {
        case .planning, .applying, .awaitingFeedback, .planReady:
            state = .cancelled
        default:
            break
        }
        inFlightTask?.cancel()
        inFlightTask = nil
    }

    func resetToIdle() {
        cancelRequested = false
        state = .idle
        currentPlan = nil
        lastError = nil
    }


    /// Wave 2: build a regenerate-from-here preview (cut → chapters + remaining time) without mutating the book.
    func previewRegeneration(
        book: Book,
        fromChapterId cutChapterId: UUID,
        preferences: ReadingTimePreferences = .default,
        maxChapters: Int = 2,
        length: AdaptationLengthPreset = .full
    ) async throws -> RegenerationPreview {
        cancelRequested = false
        let locked = try await lockedChapterIds(bookId: book.id)
        let ordered = book.chapters.sorted { $0.orderIndex < $1.orderIndex }
        guard let cutChapter = ordered.first(where: { $0.id == cutChapterId }) else {
            throw AdaptationError.illegalChapterId(cutChapterId)
        }
        guard !locked.contains(cutChapter.id) else {
            throw AdaptationError.lockedChapter(cutChapter.id)
        }
        let cut = RegenerationCut(
            chapterId: cutChapter.id,
            chapterTitle: cutChapter.title,
            chapterOrderIndex: cutChapter.orderIndex,
            blockId: nil
        )

        var unlockedFromCut: [Chapter] = []
        var lockedSkipped = 0
        for chapter in ordered where chapter.orderIndex >= cutChapter.orderIndex {
            if locked.contains(chapter.id) {
                lockedSkipped += 1
                continue
            }
            unlockedFromCut.append(chapter)
        }
        if unlockedFromCut.isEmpty {
            throw AdaptationError.nothingToAdapt
        }

        var chapterBlocks: [[ContentBlock]] = []
        for chapter in unlockedFromCut {
            let revision = try await versioning.readableRevision(bookId: book.id, chapterId: chapter.id)
            chapterBlocks.append(revision.blocks)
        }

        let baseline = ReadingTimeEstimator.estimateRemaining(
            chapterBlocks: chapterBlocks,
            preferences: preferences
        )

        let applySlice = Array(unlockedFromCut.prefix(max(1, maxChapters)))
        var regenerating: [RegenChapterSummary] = []
        var targets: [AdaptationChapterTarget] = []
        var plannedBlocks: [[ContentBlock]] = []
        for chapter in applySlice {
            let revision = try await versioning.readableRevision(bookId: book.id, chapterId: chapter.id)
            let visuals = revision.blocks.filter { $0.kind == .imagePlaceholder }.count
            let currentWordCount = AdaptationPlanValidator.wordCount(
                of: revision.blocks.filter { $0.kind != .imagePlaceholder }
            )
            regenerating.append(
                RegenChapterSummary(
                    id: chapter.id,
                    title: chapter.title,
                    orderIndex: chapter.orderIndex,
                    wordCount: currentWordCount
                )
            )
            let chapterBaseline = ReadingTimeEstimator.estimate(blocks: revision.blocks, preferences: preferences)
            let fullTargetWC = ReadingTimeEstimator.targetWordCount(
                preservingMinutes: chapterBaseline,
                plannedVisualCount: visuals,
                preferences: preferences
            )
            let targetWC = length.scaledWordCount(fullTargetWC)
            let plain = revision.blocks.map(\.text).joined(separator: "\n")
            let concepts = DeterministicAdaptationSynthesizer.mustRemainConcepts(from: plain, title: chapter.title)
            var desired = ["Regenerate from cut at \(cutChapter.title)"]
            if length == .half {
                desired.append("Aim for half-length; Full remains opt-in")
            } else {
                desired.append("Preserve expected remaining reading time")
            }
            targets.append(
                AdaptationChapterTarget(
                    chapterId: chapter.id,
                    chapterTitle: chapter.title,
                    currentWordCount: currentWordCount,
                    targetWordCount: targetWC,
                    desiredChanges: desired,
                    mustRemainConcepts: concepts
                )
            )
            plannedBlocks.append(
                [ContentBlock(id: UUID(), kind: .paragraph, text: String(repeating: "word ", count: targetWC), orderIndex: 0)]
                + Array(repeating: ContentBlock(id: UUID(), kind: .imagePlaceholder, text: "visual", orderIndex: 1), count: visuals)
            )
        }

        let plannedApply = ReadingTimeEstimator.estimateRemaining(
            chapterBlocks: plannedBlocks,
            preferences: preferences
        )
        let applyBaseline = ReadingTimeEstimator.estimateRemaining(
            chapterBlocks: Array(chapterBlocks.prefix(applySlice.count)),
            preferences: preferences
        )
        if length == .full {
            try ReadingTimeGuardrail.assertPreservesRemainingTime(
                baseline: applyBaseline,
                planned: plannedApply,
                preferences: preferences
            )
        }
        // Compare like-for-like totals in the UI: changed chapters plus untouched remaining chapters.
        let projectedRemaining = ReadingTimeEstimator.estimateRemaining(
            chapterBlocks: plannedBlocks + Array(chapterBlocks.dropFirst(applySlice.count)),
            preferences: preferences
        )

        let plan = AdaptationPlan(
            id: UUID(),
            bookId: book.id,
            createdAt: Date(),
            sourceFeedbackId: UUID(),
            preferenceUpdatesSummary: [
                length == .half
                    ? "Regenerate-from-here (half-length default)"
                    : "Regenerate-from-here (time-preserving)"
            ],
            affectedChapterIds: targets.map(\.chapterId),
            chapterTargets: targets,
            continuityNotes: [
                "Cut boundary: \(cutChapter.title)",
                "Consumed chapters remain locked",
                length == .half
                    ? "Half-length Apply; Full remains available"
                    : "Preserve remaining reading time via WPM/words"
            ],
            reasonsFromFeedback: [
                "User requested regenerate from \(cutChapter.title) onward",
                "Apply slice \(applyBaseline.displayLabel); planned \(plannedApply.displayLabel)"
            ],
            lockedChapterIds: Array(locked),
            isValidated: false,
            readingTimeBaselineMinutes: length == .full
                ? applyBaseline.remainingMinutes
                : plannedApply.remainingMinutes,
            readingTimePreferences: preferences.normalized,
            lengthPreset: length
        )
        try AdaptationPlanValidator.validate(plan, book: book, lockedChapterIds: locked)
        var validated = plan
        validated.isValidated = true
        currentPlan = validated
        state = .planReady

        return RegenerationPreview(
            cut: cut,
            regeneratingChapters: regenerating,
            lockedSkippedCount: lockedSkipped,
            baselineRemaining: baseline,
            plannedRemaining: projectedRemaining,
            plan: validated
        )
    }

    /// Apply a regenerate-from-here preview via the existing Stage-2 pipeline.
    @discardableResult
    func applyRegeneration(book: Book, preview: RegenerationPreview) async throws -> [ChapterRevision] {
        currentPlan = preview.plan
        return try await applyPlan(book: book, plan: preview.plan)
    }

    // MARK: - Regenerate from a word (word-forward)

    /// Preview "change the book from this word onward" without mutating anything.
    ///
    /// The split is computed against the live readable revision, so the sheet can state
    /// exactly how many words stay frozen and how many are up for rewrite.
    func previewWordForwardRegeneration(
        book: Book,
        request: WordForwardRegenerationRequest,
        preferences: ReadingTimePreferences = .default
    ) async throws -> WordForwardRegenerationPreview {
        cancelRequested = false
        let prefs = preferences.normalized
        let anchor = request.anchor
        let locked = try await lockedChapterIds(bookId: book.id)
        let ordered = book.chapters.sorted { $0.orderIndex < $1.orderIndex }
        guard let anchorChapter = ordered.first(where: { $0.id == anchor.chapterId }) else {
            throw AdaptationError.illegalChapterId(anchor.chapterId)
        }
        guard !locked.contains(anchorChapter.id) else {
            throw AdaptationError.lockedChapter(anchorChapter.id)
        }

        let current = try await versioning.readableRevision(bookId: book.id, chapterId: anchorChapter.id)
        guard current.id == anchor.revisionId else {
            throw AdaptationError.anchorMoved
        }
        let split = try ChapterAnchorSplitter.split(
            blocks: current.blocks,
            blockId: anchor.blockId,
            utf16OffsetInBlock: anchor.utf16OffsetInBlock,
            boundary: anchor.effectiveBoundary
        )

        var unlockedAfter: [Chapter] = []
        var lockedSkipped = 0
        for chapter in ordered where chapter.orderIndex > anchorChapter.orderIndex {
            if locked.contains(chapter.id) {
                lockedSkipped += 1
                continue
            }
            unlockedAfter.append(chapter)
        }
        let followOn = Array(unlockedAfter.prefix(request.maxFollowOnChapters))
        let untouched = Array(unlockedAfter.dropFirst(followOn.count))

        var followOnBlocks: [[ContentBlock]] = []
        for chapter in followOn {
            followOnBlocks.append(
                try await versioning.readableRevision(bookId: book.id, chapterId: chapter.id).blocks
            )
        }
        var untouchedBlocks: [[ContentBlock]] = []
        for chapter in untouched {
            untouchedBlocks.append(
                try await versioning.readableRevision(bookId: book.id, chapterId: chapter.id).blocks
            )
        }

        let suffixBaseline = ReadingTimeEstimator.estimate(blocks: split.regenerableSuffix, preferences: prefs)
        let plannedVisualCount = Self.affordableVisualCount(
            currentVisuals: split.suffixVisualCount,
            extraRequested: request.extraVisuals,
            baseline: suffixBaseline,
            preferences: prefs
        )
        let suffixTarget = ReadingTimeEstimator.targetWordCount(
            preservingMinutes: suffixBaseline,
            plannedVisualCount: plannedVisualCount,
            preferences: prefs
        )

        var targets: [AdaptationChapterTarget] = []
        var plannedChangedBlocks: [[ContentBlock]] = []
        if split.hasRegenerableSuffix {
            let suffixPlain = split.regenerableSuffix.map(\.text).joined(separator: "\n")
            var changes = [
                anchor.effectiveBoundary == .chapterStart
                    ? "Rewrite this unread chapter from its beginning"
                    : "Rewrite only after “\(anchor.displayWord)”",
                "Leave all \(split.prefixWordCount) frozen words untouched"
            ]
            changes.append(contentsOf: request.promptLines)
            targets.append(
                AdaptationChapterTarget(
                    chapterId: anchorChapter.id,
                    chapterTitle: anchorChapter.title,
                    currentWordCount: split.prefixWordCount + split.suffixWordCount,
                    targetWordCount: split.prefixWordCount + suffixTarget,
                    desiredChanges: changes,
                    mustRemainConcepts: DeterministicAdaptationSynthesizer.mustRemainConcepts(
                        from: suffixPlain,
                        title: anchorChapter.title
                    )
                )
            )
            plannedChangedBlocks.append(
                Self.syntheticBlocks(wordCount: suffixTarget, visualCount: plannedVisualCount)
            )
        }

        for (index, chapter) in followOn.enumerated() {
            let blocks = followOnBlocks[index]
            let visuals = blocks.filter { $0.kind == .imagePlaceholder }.count
            let chapterBaseline = ReadingTimeEstimator.estimate(blocks: blocks, preferences: prefs)
            let chapterTarget = ReadingTimeEstimator.targetWordCount(
                preservingMinutes: chapterBaseline,
                plannedVisualCount: visuals,
                preferences: prefs
            )
            let plain = blocks.map(\.text).joined(separator: "\n")
            var changes = [anchor.effectiveBoundary == .chapterStart
                ? "Continue the arc of \(anchor.chapterTitle)"
                : "Continue the arc after “\(anchor.displayWord)”"]
            changes.append(contentsOf: request.promptLines)
            targets.append(
                AdaptationChapterTarget(
                    chapterId: chapter.id,
                    chapterTitle: chapter.title,
                    currentWordCount: AdaptationPlanValidator.wordCount(
                        of: blocks.filter { $0.kind != .imagePlaceholder }
                    ),
                    targetWordCount: chapterTarget,
                    desiredChanges: changes,
                    mustRemainConcepts: DeterministicAdaptationSynthesizer.mustRemainConcepts(
                        from: plain,
                        title: chapter.title
                    )
                )
            )
            plannedChangedBlocks.append(
                Self.syntheticBlocks(wordCount: chapterTarget, visualCount: visuals)
            )
        }

        if targets.isEmpty {
            throw AdaptationError.nothingToAdapt
        }

        var changedBaselineBlocks: [[ContentBlock]] = []
        if split.hasRegenerableSuffix {
            changedBaselineBlocks.append(split.regenerableSuffix)
        }
        changedBaselineBlocks.append(contentsOf: followOnBlocks)
        let changedBaseline = ReadingTimeEstimator.estimateRemaining(
            chapterBlocks: changedBaselineBlocks,
            preferences: prefs
        )
        let changedPlanned = ReadingTimeEstimator.estimateRemaining(
            chapterBlocks: plannedChangedBlocks,
            preferences: prefs
        )
        try ReadingTimeGuardrail.assertPreservesRemainingTime(
            baseline: changedBaseline,
            planned: changedPlanned,
            preferences: prefs
        )

        // Compare like-for-like in the sheet: changed stretch plus untouched remainder.
        let baselineRemaining = ReadingTimeEstimator.estimateRemaining(
            chapterBlocks: changedBaselineBlocks + untouchedBlocks,
            preferences: prefs
        )
        let plannedRemaining = ReadingTimeEstimator.estimateRemaining(
            chapterBlocks: plannedChangedBlocks + untouchedBlocks,
            preferences: prefs
        )

        let plan = AdaptationPlan(
            id: UUID(),
            bookId: book.id,
            createdAt: Date(),
            sourceFeedbackId: UUID(),
            preferenceUpdatesSummary: [anchor.effectiveBoundary == .chapterStart
                ? "From the start of \(anchorChapter.title): \(request.summaryLine)"
                : "After “\(anchor.displayWord)”: \(request.summaryLine)"],
            affectedChapterIds: targets.map(\.chapterId),
            chapterTargets: targets,
            continuityNotes: [
                anchor.effectiveBoundary == .chapterStart
                    ? "Rewrite the whole unread chapter; earlier chapters stay unchanged"
                    : "Frozen: everything through “\(anchor.displayWord)” in \(anchorChapter.title), including that word",
                "Consumed chapters remain locked",
                "Preserve remaining reading time via WPM/words"
            ],
            reasonsFromFeedback: [
                "Reader asked for the unread continuation: \(request.summaryLine)",
                "\(split.prefixWordCount) words stay frozen; \(split.suffixWordCount) words are eligible"
            ],
            lockedChapterIds: Array(locked),
            isValidated: false,
            readingTimeBaselineMinutes: changedBaseline.remainingMinutes,
            readingTimePreferences: prefs
        )
        try AdaptationPlanValidator.validate(plan, book: book, lockedChapterIds: locked)
        var validated = plan
        validated.isValidated = true
        currentPlan = validated
        state = .planReady

        return WordForwardRegenerationPreview(
            anchor: anchor,
            requestSummary: request.summaryLine,
            requestLines: request.promptLines,
            frozenPrefixWordCount: split.prefixWordCount,
            regeneratingWordCount: split.suffixWordCount,
            suffixTargetWordCount: suffixTarget,
            plannedVisualCount: plannedVisualCount,
            followOnChapters: followOn.enumerated().map { index, chapter in
                RegenChapterSummary(
                    id: chapter.id,
                    title: chapter.title,
                    orderIndex: chapter.orderIndex,
                    wordCount: AdaptationPlanValidator.wordCount(
                        of: followOnBlocks[index].filter { $0.kind != .imagePlaceholder }
                    )
                )
            },
            lockedSkippedCount: lockedSkipped,
            baselineRemaining: baselineRemaining,
            plannedRemaining: plannedRemaining,
            plan: validated,
            preferences: prefs,
            readerPreferencesSummary: request.readerPreferencesSummary
        )
    }

    /// Apply a word-forward preview: rewrite only after the selected word (or the whole
    /// unread chapter for an explicit chapter-start redirect),
    /// then hand any follow-on unread chapters to the existing Stage-2 pipeline.
    @discardableResult
    func applyWordForwardRegeneration(
        book: Book,
        preview: WordForwardRegenerationPreview
    ) async throws -> [ChapterRevision] {
        cancelRequested = false
        state = .applying
        lastError = nil

        let prefs = preview.preferences.normalized
        let locked = try await lockedChapterIds(bookId: book.id)
        try AdaptationPlanValidator.validate(preview.plan, book: book, lockedChapterIds: locked)

        var activated: [ChapterRevision] = []
        if preview.regeneratesAnchorChapter {
            activated.append(
                try await regenerateAnchorChapter(
                    book: book,
                    preview: preview,
                    preferences: prefs,
                    locked: locked
                )
            )
        }

        let followOnTargets = preview.plan.chapterTargets.filter { $0.chapterId != preview.anchor.chapterId }
        if !followOnTargets.isEmpty {
            var followOnPlan = preview.plan
            followOnPlan.chapterTargets = followOnTargets
            followOnPlan.affectedChapterIds = followOnTargets.map(\.chapterId)
            // The anchor chapter is already rewritten, so the remaining-time band for the
            // follow-on pass must be measured without it.
            var baselineBlocks: [[ContentBlock]] = []
            for target in followOnTargets {
                baselineBlocks.append(
                    try await versioning.readableRevision(bookId: book.id, chapterId: target.chapterId).blocks
                )
            }
            followOnPlan.readingTimeBaselineMinutes = ReadingTimeEstimator.estimateRemaining(
                chapterBlocks: baselineBlocks,
                preferences: prefs
            ).remainingMinutes
            activated.append(contentsOf: try await applyPlan(book: book, plan: followOnPlan))
        }

        state = .applied
        currentPlan = preview.plan
        try await promoteCanonImportToLivingIfNeeded(bookId: book.id)
        return activated
    }

    private func regenerateAnchorChapter(
        book: Book,
        preview: WordForwardRegenerationPreview,
        preferences: ReadingTimePreferences,
        locked: Set<UUID>
    ) async throws -> ChapterRevision {
        let anchor = preview.anchor
        if let latest = try await versioning.loadBook(id: book.id),
           latest.chapters.first(where: { $0.id == anchor.chapterId })?.sourceGrounding != nil {
            throw SourceGroundingError.invalid("Word-forward adaptation of this source preview is not available yet. Its saved text is unchanged; no generation request was sent.")
        }
        guard !locked.contains(anchor.chapterId) else {
            throw AdaptationError.lockedChapter(anchor.chapterId)
        }
        guard let planned = preview.plan.chapterTargets.first(where: { $0.chapterId == anchor.chapterId }) else {
            throw AdaptationError.illegalChapterId(anchor.chapterId)
        }

        let current = try await versioning.readableRevision(bookId: book.id, chapterId: anchor.chapterId)
        // Reading moved the chapter on (another regen, a restore) — refuse rather than
        // rewrite from a stale cut that could sit behind the reader's eyes.
        guard current.id == anchor.revisionId else {
            state = .failed
            lastError = AdaptationError.anchorMoved.errorDescription
            throw AdaptationError.anchorMoved
        }
        let split = try ChapterAnchorSplitter.split(
            blocks: current.blocks,
            blockId: anchor.blockId,
            utf16OffsetInBlock: anchor.utf16OffsetInBlock,
            boundary: anchor.effectiveBoundary
        )
        guard split.hasRegenerableSuffix else {
            throw AdaptationError.nothingToAdapt
        }

        let profile = try preferenceStore.load(bookId: book.id)
        let suffixTarget = AdaptationChapterTarget(
            chapterId: anchor.chapterId,
            chapterTitle: anchor.chapterTitle,
            currentWordCount: split.suffixWordCount,
            targetWordCount: preview.suffixTargetWordCount,
            desiredChanges: planned.desiredChanges,
            mustRemainConcepts: planned.mustRemainConcepts
        )
        let store = await packets()
        let packet = (try? store.loadPacket(bookId: book.id)) ?? .empty(bookId: book.id)
        let generateRequest = AdaptationGenerateRequest(
            book: book,
            plan: preview.plan,
            chapterId: anchor.chapterId,
            chapterTitle: anchor.chapterTitle,
            currentPlainText: split.regenerableSuffix.map(\.text).joined(separator: "\n"),
            target: suffixTarget,
            profile: profile,
            continuityNotes: preview.plan.continuityNotes,
            packet: packet,
            anchorContext: anchor.effectiveBoundary == .chapterStart ? nil : WordAnchorPromptContext(
                anchorWord: anchor.displayWord,
                frozenPrefixTail: ChapterAnchorSplitter.frozenPrefixTail(split.frozenPrefix),
                frozenPrefixWordCount: split.prefixWordCount,
                userRequest: preview.requestSummary,
                requestLines: preview.requestLines,
                readerPreferencesSummary: preview.readerPreferencesSummary,
                plannedVisualCount: preview.plannedVisualCount
            )
        )

        let generated: [ContentBlock]
        do {
            try Task.checkCancellation()
            if cancelRequested {
                state = .cancelled
                throw AdaptationError.cancelled
            }
            generated = try await ai.generateAdaptedChapter(generateRequest)
            if cancelRequested || Task.isCancelled {
                state = .cancelled
                throw AdaptationError.cancelled
            }
        } catch let error as AdaptationError {
            if case .cancelled = error {
                state = .cancelled
                lastError = error.errorDescription
                throw error
            }
            state = .failed
            lastError = error.localizedDescription
            throw error
        } catch is CancellationError {
            state = .cancelled
            lastError = AdaptationError.cancelled.errorDescription
            throw AdaptationError.cancelled
        } catch {
            state = .failed
            lastError = error.localizedDescription
            throw AdaptationError.malformedGeneration(error.localizedDescription)
        }

        let suffix = Self.shapingVisuals(
            generated: generated,
            sourceSuffix: split.regenerableSuffix,
            desiredVisualCount: preview.plannedVisualCount,
            captionSeed: anchor.chapterTitle
        )
        do {
            try validateGeneratedBlocks(
                suffix,
                target: suffixTarget,
                chapterId: anchor.chapterId,
                book: book,
                locked: locked
            )
            try ReadingTimeGuardrail.assertPreservesRemainingTime(
                baseline: ReadingTimeEstimator.estimate(blocks: split.regenerableSuffix, preferences: preferences),
                planned: ReadingTimeEstimator.estimate(blocks: suffix, preferences: preferences),
                preferences: preferences
            )
        } catch {
            state = .failed
            lastError = error.localizedDescription
            throw error
        }

        let assembled = ChapterAnchorSplitter.assemble(frozenPrefix: split.frozenPrefix, regenerated: suffix)
        do {
            try ChapterAnchorSplitter.assertPrefixPreserved(split.frozenPrefix, in: assembled)
        } catch {
            state = .failed
            lastError = AdaptationError.frozenPrefixMutated.errorDescription
            throw AdaptationError.frozenPrefixMutated
        }

        let candidate = CandidateRevision(
            id: UUID(),
            bookId: book.id,
            chapterId: anchor.chapterId,
            proposedRevisionIndex: current.revisionIndex + 1,
            createdAt: Date(),
            blocks: assembled,
            status: .staged,
            rejectionReason: nil,
            origin: anchor.effectiveBoundary == .chapterStart ? .regeneratedFromChapter : .regeneratedFromWord(
                word: anchor.displayWord,
                request: preview.requestSummary,
                frozenPrefixWordCount: split.prefixWordCount
            )
        )
        do {
            try await versioning.stageCandidate(candidate)
            return try await versioning.activateCandidate(id: candidate.id, expectedRevisionId: anchor.revisionId)
        } catch ManuscriptError.staleRevision {
            state = .failed
            lastError = AdaptationError.anchorMoved.errorDescription
            throw AdaptationError.anchorMoved
        } catch {
            state = .failed
            lastError = error.localizedDescription
            throw error
        }
    }

    // MARK: - Helpers

    private func lockedChapterIds(bookId: UUID) async throws -> Set<UUID> {
        let ledger = try await versioning.ledgerSnapshot()
        return Set(ledger.filter { $0.bookId == bookId }.map(\.chapterId))
    }

    /// Advances continuity for a chapter that just activated. Falls back to a
    /// locally derived delta so continuity keeps moving when the model returns
    /// prose only, and never throws: the revision is already readable, and a
    /// merge that refuses to rewrite a consumed entry is the correct outcome.
    private func mergeContinuity(
        store: PEPacketStoring,
        book: Book,
        plan: AdaptationPlan,
        chapterId: UUID,
        revision: ChapterRevision,
        proposed: ContinuityDelta?
    ) async {
        guard let chapter = (try? await versioning.loadBook(id: book.id))?
            .chapters.first(where: { $0.id == chapterId })
            ?? book.chapters.first(where: { $0.id == chapterId })
        else { return }

        var delta = proposed ?? ContinuityDeltaBuilder.derive(
            bookId: book.id,
            chapter: chapter,
            revision: revision,
            plan: plan
        )
        // Pin the entry to the revision activation actually produced.
        for index in delta.entries.indices where delta.entries[index].chapterId == chapterId {
            delta.entries[index].revisionId = revision.id
            delta.entries[index].chapterOrderIndex = chapter.orderIndex
            delta.entries[index].chapterTitle = chapter.title
        }
        _ = try? store.mergeContinuity(delta)
    }

    /// Placeholder body used to price a plan before any generation happens.
    private static func syntheticBlocks(wordCount: Int, visualCount: Int) -> [ContentBlock] {
        var blocks = [
            ContentBlock(
                id: UUID(),
                kind: .paragraph,
                text: String(repeating: "word ", count: max(1, wordCount)),
                orderIndex: 0
            )
        ]
        for index in 0..<max(0, visualCount) {
            blocks.append(
                ContentBlock(id: UUID(), kind: .imagePlaceholder, text: "visual", orderIndex: index + 1)
            )
        }
        return blocks
    }

    /// Visuals borrow minutes from prose, so "more images" can only add as many as the
    /// stretch can pay for without breaking the remaining-time promise.
    private static func affordableVisualCount(
        currentVisuals: Int,
        extraRequested: Int,
        baseline: ReadingTimeEstimate,
        preferences: ReadingTimePreferences
    ) -> Int {
        guard extraRequested > 0 else { return currentVisuals }
        let prefs = preferences.normalized
        let minutesPerVisual = Double(prefs.secondsPerVisual) / 60.0
        guard minutesPerVisual > 0 else { return currentVisuals + extraRequested }
        let affordable = Int((baseline.remainingMinutes * 0.5) / minutesPerVisual)
        return max(currentVisuals, min(currentVisuals + extraRequested, affordable))
    }

    /// Shapes the regenerated stretch to hold exactly `desiredVisualCount` visuals: model
    /// output first, then the stretch's own captions, then a plain placeholder.
    private static func shapingVisuals(
        generated: [ContentBlock],
        sourceSuffix: [ContentBlock],
        desiredVisualCount: Int,
        captionSeed: String
    ) -> [ContentBlock] {
        let prose = generated.filter { $0.kind != .imagePlaceholder }
        guard !prose.isEmpty else { return reindexed(generated) }

        var visuals = generated.filter { $0.kind == .imagePlaceholder }.map(\.text)
        if visuals.count < desiredVisualCount {
            let sourceCaptions = sourceSuffix.filter { $0.kind == .imagePlaceholder }.map(\.text)
            visuals.append(contentsOf: sourceCaptions.prefix(desiredVisualCount - visuals.count))
        }
        while visuals.count < desiredVisualCount {
            visuals.append("[Image] \(captionSeed)")
        }
        visuals = Array(visuals.prefix(max(0, desiredVisualCount)))
        guard !visuals.isEmpty else { return reindexed(prose) }

        var result = prose
        for (index, caption) in visuals.enumerated() {
            let ratio = Double(index + 1) / Double(visuals.count + 1)
            let position = min(result.count, max(0, Int((ratio * Double(prose.count)).rounded()) + index))
            result.insert(
                ContentBlock(id: UUID(), kind: .imagePlaceholder, text: caption, orderIndex: position),
                at: position
            )
        }
        return reindexed(result)
    }

    private static func reindexed(_ blocks: [ContentBlock]) -> [ContentBlock] {
        var copy = blocks
        for index in copy.indices { copy[index].orderIndex = index }
        return copy
    }

    /// Visual placeholders are structured local content, not prose for the model to silently drop.
    /// Time-sensitive regeneration keeps their text/count and places them near their prior position.
    private static func preservingVisualPlaceholders(
        from currentBlocks: [ContentBlock],
        in generatedBlocks: [ContentBlock]
    ) -> [ContentBlock] {
        let visuals = currentBlocks.enumerated().filter { $0.element.kind == .imagePlaceholder }
        guard !visuals.isEmpty else {
            return generatedBlocks.filter { $0.kind != .imagePlaceholder }
                .enumerated()
                .map { index, block in
                    var copy = block
                    copy.orderIndex = index
                    return copy
                }
        }

        var result = generatedBlocks.filter { $0.kind != .imagePlaceholder }
        let originalSpan = max(1, currentBlocks.count - 1)
        let generatedSpan = result.count
        for (visualOffset, visual) in visuals.enumerated() {
            let ratio = Double(visual.offset) / Double(originalSpan)
            let insertion = min(
                result.count,
                max(0, Int((ratio * Double(generatedSpan)).rounded()) + visualOffset)
            )
            result.insert(
                ContentBlock(
                    id: UUID(),
                    kind: .imagePlaceholder,
                    text: visual.element.text,
                    orderIndex: insertion
                ),
                at: insertion
            )
        }
        for index in result.indices {
            result[index].orderIndex = index
        }
        return result
    }

    /// Enforce remaining reading-time band for planned targets (words/WPM + visuals).
    private func assertReadingTimeGuardrail(
        book: Book,
        plan: AdaptationPlan,
        preferences: ReadingTimePreferences = .default
    ) async throws {
        var baselineBlocks: [[ContentBlock]] = []
        var plannedBlocks: [[ContentBlock]] = []
        for target in plan.chapterTargets {
            let current = try await versioning.readableRevision(bookId: book.id, chapterId: target.chapterId)
            baselineBlocks.append(current.blocks)
            let visuals = current.blocks.filter { $0.kind == .imagePlaceholder }.count
            let prose = String(repeating: "word ", count: max(20, target.targetWordCount))
            var blocks: [ContentBlock] = [
                ContentBlock(id: UUID(), kind: .paragraph, text: prose, orderIndex: 0)
            ]
            for i in 0..<visuals {
                blocks.append(ContentBlock(id: UUID(), kind: .imagePlaceholder, text: "visual", orderIndex: i + 1))
            }
            plannedBlocks.append(blocks)
        }
        let baseline = ReadingTimeEstimator.estimateRemaining(chapterBlocks: baselineBlocks, preferences: preferences)
        let planned = ReadingTimeEstimator.estimateRemaining(chapterBlocks: plannedBlocks, preferences: preferences)
        try ReadingTimeGuardrail.assertPreservesRemainingTime(
            baseline: baseline,
            planned: planned,
            preferences: preferences
        )
    }

    private func validateGeneratedBlocks(
        _ blocks: [ContentBlock],
        target: AdaptationChapterTarget,
        chapterId: UUID,
        book: Book,
        locked: Set<UUID>
    ) throws {
        if blocks.isEmpty {
            throw AdaptationError.malformedGeneration("empty blocks")
        }
        for (idx, block) in blocks.enumerated() {
            if block.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw AdaptationError.malformedGeneration("block \(idx) empty")
            }
        }
        if locked.contains(chapterId) {
            throw AdaptationError.lockedChapter(chapterId)
        }
        guard book.chapters.contains(where: { $0.id == chapterId }) else {
            throw AdaptationError.illegalChapterId(chapterId)
        }
        let wc = AdaptationPlanValidator.wordCount(of: blocks)
        try AdaptationPlanValidator.assertWordCountSanity(actual: wc, target: target.targetWordCount)
        let joined = blocks.map(\.text).joined(separator: "\n")
        try AdaptationPlanValidator.assertContinuity(text: joined, mustRemain: target.mustRemainConcepts)
    }
}
