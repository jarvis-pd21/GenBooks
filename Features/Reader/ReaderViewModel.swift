import Foundation
import SwiftUI
import UIKit
#if DEBUG
import CryptoKit
#endif

@MainActor
final class ReaderViewModel: ObservableObject {
    @Published private(set) var document: ReaderDocument?
    @Published private(set) var documentEpoch: Int = 0
    @Published private(set) var loadError: String?
    @Published private(set) var currentLocation: ReaderLocation?
    @Published private(set) var progress: Double = 0
    @Published private(set) var aiAdaptCallCountAtOpen: Int = -1
    @Published var searchQuery: String = "" {
        didSet {
            guard searchQuery != oldValue else { return }
            searchHits = []
            previewSearchHitIndex = nil
            activeSearchHitIndex = nil
            hasSubmittedSearch = false
        }
    }
    @Published private(set) var hasSubmittedSearch = false
    @Published private(set) var searchHits: [ReaderSearchHit] = []
    @Published private(set) var previewSearchHitIndex: Int?
    @Published var activeSearchHitIndex: Int?
    @Published var jumpToken: UUID?
    @Published var jumpUtf16: Int?
    /// Scrubbing should track the thumb instantly; discrete jumps animate.
    @Published private(set) var jumpAnimated: Bool = true
    @Published private(set) var restoreLocation: ReaderLocation?
    @Published private(set) var chapters: [(id: UUID, title: String, orderIndex: Int)] = []
    @Published private(set) var isReady = false

    // Wave 2 Books reading surface
    /// How far through the *current chapter* the reader is (0…1), used for "min left".
    @Published private(set) var chapterLocalProgress: Double = 0
    /// Per-chapter content counts, stamped with default pace; re-stamped on read.
    @Published private(set) var chapterContentCounts: [UUID: ReadingTimeEstimate] = [:]
    /// Where the reader was before the last scrub / TOC / search jump, for "Back to…".
    @Published private(set) var returnLocation: ReaderLocation?
    @Published private(set) var returnLocationChapterTitle: String = ""
    /// True while the scrubber thumb is down. Preview updates progress chrome only.
    @Published private(set) var isScrubbing = false
    private var a11yScrubCommitTask: Task<Void, Never>?

    // Phase 3 learning interactions
    @Published var activeSelection: ReaderTextSelection?
    @Published var showSelectionActions = false
    @Published var defineResult: DefinitionResult?
    @Published var showDefineSheet = false
    @Published var showAskSheet = false
    @Published var askSeedQuestion: String?
    @Published private(set) var aiAskCallCountAtOpen: Int = -1
    @Published var showNoteEditor = false
    @Published var noteDraft: String = ""
    @Published var noteColor: HighlightColor = .default
    /// Set when the editor is reworking a note that already exists on these words.
    @Published private(set) var noteEditTarget: NoteEditTarget?
    @Published private(set) var highlights: [HighlightAnnotation] = []
    @Published private(set) var notes: [NoteAnnotation] = []
    @Published private(set) var bookmarks: [NamedBookmark] = []
    @Published private(set) var highlightEpoch: Int = 0
    @Published var bannerMessage: String?
    @Published private(set) var consumedChapterIds: Set<UUID> = []

    // Phase 5 Living Book adaptation
    @Published var showFinishChapterConfirm = false
    @Published var showFeedbackSheet = false
    @Published var showAdaptationPlanSheet = false
    @Published private(set) var adaptationState: AdaptationPhaseState = .idle
    @Published private(set) var adaptationPlan: AdaptationPlan?
    var isBundledAdaptationPlan: Bool {
        guard let plan = adaptationPlan else { return false }
        return bundledPlanService?.planID == plan.id
    }
    @Published private(set) var adaptationError: String?
    @Published private(set) var nearChapterEnd = false
    @Published private(set) var canFinishCurrentChapter = false
    @Published var feedbackOverall: FeedbackOverallRating = .fine
    @Published var feedbackMoreOf: Set<FeedbackMoreTopic> = []
    @Published var feedbackLessOf: Set<FeedbackLessTopic> = []
    @Published var feedbackFreeText: String = ""
    @Published private(set) var isAdaptationBusy = false
    @Published private(set) var finishedChapterTitle: String = ""

    // Wave 2 generative
    @Published var showVersionHistory = false
    @Published var showRegenerateFromHere = false
    @Published private(set) var versionHistoryEntries: [ChapterVersionEntry] = []
    @Published private(set) var isVersionRestoring = false
    @Published private(set) var versionHistoryError: String?
    @Published var regenSelectedChapterId: UUID?
    @Published private(set) var regenPreview: RegenerationPreview?
    @Published private(set) var regenError: String?
    @Published private(set) var remainingReadingLabel: String = ""
    /// Normal AI sheets reset to Half; a fixed bundled example preserves full text.
    @Published var applyLengthPreset: AdaptationLengthPreset = .applyDefault
    /// When set, version history opens scoped to one chapter.
    @Published var versionHistoryFocusChapterId: UUID?

    // Regenerate from the nearest word
    @Published var showRegenerateFromWord = false
    @Published private(set) var wordAnchor: RegenerationWordAnchor?
    @Published var wordRegenIntents: Set<RegenerationIntent> = [.moreImages]
    @Published var wordRegenFreeText: String = ""
    @Published private(set) var wordRegenPreview: WordForwardRegenerationPreview?
    @Published private(set) var wordRegenError: String?
    @Published private(set) var wordRegenChapterLocked = false
    @Published private(set) var isSourceWordRegen = false
    @Published private(set) var sourceWordRegenState: SourceContinuationState?
    private var sourceSelectionAnchor: RegenerationWordAnchor?
    private var sourceWordBoundaryAvailable = false
    private var sourceWordStateLoadFailed = false
    #if DEBUG
    @Published private(set) var sourceContinuationOfflineProof: String?
    #endif
    var offlineSourceEvidenceForUI: String? {
        #if DEBUG
        return sourceContinuationOfflineProof
        #else
        return nil
        #endif
    }
    private var readingTimePreferences = ReadingTimePreferences.default

    @Published private(set) var book: Book
    let settings: ReaderSettingsStore
    private let versioning: ManuscriptVersioningService
    private let checkpoints: ReadingCheckpointStoring
    private let annotations: AnnotationStoring
    private let vocabulary: VocabularyStoring
    private let bookmarkStore: BookmarkStoring
    private let ai: MockAIService
    private var askService: any AIService
    let askSession: AskSession
    private let feedbackStore: FeedbackStoring
    private let preferenceStore: ReaderPreferenceStoring
    private var adaptationAI: any AIService
    private var adaptationService: LivingBookAdaptationService?
    private var bundledPlanService: (planID: UUID, service: LivingBookAdaptationService)?
    private var saveTask: Task<Void, Never>?
    private var existingCheckpointId: UUID?
    private var readableRevisions: [UUID: ChapterRevision] = [:] {
        didSet {
            chapterContentCounts = readableRevisions.mapValues { ReadingTimeEstimator.estimate(blocks: $0.blocks) }
        }
    }
    private var ignoreScrollSavesUntil: Date = .distantPast
    /// When set, discard stale pre-jump scroll callbacks that would snap chapter chrome back.
    private var pendingJumpUtf16: Int?
    /// Continue/step commits the checkpoint itself; suppress only the next accepted
    /// renderer settle so that synthetic search navigation cannot consume skipped
    /// chapters. Ordinary reading callbacks after that resume normal consumption.
    private var suppressNextSearchSettleConsumption = false
    private var selectionClearTask: Task<Void, Never>?
    private var defineEnrichTask: Task<Void, Never>?

    init(
        book: Book,
        versioning: ManuscriptVersioningService,
        checkpoints: ReadingCheckpointStoring,
        settings: ReaderSettingsStore,
        annotations: AnnotationStoring,
        vocabulary: VocabularyStoring,
        bookmarks: BookmarkStoring,
        feedbackStore: FeedbackStoring,
        preferenceStore: ReaderPreferenceStoring,
        ai: MockAIService = MockAIService(),
        askService: (any AIService)? = nil,
        adaptationAI: (any AIService)? = nil
    ) {
        self.book = book
        self.versioning = versioning
        self.checkpoints = checkpoints
        self.settings = settings
        self.annotations = annotations
        self.vocabulary = vocabulary
        self.bookmarkStore = bookmarks
        self.feedbackStore = feedbackStore
        self.preferenceStore = preferenceStore
        self.ai = ai
        var resolvedAsk: any AIService = askService ?? ai
        var resolvedAdaptation: any AIService = adaptationAI ?? resolvedAsk
        #if DEBUG
        if SourceContinuationTrial.requested() {
            // Retain the resolver's actual model decision, including a closed
            // wrapper. Missing/non-trial injections must never reopen with defaults.
            resolvedAsk = resolvedAsk as? SourceContinuationTrialService ?? SourceContinuationTrialService(live: nil)
            resolvedAdaptation = adaptationAI as? SourceContinuationTrialService ?? SourceContinuationTrialService(live: nil)
        } else if let fixtureID = Self.offlineSourceFixtureID {
            resolvedAdaptation = SourceContinuationOfflineAI(fixtureID: fixtureID)
        }
        #endif
        self.askService = resolvedAsk
        self.askSession = AskSession(ai: resolvedAsk)
        self.adaptationAI = resolvedAdaptation
    }

    /// Re-resolve Ask (Luna) + adaptation (Astra) after key save/remove or model change.
    /// Honors `-uitesting` / `-useMockAI` / `-phase4MockAsk` / `-phase5AdaptationDemo` → Mock.
    func refreshAIServices(
        keyStore: APIKeyStoring,
        modelPrefs: AIModelPreferenceStore,
        session: URLSession = .shared,
        processInfo: ProcessInfo = .processInfo
    ) {
        #if DEBUG
        // The isolated fixture must remain offline even if Settings refreshes services.
        if !SourceContinuationTrial.requested(arguments: processInfo.arguments, environment: processInfo.environment),
           let fixtureID = Self.offlineSourceFixtureID {
            let mock = SourceContinuationOfflineAI(fixtureID: fixtureID)
            adaptationAI = mock
            if let service = adaptationService { Task { await service.updateAI(mock) } }
            return
        }
        #endif
        let pair = AIServiceResolver.makeAskAndAdaptation(
            keyStore: keyStore,
            askModel: modelPrefs.askModel,
            generationModel: modelPrefs.generationModel,
            session: session,
            processInfo: processInfo
        )
        askService = pair.ask
        adaptationAI = pair.adaptation
        askSession.updateAI(pair.ask)
        if let service = adaptationService {
            Task { await service.updateAI(pair.adaptation) }
        } else if isReady {
            adaptationService = LivingBookAdaptationService(
                versioning: versioning,
                feedbackStore: feedbackStore,
                preferenceStore: preferenceStore,
                ai: pair.adaptation
            )
        }
    }

    /// Test/helper: currently wired Ask service type name (Mock vs Live).
    var askServiceTypeName: String {
        String(describing: type(of: askService))
    }

    /// Test/helper: currently wired adaptation service type name.
    var adaptationServiceTypeName: String {
        String(describing: type(of: adaptationAI))
    }

