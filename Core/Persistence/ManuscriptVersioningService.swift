import Foundation

/// Orchestrates immutable versioning: consumed ledger, append-only revisions, candidate staging + activation.
/// Concrete disk operations are synchronous: a check and its writes cannot yield
/// to another call on this actor. This does not serialize independent service
/// instances or external file writers, and is not a multi-file crash transaction.
actor ManuscriptVersioningService {
    private let manuscripts: FileManuscriptStore
    private let ledger: FileConsumedLedgerStore
    private let candidates: FileCandidateStagingStore
    private let packets: PEPacketStoring

    init(
        rootDirectory: URL,
        packets: PEPacketStoring? = nil
    ) throws {
        let manuscriptsDir = rootDirectory.appendingPathComponent("Manuscripts", isDirectory: true)
        let ledgerDir = rootDirectory.appendingPathComponent("Ledger", isDirectory: true)
        let candidatesDir = rootDirectory.appendingPathComponent("Candidates", isDirectory: true)
        self.manuscripts = try FileManuscriptStore(directory: manuscriptsDir)
        self.ledger = try FileConsumedLedgerStore(directory: ledgerDir)
        self.candidates = try FileCandidateStagingStore(directory: candidatesDir)
        self.packets = try packets ?? FilePEPacketStore(rootDirectory: rootDirectory)
    }

    /// Test / app helper exposing the manuscript store directory.
    var manuscriptsDirectory: URL { manuscripts.directory }

    /// The PE packet store this service gates activation against. Callers share
    /// it so the brief / continuity / checklist they write is the one enforced.
    var packetStore: PEPacketStoring { packets }

    // MARK: - Load / seed

    func loadBook(id: UUID) throws -> Book? {
        try manuscripts.loadBook(id: id)
    }

    func saveBook(_ book: Book) throws {
        try manuscripts.saveBook(book)
    }

    func listBooks() throws -> [(id: UUID, title: String, author: String)] {
        try manuscripts.listBookSummaries()
    }

    func loadLibrarySnapshot() throws -> LibrarySnapshot {
        try manuscripts.loadLibrarySnapshot()
    }

    // MARK: - Consumption (immutable past)

    /// Marks a chapter revision as consumed. Stores exact revision identity permanently in the ledger.
    func consume(bookId: UUID, chapterId: UUID, revisionId: UUID, at date: Date = Date()) throws {
        guard var book = try manuscripts.loadBook(id: bookId) else {
            throw ManuscriptError.bookNotFound(bookId)
        }
        guard let chapterIndex = book.chapters.firstIndex(where: { $0.id == chapterId }) else {
            throw ManuscriptError.chapterNotFound(chapterId)
        }
        guard let revisionIndex = book.chapters[chapterIndex].revisions.firstIndex(where: { $0.id == revisionId }) else {
            throw ManuscriptError.revisionNotFound(revisionId)
        }

        if let existing = try ledger.entry(bookId: bookId, chapterId: chapterId) {
            guard existing.revisionId == revisionId else {
                throw ManuscriptError.chapterAlreadyConsumed(
                    chapterId: chapterId,
                    lockedRevisionId: existing.revisionId
                )
            }
            return
        }

        let revision = book.chapters[chapterIndex].revisions[revisionIndex]
        if let requirement = book.chapters[chapterIndex].sourceGrounding {
            guard book.chapters[chapterIndex].activeRevisionId == revision.id else {
                throw SourceGroundingError.invalid("Only the current readable preview can be marked read.")
            }
            if revision.id != requirement.outlineRevisionID {
                try SourceGrounding.validate(receipt: revision.sourceReview, bookID: bookId, chapterID: chapterId,
                                             blocks: revision.blocks, requirement: requirement)
            }
        }
        let entry = ConsumedChapterRevision(
            id: UUID(),
            bookId: bookId,
            chapterId: chapterId,
            revisionId: revision.id,
            revisionIndex: revision.revisionIndex,
            consumedAt: date
        )
        try ledger.record(entry)

        book.chapters[chapterIndex].revisions[revisionIndex].isConsumed = true
        try manuscripts.saveBook(book)
    }

    /// Returns the permanently pinned consumed revision content (by ledger identity), if any.
    func retrieveConsumedRevision(bookId: UUID, chapterId: UUID) throws -> ChapterRevision? {
        guard let entry = try ledger.entry(bookId: bookId, chapterId: chapterId) else {
            return nil
        }
        guard let book = try manuscripts.loadBook(id: bookId) else {
            throw ManuscriptError.bookNotFound(bookId)
        }
        guard let chapter = book.chapters.first(where: { $0.id == chapterId }) else {
            throw ManuscriptError.chapterNotFound(chapterId)
        }
        guard let revision = chapter.revision(id: entry.revisionId) else {
            throw ManuscriptError.revisionNotFound(entry.revisionId)
        }
        return revision
    }

    func isChapterConsumed(bookId: UUID, chapterId: UUID) throws -> Bool {
        try ledger.entry(bookId: bookId, chapterId: chapterId) != nil
    }

    func ledgerSnapshot() throws -> [ConsumedChapterRevision] {
        try ledger.allEntries()
    }

    /// UITest-only: wipe the on-disk consumed ledger so suite isolation can
    /// re-anchor word-regen demos in chapters earlier tests navigated past.
    /// Never call from product UI — consumed past is permanent by design.
    func resetConsumedLedgerForUITesting() throws {
        let url = ledger.fileURL
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        // Clear isConsumed bits that consume() stamped onto manuscript revisions.
        for summary in try manuscripts.listBookSummaries() {
            guard var book = try manuscripts.loadBook(id: summary.id) else { continue }
            var dirty = false
            for ci in book.chapters.indices {
                for ri in book.chapters[ci].revisions.indices where book.chapters[ci].revisions[ri].isConsumed {
                    book.chapters[ci].revisions[ri].isConsumed = false
                    dirty = true
                }
            }
            if dirty {
                try manuscripts.saveBook(book)
            }
        }
    }

    // MARK: - Future revisions (append-only)

    /// Creates a new revision for a chapter without overwriting prior revisions (including consumed v1).
    @discardableResult
    func createRevision(
        bookId: UUID,
        chapterId: UUID,
        blocks: [ContentBlock],
        origin: RevisionOrigin? = nil,
        at date: Date = Date()
    ) throws -> ChapterRevision {
        guard !blocks.isEmpty else { throw ManuscriptError.emptyBlocks }
        guard var book = try manuscripts.loadBook(id: bookId) else {
            throw ManuscriptError.bookNotFound(bookId)
        }
        guard let chapterIndex = book.chapters.firstIndex(where: { $0.id == chapterId }) else {
            throw ManuscriptError.chapterNotFound(chapterId)
        }

        let nextIndex = (book.chapters[chapterIndex].revisions.map(\.revisionIndex).max() ?? -1) + 1
        guard book.chapters[chapterIndex].sourceGrounding == nil else {
            throw SourceGroundingError.invalid("New preview text must use source-reviewed candidate activation.")
        }
        let revision = ChapterRevision(
            id: UUID(),
            chapterId: chapterId,
            revisionIndex: nextIndex,
            createdAt: date,
            blocks: blocks,
            isConsumed: false,
            origin: origin
        )

        // If chapter is already consumed, still allow storing future revisions for unread paths,
        // but never change active readable past — leave activeRevisionId pointing at consumed,
        // and do not flip isConsumed on older revisions.
        let consumed = try ledger.entry(bookId: bookId, chapterId: chapterId)
        book.chapters[chapterIndex].revisions.append(revision)
        if consumed == nil {
            book.chapters[chapterIndex].activeRevisionId = revision.id
        }
        try manuscripts.saveBook(book)
        return revision
    }

    /// Readable revision for a chapter: ledger-pinned if consumed, else active/latest.
    func readableRevision(bookId: UUID, chapterId: UUID) throws -> ChapterRevision {
        if let consumed = try retrieveConsumedRevision(bookId: bookId, chapterId: chapterId) {
            return consumed
        }
        guard let book = try manuscripts.loadBook(id: bookId) else {
            throw ManuscriptError.bookNotFound(bookId)
        }
        guard let chapter = book.chapters.first(where: { $0.id == chapterId }) else {
            throw ManuscriptError.chapterNotFound(chapterId)
        }
        guard let revision = chapter.activeRevision else {
            throw ManuscriptError.revisionNotFound(chapterId)
        }
        return revision
    }

    // MARK: - Candidate staging + atomic activation

    func stageCandidate(_ candidate: CandidateRevision) throws {
        try Self.validateCandidateStructure(candidate)
        var staged = candidate
        staged.status = .staged
        staged.rejectionReason = nil
        try candidates.save(staged)
    }

    /// Validates and activates a staged candidate for *unread* future only.
    /// Generated replacements supply the revision they used as input. Stale
    /// work is refused before changing either the book or candidate status.
    @discardableResult
    func activateCandidate(id: UUID, expectedRevisionId: UUID? = nil) throws -> ChapterRevision {
        let candidate: CandidateRevision
        do {
            guard let loaded = try candidates.load(id: id) else {
                throw ManuscriptError.candidateNotFound(id)
            }
            candidate = loaded
        } catch let error as ManuscriptError {
            throw error
        }

        if candidate.status == .activated || candidate.status == .rejected {
            throw ManuscriptError.candidateAlreadyHandled(id)
        }

        if let chapter = try manuscripts.loadBook(id: candidate.bookId)?.chapters.first(where: { $0.id == candidate.chapterId }),
           let requirement = chapter.sourceGrounding {
            let current = try readableRevision(bookId: candidate.bookId, chapterId: candidate.chapterId)
            try SourceGrounding.validate(receipt: candidate.sourceReview, bookID: candidate.bookId, chapterID: candidate.chapterId,
                                         blocks: candidate.blocks, requirement: requirement, baseRevisionID: current.id)
            try SourceGrounding.validateTransition(receipt: candidate.sourceReview, origin: candidate.origin,
                blocks: candidate.blocks, bookID: candidate.bookId, chapter: chapter, history: chapter.revisions)
        }

        if let expectedRevisionId {
            let current = try readableRevision(bookId: candidate.bookId, chapterId: candidate.chapterId)
            guard current.id == expectedRevisionId else {
                throw ManuscriptError.staleRevision(expected: expectedRevisionId, actual: current.id)
            }
        }

        do {
            try Self.validateCandidateStructure(candidate)
        } catch {
            var rejected = candidate
            rejected.status = .rejected
            rejected.rejectionReason = (error as? ManuscriptError)?.errorDescription ?? "invalid"
            try? candidates.save(rejected)
            throw error
        }

        if try isChapterConsumed(bookId: candidate.bookId, chapterId: candidate.chapterId) {
            var rejected = candidate
            rejected.status = .rejected
            rejected.rejectionReason = "chapter locked/consumed"
            try candidates.save(rejected)
            throw ManuscriptError.cannotMutateConsumedChapter(candidate.chapterId)
        }

        // PE fact gate at the choke point where `activeRevisionId` flips: a new
        // unread revision may not carry unresolved evidence, stub digests, or
        // unverified essential claims. Rejecting here happens before any
        // manuscript write, so the prior revision stays readable.
        do {
            let checklist: FactChecklist
            do {
                checklist = try packets.loadFactChecklist(bookId: candidate.bookId)
            } catch {
                // An unreadable checklist is an unverifiable one: fail closed.
                // Adaptation is optional; reading is unaffected either way.
                throw PEGateError.checklistUnreadable(error.localizedDescription)
            }
            try PEContinuityGate.assertActivationAllowed(
                checklist: checklist,
                bookId: candidate.bookId,
                chapterId: candidate.chapterId
            )
        } catch let error as PEGateError {
            var rejected = candidate
            rejected.status = .rejected
            rejected.rejectionReason = error.errorDescription ?? "fact gate rejected"
            try candidates.save(rejected)
            throw error
        }

        // Best-effort rollback on an observed write failure, not crash atomicity.
        let bookURL = manuscripts.bookURL(id: candidate.bookId)
        let priorData = FileManager.default.fileExists(atPath: bookURL.path)
            ? try Data(contentsOf: bookURL)
            : nil

        do {
            guard var book = try manuscripts.loadBook(id: candidate.bookId) else {
                throw ManuscriptError.bookNotFound(candidate.bookId)
            }
            guard let chapterIndex = book.chapters.firstIndex(where: { $0.id == candidate.chapterId }) else {
                throw ManuscriptError.chapterNotFound(candidate.chapterId)
            }

            let nextIndex = (book.chapters[chapterIndex].revisions.map(\.revisionIndex).max() ?? -1) + 1
            let revision = ChapterRevision(
                id: UUID(),
                chapterId: candidate.chapterId,
                revisionIndex: nextIndex,
                createdAt: Date(),
                blocks: candidate.blocks,
                isConsumed: false,
                origin: candidate.origin,
                sourceReview: candidate.sourceReview
            )
            book.chapters[chapterIndex].revisions.append(revision)
            book.chapters[chapterIndex].activeRevisionId = revision.id
            try manuscripts.saveBook(book)

            var activated = candidate
            activated.status = .activated
            activated.proposedRevisionIndex = revision.revisionIndex
            try candidates.save(activated)
            return revision
        } catch {
            // Restore prior manuscript bytes if present — previous readable book unchanged.
            if let priorData {
                try? AtomicFileWriter.writeAtomically(priorData, to: bookURL)
            }
            throw ManuscriptError.atomicActivationFailed(error.localizedDescription)
        }
    }

    /// Update generation metadata without a caller's suspended load/save pair
    /// overwriting a revision published since that caller loaded the book.
    func markChapterPolished(bookId: UUID, chapterId: UUID, expectedRevisionId: UUID) throws {
        guard var book = try manuscripts.loadBook(id: bookId) else {
            throw ManuscriptError.bookNotFound(bookId)
        }
        guard let index = book.chapters.firstIndex(where: { $0.id == chapterId }) else {
            throw ManuscriptError.chapterNotFound(chapterId)
        }
        guard book.chapters[index].activeRevision?.id == expectedRevisionId,
              book.chapters[index].isOutlineStub else { return }
        book.chapters[index].manuscriptStatus = .polished
        try manuscripts.saveBook(book)
    }

    /// Rejects a malformed on-disk candidate without touching the manuscript.
    func rejectMalformedCandidate(id: UUID) throws {
        do {
            _ = try candidates.load(id: id)
        } catch ManuscriptError.malformedCandidate {
            // Leave raw file; manuscript untouched. Surface as rejection.
            throw ManuscriptError.malformedCandidate("on-disk candidate \(id) is malformed")
        }
    }

    /// Test seam: plant raw candidate bytes.
    func plantRawCandidate(id: UUID, data: Data) throws {
        try candidates.writeRaw(id: id, data: data)
    }

    // MARK: - Version history + restore (Wave 2)

    /// Lists append-only revisions for a chapter (Sheets-like history rows).
    func listChapterVersions(bookId: UUID, chapterId: UUID) throws -> [ChapterVersionEntry] {
        guard let book = try manuscripts.loadBook(id: bookId) else {
            throw ManuscriptError.bookNotFound(bookId)
        }
        guard let chapter = book.chapters.first(where: { $0.id == chapterId }) else {
            throw ManuscriptError.chapterNotFound(chapterId)
        }
        let lockedRevisionId = try ledger.entry(bookId: bookId, chapterId: chapterId)?.revisionId
        // A consumed chapter is locked as a whole. Its ledger-pinned revision is the readable
        // "active" version even if malformed legacy data points activeRevisionId elsewhere.
        let activeId = lockedRevisionId ?? chapter.activeRevision?.id
        return chapter.revisions
            .sorted { $0.revisionIndex < $1.revisionIndex }
            .map { rev in
                let prose = rev.blocks.filter { $0.kind != .imagePlaceholder }
                let visuals = rev.blocks.filter { $0.kind == .imagePlaceholder }
                let snippet = rev.blocks.first(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?.text
                    ?? ""
                let clipped = String(snippet.prefix(120))
                return ChapterVersionEntry(
                    chapterId: chapterId,
                    chapterTitle: chapter.title,
                    chapterOrderIndex: chapter.orderIndex,
                    revisionId: rev.id,
                    revisionIndex: rev.revisionIndex,
                    createdAt: rev.createdAt,
                    isActive: rev.id == activeId,
                    isConsumedLocked: lockedRevisionId != nil,
                    proseWordCount: AdaptationPlanValidator.wordCount(of: prose),
                    visualBlockCount: visuals.count,
                    previewSnippet: clipped,
                    origin: rev.origin
                )
            }
    }

    /// All chapter version rows for a book.
    func listBookVersionHistory(bookId: UUID) throws -> [ChapterVersionEntry] {
        guard let book = try manuscripts.loadBook(id: bookId) else {
            throw ManuscriptError.bookNotFound(bookId)
        }
        var rows: [ChapterVersionEntry] = []
        for chapter in book.chapters.sorted(by: { $0.orderIndex < $1.orderIndex }) {
            rows.append(contentsOf: try listChapterVersions(bookId: bookId, chapterId: chapter.id))
        }
        return rows
    }

    /// Restores a prior revision by copying its blocks into a new candidate → validate → activate.
    /// Consumed chapters are rejected (immutable ledger). Prior revision bodies are never mutated.
    @discardableResult
    func restoreRevision(
        bookId: UUID,
        chapterId: UUID,
        sourceRevisionId: UUID
    ) throws -> ChapterRevision {
        if try isChapterConsumed(bookId: bookId, chapterId: chapterId) {
            throw ManuscriptError.cannotMutateConsumedChapter(chapterId)
        }
        guard let book = try manuscripts.loadBook(id: bookId) else {
            throw ManuscriptError.bookNotFound(bookId)
        }
        guard let chapter = book.chapters.first(where: { $0.id == chapterId }) else {
            throw ManuscriptError.chapterNotFound(chapterId)
        }
        guard let source = chapter.revision(id: sourceRevisionId) else {
            throw ManuscriptError.revisionNotFound(sourceRevisionId)
        }
        let copiedBlocks: [ContentBlock] = source.blocks.enumerated().map { idx, block in
            ContentBlock(
                id: UUID(),
                kind: block.kind,
                text: block.text,
                orderIndex: block.orderIndex >= 0 ? block.orderIndex : idx
            )
        }
        var candidate = CandidateRevision(
            id: UUID(),
            bookId: bookId,
            chapterId: chapterId,
            proposedRevisionIndex: (chapter.revisions.map(\.revisionIndex).max() ?? -1) + 1,
            createdAt: Date(),
            blocks: copiedBlocks,
            status: .staged,
            rejectionReason: nil,
            origin: .restored(fromRevisionIndex: source.revisionIndex)
        )
        if let requirement = chapter.sourceGrounding {
            try SourceGrounding.validate(receipt: source.sourceReview, bookID: bookId, chapterID: chapterId,
                                         blocks: source.blocks, requirement: requirement)
            guard let prior = source.sourceReview, let base = chapter.activeRevision?.id else {
                throw SourceGroundingError.invalid("An unreviewed outline cannot restore a source-checked preview.")
            }
            // Exact text restore reuses the original source assessment, not a new AI claim.
            // Rebind only the expected current revision; content excludes fresh block UUIDs.
            candidate.sourceReview = SourceReviewReceipt(bookID: bookId, chapterID: chapterId, baseRevisionID: base,
                contentHash: prior.contentHash, sourceHash: prior.sourceHash, model: prior.model,
                promptVersion: prior.promptVersion, reviewedAt: prior.reviewedAt, response: prior.response,
                wordCutHash: prior.wordCutHash)
            candidate.origin?.sourceWordCut = source.origin?.sourceWordCut
        }
        try stageCandidate(candidate)
        return try activateCandidate(id: candidate.id)
    }

    // MARK: - Validation

    static func validateCandidateStructure(_ candidate: CandidateRevision) throws {
        if candidate.blocks.isEmpty {
            throw ManuscriptError.malformedCandidate("empty blocks")
        }
        for (idx, block) in candidate.blocks.enumerated() {
            if block.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw ManuscriptError.malformedCandidate("block \(idx) has empty text")
            }
        }
        if candidate.chapterId == UUID(uuidString: "00000000-0000-0000-0000-000000000000") {
            throw ManuscriptError.malformedCandidate("nil chapter id")
        }
    }
}
