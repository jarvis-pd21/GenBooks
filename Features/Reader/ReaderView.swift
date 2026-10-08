import SwiftUI
import UIKit

/// Production reader chrome: continuous TextKit surface + TOC / search / font / theme / progress + learning actions.
struct ReaderView: View {
    @StateObject private var model: ReaderViewModel
    @StateObject private var listen: ListenViewModel
    @StateObject private var askVoice: AskVoiceController
    @ObservedObject private var orientation = ReaderOrientationController.shared
    @ObservedObject private var settings: ReaderSettingsStore
    @State private var showTOC = false
    @State private var showSearch = false
    @FocusState private var searchFocused: Bool
    @State private var searchPreviewScrollToken = UUID()
    @State private var showSettings = false
    @State private var showAnnotations = false
    @State private var showBookmarks = false
    @State private var showVocabulary = false
    @State private var showListen = false
    @State private var showOverflow = false
    @State private var overflowDetent: PresentationDetent = .large
    @State private var overflowFollowUp: ReaderOverflowAction?
    @State private var chromeVisible = true
    @State private var bottomChromeHeight: CGFloat = TextKitReaderUIView.bottomInset
    @State private var pageChrome = ReaderPageChromeState(index: 0, count: 1)
    @State private var showGoToPage = false
    @State private var pageJumpToken: UUID?
    @State private var pageJumpIndex: Int?
    private var forceChromeVisible: Bool {
        ProcessInfo.processInfo.arguments.contains("-uitesting")
    }
    private let annotations: AnnotationStoring
    private let vocabulary: VocabularyStoring
    private let bookmarks: BookmarkStoring
    @ObservedObject private var modelPrefs: AIModelPreferenceStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let keyStore: APIKeyStoring
    private let originalDocumentsRoot: URL?
    private let textCheckpoints: ReadingCheckpointStoring
    @State private var originalDocument: LoadedOriginalDocument?
    @State private var originalPageIndex = 0
    @State private var originalPagePoint: CGPoint?
    @State private var originalLoadError: String?
    @State private var originalPositionError: String?
    @State private var checkedOriginal = false
    @State private var showsOriginalPages = true

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
        modelPrefs: AIModelPreferenceStore,
        keyStore: APIKeyStoring = KeychainAPIKeyStore.shared,
        originalDocumentsRoot: URL? = nil,
        askService: (any AIService)? = nil,
        listenServices: ListenServices? = nil
    ) {
        let pair: (ask: any AIService, adaptation: any AIService)
        if let askService {
            pair = (askService, askService)
        } else {
            pair = AIServiceResolver.makeAskAndAdaptation(
                keyStore: keyStore,
                askModel: modelPrefs.askModel,
                generationModel: modelPrefs.generationModel
            )
        }
        let vm = ReaderViewModel(
            book: book,
            versioning: versioning,
            checkpoints: checkpoints,
            settings: settings,
            annotations: annotations,
            vocabulary: vocabulary,
            bookmarks: bookmarks,
            feedbackStore: feedbackStore,
            preferenceStore: preferenceStore,
            askService: pair.ask,
            adaptationAI: pair.adaptation
        )
        _model = StateObject(wrappedValue: vm)
        let resolvedListenServices = listenServices ?? ListenServices.makeDefault(keyStore: keyStore)
        _listen = StateObject(
            wrappedValue: ListenViewModel(
                bookId: book.id,
                services: resolvedListenServices,
                documentProvider: { chapterId, voice in
                    vm.makeListenDocument(chapterId: chapterId, voice: voice)
                },
                chapterOrderProvider: { vm.orderedChapterIds },
                chapterTitleProvider: { chapterId in
                    vm.chapters.first(where: { $0.id == chapterId })?.title ?? ""
                }
            )
        )
        // Answers are spoken through the Listen narration path, falling back to
        // on-device speech when no key is present.
        _askVoice = StateObject(
            wrappedValue: AskVoiceController(
                dictation: AskVoiceFactory.makeDictation(),
                speaker: AskVoiceFactory.makeReplySpeaker(services: resolvedListenServices)
            )
        )
        _settings = ObservedObject(wrappedValue: settings)
        _modelPrefs = ObservedObject(wrappedValue: modelPrefs)
        self.annotations = annotations
        self.vocabulary = vocabulary
        self.bookmarks = bookmarks
        self.keyStore = keyStore
        self.originalDocumentsRoot = originalDocumentsRoot
        self.textCheckpoints = checkpoints
    }

    var body: some View {
        Group {
            if !checkedOriginal {
                ProgressView("Opening…")
                    .accessibilityIdentifier("reader.loading")
            } else if let error = originalLoadError {
                ContentUnavailableView {
                    Label("Original file unavailable", systemImage: "doc.badge.ellipsis")
                } description: {
                    Text(error + " Your saved text and notes have not changed.")
                } actions: {
                    Button("Open text view") {
                        originalLoadError = nil
                        setOriginalMode(false)
                    }
                    .accessibilityIdentifier("original.error.text")
                }
            } else if showsOriginalPages, let original = originalDocument {
                OriginalPDFReaderView(
                    url: original.url,
                    title: model.book.title,
                    initialPageIndex: originalPageIndex,
                    initialPoint: originalPagePoint,
                    chapterLocations: original.attachment.chapters,
                    onPositionChange: { index, point in
                        saveOriginalPosition(index: index, point: point, original: original)
                    },
                    onShowText: { setOriginalMode(false) }
                )
                .id(original.attachment.source.sha256)
                .safeAreaInset(edge: .bottom) {
                    if let originalPositionError {
                        Text(originalPositionError)
                            .font(.caption)
                            .padding(8)
                            .background(.regularMaterial)
                            .accessibilityIdentifier("original.position.error")
                    }
                }
            } else {
                textReaderBody
                    .safeAreaInset(edge: .top, spacing: 0) {
                        if originalDocument != nil {
                            HStack {
                                Text("Text view")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button { setOriginalMode(true) } label: {
                                    Label("Original pages", systemImage: "doc.richtext")
                                }
                                .font(.subheadline.weight(.semibold))
                                .accessibilityIdentifier("reader.original.button")
                            }
                            .padding(.horizontal)
                            .padding(.vertical, 8)
                            .background(.regularMaterial)
                        }
                    }
            }
        }
        .background(ReaderOrientationObserver().allowsHitTesting(false).accessibilityHidden(true))
        .task { loadOriginalDocument() }
    }

    private var originalModeKey: String { "livingreader.original.mode.\(model.book.id.uuidString)" }

    private func setOriginalMode(_ original: Bool) {
        if original, model.isReady {
            model.prepareForTextRemount()
            pageJumpToken = nil
            pageJumpIndex = nil
        }
        showsOriginalPages = original
        UserDefaults.standard.set(original ? "original" : "text", forKey: originalModeKey)
    }

    private func loadOriginalDocument() {
        guard !checkedOriginal else { return }
        defer { checkedOriginal = true }
        do {
            let store = try OriginalDocumentStore(rootDirectory: originalDocumentsRoot)
            originalDocument = try store.load(bookID: model.book.id)
            if let original = originalDocument {
                do {
                    if let position = try store.loadPosition(bookID: model.book.id, sourceSHA256: original.attachment.source.sha256) {
                        originalPageIndex = position.pageIndex
                        if let x = position.pagePointX, let y = position.pagePointY {
                            originalPagePoint = CGPoint(x: x, y: y)
                        }
                    } else if let checkpoint = try? textCheckpoints.loadCheckpoint(bookId: model.book.id),
                              let chapter = original.attachment.chapters.first(where: { $0.chapterID == checkpoint.chapterId }) {
                        // A verified chapter start is a useful first opening; it is
                        // not a translation of a text offset or proof of reading.
                        originalPageIndex = chapter.pageIndex
                    }
                } catch {
                    originalPositionError = "Your saved page could not be read. The original file is still available."
                }
                showsOriginalPages = UserDefaults.standard.string(forKey: originalModeKey) != "text"
            }
        } catch {
            originalLoadError = error.localizedDescription
        }
    }

    private func saveOriginalPosition(index: Int, point: CGPoint?, original: LoadedOriginalDocument) -> Bool {
        originalPageIndex = index
        originalPagePoint = point
        do {
            let store = try OriginalDocumentStore(rootDirectory: originalDocumentsRoot)
            try store.savePosition(bookID: model.book.id, sourceSHA256: original.attachment.source.sha256,
                                   pageIndex: index, pagePointX: point.map { Double($0.x) },
                                   pagePointY: point.map { Double($0.y) })
            originalPositionError = nil
            return true
        } catch {
            originalPositionError = "Your page could not be saved. Reading is still available."
            return false
        }
    }

    private var textReaderBody: some View {
        ZStack {
            (settings.typography.backgroundColor.swiftUIColor)
                .ignoresSafeArea()

            if let error = model.loadError {
                ContentUnavailableView("Couldn’t open book", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if let document = model.document, model.isReady {
                TextKitReaderRepresentable(
                    document: document,
                    typography: settings.typography,
                    scrollMode: settings.scrollMode,
                    restoreLocation: model.restoreLocation,
                    searchHighlight: model.activeSearchRange,
                    jumpToken: model.jumpToken,
                    jumpUtf16: model.jumpUtf16,
                    jumpAnimated: model.jumpAnimated,
                    pageJumpToken: pageJumpToken,
                    pageJumpIndex: pageJumpIndex,
                    documentEpoch: model.documentEpoch,
                    persistentHighlights: model.persistentHighlightPaint,
                    highlightEpoch: model.highlightEpoch,
                    bottomChromeHeight: (chromeVisible || forceChromeVisible) ? bottomChromeHeight : 0,
                    onLocationChange: { model.handleLocationChange($0) },
                    onSelectionChange: { model.handleSelectionChange($0) },
                    onPageStateChange: { pageChrome = $0 },
                    onTapAtOffset: { model.handleTapAtDocumentOffset($0) }
                )
                .ignoresSafeArea(edges: .bottom)
                .accessibilityIdentifier("reader.screen")
                .background(
                    Text(model.currentChapterTitle)
                        .accessibilityIdentifier("reader.currentChapter")
                        .accessibilityLabel(model.currentChapterTitle)
                        .opacity(0.01)
                        .accessibilityAddTraits(.isStaticText)
                )
                .background {
                    if let proof = model.offlineSourceEvidenceForUI {
                        Text("Authored offline source fixture")
                            .accessibilityIdentifier("reader.source.offlineProof")
                            .accessibilityValue(proof)
                            .opacity(0.01)
                            .accessibilityAddTraits(.isStaticText)
                    }
                }
                .onTapGesture {
                    guard !forceChromeVisible else { return }
                    // A tap that landed on a note opens it; don't also swallow the chrome.
                    guard !model.showNoteEditor else { return }
                    if reduceMotion {
                        chromeVisible.toggle()
                    } else {
                        withAnimation(.easeInOut(duration: 0.2)) { chromeVisible.toggle() }
                    }
                }
            } else {
                ProgressView("Opening…")
                    .accessibilityIdentifier("reader.loading")
            }

            if let banner = model.bannerMessage {
                VStack {
                    Spacer()
                    Text(banner)
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.bottom, 72)
                        .accessibilityIdentifier("reader.banner")
                }
                .transition(.opacity)
                .allowsHitTesting(false)
            }

            if settings.dimOpacity > 0.005 {
                Color.black
                    .opacity(settings.dimOpacity)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("reader.page.dim")
                    .accessibilityHidden(true)
            }
        }
        .navigationTitle(model.currentChapterTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar((chromeVisible || forceChromeVisible) ? .visible : .hidden, for: .navigationBar)
        .toolbar {
            // Books-like visible chrome only. Extra icons were collapsing into a
            // system "…" that wrapped this Menu — a dead intermediate screen.
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { showSettings = true } label: {
                    Image(systemName: "textformat.size")
                }
                .accessibilityIdentifier("reader.settings.button")
                .accessibilityLabel("Reading settings")

                Button { showTOC = true } label: {
                    Image(systemName: "list.bullet")
                }
                .accessibilityIdentifier("reader.toc.button")
                .accessibilityLabel("Table of contents")

                Button { showSearch = true } label: {
                    Image(systemName: "magnifyingglass")
                }
                .accessibilityIdentifier("reader.search.button")
                .accessibilityLabel("Search")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    overflowDetent = .large
                    showOverflow = true
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityIdentifier("reader.more.button")
                .accessibilityLabel("More")
                .accessibilityHint(
                    model.book.canMakeLivingFromCanon
                        ? "Make Living, Ask BookBot, bookmarks, and more"
                        : "Ask BookBot, bookmarks, words, and more"
                )
            }
        }
        .sheet(isPresented: $showOverflow, onDismiss: { performOverflowFollowUp() }) { overflowSheet }
        .safeAreaInset(edge: .bottom) {
            Group {
                if (chromeVisible || forceChromeVisible), model.isReady {
                    VStack(spacing: 8) {
                        if model.returnLocation != nil {
                            returnPill
                        }
                        if model.nearChapterEnd && model.canFinishCurrentChapter {
                            Button {
                                model.beginFinishChapter()
                            } label: {
                                Label("Finish chapter", systemImage: "checkmark.circle.fill")
                                    .font(.subheadline.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .padding(.horizontal, 16)
                            .accessibilityIdentifier("reader.finish.banner")
                        }
                        AdaptationStatusBanner(state: model.adaptationState,
                            message: model.isSourceWordRegen ? model.sourceWordRegenerationStatusMessage : model.adaptationError)
                            .padding(.horizontal, 16)
                        if model.activeSearchHitIndex != nil {
                            searchHitBar
                        }
                        if settings.scrollMode == .pages {
                            pageModeChrome
                        } else {
                            progressBar
                        }
                    }
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(key: ReaderBottomChromeHeightKey.self, value: proxy.size.height)
                        }
                    }
                } else {
                    Color.clear
                        .frame(height: 0)
                        .preference(key: ReaderBottomChromeHeightKey.self, value: 0)
                }
            }
        }
        .onPreferenceChange(ReaderBottomChromeHeightKey.self) { height in
            bottomChromeHeight = height
        }
        .sheet(isPresented: $showTOC) { tocSheet }
        .sheet(isPresented: $showSearch) { searchSheet }
        .sheet(isPresented: $showSettings) { settingsSheet }
        .sheet(isPresented: $showGoToPage) { goToPageSheet }
        .sheet(isPresented: $model.showSelectionActions) {
            if let selection = model.activeSelection {
                SelectionActionsSheet(
                    selection: selection,
                    hasExistingNote: model.selectionHasExistingNote,
                    onDefine: { model.performDefine() },
                    onAsk: { model.performAsk() },
                    onLearn: { model.performLearn() },
                    onNote: { model.beginNote() },
                    onBookmark: { model.performBookmark() },
                    onListen: {
                        model.showSelectionActions = false
                        if let offset = model.narrationUTF16Offset(for: selection) {
                            listen.openFromWord(chapterId: selection.chapterId, narrationUTF16Offset: offset)
                        } else {
                            listen.open(chapterId: selection.chapterId)
                        }
                        showListen = true
                    },
                    onRegenerateFromWord: { model.beginRegenerateFromWord() },
                    onClose: { model.showSelectionActions = false }
                )
            }
        }
        .sheet(isPresented: $model.showDefineSheet) {
            if let result = model.defineResult {
                DefineSheet(
                    result: result,
                    onExplainInContext: { model.performExplainInContext() },
                    onClose: { model.showDefineSheet = false }
                )
            }
        }
        .sheet(isPresented: $model.showAskSheet) {
            AskSheet(
                session: model.askSession,
                voice: askVoice,
                onClose: { model.showAskSheet = false }
            )
        }
        .sheet(isPresented: $model.showNoteEditor) {
            NoteEditorSheet(
                selectedText: model.noteEditTarget?.row?.selectedText ?? model.activeSelection?.selectedText ?? "",
                isEditingExisting: model.noteEditTarget != nil,
                draft: $model.noteDraft,
                color: $model.noteColor,
                onSave: { try model.saveNoteFromEditor() },
                onClose: { model.dismissNoteEditor() },
                onDelete: model.noteEditTarget?.row == nil ? nil : { try model.deleteEditingNote() }
            )
        }
        .sheet(isPresented: $showAnnotations, onDismiss: { model.reloadAnnotations() }) {
            NavigationStack {
                BookNotesListView(
                    bookId: model.book.id,
                    annotations: annotations,
                    onOpen: { row in
                        showAnnotations = false
                        model.jumpToBlock(blockId: row.range.blockId, utf16OffsetInBlock: row.range.utf16Start)
                    }
                )
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { showAnnotations = false }
                    }
                }
            }
        }
        .sheet(isPresented: $showBookmarks, onDismiss: { model.reloadBookmarks() }) {
            NavigationStack {
                BookBookmarksListView(
                    bookId: model.book.id,
                    bookTitle: model.book.title,
                    bookmarks: bookmarks,
                    onOpen: { bookmark in
                        showBookmarks = false
                        model.jumpToBookmark(bookmark)
                    }
                )
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { showBookmarks = false }
                            .accessibilityIdentifier("reader.bookmarks.done")
                    }
                }
            }
        }
        .sheet(isPresented: $showListen, onDismiss: { listen.persistResumePoint() }) {
            ListenSheet(model: listen, onClose: { showListen = false })
                .onAppear {
                    // Selection → Listen already called openFromWord; don't clobber it.
                    if listen.document == nil || listen.phase == .idle {
                        listen.open(chapterId: model.currentChapterId)
                    } else if listen.document?.chapterId != model.currentChapterId, !listen.isPlaying {
                        listen.open(chapterId: model.currentChapterId)
                    }
                }
        }
        .sheet(isPresented: $showVocabulary) {
            NavigationStack {
                VocabularyListView(
                    store: vocabulary,
                    bookId: model.book.id,
                    onOpen: { entry in
                        showVocabulary = false
                        model.jumpToBlock(blockId: entry.blockId)
                    }
                )
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { showVocabulary = false }
                    }
                }
            }
        }
        .sheet(isPresented: $model.showFeedbackSheet) {
            ChapterFeedbackSheet(
                chapterTitle: model.finishedChapterTitle.isEmpty ? model.currentChapterTitle : model.finishedChapterTitle,
                overall: $model.feedbackOverall,
                moreOf: $model.feedbackMoreOf,
                lessOf: $model.feedbackLessOf,
                freeText: $model.feedbackFreeText,
                isSubmitting: model.isAdaptationBusy,
                onSubmit: { Task { await model.submitFeedbackAndBuildPlan() } },
                onClose: { model.showFeedbackSheet = false },
                onBundledExample: model.book.id == ArgentinaFixtureIDs.book && !model.book.isCanonImport
                    ? { Task { await model.submitFeedbackAndBuildPlan(useBundledExample: true) } } : nil,
                errorMessage: model.adaptationError
            )
        }
        .sheet(isPresented: $model.showAdaptationPlanSheet) {
            if let plan = model.adaptationPlan {
                AdaptationPlanSheet(
                    plan: plan,
                    isApplying: model.isAdaptationBusy && model.adaptationState == .applying,
                    errorMessage: model.adaptationError,
                    fromCanon: model.book.isCanonImport || model.book.isLivingFromCanon,
                    allowsLengthChange: !model.isBundledAdaptationPlan,
                    lengthPreset: $model.applyLengthPreset,
                    onLengthChanged: { model.adaptationLengthChanged() },
                    onApply: { Task { await model.applyAdaptationPlan() } },
                    onCancel: { Task { await model.cancelAdaptation() } },
                    onClose: { model.showAdaptationPlanSheet = false }
                )
            }
        }
        .sheet(isPresented: $model.showVersionHistory) {
            VersionHistoryView(
                bookTitle: model.book.title,
                entries: model.versionHistoryEntries,
                isRestoring: model.isVersionRestoring,
                errorMessage: model.versionHistoryError,
                focusChapterId: model.versionHistoryFocusChapterId,
                onRestore: { entry in
                    Task { await model.restoreVersion(entry) }
                },
                onClose: { model.showVersionHistory = false }
            )
        }
        .sheet(isPresented: $model.showRegenerateFromWord) {
            if let anchor = model.wordAnchor {
                RegenerateFromWordSheet(
                    anchor: anchor,
                    chapterFinished: model.wordRegenChapterLocked,
                    intents: $model.wordRegenIntents,
                    freeText: $model.wordRegenFreeText,
                    preview: model.wordRegenPreview,
                    isSourceMode: model.isSourceWordRegen,
                    sourceState: model.sourceWordRegenState,
                    offlineEvidence: model.offlineSourceEvidenceForUI,
                    isBusy: model.isAdaptationBusy,
                    canPreview: model.canPreviewWordRegen,
                    canApply: model.canApplyWordRegen,
                    errorMessage: model.wordRegenError,
                    onRequestChanged: { model.wordRegenRequestChanged() },
                    onBuildPreview: { Task { await model.buildWordForwardPreview() } },
                    onApply: { Task { await model.applyWordForwardPreview() } },
                    onOpenVersionHistory: {
                        guard !model.isAdaptationBusy else { return }
                        model.showRegenerateFromWord = false
                        Task { await model.openVersionHistory(focusChapterId: anchor.chapterId) }
                    },
                    onClose: { model.closeWordRegeneration() },
                    onStartNewSourceChange: { Task { await model.startNewSourceWordRegeneration() } }
                )
            }
        }
        .sheet(isPresented: $model.showRegenerateFromHere) {
            RegenerateFromHereSheet(
                chapters: model.chapters,
                lockedChapterIds: model.consumedChapterIds,
                selectedChapterId: $model.regenSelectedChapterId,
                preview: model.regenPreview,
                isBusy: model.isAdaptationBusy,
                errorMessage: model.regenError,
                remainingLabel: model.remainingReadingLabel,
                fromCanon: model.book.isCanonImport || model.book.isLivingFromCanon,
                lengthPreset: $model.applyLengthPreset,
                onCutChanged: { model.regenerationCutChanged() },
                onLengthChanged: { model.regenerationLengthChanged() },
                onBuildPreview: { Task { await model.buildRegenerationPreview() } },
                onApply: { Task { await model.applyRegenerationPreview() } },
                onClose: { model.showRegenerateFromHere = false }
            )
        }
        .task {
            if !model.isReady { await model.open() }
        }

        .onChange(of: settings.fontSize) { _, _ in
            model.rebuildDocumentPreservingLocation()
        }
        .onChange(of: settings.colorScheme) { _, _ in
            model.rebuildDocumentPreservingLocation()
        }
        .onChange(of: settings.fontFamily) { _, _ in
            model.rebuildDocumentPreservingLocation()
        }
        .onChange(of: settings.lineSpacing) { _, _ in
            model.rebuildDocumentPreservingLocation()
        }
        .onChange(of: settings.marginInset) { _, _ in
            model.rebuildDocumentPreservingLocation()
        }
        .onChange(of: settings.justified) { _, _ in
            model.rebuildDocumentPreservingLocation()
        }
        .onDisappear {
            Task { await model.persistNow() }
            model.askSession.cancelInFlight()
            askVoice.shutDown()
            listen.close()
        }
        .onChange(of: scenePhase) { _, phase in
            // RDR-703: background/inactive must flush checkpoint (terminate mid-reading).
            if phase == .background || phase == .inactive {
                Task { await model.persistNow() }
                // Narration keeps playing in the background; only the resume point is flushed.
                listen.persistResumePoint()
            }
        }
        .onChange(of: model.showAskSheet) { _, isPresented in
            if !isPresented {
                model.askSession.cancelInFlight()
                askVoice.shutDown()
            }
        }
    }

    /// Pages-mode chrome: N of M + Go to page (Codex language), while Scroll keeps the scrubber.
    private var pageModeChrome: some View {
        HStack(spacing: 12) {
            listenChromeButton
            Button {
                pageJumpIndex = max(0, pageChrome.index - 1)
                pageJumpToken = UUID()
            } label: {
                Image(systemName: "chevron.left")
                    .frame(minWidth: 44, minHeight: 44)
            }
            .disabled(pageChrome.index <= 0)
            .accessibilityIdentifier("reader.page.prev")
            .accessibilityLabel("Previous page")

            Button {
                showGoToPage = true
            } label: {
                Text(pageChrome.displayLabel)
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 80, minHeight: 44)
            }
            .accessibilityIdentifier("reader.page.status")
            .accessibilityLabel("Page \(pageChrome.displayLabel). Go to page")

            Button {
                pageJumpIndex = pageChrome.index + 1
                pageJumpToken = UUID()
            } label: {
                Image(systemName: "chevron.right")
                    .frame(minWidth: 44, minHeight: 44)
            }
            .disabled(pageChrome.index >= max(0, pageChrome.count - 1))
            .accessibilityIdentifier("reader.page.next")
            .accessibilityLabel("Next page")
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
    }

    private var goToPageSheet: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper(
                        value: Binding(
                            get: { ReaderPageGeometry.displayPage(indexZeroBased: pageChrome.index, count: pageChrome.count) },
                            set: { newValue in
                                let count = max(1, pageChrome.count)
                                let clamped = min(count, max(1, newValue))
                                pageJumpIndex = clamped - 1
                                pageJumpToken = UUID()
                            }
                        ),
                        in: 1...max(1, pageChrome.count)
                    ) {
                        Text("Page \(pageChrome.displayLabel)")
                            .accessibilityIdentifier("reader.goto.page.label")
                    }
                    .accessibilityIdentifier("reader.goto.page.stepper")
                } footer: {
                    Text("Pages resize with type size and screen layout. Your semantic reading place stays saved.")
                }
            }
            .navigationTitle("Go to page")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showGoToPage = false }
                        .accessibilityIdentifier("reader.goto.done")
                }
            }
        }
        .presentationDetents([.medium])
        .accessibilityIdentifier("reader.goto.sheet")
    }

    /// Books-style bottom chrome: Listen + scrubber over "N min left in chapter" and overall %.
    private var progressBar: some View {
        VStack(spacing: 4) {
            // Preview on drag; commit seek once on finger-up (Apple Books–like).
            Slider(
                value: Binding(
                    get: { model.progress },
                    set: { model.scrubberChanged($0) }
                ),
                in: 0...1,
                step: 0.01,
                onEditingChanged: { model.scrubberEditingChanged($0) }
            )
            .tint(.accentColor)
            .accessibilityIdentifier("reader.scrubber")
            .accessibilityLabel("Book position")
            .accessibilityValue(model.progressPercentLabel)

            HStack(spacing: 8) {
                listenChromeButton
                Text(model.timeLeftLabel)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityIdentifier("reader.timeLeft")
                    .accessibilityLabel(model.timeLeftInChapter.accessibilityLabel)
                Spacer(minLength: 8)
                Text(model.progressPercentLabel)
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("reader.progress.label")
                    .accessibilityLabel("\(model.progressPercentLabel) of book read")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 10)
        .background(.ultraThinMaterial)
    }

    /// Undo affordance for scrubs / TOC / search jumps, so exploring the book
    /// never costs the reader their place.
    private var returnPill: some View {
        HStack(spacing: 10) {
            Button {
                model.returnToRememberedLocation()
            } label: {
                Label(model.returnLocationLabel, systemImage: "arrow.uturn.backward")
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
            }
            .accessibilityIdentifier("reader.return.button")

            Button {
                model.dismissReturnLocation()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("reader.return.dismiss")
            .accessibilityLabel("Dismiss return to previous position")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.thinMaterial, in: Capsule())
    }

    private var searchHitBar: some View {
        HStack(spacing: 14) {
            Text(model.searchStatusLabel)
                .font(.caption.monospacedDigit().weight(.semibold))
                .accessibilityIdentifier("reader.search.status")
            Spacer()
            Button { model.advanceSearch(by: -1) } label: {
                Image(systemName: "chevron.up")
            }
            .accessibilityIdentifier("reader.search.prev")
            .accessibilityLabel("Previous search result")

            Button { model.advanceSearch(by: 1) } label: {
                Image(systemName: "chevron.down")
            }
            .accessibilityIdentifier("reader.search.next")
            .accessibilityLabel("Next search result")

            Button { model.clearSearch() } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("reader.search.clear")
            .accessibilityLabel("Clear search")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    /// Real overflow menu — one tap from More, never a …-only intermediate.
    /// Listen lives on the bottom bar (1 tap). Finish stays on the chapter-end banner.
    private var overflowSheet: some View {
        NavigationStack {
            List {
                overflowRow(BookBotChrome.askAction, "bubble.left.and.bubble.right", "reader.ask.button") {
                    chooseOverflow(.ask)
                }
                overflowRow("Bookmarks", "bookmark", "reader.bookmarks.button") {
                    chooseOverflow(.bookmarks)
                }
                overflowRow("Notes", "note.text", "reader.notes.button") {
                    chooseOverflow(.annotations)
                }
                overflowRow("Words", "textformat.abc", "reader.vocab.button") {
                    chooseOverflow(.words)
                }
                overflowRow("Version history", "clock.arrow.circlepath", "reader.versionHistory.button") {
                    chooseOverflow(.versionHistory)
                }
                if model.book.canMakeLivingFromCanon {
                    overflowRow("Make Living", "sparkles", "reader.makeLiving.button") {
                        chooseOverflow(.makeLiving)
                    }
                } else {
                    overflowRow("Regenerate from here", "arrow.triangle.2.circlepath", "reader.regen.button") {
                        chooseOverflow(.regen)
                    }
                }
            }
            .listStyle(.plain)
            .scrollIndicators(.visible, axes: .vertical)
            .scrollIndicatorsFlash(onAppear: true)
            .navigationTitle("More")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { showOverflow = false }
                        .accessibilityIdentifier("reader.overflow.done")
                }
            }
        }
        .presentationDetents([.medium, .large], selection: $overflowDetent)
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("reader.overflow.sheet")
    }

    /// Books-familiar Listen on existing bottom chrome — not a 5th top-bar icon
    /// (that reintroduced the system-… overflow in #45/#46).
    private var listenChromeButton: some View {
        Button { showListen = true } label: {
            Image(systemName: "headphones")
                .frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityIdentifier("reader.listen.button")
        .accessibilityLabel("Listen")
    }

    private func chooseOverflow(_ action: ReaderOverflowAction) {
        overflowFollowUp = action
        showOverflow = false
    }

    private func performOverflowFollowUp() {
        guard let overflowFollowUp else { return }
        let action = overflowFollowUp
        self.overflowFollowUp = nil
        // Present the follow-up on the next turn so SwiftUI can finish dismissing
        // the overflow sheet (same-frame sheet swap drops Listen/Words intermittently).
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 80_000_000)
            applyOverflow(action)
        }
    }

    private func applyOverflow(_ overflowFollowUp: ReaderOverflowAction) {
        switch overflowFollowUp {
        case .ask:
            model.performAskFromToolbar()
        case .bookmarks:
            showBookmarks = true
        case .annotations:
            showAnnotations = true
        case .words:
            showVocabulary = true
        case .versionHistory:
            Task { await model.openVersionHistory() }
        case .regen:
            Task { await model.openRegenerateFromHere() }
        case .makeLiving:
            Task { await model.openMakeLivingFromCanon() }
        }
    }

    private func overflowRow(
        _ title: String,
        _ systemImage: String,
        _ identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .accessibilityIdentifier(identifier)
        .accessibilityLabel(title)
    }

    private var tocSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    NavigationLink {
                        BookGuideView(book: model.book, onDone: { showTOC = false })
                    } label: {
                        Label("Book Guide", systemImage: "info.circle")
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 8)
                    }
                    .accessibilityIdentifier("reader.toc.guide")
                    Divider()
                    ForEach(model.chapters, id: \.id) { chapter in
                        let isCurrent = model.currentChapterId == chapter.id
                        Button {
                            model.jumpToChapter(id: chapter.id)
                            showTOC = false
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: isCurrent ? "bookmark.fill" : "bookmark")
                                    .font(.caption)
                                    .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(chapter.title)
                                        .font(isCurrent ? .body.weight(.semibold) : .body)
                                        .foregroundStyle(.primary)
                                        .multilineTextAlignment(.leading)
                                    Text(model.chapterEstimate(chapter.id).compactLabel)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 8)
                                if isCurrent {
                                    Text("Now")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(Color.accentColor)
                                        .accessibilityIdentifier("reader.toc.currentBadge")
                                }
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)
                            .background(isCurrent ? Color.accentColor.opacity(0.08) : Color.clear)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("reader.toc.chapter.\(chapter.id.uuidString)")
                        .accessibilityLabel(isCurrent ? "\(chapter.title), current chapter" : chapter.title)
                        .accessibilityAddTraits(isCurrent ? AccessibilityTraits.isSelected : AccessibilityTraits())
                        Divider()
                    }
                }
            }
            .navigationTitle("Contents")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { showTOC = false }
                        .accessibilityIdentifier("reader.toc.done")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .accessibilityIdentifier("reader.toc.sheet")
    }

    private var searchSheet: some View {
        NavigationStack {
          ScrollViewReader { proxy in
            List {
                VStack(alignment: .leading, spacing: 8) {
                    Picker(
                        "Search scope",
                        selection: Binding(
                            get: { settings.searchScope },
                            set: { model.setSearchScope($0) }
                        )
                    ) {
                        ForEach(BookSearchScope.allCases) { scope in
                            Text(scope.displayName).tag(scope)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("reader.search.scope")
                    .accessibilityLabel("Search scope")
                    .accessibilityValue(settings.searchScope.displayName)

                    if settings.searchScope == .wholeBook {
                        Label("Spoilers: includes unread chapters", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("reader.search.spoiler.warning")
                    }
                }
                .padding(.horizontal)
                .padding(.top)

                HStack {
                    TextField("Search in book", text: $model.searchQuery)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("reader.search.field")
                        .focused($searchFocused)
                        .submitLabel(.search)
                        .onSubmit { dismissSearchKeyboard(); model.runSearch() }
                    Button("Find") { dismissSearchKeyboard(); model.runSearch() }
                        .accessibilityIdentifier("reader.search.submit")
                }
                .padding()

                if !model.searchHits.isEmpty {
                    Text(model.searchResultsLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                        .accessibilityIdentifier("reader.search.count")
                }

                if model.searchHits.isEmpty && model.hasSubmittedSearch {
                    ContentUnavailableView("No matches", systemImage: "magnifyingglass")
                } else {
                    ForEach(Array(model.searchHits.enumerated()), id: \.element.id) { index, hit in
                        Button {
                            dismissSearchKeyboard()
                            model.previewSearchHit(at: index)
                            searchPreviewScrollToken = UUID()
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(hit.chapterTitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(hit.snippet)
                                        .font(.body)
                                        .lineLimit(2)
                                }
                                Spacer(minLength: 4)
                                if model.previewSearchHitIndex == index {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(Color.accentColor)
                                        .accessibilityHidden(true)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("reader.search.hit.\(index)")
                        .listRowBackground(
                            model.previewSearchHitIndex == index
                                ? Color.accentColor.opacity(0.10)
                                : Color.clear
                        )
                    }
                }

                if let hit = model.previewedSearchHit {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Preview")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                        Text(hit.chapterTitle)
                            .font(.subheadline.weight(.semibold))
                        Text(hit.snippet)
                            .font(.callout)
                            .lineLimit(3)
                        Label("Your Continue Reading place is unchanged.", systemImage: "bookmark")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("reader.search.preview.unchanged")
                        Button {
                            if model.continueFromSearchPreview() {
                                showSearch = false
                            }
                        } label: {
                            Label("Continue from here", systemImage: "arrow.right.circle.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("reader.search.continue")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(.thinMaterial)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("reader.search.preview")
                    .id("reader.search.preview")
                }
            }
            .listStyle(.plain)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: searchPreviewScrollToken) { _, _ in
                proxy.scrollTo("reader.search.preview", anchor: .bottom)
            }
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { showSearch = false }
                        .accessibilityIdentifier("reader.search.done")
                }
            }
          }
        }
        .presentationDetents([.large])
        .accessibilityIdentifier("reader.search.sheet")
    }

    private func dismissSearchKeyboard() {
        searchFocused = false
        // List row reuse can retain UIKit's first responder after the SwiftUI
        // focus binding clears. A committed search must reveal its results.
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private var settingsSheet: some View {
        NavigationStack {
            Form {
                Section {
                    // Explicit buttons (not SwiftUI segmented Picker): XCUITest
                    // frequently fails to commit the Scroll segment under full-suite
                    // load even though Pages taps work. Buttons set scrollMode
                    // directly and expose stable per-mode identifiers.
                    HStack(spacing: 0) {
                        ForEach(ReaderScrollMode.allCases) { mode in
                            let selected = settings.scrollMode == mode
                            Button {
                                settings.scrollMode = mode
                            } label: {
                                Text(mode.displayName)
                                    .font(.subheadline.weight(selected ? .semibold : .regular))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                                    .background(selected ? Color.accentColor.opacity(0.18) : Color.clear)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("reader.scrollMode.\(mode.rawValue)")
                            .accessibilityLabel(mode.displayName)
                            .accessibilityAddTraits(selected ? .isSelected : [])
                        }
                    }
                    .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("reader.scrollMode.picker")
                    .accessibilityLabel("Reading mode")
                } header: {
                    Text("Reading mode")
                } footer: {
                    Text(settings.scrollMode == .pages
                         ? "Swipe or tap page edges to turn pages. Progress stays synced with your place in the book."
                         : "Continuous vertical scroll — the default GenBooks experience.")
                }

                Section("Typeface") {
                    Picker("Font", selection: $settings.fontFamily) {
                        ForEach(ReaderFontFamily.allCases) { family in
                            Text(family.displayName).tag(family)
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("reader.font.family")
                    .accessibilityLabel("Typeface")
                    .accessibilityValue(settings.fontFamily.displayName)

                    HStack(spacing: 14) {
                        Button {
                            settings.bumpFont(by: -1)
                        } label: {
                            Image(systemName: "textformat.size.smaller")
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("reader.font.smaller")
                        .accessibilityLabel("Smaller text")

                        Slider(
                            value: $settings.fontSize,
                            in: Double(ReaderTypography.minBodySize)...Double(ReaderTypography.maxBodySize),
                            step: 1
                        )
                        .accessibilityIdentifier("reader.font.slider")

                        Button {
                            settings.bumpFont(by: 1)
                        } label: {
                            Image(systemName: "textformat.size.larger")
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("reader.font.larger")
                        .accessibilityLabel("Larger text")
                    }
                    Text("\(Int(settings.fontSize)) pt")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("reader.font.size.label")
                        .accessibilityLabel("\(Int(settings.fontSize)) pt")
                }

                Section("Layout") {
                    Toggle("Justify body text", isOn: $settings.justified)
                        .accessibilityIdentifier("reader.justified.toggle")
                        .accessibilityHint("Align body paragraphs to both margins. Other text keeps its original alignment.")
                    HStack(spacing: 12) {
                        Image(systemName: "arrow.up.and.down.text.horizontal")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Slider(
                            value: $settings.lineSpacing,
                            in: Double(ReaderTypography.minLineHeight)...Double(ReaderTypography.maxLineHeight),
                            step: 0.05
                        )
                        .accessibilityIdentifier("reader.lineSpacing.slider")
                        .accessibilityLabel("Line spacing")
                    }
                    HStack(spacing: 12) {
                        Image(systemName: "arrow.left.and.right")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Slider(
                            value: $settings.marginInset,
                            in: Double(ReaderTypography.minInset)...Double(ReaderTypography.maxInset),
                            step: 1
                        )
                        .accessibilityIdentifier("reader.margin.slider")
                        .accessibilityLabel("Page margins")
                    }
                }

                Section("Theme") {
                    HStack(spacing: 12) {
                        themeSwatch(.light)
                        themeSwatch(.sepia)
                        themeSwatch(.dark)
                        themeSwatch(.system)
                    }
                    .padding(.vertical, 2)
                    // Intentionally no container a11y id — it hides child swatch buttons from XCUITest

                    HStack(spacing: 12) {
                        Image(systemName: "sun.min")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Slider(value: $settings.pageDim, in: 0...1, step: 0.05)
                            .accessibilityIdentifier("reader.dim.slider")
                            .accessibilityLabel("Page dim")
                        Image(systemName: "moon")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                }

                Section {
                    Stepper(
                        value: $settings.wordsPerMinute,
                        in: ReaderSettingsStore.minWordsPerMinute...ReaderSettingsStore.maxWordsPerMinute,
                        step: 10
                    ) {
                        Text("\(settings.wordsPerMinute) words per minute")
                            .accessibilityIdentifier("reader.wpm.label")
                    }
                    .accessibilityIdentifier("reader.wpm.stepper")
                } header: {
                    Text("Reading pace")
                } footer: {
                    Text("Sets the “time left” estimate. Estimates use words, not pages, so they stay stable when you change type size.")
                }

                Section {
                    Toggle("Lock orientation", isOn: Binding(
                        get: { orientation.isLocked },
                        set: { orientation.setLocked($0) }
                    ))
                    .disabled(!orientation.isAvailable)
                    .accessibilityIdentifier("reader.orientation.toggle")
                    .accessibilityHint("Keeps the current screen orientation while this book is open")
                    Text(orientation.orientationDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("reader.orientation.status")
                    if let notice = orientation.notice {
                        Text(notice)
                            .font(.caption)
                            .accessibilityIdentifier("reader.orientation.notice")
                    }
                } header: {
                    Text("Orientation")
                } footer: {
                    Text("This book only. Resets to unlocked when you return to Library.")
                }

                AISettingsSection(
                    modelPrefs: modelPrefs,
                    keyStore: keyStore,
                    onAIConfigurationChanged: {
                        model.refreshAIServices(keyStore: keyStore, modelPrefs: modelPrefs)
                    }
                )
            }
            .navigationTitle("Reading settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showSettings = false }
                        .accessibilityIdentifier("reader.settings.done")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .accessibilityIdentifier("reader.settings.sheet")
    }

    /// Page-colour swatch that previews the real palette it selects.
    private func themeSwatch(_ scheme: ReaderColorScheme) -> some View {
        let palette = ReaderPagePalette.forScheme(scheme)
        let isSelected = settings.colorScheme == scheme
        return Button {
            settings.colorScheme = scheme
        } label: {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(palette.background))
                .frame(height: 52)
                .overlay(alignment: .center) {
                    Text(scheme == .system ? "Auto" : "Aa")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color(palette.text))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(
                            isSelected ? Color.accentColor : Color.secondary.opacity(0.35),
                            lineWidth: isSelected ? 2.5 : 1
                        )
                }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("reader.theme.swatch.\(scheme.rawValue)")
        .accessibilityLabel("\(scheme.displayName) theme")
        .accessibilityAddTraits(isSelected ? AccessibilityTraits.isSelected : AccessibilityTraits())
    }
}

private enum ReaderOverflowAction {
    case ask, bookmarks, annotations, words, versionHistory, regen, makeLiving
}

private struct ReaderBottomChromeHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private extension UIColor {
    var swiftUIColor: Color { Color(self) }
}