    func open() async {
        ai.resetCallCount()
        do {
            #if DEBUG
            if let fixtureID = Self.offlineSourceFixtureID {
                book = try await openOfflineSourceFixture(id: fixtureID)
            }
            #endif
            var revisions: [UUID: ChapterRevision] = [:]
            let ordered = book.chapters.sorted { $0.orderIndex < $1.orderIndex }
            chapters = ordered.map { ($0.id, $0.title, $0.orderIndex) }
            // Friend-demo: Quran is 114 surahs / ~2MB. Do NOT re-decode the manuscript
            // once per chapter (was 114× disk loads). Use the already-loaded book and
            // only fall back to the service when ledger pins are missing in-memory.
            let ledger = try await versioning.ledgerSnapshot()
            let pinnedByChapter = Dictionary(
                uniqueKeysWithValues: ledger
                    .filter { $0.bookId == book.id }
                    .map { ($0.chapterId, $0.revisionId) }
            )
            for chapter in ordered {
                if let pinnedId = pinnedByChapter[chapter.id],
                   let pinned = chapter.revision(id: pinnedId) {
                    revisions[chapter.id] = pinned
                } else if pinnedByChapter[chapter.id] != nil {
                    revisions[chapter.id] = try await versioning.readableRevision(
                        bookId: book.id,
                        chapterId: chapter.id
                    )
                } else if let active = chapter.activeRevision {
                    revisions[chapter.id] = active
                } else {
                    revisions[chapter.id] = try await versioning.readableRevision(
                        bookId: book.id,
                        chapterId: chapter.id
                    )
                }
            }
            readableRevisions = revisions
            aiAdaptCallCountAtOpen = ai.adaptCallCount
            aiAskCallCountAtOpen = ai.askCallCount
            rebuildDocument()
            reloadAnnotations()
            reloadBookmarks()

            if let saved = try checkpoints.loadCheckpoint(bookId: book.id),
               let location = saved.asLocation(progress: 0) {
                existingCheckpointId = saved.id
                if document?.anchor(blockId: location.blockId) != nil {
                    restoreLocation = location
                    currentLocation = location
                    progress = location.progress
                }
            }
            isReady = true

            adaptationService = LivingBookAdaptationService(
                versioning: versioning,
                feedbackStore: feedbackStore,
                preferenceStore: preferenceStore,
                ai: adaptationAI
            )
            // Refresh consumed set from ledger
            if ProcessInfo.processInfo.arguments.contains("-resetConsumedLedger") {
                try? await versioning.resetConsumedLedgerForUITesting()
                consumedChapterIds = []
            } else if let ledger = try? await versioning.ledgerSnapshot() {
                consumedChapterIds = Set(ledger.filter { $0.bookId == book.id }.map(\.chapterId))
            }
            refreshFinishAffordances()

            #if DEBUG
            presentSourceContinuationTrialSelection()
            if Self.offlineSourceFixtureID != nil {
                await refreshSourceContinuationOfflineProof()
                if ProcessInfo.processInfo.arguments.contains("-sourceContinuationDemoSelection") {
                    presentOfflineSourceSelection()
                }
            }
            #endif

            if ProcessInfo.processInfo.arguments.contains("-phase3DemoSelection")
                || ProcessInfo.processInfo.arguments.contains("-wordRegenDemoSelection")
                || ProcessInfo.processInfo.arguments.contains("-phase4MockAsk") {
                presentDemoSelectionIfPossible()
            }
            if ProcessInfo.processInfo.arguments.contains("-phase4MockAsk") {
                // Deterministic Ask UI path for smoke screenshot — never blocks first paint.
                Task { await self.presentAskForDemo() }
            }
            if ProcessInfo.processInfo.arguments.contains("-phase5AdaptationDemo") {
                Task { await self.runPhase5AdaptationDemo() }
            }
            if ProcessInfo.processInfo.arguments.contains(ArgentinaQualityRegen.launchArgument) {
                Task { await self.runArgentinaQualityRegen() }
            }
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// A new TextKit coordinator must restore the latest reading place, not replay
    /// an earlier TOC/search/scrubber command that the previous view already handled.
    /// The reader remains loaded across the mode switch; its text checkpoint and
    /// return-to-previous-place affordance keep their independent meanings.
    func prepareForTextRemount() {
        jumpToken = nil
        jumpUtf16 = nil
        jumpAnimated = false
        pendingJumpUtf16 = nil
        a11yScrubCommitTask?.cancel()
        isScrubbing = false
        ignoreScrollSavesUntil = .distantPast
        if let currentLocation { restoreLocation = currentLocation }
        // Restoring a viewport is not evidence that skipped chapters were read.
        suppressNextSearchSettleConsumption = true
    }

    func rebuildDocumentPreservingLocation() {
        let previous = currentLocation
        rebuildDocument()
        highlightEpoch += 1
        if let previous, let utf16 = document?.utf16Location(for: previous) {
            jumpAnimated = false
            jumpUtf16 = utf16
            jumpToken = UUID()
        }
    }

    private func rebuildDocument() {
        let doc = ReaderDocumentBuilder.build(
            book: book,
            readableRevisions: readableRevisions,
            typography: settings.typography
        )
        document = doc
        documentEpoch += 1
    }

    func reloadAnnotations() {
        do {
            let loadedHighlights = try annotations.loadHighlights(bookId: book.id)
            let loadedNotes = try annotations.loadNotes(bookId: book.id)
            highlights = loadedHighlights
            notes = loadedNotes
            highlightEpoch += 1
        } catch {
            flash("Couldn’t refresh notes. Reopen Notes to retry.")
        }
    }

    func reloadBookmarks() {
        do { bookmarks = try bookmarkStore.loadBookmarks(bookId: book.id) }
        catch { flash("Couldn’t refresh bookmarks. Reopen Bookmarks to retry.") }
    }

    var persistentHighlightPaint: [(NSRange, UIColor)] {
        guard let document else { return [] }
        return highlights.compactMap { highlight in
            guard let range = ReaderSelectionMapper.documentRange(for: highlight, in: document) else { return nil }
            return (range, Self.uiColor(for: highlight.color))
        }
    }

    static func uiColor(for color: HighlightColor) -> UIColor {
        NoteColorPalette.uiColor(for: color)
    }

    func handleLocationChange(_ location: ReaderLocation) {
        if isScrubbing { return }
        if Date() < ignoreScrollSavesUntil {
            return
        }
        if let pending = pendingJumpUtf16, let document {
            let actual = document.utf16Location(for: location) ?? 0
            // Ignore one stale callback from the pre-jump viewport (common after TOC dismiss).
            if abs(actual - pending) > 240 {
                pendingJumpUtf16 = nil
                return
            }
            pendingJumpUtf16 = nil
        }
        currentLocation = location
        progress = location.progress
        scheduleCheckpointSave(location)
        refreshFinishAffordances()
        let suppressConsumption = suppressNextSearchSettleConsumption
        suppressNextSearchSettleConsumption = false
        if !suppressConsumption {
            Task { await maybeConsumeChapter(for: location) }
        }
    }

    func handleSelectionChange(_ range: NSRange?) {
        selectionClearTask?.cancel()
        guard let range, range.length > 0, let document,
              let selection = ReaderSelectionMapper.selection(in: document, documentRange: range) else {
            // Delay clear so tapping an action button doesn't lose selection immediately.
            selectionClearTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard let self, !Task.isCancelled else { return }
                if !self.showSelectionActions && !self.showDefineSheet && !self.showAskSheet && !self.showNoteEditor {
                    self.activeSelection = nil
                }
            }
            return
        }
        activeSelection = selection
        showSelectionActions = true
    }

    private func scheduleCheckpointSave(_ location: ReaderLocation) {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self, !Task.isCancelled else { return }
            await self.persist(location)
        }
    }

    func persist(_ location: ReaderLocation) async {
        let checkpoint = ReadingCheckpoint.from(
            location: location,
            bookId: book.id,
            id: existingCheckpointId ?? UUID(),
            updatedAt: Date()
        )
        do {
            try checkpoints.saveCheckpoint(checkpoint)
            existingCheckpointId = checkpoint.id
        } catch {
            // Soft-fail: reading continues even if checkpoint write fails.
        }
    }

    func persistNow() async {
        guard let currentLocation else { return }
        await persist(currentLocation)
    }

    /// Marks prior chapters consumed once the reader has moved into a later chapter.
    func maybeConsumeChapter(for location: ReaderLocation) async {
        let ordered = chapters.sorted { $0.orderIndex < $1.orderIndex }
        guard let currentIdx = ordered.firstIndex(where: { $0.id == location.chapterId }) else { return }
        for chapter in ordered.prefix(currentIdx) {
            if consumedChapterIds.contains(chapter.id) { continue }
            guard let revision = readableRevisions[chapter.id] else { continue }
            do {
                try await versioning.consume(bookId: book.id, chapterId: chapter.id, revisionId: revision.id)
                consumedChapterIds.insert(chapter.id)
            } catch {
                // Keep UI/Ask lock state ledger-backed. A failed write or revision mismatch
                // must not make unread content appear consumed in memory.
                flash("Couldn’t lock \(chapter.title) as read")
            }
        }
    }

    func jumpToChapter(id: UUID) {
        guard let document,
              let start = document.chapterStarts.first(where: { $0.chapterId == id }) else { return }
        rememberReturnLocation(movingTo: start.utf16Location)
        pendingJumpUtf16 = start.utf16Location
        ignoreScrollSavesUntil = Date().addingTimeInterval(1.2)
        jumpAnimated = true
        jumpUtf16 = start.utf16Location
        jumpToken = UUID()
        if let location = document.location(atUtf16: start.utf16Location) {
            currentLocation = location
            progress = location.progress
            scheduleCheckpointSave(location)
            refreshFinishAffordances()
            Task { await maybeConsumeChapter(for: location) }
        }
    }

    func jumpToBlock(blockId: UUID, utf16OffsetInBlock: Int = 0) {
        guard let document, let anchor = document.anchor(blockId: blockId) else { return }
        let utf16 = anchor.utf16Range.lowerBound + min(max(0, utf16OffsetInBlock), max(0, anchor.utf16Range.count - 1))
        rememberReturnLocation(movingTo: utf16)
        ignoreScrollSavesUntil = Date().addingTimeInterval(0.6)
        jumpAnimated = true
        jumpUtf16 = utf16
        jumpToken = UUID()
        if let location = document.location(atUtf16: utf16) {
            currentLocation = location
            progress = location.progress
            scheduleCheckpointSave(location)
        }
    }

    func runSearch() {
        hasSubmittedSearch = !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        previewSearchHitIndex = nil
        activeSearchHitIndex = nil
        guard let document else {
            searchHits = []
            return
        }
        let range: Range<Int>? = settings.searchScope == .readSoFar
            ? 0..<readSoFarSearchUpperBound
            : nil
        searchHits = document.search(query: searchQuery, in: range)
    }

    /// The spoiler-safe boundary includes the contiguous consumed prefix and text
    /// strictly behind the current checkpoint/reading place. It rounds backward
    /// to a whole-word boundary rather than leaking the rest of the current block.
    var readSoFarSearchUpperBound: Int {
        guard let document else { return 0 }
        var consumedPrefixEnd = 0
        for chapter in chapters.sorted(by: { $0.orderIndex < $1.orderIndex }) {
            guard consumedChapterIds.contains(chapter.id) else { break }
            let chapterEnd = document.anchors
                .filter { $0.chapterId == chapter.id }
                .map(\.utf16Range.upperBound)
                .max() ?? consumedPrefixEnd
            consumedPrefixEnd = max(consumedPrefixEnd, chapterEnd)
        }
        let readingBoundary: Int
        if let currentLocation,
           let utf16 = document.utf16Location(for: currentLocation) {
            readingBoundary = document.searchBoundary(atOrBeforeUtf16: utf16)
        } else {
            readingBoundary = 0
        }
        return min(document.length, max(consumedPrefixEnd, readingBoundary))
    }

