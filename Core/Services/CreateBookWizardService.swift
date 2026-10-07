import Foundation

/// One in-process writer per draft, including a second sheet opened while the
/// first sheet's asynchronous generation is still finishing.
private final class CreateAttemptRegistry: @unchecked Sendable {
    static let shared = CreateAttemptRegistry()
    private let lock = NSLock()
    private var active: Set<UUID> = []

    func acquire(_ id: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return active.insert(id).inserted
    }

    func release(_ id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        active.remove(id)
    }
}

/// Wave 3 Create / New Book: import a manuscript or generate one through the
/// existing PE packet + Astra path. Reading never depends on this service.
actor CreateBookWizardService {
    private let versioning: ManuscriptVersioningService
    private let preferenceStore: ReaderPreferenceStoring
    private let packets: PEPacketStoring
    private let drafts: CreateBookDraftStoring
    private var ai: any AIService
    private let sourceRetriever: any ResearchSourceRetrieving

    init(
        versioning: ManuscriptVersioningService,
        preferenceStore: ReaderPreferenceStoring,
        packets: PEPacketStoring,
        drafts: CreateBookDraftStoring,
        ai: any AIService,
        sourceRetriever: any ResearchSourceRetrieving = WikipediaSourceClient()
    ) {
        self.versioning = versioning
        self.preferenceStore = preferenceStore
        self.packets = packets
        self.drafts = drafts
        self.ai = ai
        self.sourceRetriever = sourceRetriever
    }

    /// Swap AI after a Keychain key save without dropping the draft.
    func updateAI(_ service: any AIService) {
        ai = service
    }

    func persistDraft(_ draft: CreateBookDraft) throws {
        try drafts.save(draft)
    }

    func proposeOutline(for draft: CreateBookDraft) -> [String] {
        draft.resolvedOutline(for: draft.length)
    }

    /// Path A: paste / PDF extract → Codable manuscript, offline-readable.
    @discardableResult
    func importAndSave(draft: CreateBookDraft) async throws -> Book {
        guard CreateAttemptRegistry.shared.acquire(draft.id) else {
            throw CreateBookError.generationFailed("This book is already being generated.")
        }
        defer { CreateAttemptRegistry.shared.release(draft.id) }
        let existing = try await versioning.loadBook(id: draft.id)
        guard existing == nil || BundledSeedIDs.isProtected(draft.id) else {
            throw CreateBookError.generationFailed("This draft already has a saved book. Start a new book to import without replacing it.")
        }
        try persistDraft(draft)
        let book = try ManuscriptImporter.importPlainText(
            text: draft.importedText,
            title: draft.trimmedTitle.isEmpty ? nil : draft.trimmedTitle,
            author: draft.trimmedAuthor.isEmpty ? nil : draft.trimmedAuthor,
            sourceKind: draft.importSourceKind,
            bookId: BundledSeedIDs.isProtected(draft.id) ? UUID() : draft.id
        )
        try await versioning.saveBook(book)
        try seedImportPackets(book: book, draft: draft)
        try drafts.delete(id: draft.id)
        return book
    }

    /// Path B: brief → outline / length / style sign-off → research → Astra + PE.
    /// Failed chapters remain outlines; retries preserve published and consumed revisions.
    @discardableResult
    func generateAndSave(draft: CreateBookDraft) async throws -> CreateBookGenerationResult {
        guard !draft.trimmedTitle.isEmpty else { throw CreateBookError.missingTitle }
        guard !draft.trimmedTopic.isEmpty else { throw CreateBookError.missingTopic }
        _ = try draft.validatedTargetWordCount()
        if draft.id == ArgentinaFixtureIDs.book {
            throw CreateBookError.argentinaProtected
        }
        if draft.id == QuranFixtureIDs.book {
            throw CreateBookError.quranProtected
        }
        guard CreateAttemptRegistry.shared.acquire(draft.id) else {
            throw CreateBookError.generationFailed("This book is already being generated.")
        }
        defer { CreateAttemptRegistry.shared.release(draft.id) }
        if draft.sourcePilot != nil { return try await generateSourcePreview(draft: draft) }
        let outlineTitles = proposeOutline(for: draft)
        guard !outlineTitles.isEmpty else { throw CreateBookError.noChapters }

        let bookId = draft.id
        let generationAI = ai
        let author = draft.trimmedAuthor.isEmpty ? "GenBooks" : draft.trimmedAuthor
        let outlineBook: Book
        let isResume: Bool
        if let existing = try await versioning.loadBook(id: bookId) {
            // A matching unfinished Create draft is required. Never replace an
            // unrelated manuscript, or rebuild IDs underneath a consumed ledger.
            guard var savedDraft = try drafts.load(id: draft.id),
                  savedDraft.path == .generate,
                  existing.coverAccent == "generated",
                  existing.title == draft.trimmedTitle,
                  existing.author == author,
                  existing.synopsis == draft.trimmedTopic,
                  existing.chapters.sorted(by: { $0.orderIndex < $1.orderIndex }).map(\.title) == outlineTitles else {
                throw CreateBookError.generationFailed("This saved book cannot be replaced. Keep its title, topic and outline to resume, or start a new book.")
            }
            savedDraft.updatedAt = draft.updatedAt
            guard savedDraft == draft else {
                throw CreateBookError.generationFailed("Keep the saved brief and length unchanged to resume this book. Start a new book for a different brief.")
            }
            outlineBook = existing
            isResume = true
        } else {
            var newBook = try makeOutlineBook(
                bookId: bookId, title: draft.trimmedTitle, author: author,
                draft: draft, outlineTitles: outlineTitles
            )
            if generationAI.usesDeterministicGeneration {
                newBook.subtitle = "Bundled demo · " + draft.style.displayName
                newBook.provenanceNotes.append("Bundled deterministic demo; no live AI was used to write this book.")
            }
            outlineBook = newBook
            isResume = false
        }
        try persistDraft(draft)
        if !isResume { try await versioning.saveBook(outlineBook) }

        let profile = try isResume ? preferenceStore.load(bookId: bookId) : seedPreferences(book: outlineBook, draft: draft)
        _ = try packets.refreshBrief(book: outlineBook, profile: profile)
        if !isResume {
            try seedResearchFacts(book: outlineBook, draft: draft)
            try seedOutlineContinuity(book: outlineBook)
        } else {
            try await repairPublishedContinuity(book: outlineBook)
        }

        let plan = try makeAuthoringPlan(book: outlineBook, draft: draft, profile: profile)
        var generatedIds: [UUID] = []
        var skippedIds: [UUID] = []
        var failureMessages: [String] = []
        // Capture one provider for this attempt, even if a key/model changes mid-call.
        let usedFallback = generationAI.usesDeterministicGeneration

        for target in plan.chapterTargets {
            try Task.checkCancellation()
            guard let currentBook = try await versioning.loadBook(id: bookId),
                  let chapter = currentBook.chapters.first(where: { $0.id == target.chapterId }) else {
                throw CreateBookError.generationFailed("The chapter to generate could not be reloaded.")
            }
            let current = try await versioning.readableRevision(bookId: bookId, chapterId: target.chapterId)
            guard chapter.isOutlineStub else { continue }
            guard !(try await versioning.isChapterConsumed(bookId: bookId, chapterId: chapter.id)),
                  chapter.revisions.count == 1,
                  chapter.revisions.first?.id == chapter.activeRevisionId,
                  current.revisionIndex == 1 else {
                skippedIds.append(chapter.id)
                failureMessages.append("“\(chapter.title)” changed or was read; its saved revision will not be overwritten.")
                continue
            }
            // Earlier chapters have already published their prose and continuity.
            // Read both stores again so each chapter starts from that latest state.
            let packet = try packets.loadPacket(bookId: bookId)
            let request = AdaptationGenerateRequest(
                book: currentBook,
                plan: plan,
                chapterId: target.chapterId,
                chapterTitle: target.chapterTitle,
                currentPlainText: current.blocks.map(\.text).joined(separator: "\n"),
                target: target,
                profile: profile,
                continuityNotes: plan.continuityNotes,
                packet: packet
            )

            let generated: GeneratedChapter
            do {
                generated = try await generationAI.generateAdaptedChapterWithPacket(request)
            } catch {
                skippedIds.append(target.chapterId)
                failureMessages.append(error.localizedDescription)
                continue
            }

            let priorChecklist = (try? packets.loadFactChecklist(bookId: bookId)) ?? .empty(bookId: bookId)
            let merged = FactChecklistMerge.merge(
                claims: generated.proposedClaims,
                evidence: generated.proposedEvidence,
                into: priorChecklist
            )
            do {
                try PEContinuityGate.assertActivationAllowed(
                    checklist: merged,
                    bookId: bookId,
                    chapterId: target.chapterId
                )
                try packets.saveFactChecklist(merged)
            } catch {
                skippedIds.append(target.chapterId)
                failureMessages.append(error.localizedDescription)
                try? packets.saveFactChecklist(priorChecklist)
                continue
            }

            let candidate = CandidateRevision(
                id: UUID(),
                bookId: bookId,
                chapterId: target.chapterId,
                proposedRevisionIndex: current.revisionIndex + 1,
                createdAt: Date(),
                blocks: generated.blocks,
                status: .staged,
                rejectionReason: nil,
                origin: .generated(style: draft.style.displayName)
            )
            let revision: ChapterRevision
            do {
                try await versioning.stageCandidate(candidate)
                revision = try await versioning.activateCandidate(id: candidate.id, expectedRevisionId: current.id)
            } catch {
                try? packets.saveFactChecklist(priorChecklist)
                skippedIds.append(target.chapterId)
                failureMessages.append(error.localizedDescription)
                continue
            }

            // Activation has committed readable prose and its vetted checklist.
            // Later metadata failures must not roll either of them back.
            do {
                try await versioning.markChapterPolished(
                    bookId: bookId, chapterId: target.chapterId, expectedRevisionId: revision.id
                )
                let derived = ContinuityDeltaBuilder.derive(
                    bookId: bookId, chapter: chapter, revision: revision, plan: plan
                )
                var delta = generated.continuityDelta ?? derived
                // Generation owns the summary and threads, not stored identities.
                // A response describes this one chapter, even if its IDs are wrong.
                var entry = delta.entries.first(where: { $0.chapterId == chapter.id })
                    ?? delta.entries.first ?? derived.entries[0]
                entry.chapterId = chapter.id
                entry.chapterTitle = chapter.title
                entry.chapterOrderIndex = chapter.orderIndex
                entry.revisionId = revision.id
                entry.isConsumed = revision.isConsumed
                delta.bookId = bookId
                delta.entries = [entry]
                _ = try packets.mergeContinuity(delta)
                generatedIds.append(target.chapterId)
            } catch {
                skippedIds.append(target.chapterId)
                failureMessages.append("“\(chapter.title)” was written, but publication metadata could not be saved: \(error.localizedDescription) Saved text and facts are kept.")
                // A following chapter cannot continue from an out-of-date packet.
                break
            }
        }

        guard let saved = try await versioning.loadBook(id: bookId) else {
            throw CreateBookError.generationFailed("Generated book could not be reloaded.")
        }
        // A failed final read keeps the retry handle; an empty replacement packet
        // would falsely report that the entire publication succeeded.
        let finalPacket = try packets.loadPacket(bookId: bookId)
        if skippedIds.isEmpty && saved.outlineChapterCount == 0 {
            try drafts.delete(id: draft.id)
        }
        return CreateBookGenerationResult(
            book: saved,
            generatedChapterIds: generatedIds,
            skippedChapterIds: skippedIds,
            usedDeterministicFallback: usedFallback,
            packet: finalPacket,
            failureMessages: failureMessages
        )
    }

    /// One immutable source snapshot, one saved writing draft, and a separate
    /// review request. Failed review retries never silently buy another rewrite.
    private func generateSourcePreview(draft: CreateBookDraft) async throws -> CreateBookGenerationResult {
        guard let plan = draft.sourcePilot, !plan.articleTitle.isEmpty,
              plan.approvedBriefHash == (try SourcePilotPlan.briefHash(draft)),
              draft.path == .generate, draft.length == .short, draft.readingTimeInput == nil,
              draft.cleanedOutlineTitles.count == 1,
              let writer = ai as? any SourceGroundedAI,
              writer.sourceReviewModelID == OpenAIModelOption.defaultGeneration.rawValue else {
            throw SourceGroundingError.invalid("Approve the one-chapter, 400-word preview with Astra before starting.")
        }
        let existing = try await versioning.loadBook(id: draft.id)
        if let existing {
            guard let savedDraft = try drafts.load(id: draft.id),
                  try SourcePilotPlan.briefHash(savedDraft) == plan.approvedBriefHash,
                  savedDraft.sourcePilot == plan, existing.coverAccent == "generated",
                  existing.title == draft.trimmedTitle, existing.synopsis == draft.trimmedTopic,
                  existing.chapters.count == 1, existing.chapters.first?.title == draft.cleanedOutlineTitles[0] else {
                throw SourceGroundingError.invalid("This saved preview belongs to another brief. Start a new preview instead of replacing it.")
            }
        }
        try drafts.save(draft)
        if existing == nil {
            var book = try makeOutlineBook(bookId: draft.id, title: draft.trimmedTitle,
                author: draft.trimmedAuthor.isEmpty ? "GenBooks" : draft.trimmedAuthor,
                draft: draft, outlineTitles: draft.cleanedOutlineTitles)
            book.subtitle = "Source preview · not reviewed"
            book.provenanceNotes = ["Pending preview: no source-support review has been completed.",
                "Preview only: later adaptation requires a new source review and is not available in this pilot."]
            try await versioning.saveBook(book)
        }
        guard var book = try await versioning.loadBook(id: draft.id), let chapter = book.chapters.first,
              let outline = chapter.activeRevision else {
            throw SourceGroundingError.invalid("The saved preview could not be reloaded.")
        }
        let profile = try preferenceStore.load(bookId: book.id)
        _ = try packets.refreshBrief(book: book, profile: profile)

        // A previous attempt may have published before metadata persistence failed.
        if outline.sourceReview != nil {
            return try await finishSourcePreview(bookID: book.id, chapterID: chapter.id, revisionID: outline.id)
        }
        guard chapter.isOutlineStub, chapter.revisions.count == 1,
              !(try await versioning.isChapterConsumed(bookId: book.id, chapterId: chapter.id)) else {
            throw SourceGroundingError.invalid("This chapter changed or was finished; its text will not be replaced.")
        }

        if chapter.sourceGrounding == nil {
            let source: RetrievedResearchSource
            switch plan.selectedScope {
            case .wikipediaIntroduction:
                source = try await sourceRetriever.retrieve(articleTitle: plan.articleTitle)
            case .wikipediaOpeningExcerpt:
                guard let retriever = sourceRetriever as? any ResearchExcerptSourceRetrieving else {
                    throw SourceGroundingError.invalid("Opening article excerpts are unavailable with this source provider.")
                }
                source = try await retriever.retrieveOpeningExcerpt(articleTitle: plan.articleTitle)
            }
            try Task.checkCancellation()
            try SourceGrounding.validateSource(source)
            guard source.scope == plan.selectedScope,
                  source.requestedTitle == plan.articleTitle else {
                throw SourceGroundingError.invalid("The retrieved source does not match the approved article and scope.")
            }
            // Re-read after network suspension so a stale outline cannot win.
            guard var latest = try await versioning.loadBook(id: book.id),
                  latest.chapters.count == 1, latest.chapters[0].activeRevision?.id == outline.id,
                  latest.chapters[0].revisions.count == 1, latest.chapters[0].sourceGrounding == nil,
                  !(try await versioning.isChapterConsumed(bookId: book.id, chapterId: chapter.id)) else {
                throw SourceGroundingError.invalid("The outline changed during research; no prose was written.")
            }
            latest.chapters[0].sourceGrounding = SourceGroundingRequirement(source: source,
                outlineRevisionID: outline.id, outlineContentHash: try SourceGrounding.contentHash(outline.blocks),
                approvedBriefHash: plan.approvedBriefHash)
            try await versioning.saveBook(latest)
        }
        guard let reloaded = try await versioning.loadBook(id: book.id),
              let requirement = reloaded.chapters.first?.sourceGrounding,
              requirement.approvedBriefHash == plan.approvedBriefHash,
              requirement.source.scope == plan.selectedScope,
              requirement.source.requestedTitle == plan.articleTitle else {
            throw SourceGroundingError.invalid("The source snapshot could not be saved.")
        }
        book = reloaded
        let source = requirement.source
        var facts = try packets.loadFactChecklist(bookId: book.id)
        if let pending = facts.sourcePilot {
            guard pending.approvedBriefHash == plan.approvedBriefHash, pending.chapterID == chapter.id,
                  pending.expectedRevisionID == outline.id else {
                throw SourceGroundingError.invalid("The saved writing draft has a different brief or revision.")
            }
        } else {
            facts.sourcePilot = SourcePilotState(approvedBriefHash: plan.approvedBriefHash,
                chapterID: chapter.id, expectedRevisionID: outline.id)
        }
        if facts.evidenceItem(id: "source1") == nil {
            let scopeLabel = source.scope == .wikipediaIntroduction ? "Wikipedia introduction" : "Wikipedia opening excerpt"
            var evidence = FactEvidenceItem(id: "source1", sourceLabel: "\(scopeLabel) · \(source.title)",
                digest: source.text, locator: source.revisionURL.absoluteString, recordedAt: source.retrievedAt)
            evidence.retrievedSource = source
            facts.evidence.append(evidence)
        }
        try packets.saveFactChecklist(facts)

        if facts.sourcePilot?.candidate == nil {
            let paragraphs = try await writer.writeSourcePreview(SourceWritingRequest(title: chapter.title,
                topic: draft.trimmedTopic, voice: draft.voice, source: source))
            try Task.checkCancellation()
            let blocks = try SourceGrounding.blocks(title: chapter.title, paragraphs: paragraphs, source: source)
            facts.sourcePilot?.candidate = CandidateRevision(id: UUID(), bookId: book.id, chapterId: chapter.id,
                proposedRevisionIndex: outline.revisionIndex + 1, createdAt: Date(), blocks: blocks,
                status: .staged, rejectionReason: nil, origin: .generated(style: draft.style.displayName))
            try packets.saveFactChecklist(facts)
        }
        guard var candidate = facts.sourcePilot?.candidate else {
            throw SourceGroundingError.invalid("The writing draft could not be saved.")
        }
        if candidate.sourceReview == nil {
            let response = try await writer.reviewSourcePreview(SourceReviewRequest(
                paragraphs: SourceGrounding.prose(candidate.blocks, source: source), source: source))
            try Task.checkCancellation()
            candidate.sourceReview = try SourceGrounding.receipt(bookID: book.id, chapterID: chapter.id,
                baseRevisionID: outline.id, blocks: candidate.blocks, source: source,
                model: writer.sourceReviewModelID, response: response)
            facts.sourcePilot?.candidate = candidate
            try packets.saveFactChecklist(facts)
        }
        try await versioning.stageCandidate(candidate)
        let revision = try await versioning.activateCandidate(id: candidate.id, expectedRevisionId: outline.id)
        return try await finishSourcePreview(bookID: book.id, chapterID: chapter.id, revisionID: revision.id)
    }

    private func finishSourcePreview(bookID: UUID, chapterID: UUID, revisionID: UUID) async throws -> CreateBookGenerationResult {
        try await versioning.markChapterPolished(bookId: bookID, chapterId: chapterID, expectedRevisionId: revisionID)
        guard var saved = try await versioning.loadBook(id: bookID) else {
            throw SourceGroundingError.invalid("Published preview could not be reloaded.")
        }
        guard let chapter = saved.chapters.first(where: { $0.id == chapterID }),
              let source = chapter.sourceGrounding?.source,
              let revision = chapter.activeRevision, revision.id == revisionID else {
            throw SourceGroundingError.invalid("The published preview's source or active revision changed.")
        }
        let words = try SourceGrounding.proseWordCount(revision.blocks, source: source)
        saved.subtitle = "Source-checked preview · \(words) prose words"
        saved.provenanceNotes = [SourcePilotPlan.disclosure(for: source.scope),
            "Preview only: text changes after a selected prose word require a new review against this saved source. Images and later-chapter adaptation are not supported."]
        try await versioning.saveBook(saved)
        try await repairPublishedContinuity(book: saved)
        let packet = try packets.loadPacket(bookId: bookID)
        try drafts.delete(id: bookID)
        return CreateBookGenerationResult(book: saved, generatedChapterIds: [chapterID], skippedChapterIds: [],
            usedDeterministicFallback: false, packet: packet)
    }

    // MARK: - Outline + PE seed

    /// Repairs only missing/stale metadata for already-published text. Never
    /// spends another generation request or rewrites a chapter to repair a packet.
    private func repairPublishedContinuity(book: Book) async throws {
        for chapter in book.chapters.filter({ !$0.isOutlineStub }).sorted(by: { $0.orderIndex < $1.orderIndex }) {
            let revision = try await versioning.readableRevision(bookId: book.id, chapterId: chapter.id)
            let consumed = try await versioning.isChapterConsumed(bookId: book.id, chapterId: chapter.id)
            let state = try packets.loadContinuity(bookId: book.id)
            let entry = state.entry(chapterId: chapter.id)
            if let entry, entry.revisionId == revision.id {
                if consumed && !entry.isConsumed {
                    _ = try packets.recordConsumedContinuity(bookId: book.id, chapter: chapter, revision: revision)
                }
                continue
            }
            guard entry?.isConsumed != true else {
                throw CreateBookError.generationFailed("The consumed continuity for “\(chapter.title)” does not match its saved revision. Its history is preserved; repair that metadata before continuing.")
            }
            do {
                let delta = ContinuityDeltaBuilder.derive(bookId: book.id, chapter: chapter, revision: revision)
                _ = try packets.mergeContinuity(delta)
                if consumed {
                    _ = try packets.recordConsumedContinuity(bookId: book.id, chapter: chapter, revision: revision)
                }
            } catch {
                throw CreateBookError.generationFailed("Could not repair saved continuity for “\(chapter.title)”: \(error.localizedDescription) Its published text and facts are kept; retry after the metadata store is available.")
            }
        }
    }

    private func makeOutlineBook(
        bookId: UUID,
        title: String,
        author: String,
        draft: CreateBookDraft,
        outlineTitles: [String]
    ) throws -> Book {
        var chapters: [Chapter] = []
        for (index, chapterTitle) in outlineTitles.enumerated() {
            let chapterId = UUID()
            let revisionId = UUID()
            let beats = outlineBeats(for: chapterTitle, topic: draft.trimmedTopic, style: draft.style)
            let body = outlineStubText(title: chapterTitle, topic: draft.trimmedTopic, beats: beats)
            let blocks = [
                ContentBlock(id: UUID(), kind: .heading, text: chapterTitle, orderIndex: 0),
                ContentBlock(id: UUID(), kind: .paragraph, text: body, orderIndex: 1)
            ]
            let revision = ChapterRevision(
                id: revisionId,
                chapterId: chapterId,
                revisionIndex: 1,
                createdAt: Date(),
                blocks: blocks,
                isConsumed: false,
                origin: .generated(style: draft.style.displayName)
            )
            chapters.append(
                Chapter(
                    id: chapterId,
                    bookId: bookId,
                    title: chapterTitle,
                    orderIndex: index + 1,
                    activeRevisionId: revisionId,
                    revisions: [revision],
                    manuscriptStatus: .outline,
                    eraLabel: draft.trimmedTopic,
                    outlineBeats: beats
                )
            )
        }
        return Book(
            id: bookId,
            title: title,
            author: author,
            subtitle: "Living · " + draft.style.displayName + " · "
                + (draft.readingTimeInput == nil ? draft.length.displayName : draft.readingTimeLabel),
            synopsis: draft.trimmedTopic,
            coverAccent: "generated",
            edition: BookEdition(
                id: UUID(),
                bookId: bookId,
                label: "Generated",
                localeIdentifier: "en"
            ),
            timeline: [],
            provenanceNotes: [
                "Generated from a reader brief. Ask stays gpt-5.6-luna; generation uses gpt-6-astra.",
                "PE packet A/B/C + fact gates apply before a generated revision goes live."
            ],
            chapters: chapters
        )
    }

    private func seedPreferences(book: Book, draft: CreateBookDraft) throws -> ReaderPreferenceProfile {
        var notes = draft.readerNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !draft.referenceStyles.isEmpty {
            let refs = draft.referenceStyles.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            if !refs.isEmpty {
                let line = "Reference styles: \(refs.joined(separator: ", "))"
                notes = notes.isEmpty ? line : notes + "\n" + line
            }
        }
        for card in draft.profileCards where !card.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            notes = notes.isEmpty
                ? "\(card.title): \(card.body)"
                : notes + "\n\(card.title): \(card.body)"
        }
        let feedback = ChapterFeedback(
            id: UUID(),
            bookId: book.id,
            chapterId: book.chapters.first?.id ?? UUID(),
            revisionId: book.chapters.first?.activeRevisionId ?? UUID(),
            overall: .fine,
            moreOf: draft.moreOf,
            lessOf: draft.lessOf,
            freeText: notes,
            createdAt: Date()
        )
        var profile = try preferenceStore.applyFeedback(feedback)
        if !draft.voice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            profile.overallTone = draft.voice.trimmingCharacters(in: .whitespacesAndNewlines)
            profile.updatedAt = Date()
            try preferenceStore.save(profile)
        }
        return profile
    }

    private func seedImportPackets(book: Book, draft: CreateBookDraft) throws {
        let profile = try preferenceStore.load(bookId: book.id)
        _ = try packets.refreshBrief(book: book, profile: profile)
        var continuity = ContinuityState.empty(bookId: book.id)
        for chapter in book.chapters.sorted(by: { $0.orderIndex < $1.orderIndex }) {
            guard let revision = chapter.activeRevision else { continue }
            let delta = ContinuityDeltaBuilder.derive(
                bookId: book.id,
                chapter: chapter,
                revision: revision
            )
            continuity = try ContinuityMerge.merge(delta, into: continuity).state
        }
        try packets.saveContinuity(continuity)
        if !draft.researchNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try seedResearchFacts(book: book, draft: draft)
        }
    }

    /// Research notes become supporting evidence — never essential unverified claims,
    /// so they cannot block the first activation.
    private func seedResearchFacts(book: Book, draft: CreateBookDraft) throws {
        var checklist = (try? packets.loadFactChecklist(bookId: book.id)) ?? .empty(bookId: book.id)
        let snippets = researchSnippets(from: draft)
        guard !snippets.isEmpty else {
            try packets.saveFactChecklist(checklist)
            return
        }
        let chapterId = book.chapters.sorted(by: { $0.orderIndex < $1.orderIndex }).first?.id ?? book.id
        var evidence: [FactEvidenceItem] = []
        var claims: [FactClaim] = []
        for (index, snippet) in snippets.enumerated() {
            let evidenceId = "ev-create-\(index + 1)"
            evidence.append(
                FactEvidenceItem(
                    id: evidenceId,
                    sourceLabel: "Reader research",
                    digest: snippet,
                    locator: "create-wizard"
                )
            )
            claims.append(
                FactClaim(
                    chapterId: chapterId,
                    statement: snippet,
                    importance: .supporting,
                    status: .unverified,
                    evidenceIds: [evidenceId],
                    notes: "Seeded from the Create research step"
                )
            )
        }
        checklist = FactChecklistMerge.merge(claims: claims, evidence: evidence, into: checklist)
        try packets.saveFactChecklist(checklist)
    }

    private func seedOutlineContinuity(book: Book) throws {
        var continuity = ContinuityState.empty(bookId: book.id)
        for chapter in book.chapters.sorted(by: { $0.orderIndex < $1.orderIndex }) {
            guard let revision = chapter.activeRevision else { continue }
            let delta = ContinuityDeltaBuilder.derive(
                bookId: book.id,
                chapter: chapter,
                revision: revision
            )
            continuity = try ContinuityMerge.merge(delta, into: continuity).state
        }
        try packets.saveContinuity(continuity)
    }

    private func makeAuthoringPlan(
        book: Book,
        draft: CreateBookDraft,
        profile: ReaderPreferenceProfile
    ) throws -> AdaptationPlan {
        let ordered = book.chapters.sorted { $0.orderIndex < $1.orderIndex }
        let budgets = try draft.chapterWordTargets(chapterCount: ordered.count)
        let targets = ordered.enumerated().filter { $0.element.isOutlineStub }.map { index, chapter in
            let plain = chapter.activeRevision?.blocks.map(\.text).joined(separator: " ") ?? ""
            return AdaptationChapterTarget(
                chapterId: chapter.id,
                chapterTitle: chapter.title,
                currentWordCount: AdaptationPlanValidator.wordCount(of: plain),
                targetWordCount: budgets[index],
                desiredChanges: [
                    "Expand outline beats into full \(draft.style.displayName.lowercased()) prose",
                    "Honour the reader brief and reference styles",
                    "Aim for this chapter's allocated word target; the whole book is \(draft.readingTimeLabel.lowercased())"
                ],
                mustRemainConcepts: DeterministicAdaptationSynthesizer.mustRemainConcepts(
                    from: draft.trimmedTopic + " " + chapter.title,
                    title: chapter.title
                )
            )
        }
        return AdaptationPlan(
            id: UUID(),
            bookId: book.id,
            createdAt: Date(),
            sourceFeedbackId: UUID(),
            preferenceUpdatesSummary: [ReaderPreferenceEngine.summaryLine(for: profile)],
            affectedChapterIds: targets.map(\.chapterId),
            chapterTargets: targets,
            continuityNotes: [
                "Write only the remaining outlines; preserve all previously published or consumed chapters",
                "Stay consistent with the outline and research notes",
                "Never invent essential facts without Packet C evidence"
            ],
            reasonsFromFeedback: [
                "Create wizard brief: \(draft.trimmedTopic)",
                "Style: \(draft.style.displayName)",
                "Length: \(draft.readingTimeInput == nil ? draft.length.displayName : draft.readingTimeLabel)"
            ],
            lockedChapterIds: book.chapters.filter { !$0.isOutlineStub }.map(\.id),
            isValidated: true
        )
    }

    private func researchSnippets(from draft: CreateBookDraft) -> [String] {
        var snippets: [String] = []
        let notes = draft.researchNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty {
            snippets.append(contentsOf: notes.components(separatedBy: "\n").map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty }.prefix(8))
        }
        for card in draft.profileCards where card.title.localizedCaseInsensitiveContains("research") {
            let body = card.body.trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty { snippets.append(String(body.prefix(240))) }
        }
        return Array(snippets.prefix(8))
    }

    private func outlineBeats(for title: String, topic: String, style: CreateBookStyle) -> [String] {
        [
            "Open \(title) in the \(style.displayName.lowercased()) voice the reader asked for.",
            "Explain how this beat belongs to \(topic).",
            "Close with a thread the next chapter can pick up."
        ]
    }

    private func outlineStubText(title: String, topic: String, beats: [String]) -> String {
        let beatLines = beats.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        return "[Outline] \(title) for \(topic)\n\(beatLines)"
    }

}