    func setSearchScope(_ scope: BookSearchScope) {
        guard settings.searchScope != scope else { return }
        settings.searchScope = scope
        if searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            searchHits = []
            previewSearchHitIndex = nil
            activeSearchHitIndex = nil
        } else {
            runSearch()
        }
    }

    /// Selecting a result is preview-only: no renderer jump, progress update,
    /// checkpoint save, consumed-ledger write, or Back-to state is changed.
    func previewSearchHit(at index: Int) {
        guard searchHits.indices.contains(index) else { return }
        previewSearchHitIndex = index
    }

    var previewedSearchHit: ReaderSearchHit? {
        guard let previewSearchHitIndex,
              searchHits.indices.contains(previewSearchHitIndex) else { return nil }
        return searchHits[previewSearchHitIndex]
    }

    /// Explicit confirmation turns the preview into a committed reading jump.
    @discardableResult
    func continueFromSearchPreview() -> Bool {
        guard let previewSearchHitIndex,
              searchHits.indices.contains(previewSearchHitIndex) else { return false }
        commitSearchHit(at: previewSearchHitIndex)
        return true
    }

    private func commitSearchHit(at index: Int) {
        guard searchHits.indices.contains(index) else { return }
        activeSearchHitIndex = index
        previewSearchHitIndex = index
        let hit = searchHits[index]
        rememberReturnLocation(movingTo: hit.range.location)
        ignoreScrollSavesUntil = Date().addingTimeInterval(0.6)
        suppressNextSearchSettleConsumption = true
        jumpAnimated = true
        jumpUtf16 = hit.range.location
        jumpToken = UUID()
        if let document,
           let location = document.location(atUtf16: hit.range.location) {
            currentLocation = location
            progress = location.progress
            scheduleCheckpointSave(location)
            refreshFinishAffordances()
        }
    }

    var activeSearchRange: NSRange? {
        guard let activeSearchHitIndex, searchHits.indices.contains(activeSearchHitIndex) else { return nil }
        return searchHits[activeSearchHitIndex].range
    }

    var progressPercentLabel: String {
        String(format: "%.0f%%", progress * 100)
    }

    // MARK: - Wave 2 Books reading chrome

    var currentChapterId: UUID? {
        currentLocation?.chapterId ?? chapters.first?.id
    }

    /// Whole-chapter estimate at the reader's configured pace.
    func chapterEstimate(_ chapterId: UUID) -> ReadingTimeEstimate {
        (chapterContentCounts[chapterId] ?? .zero).applying(settings.readingTimePreferences)
    }

    /// Apple Books' signature affordance: how much of *this chapter* is still ahead.
    var timeLeftInChapter: ReadingTimeEstimate {
        guard let chapterId = currentChapterId else { return .zero }
        return chapterEstimate(chapterId).scaled(by: 1 - chapterLocalProgress)
    }

    var timeLeftLabel: String {
        "\(timeLeftInChapter.compactLabel) left in chapter"
    }

    /// Thumb moved. While the finger is down this updates chrome only — no jump,
    /// checkpoint, or consumption. A lone accessibility/UITest adjust commits
    /// once after a short delay if no drag-begin arrives.
    func scrubberChanged(_ value: Double) {
        let clamped = min(1, max(0, value))
        progress = clamped
        guard !isScrubbing else { return }
        a11yScrubCommitTask?.cancel()
        a11yScrubCommitTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard let self, !Task.isCancelled, !self.isScrubbing else { return }
            self.seekToProgress(self.progress)
        }
    }

    /// `Slider.onEditingChanged`: begin = preview-only; end = one committed seek.
    func scrubberEditingChanged(_ editing: Bool) {
        if editing {
            isScrubbing = true
            a11yScrubCommitTask?.cancel()
            a11yScrubCommitTask = nil
            return
        }
        isScrubbing = false
        a11yScrubCommitTask?.cancel()
        a11yScrubCommitTask = nil
        seekToProgress(progress)
    }

    /// Books-like scrubber: jump to an approximate position in the whole book.
    ///
    /// Call only on finger-up / VoiceOver adjust — not on every drag tick.
    /// Deliberately does **not** advance the consumed ledger. Scrubbing is
    /// exploratory, and consumption is irreversible — only reading through a
    /// chapter or an explicit chapter jump may lock the past.
    func seekToProgress(_ value: Double) {
        guard let document, document.length > 1 else { return }
        let clamped = min(1, max(0, value))
        let utf16 = document.utf16Location(forProgress: clamped)
        rememberReturnLocation(movingTo: utf16)
        ignoreScrollSavesUntil = Date().addingTimeInterval(0.45)
        jumpAnimated = false
        jumpUtf16 = utf16
        jumpToken = UUID()
        if let location = document.location(atUtf16: utf16) {
            currentLocation = location
            progress = location.progress
            scheduleCheckpointSave(location)
        } else {
            progress = clamped
        }
        refreshFinishAffordances()
    }

    /// Snapshots the reader's position so a long jump is undoable.
    ///
    /// Only the *first* jump of a navigation burst is remembered, so stepping
    /// through search hits keeps pointing back at where reading actually stopped.
    private func rememberReturnLocation(movingTo destinationUtf16: Int) {
        guard returnLocation == nil, let document else { return }
        // Before the first scroll settles there is no recorded location, but the
        // reader is still somewhere — the start of the book.
        guard let from = currentLocation ?? document.location(atUtf16: 0, visibleProgress: 0) else { return }
        let origin = document.utf16Location(for: from) ?? 0
        let minimumJump = max(400, document.length / 50)
        guard abs(destinationUtf16 - origin) >= minimumJump else { return }
        returnLocation = from
        returnLocationChapterTitle = chapters.first(where: { $0.id == from.chapterId })?.title
            ?? currentChapterTitle
    }

    var returnLocationLabel: String {
        returnLocationChapterTitle.isEmpty ? "Back" : "Back to \(returnLocationChapterTitle)"
    }

    func returnToRememberedLocation() {
        guard let target = returnLocation, let document,
              let utf16 = document.utf16Location(for: target) else {
            returnLocation = nil
            return
        }
        returnLocation = nil
        returnLocationChapterTitle = ""
        ignoreScrollSavesUntil = Date().addingTimeInterval(0.6)
        jumpAnimated = true
        jumpUtf16 = utf16
        jumpToken = UUID()
        currentLocation = target
        progress = target.progress
        scheduleCheckpointSave(target)
        refreshFinishAffordances()
    }

    func dismissReturnLocation() {
        returnLocation = nil
        returnLocationChapterTitle = ""
    }

    var searchStatusLabel: String {
        guard !searchHits.isEmpty else { return "No matches" }
        guard let activeSearchHitIndex,
              searchHits.indices.contains(activeSearchHitIndex) else {
            return searchResultsLabel
        }
        return "\(activeSearchHitIndex + 1) of \(searchHits.count)"
    }

    var searchResultsLabel: String {
        searchHits.count == 1 ? "1 match" : "\(searchHits.count) matches"
    }

    /// Step through search results, wrapping at either end.
    func advanceSearch(by delta: Int) {
        guard !searchHits.isEmpty else { return }
        let count = searchHits.count
        let next = ((activeSearchHitIndex ?? 0) + delta) % count
        commitSearchHit(at: next < 0 ? next + count : next)
    }

    func clearSearch() {
        searchQuery = ""
        hasSubmittedSearch = false
        searchHits = []
        previewSearchHitIndex = nil
        activeSearchHitIndex = nil
    }

    var currentChapterTitle: String {
        guard let currentLocation,
              let match = chapters.first(where: { $0.id == currentLocation.chapterId }) else {
            return chapters.first?.title ?? book.title
        }
        return match.title
    }

    // MARK: - Selection actions

    func performDefine() {
        guard let activeSelection else { return }
        defineEnrichTask?.cancel()
        var result = DefineService.define(
            term: activeSelection.selectedText,
            sentenceContext: activeSelection.originalSentence,
            surroundingContext: activeSelection.surroundingContext
        )
        // Kick Luna enrichment when a key may be present; local lexicon already stands alone.
        let shouldEnrich = !DefineService.prefersDeterministicRich()
            && (result.source == .offlineFallback || result.source == .localLexicon)
        // Spinner only when we lack a full local entry; lexicon already stands alone.
        if shouldEnrich && result.source == .offlineFallback {
            result.isEnriching = true
        }
        defineResult = result
        showDefineSheet = true
        showSelectionActions = false

        guard shouldEnrich else { return }
        let request = DefineWordRequest(
            term: result.term,
            sentenceContext: activeSelection.originalSentence,
            surroundingContext: activeSelection.surroundingContext,
            chapterTitle: activeSelection.chapterTitle,
            bookTitle: book.title
        )
        let baseline = result
        let askModel = AIModelPreferenceStore().askModel
        defineEnrichTask = Task { [weak self] in
            guard let self else { return }
            let enriched = await DefineService.enrich(
                request: request,
                baseline: baseline,
                modelPreference: askModel
            )
            guard !Task.isCancelled else { return }
            await MainActor.run {
                // Only apply if the sheet is still showing the same term.
                if self.defineResult?.term == baseline.term {
                    self.defineResult = enriched
                }
            }
        }
    }

    /// `autoSend` is for arrivals that already carry an explicit question (Define
    /// → Explain in context). Everything else opens on an empty composer with
    /// one-tap suggestion bubbles.
    func performAsk(seedQuestion: String? = nil, autoSend: Bool = false) {
        #if DEBUG
        guard !refuseTrialAuxiliaryAction() else { return }
        #endif
        askSeedQuestion = seedQuestion
        prepareAskSession(seedQuestion: seedQuestion)
        showAskSheet = true
        showSelectionActions = false
        showDefineSheet = false
        guard autoSend, seedQuestion != nil else { return }
        Task { await askSession.sendSeedQuestion() }
    }

    /// Opening BookBot from the overflow menu is a generic entry: the recap
    /// opener is one of the chips rather than a pre-filled field.
    func performAskFromToolbar() {
        performAsk()
    }

    func performExplainInContext() {
        let term = defineResult?.term ?? activeSelection?.selectedText
        let q: String
        if let term, !term.isEmpty {
            q = "Explain “\(term)” in the context of this passage and chapter."
        } else {
            q = "Explain this passage in context."
        }
        performAsk(seedQuestion: q, autoSend: true)
    }

    private func prepareAskSession(seedQuestion: String?) {
        askSession.configure(
            seedQuestion: seedQuestion,
            selectedText: activeSelection?.selectedText,
            buildRequest: { [weak self] question, allowSpoilers in
                self?.makeAskRequest(question: question, allowUnreadSpoilers: allowSpoilers)
                    ?? AskRequest(
                        userQuestion: question,
                        bookTitle: "Unknown",
                        bookAuthor: "Unknown",
                        consumedContext: "",
                        allowUnreadSpoilers: allowSpoilers
                    )
            }
        )
    }

    func makeAskRequest(question: String, allowUnreadSpoilers: Bool) -> AskRequest {
        let currentId = currentLocation?.chapterId ?? activeSelection?.chapterId
        let ordered = book.chapters.sorted { $0.orderIndex < $1.orderIndex }
        let slices: [AskContextBuilder.ReadingSlice] = ordered.compactMap { chapter in
            guard let revision = readableRevisions[chapter.id] else { return nil }
            return AskContextBuilder.ReadingSlice(
                chapterId: chapter.id,
                title: chapter.title,
                orderIndex: chapter.orderIndex,
                revisionId: revision.id,
                plainText: AskContextBuilder.plainText(from: revision),
                isConsumed: consumedChapterIds.contains(chapter.id),
                isCurrent: chapter.id == currentId
            )
        }
        let notesBit: String? = {
            let relevant = notes.prefix(5).map { "• \($0.chapterTitle): \($0.body)" }
            let qs = vocabularyEntriesPreview()
            let joined = (relevant + qs).joined(separator: "\n")
            return joined.isEmpty ? nil : joined
        }()
        let prefs = "font \(Int(settings.fontSize))pt, theme \(settings.colorScheme.rawValue)"
        let forceMock = AIServiceResolver.prefersMock()
            || ProcessInfo.processInfo.arguments.contains("-phase4MockAsk")
        return AskContextBuilder.buildRequest(
            question: question,
            book: book,
            slices: slices,
            selectedText: activeSelection?.selectedText,
            surroundingContext: activeSelection?.surroundingContext ?? activeSelection?.originalSentence,
            currentChapterId: currentId,
            notesAndQuestions: notesBit,
            readerPreferencesSummary: prefs,
            allowUnreadSpoilers: allowUnreadSpoilers,
            forceMock: forceMock
        )
    }

    private func vocabularyEntriesPreview() -> [String] {
        let entries = (try? vocabulary.load(bookId: book.id)) ?? []
        return entries.prefix(5).map { "• vocab “\($0.phrase)”: \($0.definition)" }
    }

    private func presentAskForDemo() async {
        #if DEBUG
        guard !refuseTrialAuxiliaryAction() else { return }
        #endif
        guard activeSelection != nil else { return }
        prepareAskSession(seedQuestion: "What does this mean in context?")
        showSelectionActions = false
        showAskSheet = true
        // Auto-send once for deterministic screenshot content.
        if askSession.messages.filter({ $0.role == .assistant }).isEmpty {
            await askSession.sendSeedQuestion()
        }
    }

    func performLearn() {
        guard let activeSelection else { return }
        let definition = DefineService.define(
            term: activeSelection.selectedText,
            sentenceContext: activeSelection.originalSentence,
            surroundingContext: activeSelection.surroundingContext
        ).definition
        let entry = VocabularyEntry(
            id: UUID(),
            bookId: book.id,
            bookTitle: book.title,
            chapterId: activeSelection.chapterId,
            chapterTitle: activeSelection.chapterTitle,
            revisionId: activeSelection.revisionId,
            blockId: activeSelection.range.blockId,
            phrase: activeSelection.selectedText,
            definition: definition,
            originalSentence: activeSelection.originalSentence,
            surroundingContext: activeSelection.surroundingContext,
            note: nil,
            isKnown: false,
            createdAt: Date(),
            updatedAt: Date()
        )
        do {
            try vocabulary.save(entry)
            flash("Saved to Words")
        } catch {
            flash("Couldn’t save word")
        }
        showSelectionActions = false
    }

    /// Colour mark with no body — exactly what the note editor writes when the body is
    /// empty. No longer has its own button; kept as the direct entry point for tests and
    /// the `-phase3*` demo launch arguments.
    func performHighlight(color: HighlightColor = .default) {
        guard activeSelection != nil else { return }
        noteEditTarget = nil
        noteColor = color
        noteDraft = ""
        saveNoteFromDraft()
        showSelectionActions = false
    }

    func performBookmark(customTitle: String? = nil) {
        guard let activeSelection, let document else { return }
        guard let anchor = document.anchor(blockId: activeSelection.range.blockId) else {
            flash("Couldn’t place bookmark")
            return
        }
        // Offsets are into the block's *display* text in the flattened document.
        let full = document.attributedText.string as NSString
        let blockRange = NSRange(location: anchor.utf16Range.lowerBound, length: anchor.utf16Range.count)
        let blockText = full.substring(with: blockRange)
        let pin = BookmarkAnchorResolver.nearestWordPin(
            blockText: blockText,
            selectionStartUtf16: activeSelection.range.utf16Start,
            selectedText: activeSelection.selectedText
        )
        let titleSource = customTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title: String
        if let titleSource, !titleSource.isEmpty {
            title = titleSource
        } else {
            title = NamedBookmark.defaultTitle(
                chapterTitle: activeSelection.chapterTitle,
                snippet: pin.snippet
            )
        }
        let bookmark = NamedBookmark(
            id: UUID(),
            bookId: book.id,
            chapterId: activeSelection.chapterId,
            chapterTitle: activeSelection.chapterTitle,
            revisionId: activeSelection.revisionId,
            blockId: activeSelection.range.blockId,
            utf16Offset: pin.utf16Offset,
            title: title,
            snippet: pin.snippet,
            createdAt: Date(),
            updatedAt: Date()
        )
        do {
            try bookmarkStore.saveBookmark(bookmark)
            reloadBookmarks()
            flash("Bookmark saved")
        } catch {
            flash("Couldn’t save bookmark")
        }
        showSelectionActions = false
    }

    func renameBookmark(id: UUID, title: String) {
        do {
            try bookmarkStore.renameBookmark(id: id, bookId: book.id, title: title)
            reloadBookmarks()
            flash("Bookmark renamed")
        } catch {
            flash("Couldn’t rename bookmark")
        }
    }

    func deleteBookmark(id: UUID) {
        do {
            try bookmarkStore.deleteBookmark(id: id, bookId: book.id)
            reloadBookmarks()
        } catch {
            flash("Couldn’t delete bookmark")
        }
    }

    func jumpToBookmark(_ bookmark: NamedBookmark) {
        jumpToBlock(blockId: bookmark.blockId, utf16OffsetInBlock: bookmark.utf16Offset)
    }

    /// Every note row currently on this book, notes and colour marks alike.
    var noteRows: [NoteRow] {
        NoteRowBuilder.rows(highlights: highlights, notes: notes)
    }

    /// Drives Note vs Edit Note on the selection sheet.
    var selectionHasExistingNote: Bool {
        guard let activeSelection else { return false }
        return NoteRowBuilder.target(
            highlights: highlights,
            notes: notes,
            overlapping: activeSelection.range,
            chapterId: activeSelection.chapterId,
            revisionId: activeSelection.revisionId
        ) != nil
    }

    /// Notes are the one annotation path: this opens a new note on the selection, or
    /// reopens the note already on those words so a second mark never piles up.
    func beginNote() {
        let target = activeSelection.flatMap { selection in
            NoteRowBuilder.target(
                highlights: highlights,
                notes: notes,
                overlapping: selection.range,
                chapterId: selection.chapterId,
                revisionId: selection.revisionId
            )
        }
        openNoteEditor(target: target)
        showSelectionActions = false
    }

    /// Tapping a coloured passage in the reader reopens its note — the note-centric
    /// counterpart to selecting fresh text.
    func handleTapAtDocumentOffset(_ offset: Int) {
        guard !showNoteEditor, !showSelectionActions, !showDefineSheet, !showAskSheet else { return }
        guard let document else { return }
        let candidates: [(NSRange, NoteEditTarget)] = highlights.compactMap { highlight in
            guard let range = ReaderSelectionMapper.documentRange(for: highlight, in: document) else { return nil }
            let note = notes.first {
                $0.chapterId == highlight.chapterId
                    && $0.revisionId == highlight.revisionId
                    && $0.range == highlight.range
            }
            return (range, NoteEditTarget(highlight: highlight, note: note))
        }
        // Tightest range wins, so a note inside a longer mark still opens its own note.
        guard let hit = candidates
            .filter({ NSLocationInRange(offset, $0.0) })
            .min(by: { $0.0.length < $1.0.length })
        else { return }

        if let selection = ReaderSelectionMapper.selection(in: document, documentRange: hit.0) {
            activeSelection = selection
        }
        openNoteEditor(target: hit.1)
    }

    private func openNoteEditor(target: NoteEditTarget?) {
        noteEditTarget = target
        noteDraft = target?.body ?? ""
        noteColor = target?.color ?? .default
        showNoteEditor = true
    }

    /// Saves the one note record set. An empty body is legitimate: it leaves a colour mark
    /// on the passage, which is what the old standalone Highlight action used to produce.
    func saveNoteFromDraft() {
        do {
            try saveNoteFromEditor()
        } catch {
            flash("Couldn’t save note")
        }
    }

    /// The sheet catches failures without losing the draft or dismissing itself.
    func saveNoteFromEditor() throws {
        guard let activeSelection else { return }
        let row = noteEditTarget?.row ?? NoteRow(
            id: UUID(), bookId: book.id, chapterId: activeSelection.chapterId,
            chapterTitle: activeSelection.chapterTitle, revisionId: activeSelection.revisionId,
            range: activeSelection.range, selectedText: activeSelection.selectedText,
            color: noteColor, note: nil, createdAt: Date())
        try annotations.saveNotePassage(row, body: noteDraft, color: noteColor)
        reloadAnnotations()
        flash(noteDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              ? "\(noteColor.displayName) mark saved" : "Note saved")
        dismissNoteEditor()
    }

    func deleteEditingNote() throws {
        guard let row = noteEditTarget?.row else { return }
        try annotations.deleteNotePassage(row)
        reloadAnnotations()
        flash("Note deleted")
        dismissNoteEditor()
    }

    func dismissNoteEditor() {
        showNoteEditor = false
        noteEditTarget = nil
    }

    func presentDemoSelectionIfPossible() {
        guard let document else { return }
        // Word-regen demos must land in unread text; Geography lives in chapter 1 and is
        // often already ledger-locked by earlier UITest navigation (Search Continue / TOC).
        let preferUnread = ProcessInfo.processInfo.arguments.contains("-wordRegenDemoSelection")
        // Late-book phrases first for word-regen: earlier UITests often ledger-lock ch1/ch2
        // via Search Continue / TOC jumps, which correctly refuses Preview on consumed text.
        let phrases = preferUnread
            ? ["dollars under the mattress", "In the early nineteenth century", "Geography is destiny"]
            : ["Geography is destiny", "In the early nineteenth century"]
        for phrase in phrases {
            let hits = document.search(query: phrase)
            for hit in hits {
                guard let selection = ReaderSelectionMapper.selection(in: document, documentRange: hit.range)
                else { continue }
                if preferUnread && consumedChapterIds.contains(selection.chapterId) {
                    continue
                }
                activeSelection = selection
                showSelectionActions = true
                jumpAnimated = true
                jumpUtf16 = hit.range.location
                jumpToken = UUID()
                return
            }
        }
        // Last resort for word-regen: first mid-block selection in any unread chapter.
        guard preferUnread else { return }
        let ordered = chapters.sorted { $0.orderIndex < $1.orderIndex }
        for chapter in ordered where !consumedChapterIds.contains(chapter.id) {
            let anchors = document.anchors.filter { $0.chapterId == chapter.id && $0.block.kind != .imagePlaceholder }
            guard let anchor = anchors.dropFirst().first ?? anchors.first else { continue }
            let blockText = anchor.block.text as NSString
            guard blockText.length > 12 else { continue }
            let word = BookmarkAnchorResolver.nearestWordPin(
                blockText: blockText as String,
                selectionStartUtf16: min(12, max(0, blockText.length / 3)),
                selectedText: ""
            )
            let displayStart = anchor.utf16Range.lowerBound + ReaderDocumentBuilder.displayPrefixLength(for: anchor.block) + word.utf16Offset
            let wordLen = (word.word as NSString).length
            guard wordLen > 0 else { continue }
            let range = NSRange(location: displayStart, length: wordLen)
            guard let selection = ReaderSelectionMapper.selection(in: document, documentRange: range)
            else { continue }
            activeSelection = selection
            showSelectionActions = true
            jumpAnimated = true
            jumpUtf16 = range.location
            jumpToken = UUID()
            return
        }
    }

    private func flash(_ message: String, holdNanoseconds: UInt64 = 1_600_000_000) {
        bannerMessage = message
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: holdNanoseconds)
            if self?.bannerMessage == message {
                self?.bannerMessage = nil
            }
        }
    }

    // MARK: - Phase 5 Finish → Feedback → Plan → Apply

    func refreshFinishAffordances() {
        guard let location = currentLocation, let document else {
            chapterLocalProgress = 0
            nearChapterEnd = false
            canFinishCurrentChapter = false
            return
        }
        let local = Self.localProgress(of: location, in: document)
        chapterLocalProgress = local ?? min(1, max(0, progress))

        if consumedChapterIds.contains(location.chapterId) {
            nearChapterEnd = false
            canFinishCurrentChapter = false
            return
        }
        guard let local else {
            canFinishCurrentChapter = true
            nearChapterEnd = progress > 0.85
            return
        }
        nearChapterEnd = local >= 0.82 || progress >= 0.9
        canFinishCurrentChapter = true
    }

    /// Fraction (0…1) of the current chapter already behind the reader.
    private static func localProgress(of location: ReaderLocation, in document: ReaderDocument) -> Double? {
        let starts = document.chapterStarts.sorted { $0.utf16Location < $1.utf16Location }
        guard let idx = starts.firstIndex(where: { $0.chapterId == location.chapterId }) else { return nil }
        let start = starts[idx].utf16Location
        let end = idx + 1 < starts.count ? starts[idx + 1].utf16Location : max(start + 1, document.length)
        let span = max(1, end - start)
        let docPos = document.utf16Location(for: location) ?? start
        return min(1, max(0, Double(max(0, docPos - start)) / Double(span)))
    }

    func beginFinishChapter() {
        guard let location = currentLocation else { return }
        guard !consumedChapterIds.contains(location.chapterId) else { return }
        finishedChapterTitle = chapters.first(where: { $0.id == location.chapterId })?.title ?? currentChapterTitle
        feedbackOverall = .fine
        feedbackMoreOf = [.stories, .placesIllVisit]
        feedbackLessOf = [.repetition]
        feedbackFreeText = ""
        showFeedbackSheet = true
        adaptationState = .awaitingFeedback
    }

    func submitFeedbackAndBuildPlan(useBundledExample: Bool = false) async {
        guard !isAdaptationBusy, let location = currentLocation,
              let revision = readableRevisions[location.chapterId],
              let service = adaptationService else { return }
        isAdaptationBusy = true
        adaptationError = nil
        defer { isAdaptationBusy = false }

        let feedback = ChapterFeedback(
            id: UUID(),
            bookId: book.id,
            chapterId: location.chapterId,
            revisionId: revision.id,
            overall: feedbackOverall,
            moreOf: Array(feedbackMoreOf).sorted { $0.rawValue < $1.rawValue },
            lessOf: Array(feedbackLessOf).sorted { $0.rawValue < $1.rawValue },
            freeText: feedbackFreeText,
            createdAt: Date()
        )

        do {
            let planService: LivingBookAdaptationService
            if useBundledExample {
                let example = try await BundledGlobalContextExample.prepare(
                    book: book, after: location.chapterId, versioning: versioning
                )
                planService = LivingBookAdaptationService(
                    versioning: versioning, feedbackStore: feedbackStore,
                    preferenceStore: preferenceStore, ai: example
                )
            } else {
                planService = service
            }
            // Transactional consume of the exact revision just read, then Stage 1 PLAN.
            try await planService.finishChapter(bookId: book.id, chapterId: location.chapterId, revisionId: revision.id)
            consumedChapterIds.insert(location.chapterId)
            applyLengthPreset = useBundledExample ? .full : .applyDefault
            adaptationState = .planning
            let plan = try await planService.submitFeedbackAndPlan(
                book: book,
                feedback: feedback,
                length: applyLengthPreset
            )
            bundledPlanService = useBundledExample ? (plan.id, planService) : nil
            adaptationPlan = plan
            adaptationState = .planReady
            showFeedbackSheet = false
            showAdaptationPlanSheet = true
            flash("Plan ready — review before Apply")
        } catch {
            adaptationState = .failed
            adaptationError = error.localizedDescription
            flash("Couldn’t build plan — reading unchanged")
        }
        refreshFinishAffordances()
    }

    func applyAdaptationPlan() async {
        guard !isAdaptationBusy, let plan = adaptationPlan,
              let service = bundledPlanService?.planID == plan.id ? bundledPlanService?.service : adaptationService else { return }
        isAdaptationBusy = true
        adaptationError = nil
        adaptationState = .applying
        defer { isAdaptationBusy = false }
        do {
            _ = try await service.applyPlan(book: book, plan: plan)
            // Reload readable revisions for adapted future chapters.
            var revisions = readableRevisions
            for chapterId in plan.affectedChapterIds {
                if let rev = try? await versioning.readableRevision(bookId: book.id, chapterId: chapterId) {
                    revisions[chapterId] = rev
                }
            }
            readableRevisions = revisions
            // Refresh in-memory book active revision pointers if needed
            await refreshBookFromStore()
            rebuildDocumentPreservingLocation()
            adaptationState = .applied
            showAdaptationPlanSheet = false
            flash(book.isLivingFromCanon ? "This book is now Living — unread chapters adapted" : "Adapted unread chapters")
        } catch {
            adaptationState = .failed
            adaptationError = error.localizedDescription
            flash("Apply failed — previous book unchanged")
        }
    }

    func cancelAdaptation() async {
        // Invalidate the plan before suspending so a cancelled bundled plan
        // cannot be retried through the normal AI backend.
        adaptationPlan = nil
        let bundledService = bundledPlanService?.service
        bundledPlanService = nil
        if let service = bundledService {
            await service.cancel()
        }
        if let service = adaptationService {
            await service.cancel()
        }
        adaptationState = .cancelled
        showAdaptationPlanSheet = false
        isAdaptationBusy = false
        flash("Adaptation cancelled")
    }


    // MARK: - Wave 2 generative

    func openVersionHistory(focusChapterId: UUID? = nil) async {
        versionHistoryError = nil
        versionHistoryFocusChapterId = focusChapterId ?? currentLocation?.chapterId
        do {
            versionHistoryEntries = try await versioning.listBookVersionHistory(bookId: book.id)
            showVersionHistory = true
        } catch {
            versionHistoryError = error.localizedDescription
            showVersionHistory = true
        }
    }

    func restoreVersion(_ entry: ChapterVersionEntry) async {
        isVersionRestoring = true
        versionHistoryError = nil
        defer { isVersionRestoring = false }
        do {
            _ = try await versioning.restoreRevision(
                bookId: book.id,
                chapterId: entry.chapterId,
                sourceRevisionId: entry.revisionId
            )
            if let rev = try? await versioning.readableRevision(bookId: book.id, chapterId: entry.chapterId) {
                readableRevisions[entry.chapterId] = rev
            }
            versionHistoryEntries = try await versioning.listBookVersionHistory(bookId: book.id)
            await refreshBookFromStore()
            rebuildDocumentPreservingLocation()
            await refreshSourceContinuationOfflineProof()
            flash("Restored version \(entry.revisionIndex)")
        } catch {
            versionHistoryError = error.localizedDescription
            flash("Restore blocked — consumed past unchanged")
        }
    }

    /// Canon More row: same regen/adapt Apply surface, labeled Make Living.
    func openMakeLivingFromCanon() async {
        await openRegenerateFromHere()
    }

    func openRegenerateFromHere() async {
        regenError = nil
        regenPreview = nil
        applyLengthPreset = .applyDefault
        let ordered = chapters.sorted { $0.orderIndex < $1.orderIndex }
        if let currentChapterId = currentLocation?.chapterId,
           !consumedChapterIds.contains(currentChapterId) {
            regenSelectedChapterId = currentChapterId
        } else {
            let currentOrder = currentLocation
                .flatMap { location in ordered.first(where: { $0.id == location.chapterId })?.orderIndex }
                ?? Int.min
            regenSelectedChapterId = ordered.first {
                $0.orderIndex >= currentOrder && !consumedChapterIds.contains($0.id)
            }?.id
        }
        await refreshRemainingReadingLabel()
        showRegenerateFromHere = true
    }

    func regenerationCutChanged() {
        if regenPreview != nil {
            regenPreview = nil
            adaptationPlan = nil
            adaptationState = .idle
        }
        regenError = nil
        Task { await refreshRemainingReadingLabel() }
    }

    func regenerationLengthChanged() {
        regenerationCutChanged()
    }

    func adaptationLengthChanged() {
        guard let plan = adaptationPlan else { return }
        // The bundled provider appends fixed blocks; it cannot honor a shorter
        // word target. Keep its reviewed targets and displayed length exact.
        guard !isBundledAdaptationPlan else {
            applyLengthPreset = plan.resolvedLengthPreset
            return
        }
        let stored = plan.resolvedLengthPreset
        if stored != applyLengthPreset {
            adaptationPlan = plan.retargeted(from: stored, to: applyLengthPreset)
        }
    }

    func refreshRemainingReadingLabel() async {
        let prefs = readingTimePreferences
        var blocks: [[ContentBlock]] = []
        let ordered = chapters.sorted { $0.orderIndex < $1.orderIndex }
        let startOrder: Int
        if let selected = regenSelectedChapterId,
           let match = ordered.first(where: { $0.id == selected }) {
            startOrder = match.orderIndex
        } else if let loc = currentLocation,
                  let match = ordered.first(where: { $0.id == loc.chapterId }) {
            startOrder = match.orderIndex
        } else {
            startOrder = ordered.first?.orderIndex ?? 0
        }
        for chapter in ordered where chapter.orderIndex >= startOrder {
            if consumedChapterIds.contains(chapter.id) { continue }
            if let rev = readableRevisions[chapter.id] {
                blocks.append(rev.blocks)
            } else if let rev = try? await versioning.readableRevision(bookId: book.id, chapterId: chapter.id) {
                blocks.append(rev.blocks)
            }
        }
        let estimate = ReadingTimeEstimator.estimateRemaining(chapterBlocks: blocks, preferences: prefs)
        remainingReadingLabel = "About \(estimate.displayLabel) remaining (\(estimate.proseWordCount) words @ \(prefs.wordsPerMinute) WPM)"
    }

    func buildRegenerationPreview() async {
        guard !isAdaptationBusy, let cutId = regenSelectedChapterId, let service = adaptationService else { return }
        isAdaptationBusy = true
        regenError = nil
        defer { isAdaptationBusy = false }
        do {
            await refreshRemainingReadingLabel()
            let latest = try await versioning.loadBook(id: book.id) ?? book
            let preview = try await service.previewRegeneration(
                book: latest,
                fromChapterId: cutId,
                preferences: readingTimePreferences,
                maxChapters: 2,
                length: applyLengthPreset
            )
            regenPreview = preview
            adaptationPlan = preview.plan
            adaptationState = .planReady
        } catch {
            regenPreview = nil
            regenError = error.localizedDescription
            adaptationState = .failed
            adaptationError = error.localizedDescription
        }
    }

    func applyRegenerationPreview() async {
        guard !isAdaptationBusy, let preview = regenPreview, let service = adaptationService else { return }
        isAdaptationBusy = true
        regenError = nil
        adaptationState = .applying
        defer { isAdaptationBusy = false }
        do {
            let latest = try await versioning.loadBook(id: book.id) ?? book
            _ = try await service.applyRegeneration(book: latest, preview: preview)
            var revisions = readableRevisions
            for chapterId in preview.plan.affectedChapterIds {
                if let rev = try? await versioning.readableRevision(bookId: book.id, chapterId: chapterId) {
                    revisions[chapterId] = rev
                }
            }
            readableRevisions = revisions
            await refreshBookFromStore()
            rebuildDocumentPreservingLocation()
            adaptationState = .applied
            showRegenerateFromHere = false
            regenPreview = nil
            flash(book.isLivingFromCanon
                  ? "This book is now Living — unread future adapted"
                  : (applyLengthPreset == .half
                     ? "Regenerated at half-length — Full remains available"
                     : "Regenerated from cut — reading time preserved"))
        } catch {
            adaptationState = .failed
            regenError = error.localizedDescription
            flash("Regen Apply failed — previous book unchanged")
        }
    }

    // MARK: - Wave 2C Listen

    /// Reading order, for Listen's chapter skip.
    var orderedChapterIds: [UUID] {
        chapters.sorted { $0.orderIndex < $1.orderIndex }.map { $0.id }
    }

    /// Read-only narration source for one chapter.
    ///
    /// Built from the *readable* revision, so the audio cache is keyed to the
    /// same text the reader would see. Listening is a pure reader of this state:
    /// it never moves the checkpoint, never consumes a chapter, and never edits
    /// a revision.
    func makeListenDocument(chapterId: UUID, voice: ListenVoice) -> ListenDocument? {
        #if DEBUG
        guard !refuseTrialAuxiliaryAction() else { return nil }
        #endif
        guard let revision = readableRevisions[chapterId] else { return nil }
        let title = chapters.first(where: { $0.id == chapterId })?.title ?? book.title
        return ListenDocumentBuilder.build(
            bookId: book.id,
            chapterId: chapterId,
            chapterTitle: title,
            revision: revision,
            voice: voice
        )
    }

    /// Maps a reader selection onto the narration UTF-16 stream Listen uses.
    func narrationUTF16Offset(for selection: ReaderTextSelection) -> Int? {
        guard let revision = readableRevisions[selection.chapterId] else { return nil }
        return ListenWordTiming.narrationUTF16Offset(
            blocks: revision.blocks,
            blockId: selection.range.blockId,
            utf16InBlock: selection.range.utf16Start
        )
    }

    // MARK: - Regenerate from the nearest word

    /// Turns the current selection into a word anchor and opens the request sheet.
    ///
    /// The anchor uses the same nearest-word resolver as named bookmarks, so both
    /// features agree on which word the reader actually touched. The offset remains a
    /// word locator; the splitter freezes that whole word before rewriting what follows.
    ///
    /// For ordinary books, a finished selection moves Apply to the next unread chapter.
    /// Source previews refuse finished chapters rather than remapping the selection.
    func beginRegenerateFromWord() {
        guard !isAdaptationBusy else { return }
        guard let selection = activeSelection, let document,
              let anchor = document.anchor(blockId: selection.range.blockId) else {
            flash("Couldn’t anchor on that word")
            return
        }
        let full = document.attributedText.string as NSString
        let blockRange = NSRange(location: anchor.utf16Range.lowerBound, length: anchor.utf16Range.count)
        let pin = BookmarkAnchorResolver.nearestWordPin(
            blockText: full.substring(with: blockRange),
            selectionStartUtf16: selection.range.utf16Start,
            selectedText: selection.selectedText
        )
        // Offsets above are into the rendered text; the manuscript block may carry
        // decoration (quote marks) the renderer added, so shift back into stored text.
        let stored = (anchor.block.text as NSString).length
        let manuscriptOffset = min(
            max(0, pin.utf16Offset - ReaderDocumentBuilder.displayPrefixLength(for: anchor.block)),
            max(0, stored)
        )
        let word = pin.word.isEmpty ? selection.selectedText : pin.word

        showSelectionActions = false
        wordRegenPreview = nil
        wordRegenError = nil
        wordAnchor = RegenerationWordAnchor(
            bookId: book.id,
            chapterId: selection.chapterId,
            chapterTitle: selection.chapterTitle,
            revisionId: readableRevisions[selection.chapterId]?.id ?? selection.revisionId,
            blockId: selection.range.blockId,
            utf16OffsetInBlock: manuscriptOffset,
            word: word,
            createdAt: Date(),
            boundary: .afterWord
        )
        wordRegenChapterLocked = consumedChapterIds.contains(selection.chapterId)
        isSourceWordRegen = book.chapters.first(where: { $0.id == selection.chapterId })?.sourceGrounding != nil
        sourceWordRegenState = nil
        sourceWordStateLoadFailed = false
        sourceSelectionAnchor = wordAnchor
        if isSourceWordRegen {
            wordRegenIntents = [.moreExplanation]
            wordRegenFreeText = ""
            validateSourceWordSelection()
        }
        adaptationState = .idle
        showRegenerateFromWord = true
        if isSourceWordRegen {
            // Own the busy state before scheduling; dismissal cannot race this disk read.
            isAdaptationBusy = true
            Task { await loadSourceContinuationForSheet() }
        }
    }

    /// True when at least one change option (intent or free text) is selected.
    var hasWordRegenChangeSelection: Bool {
        !wordRegenIntents.isEmpty
            || !wordRegenFreeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Source continuation changes only the selected chapter, and a failure can
    /// occur after publication while saving its completion state.
    var sourceWordRegenerationStatusMessage: String? {
        switch adaptationState {
        case .applying: return "Working on saved-source change…"
        case .applied: return "Source continuation saved"
        case .failed: return wordRegenError ?? "Saved-source change needs attention"
        default: return nil
        }
    }

    /// Preview/Apply can run when we can resolve an effective (unread) regeneration anchor.
    var canPreviewWordRegen: Bool {
        if isSourceWordRegen {
            return !isAdaptationBusy && !sourceWordStateLoadFailed && sourceWordRegenState == nil
                && sourceWordBoundaryAvailable && hasWordRegenChangeSelection
                && wordRegenFreeText.count <= 1_000
        }
        return !isAdaptationBusy && (try? effectiveWordAnchorForRegeneration()) != nil
    }

    /// Ordinary Apply may remap a finished selection. Source Apply requires a saved
    /// attempt and never remaps consumed text or automatically repeats uncertain writing.
    var canApplyWordRegen: Bool {
        if isSourceWordRegen {
            guard !isAdaptationBusy, !sourceWordStateLoadFailed, let saved = sourceWordRegenState else { return false }
            if wordRegenChapterLocked && saved.phase != .published { return false }
            return saved.phase != .writing && saved.phase != .uncertain
        }
        return hasWordRegenChangeSelection && canPreviewWordRegen
    }

    func wordRegenRequestChanged() {
        guard !isAdaptationBusy, !isSourceWordRegen || sourceWordRegenState == nil else { return }
        if isSourceWordRegen && wordRegenFreeText.count > 1_000 {
            wordRegenFreeText = String(wordRegenFreeText.prefix(1_000))
        }
        wordRegenPreview = nil
        if isSourceWordRegen { validateSourceWordSelection() } else { wordRegenError = nil }
    }

    func closeWordRegeneration() {
        guard !isAdaptationBusy else { return }
        showRegenerateFromWord = false
    }

    private func validateSourceWordSelection() {
        sourceWordBoundaryAvailable = false
        guard let anchor = sourceSelectionAnchor,
              let source = book.chapters.first(where: { $0.id == anchor.chapterId })?.sourceGrounding?.source,
              let base = readableRevisions[anchor.chapterId] else { return }
        do {
            guard !consumedChapterIds.contains(anchor.chapterId) else {
                throw ManuscriptError.cannotMutateConsumedChapter(anchor.chapterId)
            }
            guard try SourceGrounding.wordCut(base: base, blockID: anchor.blockId,
                    utf16Offset: anchor.utf16OffsetInBlock, source: source) != nil else {
                throw SourceGroundingError.invalid("That is the last prose word. There is no continuation to change.")
            }
            sourceWordBoundaryAvailable = true
            wordRegenError = nil
        } catch { wordRegenError = error.localizedDescription }
    }

    private func loadSourceContinuationForSheet() async {
        defer { isAdaptationBusy = false }
        guard let service = adaptationService else {
            sourceWordStateLoadFailed = true
            wordRegenError = "The saved change could not be loaded. Close this sheet and reopen the book."
            return
        }
        do {
            sourceWordRegenState = try await service.sourceContinuation(bookID: book.id)
            if let saved = sourceWordRegenState {
                wordAnchor = saved.anchor
                wordRegenChapterLocked = consumedChapterIds.contains(saved.chapterID)
                wordRegenError = saved.errorMessage
            }
        } catch {
            sourceWordStateLoadFailed = true
            wordRegenError = error.localizedDescription
        }
        await refreshSourceContinuationOfflineProof()
    }

    /// Explicit abandonment preserves the durable archive; it never runs a provider.
    func startNewSourceWordRegeneration() async {
        guard isSourceWordRegen, !isAdaptationBusy, let saved = sourceWordRegenState,
              let service = adaptationService else { return }
        isAdaptationBusy = true
        defer { isAdaptationBusy = false }
        do {
            try await service.archiveSourceContinuation(bookID: book.id, attemptID: saved.id)
            sourceWordRegenState = nil
            sourceWordStateLoadFailed = false
            wordAnchor = sourceSelectionAnchor
            wordRegenChapterLocked = sourceSelectionAnchor.map { consumedChapterIds.contains($0.chapterId) } ?? false
            wordRegenIntents = [.moreExplanation]
            wordRegenFreeText = ""
            validateSourceWordSelection()
            adaptationState = .idle
        } catch { wordRegenError = error.localizedDescription }
        await refreshSourceContinuationOfflineProof()
    }

    /// Selection display anchor, rematerialized onto the next unread chapter when the
    /// selected chapter is finished. Never returns an anchor inside consumed text.
    func effectiveWordAnchorForRegeneration() throws -> RegenerationWordAnchor {
        guard let anchor = wordAnchor else {
            throw AdaptationError.nothingToAdapt
        }
        guard consumedChapterIds.contains(anchor.chapterId) else {
            return anchor
        }
        if isSourceWordRegen {
            throw ManuscriptError.cannotMutateConsumedChapter(anchor.chapterId)
        }
        let ordered = book.chapters.sorted { $0.orderIndex < $1.orderIndex }
        guard let finished = ordered.first(where: { $0.id == anchor.chapterId }) else {
            throw AdaptationError.illegalChapterId(anchor.chapterId)
        }
        guard let next = ordered.first(where: {
            $0.orderIndex > finished.orderIndex && !consumedChapterIds.contains($0.id)
        }) else {
            throw AdaptationError.nothingToAdapt
        }
        guard let revision = readableRevisions[next.id] else {
            throw AdaptationError.nothingToAdapt
        }
        guard let block = revision.blocks.min(by: { $0.orderIndex < $1.orderIndex }) else {
            throw AdaptationError.nothingToAdapt
        }
        // No word in this unread chapter was selected or read. Start before its first
        // ordered block, including any leading image, rather than freezing a new word.
        return RegenerationWordAnchor(
            bookId: book.id,
            chapterId: next.id,
            chapterTitle: next.title,
            revisionId: revision.id,
            blockId: block.id,
            utf16OffsetInBlock: 0,
            word: "",
            createdAt: Date(),
            boundary: .chapterStart
        )
    }

    func buildWordForwardPreview() async {
        guard !isAdaptationBusy else { return }
        if isSourceWordRegen {
            await prepareSourceWordRegeneration()
            return
        }
        guard let service = adaptationService else { return }
        isAdaptationBusy = true
        wordRegenError = nil
        defer { isAdaptationBusy = false }
        do {
            let effective = try effectiveWordAnchorForRegeneration()
            let latest = try await versioning.loadBook(id: book.id) ?? book
            let preview = try await service.previewWordForwardRegeneration(
                book: latest,
                request: WordForwardRegenerationRequest(
                    anchor: effective,
                    intents: RegenerationIntent.allCases.filter { wordRegenIntents.contains($0) },
                    freeText: wordRegenFreeText,
                    readerPreferencesSummary: readerPreferenceSummary,
                    maxFollowOnChapters: 1
                ),
                preferences: settings.readingTimePreferences
            )
            wordRegenPreview = preview
            adaptationPlan = preview.plan
            adaptationState = .planReady
        } catch {
            wordRegenPreview = nil
            wordRegenError = error.localizedDescription
            adaptationState = .failed
        }
    }

    func applyWordForwardPreview() async {
        guard !isAdaptationBusy else { return }
        if isSourceWordRegen {
            await runSourceWordRegeneration()
            return
        }
        guard let service = adaptationService else { return }
        isAdaptationBusy = true
        wordRegenError = nil
        adaptationState = .applying
        defer { isAdaptationBusy = false }
        do {
            let preview: WordForwardRegenerationPreview
            if let existing = wordRegenPreview {
                preview = existing
            } else {
                let effective = try effectiveWordAnchorForRegeneration()
                let latestForPreview = try await versioning.loadBook(id: book.id) ?? book
                preview = try await service.previewWordForwardRegeneration(
                    book: latestForPreview,
                    request: WordForwardRegenerationRequest(
                        anchor: effective,
                        intents: RegenerationIntent.allCases.filter { wordRegenIntents.contains($0) },
                        freeText: wordRegenFreeText,
                        readerPreferencesSummary: readerPreferenceSummary,
                        maxFollowOnChapters: 1
                    ),
                    preferences: settings.readingTimePreferences
                )
                wordRegenPreview = preview
                adaptationPlan = preview.plan
            }
            let latest = try await versioning.loadBook(id: book.id) ?? book
            _ = try await service.applyWordForwardRegeneration(book: latest, preview: preview)
            var revisions = readableRevisions
            for chapterId in preview.plan.affectedChapterIds {
                if let rev = try? await versioning.readableRevision(bookId: book.id, chapterId: chapterId) {
                    revisions[chapterId] = rev
                }
            }
            readableRevisions = revisions
            await refreshBookFromStore()
            rebuildDocumentPreservingLocation()
            settleReadingPlace(after: preview.anchor)
            adaptationState = .applied
            showRegenerateFromWord = false
            wordRegenPreview = nil
            if book.isLivingFromCanon {
                flash("This book is now Living — unread future adapted")
            } else if preview.anchor.boundary == .chapterStart {
                flash("Rewritten from the start of \(preview.anchor.chapterTitle)")
            } else {
                flash("Rewritten after “\(preview.anchor.displayWord)”")
            }
        } catch {
            adaptationState = .failed
            wordRegenError = error.localizedDescription
            flash("Regen failed — your book is unchanged")
        }
    }

    private func prepareSourceWordRegeneration() async {
        guard canPreviewWordRegen, let service = adaptationService else { return }
        isAdaptationBusy = true
        wordRegenError = nil
        defer { isAdaptationBusy = false }
        do {
            let request = WordForwardRegenerationRequest(anchor: try effectiveWordAnchorForRegeneration(),
                intents: RegenerationIntent.allCases.filter { wordRegenIntents.contains($0) },
                freeText: wordRegenFreeText, readerPreferencesSummary: readerPreferenceSummary, maxFollowOnChapters: 0)
            let saved = try await service.prepareSourceContinuation(request: request)
            sourceWordRegenState = saved
            wordAnchor = saved.anchor
            adaptationState = .planReady
        } catch {
            adaptationState = .failed
            wordRegenError = error.localizedDescription
        }
        await refreshSourceContinuationOfflineProof()
    }

    private func runSourceWordRegeneration() async {
        guard canApplyWordRegen, let saved = sourceWordRegenState, let service = adaptationService else { return }
        isAdaptationBusy = true
        wordRegenError = nil
        adaptationState = .applying
        defer { isAdaptationBusy = false }
        do {
            let revision = try await service.runSourceContinuation(bookID: book.id, attemptID: saved.id)
            guard let latest = try await versioning.loadBook(id: book.id),
                  latest.chapters.first(where: { $0.id == revision.chapterId })?.activeRevision?.id == revision.id else {
                throw SourceGroundingError.invalid("The active version changed after publication. Reopen the reader to see the current saved text.")
            }
            book = latest
            readableRevisions[revision.chapterId] = revision
            // Publication already returned the saved revision; this read is only sheet state.
            sourceWordRegenState = try? await service.sourceContinuation(bookID: book.id)
            rebuildDocumentPreservingLocation()
            settleReadingPlace(after: saved.anchor)
            adaptationState = .applied
            showRegenerateFromWord = false
            flash("Saved source-checked continuation after “\(saved.anchor.displayWord)”")
        } catch {
            adaptationState = .failed
            wordRegenError = error.localizedDescription
            do {
                sourceWordRegenState = try await service.sourceContinuation(bookID: book.id)
            } catch {
                sourceWordStateLoadFailed = true
                wordRegenError = "The saved change could not be reloaded: " + error.localizedDescription
            }
        }
        await refreshSourceContinuationOfflineProof()
    }

    private func refreshBookFromStore() async {
        if let latest = try? await versioning.loadBook(id: book.id) {
            book = latest
        }
    }

    /// Only the explicitly isolated DEBUG fixture exposes persisted test evidence.
    private func refreshSourceContinuationOfflineProof() async {
        #if DEBUG
        guard let fixtureID = Self.offlineSourceFixtureID, book.id == fixtureID else { return }
        do {
            guard let stored = try await versioning.loadBook(id: fixtureID),
                  let chapter = stored.chapters.first, let active = chapter.activeRevision,
                  let original = chapter.revisions.sorted(by: { $0.revisionIndex < $1.revisionIndex })
                    .first(where: { $0.sourceReview != nil }), let source = chapter.sourceGrounding?.source else {
                throw SourceGroundingError.invalid("The authored offline fixture is incomplete.")
            }
            let packets = await versioning.packetStore
            let facts = try packets.loadFactChecklist(bookId: fixtureID)
            let proof = SourceContinuationOfflineEvidence(bookID: fixtureID, source: source, original: original,
                active: active, attempt: facts.sourceContinuation, archive: facts.sourceContinuationArchive ?? [],
                writerCalls: UserDefaults.standard.integer(forKey: SourceContinuationOfflineAI.counterKey(fixtureID, "writer")),
                reviewerCalls: UserDefaults.standard.integer(forKey: SourceContinuationOfflineAI.counterKey(fixtureID, "reviewer")))
            sourceContinuationOfflineProof = String(decoding: try JSONCoding.encoder.encode(proof), as: UTF8.self)
        } catch {
            sourceContinuationOfflineProof = "{\"fixtureError\":true}"
        }
        #endif
    }

    #if DEBUG
    /// Keep the Ask mic and narration out of this text-only acceptance route.
    private func refuseTrialAuxiliaryAction() -> Bool {
        guard SourceContinuationTrial.requested() else { return false }
        flash("Ask and voice are unavailable in this isolated continuation trial.")
        return true
    }

    /// Maps an operator-selected real word only in the separate acceptance app.
    /// No manuscript, source, candidate, checkpoint or provider response is injected.
    private func presentSourceContinuationTrialSelection() {
        let info = ProcessInfo.processInfo
        guard info.arguments.contains("-sourceContinuationTrialSelection"),
              SourceContinuationTrial.identifier(arguments: info.arguments, environment: info.environment,
                  bundleID: Bundle.main.bundleIdentifier, model: .defaultGeneration) != nil,
              let document,
              let rawBook = info.environment["SOURCE_CONTINUATION_BOOK_ID"], UUID(uuidString: rawBook) == book.id,
              let rawBase = info.environment["SOURCE_CONTINUATION_BASE_REVISION_ID"], let baseID = UUID(uuidString: rawBase),
              let rawBlock = info.environment["SOURCE_CONTINUATION_BLOCK_ID"], let blockID = UUID(uuidString: rawBlock),
              let rawOffset = info.environment["SOURCE_CONTINUATION_UTF16_OFFSET"], let offset = Int(rawOffset),
              let chapter = book.chapters.first(where: { $0.activeRevisionId == baseID }),
              !consumedChapterIds.contains(chapter.id), let base = chapter.activeRevision,
              let source = chapter.sourceGrounding?.source,
              let cut = try? SourceGrounding.wordCut(base: base, blockID: blockID, utf16Offset: offset, source: source),
              let anchor = document.anchors.first(where: { $0.chapterId == chapter.id && $0.block.id == blockID }) else { return }
        let start = anchor.utf16Range.lowerBound + ReaderDocumentBuilder.displayPrefixLength(for: anchor.block) + cut.wordStartUTF16
        let range = NSRange(location: start, length: cut.endUTF16 - cut.wordStartUTF16)
        guard let selection = ReaderSelectionMapper.selection(in: document, documentRange: range) else { return }
        activeSelection = selection; showSelectionActions = true
        jumpAnimated = true; jumpUtf16 = start; jumpToken = UUID()
    }

    private static var offlineSourceFixtureID: UUID? {
        let info = ProcessInfo.processInfo
        guard !SourceContinuationTrial.requested(),
              Bundle.main.bundleIdentifier == "com.jarvis.livingreader.codex.sourcecontinuation",
              info.arguments.contains("-uitesting"), info.arguments.contains("-sourceContinuationOfflineFixture"),
              let raw = info.environment["SOURCE_CONTINUATION_FIXTURE_ID"] else { return nil }
        return UUID(uuidString: raw)
    }

    private func openOfflineSourceFixture(id: UUID) async throws -> Book {
        if let saved = try await versioning.loadBook(id: id) { return saved }
        let source = SourceContinuationOfflineAI.authoredSource()
        let chapterID = UUID(), outlineID = UUID()
        let outlineBlocks = [ContentBlock(id: UUID(), kind: .paragraph,
            text: "Authored offline test outline; no source or AI request.", orderIndex: 0)]
        let requirement = SourceGroundingRequirement(source: source, outlineRevisionID: outlineID,
            outlineContentHash: try SourceGrounding.contentHash(outlineBlocks), approvedBriefHash: "authored-offline-continuation")
        let outline = ChapterRevision(id: outlineID, chapterId: chapterID, revisionIndex: 1,
            createdAt: source.retrievedAt, blocks: outlineBlocks, isConsumed: false)
        let chapter = Chapter(id: chapterID, bookId: id, title: "Authored Harbor Archive", orderIndex: 0,
            activeRevisionId: outlineID, revisions: [outline], manuscriptStatus: .polished, sourceGrounding: requirement)
        let fixture = Book(id: id, title: "Authored Source Continuation Fixture", author: "Offline test",
            subtitle: "Authored fixture · mocked writer and review · no network",
            provenanceNotes: ["Explicit offline fixture, not a retrieved article or actual model assessment."], chapters: [chapter])
        try await versioning.saveBook(fixture)
        let paragraphs = source.text.components(separatedBy: "\n\n").map { SourceDraftParagraph(text: $0, citations: ["source1"]) }
        let blocks = try SourceGrounding.blocks(title: chapter.title, paragraphs: paragraphs, source: source)
        let response = SourceReviewResponse(units: paragraphs.enumerated().map { index, paragraph in
            .init(index: index, assessment: .supported, quotes: [paragraph.text])
        })
        let receipt = try SourceGrounding.receipt(bookID: id, chapterID: chapterID, baseRevisionID: outlineID,
            blocks: blocks, source: source, model: OpenAIModelOption.defaultGeneration.rawValue, response: response)
        let candidate = CandidateRevision(id: UUID(), bookId: id, chapterId: chapterID, proposedRevisionIndex: 2,
            createdAt: source.retrievedAt, blocks: blocks, status: .staged, rejectionReason: nil,
            origin: .generated(style: "Authored offline fixture; no model call"), sourceReview: receipt)
        try await versioning.stageCandidate(candidate)
        _ = try await versioning.activateCandidate(id: candidate.id, expectedRevisionId: outlineID)
        guard let saved = try await versioning.loadBook(id: id) else { throw ManuscriptError.bookNotFound(id) }
        return saved
    }

    private func presentOfflineSourceSelection() {
        guard let document, let hit = document.search(query: "records,").first,
              let selection = ReaderSelectionMapper.selection(in: document, documentRange: hit.range) else { return }
        activeSelection = selection
        showSelectionActions = true
        jumpAnimated = false
        jumpUtf16 = hit.range.location
        jumpToken = UUID()
    }
    #endif

    /// The replaced stretch gets new block ids, so a reading place that pointed into it no
    /// longer resolves. Land the reader back on their anchor word rather than at page one.
    private func settleReadingPlace(after anchor: RegenerationWordAnchor) {
        guard let document else { return }
        if let currentLocation, document.utf16Location(for: currentLocation) != nil { return }
        jumpToBlock(blockId: anchor.blockId, utf16OffsetInBlock: anchor.utf16OffsetInBlock)
    }

    /// Compact reader-taste line handed to Astra with the anchor context.
    private var readerPreferenceSummary: String {
        var parts = [
            "font \(Int(settings.fontSize))pt",
            "theme \(settings.colorScheme.rawValue)",
            "\(settings.wordsPerMinute) wpm"
        ]
        if let profile = try? preferenceStore.load(bookId: book.id) {
            parts.append(ReaderPreferenceEngine.summaryLine(for: profile))
        }
        return parts.joined(separator: ", ")
    }

    /// Overnight / Manager trigger: answer the existing feedback Q&A with the
    /// Argentina quality preset and run Finish → Plan → Apply. No new chrome.
    /// Live generation uses Astra when a Keychain key is present; otherwise Mock.
    func runArgentinaQualityRegen() async {
        guard let service = adaptationService else { return }
        isAdaptationBusy = true
        adaptationError = nil
        defer { isAdaptationBusy = false }
        // Visible while mock/live apply runs — UITest polls reader.banner after open.
        flash("Adapting unread chapters…", holdNanoseconds: 30_000_000_000)

        feedbackOverall = ArgentinaQualityRegen.Preset.overall
        feedbackMoreOf = Set(ArgentinaQualityRegen.Preset.moreOf)
        feedbackLessOf = Set(ArgentinaQualityRegen.Preset.lessOf)
        feedbackFreeText = ArgentinaQualityRegen.Preset.freeText

        do {
            let result = try await ArgentinaQualityRegen.run(
                book: book,
                versioning: versioning,
                service: service
            )
            consumedChapterIds.insert(result.consumedChapterId)
            adaptationPlan = result.plan
            var revisions = readableRevisions
            for chapterId in result.plan.affectedChapterIds {
                if let rev = try? await versioning.readableRevision(bookId: book.id, chapterId: chapterId) {
                    revisions[chapterId] = rev
                }
            }
            readableRevisions = revisions
            rebuildDocumentPreservingLocation()
            adaptationState = .applied
            // Hold long enough for UITests that wait on reader.textkit before polling
            // reader.banner (1.6s flash races openArgentina).
            flash("Adapted unread chapters", holdNanoseconds: 12_000_000_000)
            refreshFinishAffordances()
        } catch {
            adaptationState = .failed
            adaptationError = error.localizedDescription
            flash("Apply failed — previous book unchanged", holdNanoseconds: 12_000_000_000)
        }
    }

    /// Deterministic UI demo for smoke screenshots — presents feedback and holds for UITest.
    /// UITest taps Continue → plan → Apply.
    func runPhase5AdaptationDemo() async {
        if let ch1 = chapters.first(where: { $0.id == ArgentinaFixtureIDs.chapter1 }) {
            jumpToChapter(id: ch1.id)
        }
        try? await Task.sleep(nanoseconds: 350_000_000)
        canFinishCurrentChapter = true
        nearChapterEnd = true
        if currentLocation?.chapterId != ArgentinaFixtureIDs.chapter1 {
            jumpToChapter(id: ArgentinaFixtureIDs.chapter1)
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        // Guarantee a currentLocation for Finish/submit even if jump raced.
        if currentLocation == nil, let document,
           let start = document.chapterStarts.first(where: { $0.chapterId == ArgentinaFixtureIDs.chapter1 }),
           let loc = document.location(atUtf16: start.utf16Location, visibleProgress: 0.9) {
            currentLocation = loc
        }
        finishedChapterTitle = chapters.first(where: { $0.id == ArgentinaFixtureIDs.chapter1 })?.title ?? "Before the Nation"
        feedbackOverall = .fine
        feedbackMoreOf = [.stories, .placesIllVisit, .explanation]
        feedbackLessOf = [.repetition, .dates]
        feedbackFreeText = "More traveler stories, fewer date piles."
        adaptationState = .awaitingFeedback
        showFeedbackSheet = true
    }
}

#if DEBUG
private struct SourceContinuationOfflineEvidence: Encodable {
    let bookID: UUID
    let source: RetrievedResearchSource
    let original: ChapterRevision
    let active: ChapterRevision
    let attempt: SourceContinuationState?
    let archive: [SourceContinuationState]
    let writerCalls: Int
    let reviewerCalls: Int
}

/// Opted in only by the exact offline bundle plus explicit fixture flags/UUID.
/// Counts survive process termination so a repeated writer is visible to UI tests.
private actor SourceContinuationOfflineAI: AIService, SourceGroundedAI {
    let fixtureID: UUID
    nonisolated var sourceReviewModelID: String { OpenAIModelOption.defaultGeneration.rawValue }
    nonisolated var usesDeterministicGeneration: Bool { true }
    nonisolated var supportsSourceContinuation: Bool { true }
    init(fixtureID: UUID) { self.fixtureID = fixtureID }

    nonisolated static func counterKey(_ id: UUID, _ role: String) -> String {
        "sourceContinuation.offline.\(id.uuidString).\(role)"
    }

    func writeSourceContinuation(_ request: SourceContinuationWritingRequest) async throws -> [SourceDraftParagraph] {
        let key = Self.counterKey(fixtureID, "writer")
        UserDefaults.standard.set(UserDefaults.standard.integer(forKey: key) + 1, forKey: key)
        UserDefaults.standard.synchronize()
        try await Task.sleep(nanoseconds: 1_000_000_000)
        return [
            .init(text: "arranged by volume and page, let readers trace each quotation to a particular document.", citations: ["source1"]),
            .init(text: Self.secondParagraph, citations: ["source1"])
        ]
    }

    func reviewSourcePreview(_ request: SourceReviewRequest) async throws -> SourceReviewResponse {
        let key = Self.counterKey(fixtureID, "reviewer")
        let call = UserDefaults.standard.integer(forKey: key) + 1
        UserDefaults.standard.set(call, forKey: key)
        UserDefaults.standard.synchronize()
        try await Task.sleep(nanoseconds: 1_000_000_000)
        return SourceReviewResponse(units: request.paragraphs.indices.map {
            .init(index: $0, assessment: call == 1 && $0 == 0 ? .unsupported : .supported,
                quotes: [Self.firstParagraph, Self.secondParagraph])
        })
    }

    func writeSourcePreview(_ request: SourceWritingRequest) async throws -> [SourceDraftParagraph] { throw unsupported }
    func adaptChapter(chapterId: UUID, promptContext: String) async throws -> ChapterRevision { throw unsupported }
    func makeAdaptationPlan(_ request: AdaptationPlanRequest) async throws -> AdaptationPlan { throw unsupported }
    func generateAdaptedChapter(_ request: AdaptationGenerateRequest) async throws -> [ContentBlock] { throw unsupported }
    func ask(_ request: AskRequest) async throws -> AskResponse { throw unsupported }
    private var unsupported: SourceGroundingError { .invalid("This authored offline fixture supports only its continuation test.") }

    nonisolated static let firstParagraph = """
    At Cafe\u{301}, the harbor keepers maintained a register of boats arriving at the town quay. Each entry named the vessel, its landing place, and the goods recorded by the clerk. A second column noted whether the cargo remained aboard or moved into a warehouse. The register did not explain why a captain chose one route rather than another. Readers could compare entries made on different days, but an empty line alone did not establish that the harbor had closed. The keepers stored receipts beside the volumes so later clerks could distinguish a corrected entry from an unrecorded journey. A small index listed the names used in each volume without changing the spelling found on its pages. Visitors consulted that index before requesting the register.
    """
    nonisolated static let secondParagraph = """
    Cafe\u{301} 🇦🇷 records, \t  arranged on wooden shelves, remained available after the original clerks left office. The archive supplied a reading table and asked visitors to return each volume before requesting another. Notes about a damaged binding described the object rather than the truth of its contents. When two entries disagreed, the catalogue preserved both and recorded their locations. A reader could therefore identify a disagreement without assuming that the later entry was correct. Copies made for visitors carried the volume number and page reference, while the original sheets stayed in the archive. These practices helped readers trace the words they quoted to a particular document. They did not turn every written claim into an independently established fact. At closing time, staff returned the volumes to their marked shelves.
    """

    nonisolated static func authoredSource() -> RetrievedResearchSource {
        let text = firstParagraph + "\n\n" + secondParagraph
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        return RetrievedResearchSource(requestedTitle: "Authored Harbor Archive", title: "Authored Harbor Archive",
            canonicalURL: URL(string: "https://en.wikipedia.org/wiki/Authored_Harbor_Archive")!, pageID: 42, revisionID: 9001,
            revisionURL: URL(string: "https://en.wikipedia.org/w/index.php?oldid=9001")!,
            revisionTimestamp: stamp, retrievedAt: stamp, scope: .wikipediaIntroduction, text: text,
            textSHA256: SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined(),
            attribution: "Authored offline test evidence; no article retrieval occurred.",
            attributionURL: URL(string: "https://en.wikipedia.org/w/index.php?title=Authored_Harbor_Archive&action=history")!,
            licenseName: "Authored test fixture", licenseURL: URL(string: "https://creativecommons.org/licenses/by-sa/4.0/")!)
    }
}
#endif
