import SwiftUI

@MainActor
final class LibraryViewModel: ObservableObject {
    @Published var books: [Book] = []
    @Published var loadError: String?
    @Published private(set) var loadIssues: [LibraryLoadIssue] = []
    @Published private(set) var isLoading = true
    @Published var inboundImportError: String?
    @Published var createError: String?
    @Published var pendingOpenBookID: UUID?
    @Published private(set) var resumableBookIDs: Set<UUID> = []
    @Published private(set) var didLoadOffline = false
    @Published private(set) var progressByBookId: [UUID: Double] = [:]
    @Published private(set) var chapterLabelByBookId: [UUID: String] = [:]
    @Published private(set) var minutesLeftByBookId: [UUID: Int] = [:]
    @Published private(set) var archivedBookIDs: Set<UUID> = []
    @Published private(set) var archiveError: String?
    private var visibilityStore: LibraryVisibilityStore?
    private(set) var versioning: ManuscriptVersioningService?
    private(set) var checkpoints: ReadingCheckpointStoring?
    private(set) var annotations: AnnotationStoring?
    private(set) var bookmarks: BookmarkStoring?
    private(set) var vocabulary: VocabularyStoring?
    private(set) var feedbackStore: FeedbackStoring?
    private(set) var preferenceStore: ReaderPreferenceStoring?
    private(set) var rootDirectory: URL?
    private(set) var listenServices: ListenServices?

    private let ai: MockAIService
    /// File / `genbooks://import` that arrived before stores finished loading.
    private var queuedIncomingURL: URL?
    private var bootstrapIssues: [LibraryLoadIssue] = []

    init(ai: MockAIService = MockAIService(), rootDirectory: URL? = nil) {
        self.ai = ai
        self.rootDirectory = rootDirectory
    }

    var aiAdaptCallCount: Int { ai.adaptCallCount }
    // Keep the complete catalog available to Notebook and existing reading history.
    var visibleBooks: [Book] { books.filter { !archivedBookIDs.contains($0.id) } }
    var archivedBooks: [Book] { books.filter { archivedBookIDs.contains($0.id) } }
    var canChangeArchive: Bool { visibilityStore != nil && !isLoading && loadError == nil }

    func archiveBook(id: UUID) {
        guard books.contains(where: { $0.id == id }) else { return }
        setArchived(true, bookID: id)
    }

    func restoreBook(id: UUID) {
        guard archivedBookIDs.contains(id) else { return }
        setArchived(false, bookID: id)
    }

    private func setArchived(_ archived: Bool, bookID: UUID) {
        guard canChangeArchive, let visibilityStore else { return }
        do {
            archivedBookIDs = try visibilityStore.setArchived(archived, bookID: bookID)
            if archived, pendingOpenBookID == bookID { pendingOpenBookID = nil }
            archiveError = nil
        } catch {
            archiveError = "Couldn’t update Archive. No book or note was removed. \(error.localizedDescription)"
        }
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        loadError = nil
        didLoadOffline = false
        bootstrapIssues = []
        ai.resetCallCount()
        do {
            let root = try rootDirectory ?? Self.defaultRootDirectory()
            rootDirectory = root
            let versioning = try ManuscriptVersioningService(rootDirectory: root)
            let checkpointStore = try FileReadingCheckpointStore(rootDirectory: root)
            let annotationStore = try FileAnnotationStore(rootDirectory: root)
            let bookmarkStore = try FileBookmarkStore(rootDirectory: root)
            let vocabularyStore = try FileVocabularyStore(rootDirectory: root)
            let feedbackStore = try FileFeedbackStore(rootDirectory: root)
            let preferenceStore = try FileReaderPreferenceStore(rootDirectory: root)
            self.versioning = versioning
            self.checkpoints = checkpointStore
            self.annotations = annotationStore
            self.bookmarks = bookmarkStore
            self.vocabulary = vocabularyStore
            self.feedbackStore = feedbackStore
            self.preferenceStore = preferenceStore
            let visibility = LibraryVisibilityStore(rootDirectory: root)
            do {
                archivedBookIDs = try visibility.loadArchivedIDs()
                visibilityStore = visibility
                archiveError = nil
            } catch {
                // Do not rewrite a damaged preference file, or infer archived IDs
                // from books that happened to fail to load.
                visibilityStore = nil
                archiveError = "Archive settings couldn’t be read. No saved files were changed."
            }
            // Listen reuses the same Keychain key as Ask; no second key UI.
            self.listenServices = ListenServices.make(rootDirectory: root)
            // Stores are not @Published; nudge observers so Notebook Words can bind.
            objectWillChange.send()
            bootstrapIssues = await BundleFixtureLoader.seedLibraryBooksIfNeeded(into: versioning)
            try await reloadBooks(using: versioning)
            didLoadOffline = ai.adaptCallCount == 0
            await refreshProgress()

            let argentina = books.first(where: { $0.id == ArgentinaFixtureIDs.book }) ?? books.first
            if ProcessInfo.processInfo.arguments.contains("-phase3SeedAnnotations"), let argentina {
                try Self.seedDemoAnnotations(
                    book: argentina,
                    annotations: annotationStore,
                    vocabulary: vocabularyStore
                )
            }
            if (ProcessInfo.processInfo.arguments.contains("-phase3SeedAnnotations")
                || ProcessInfo.processInfo.arguments.contains("-seedBookmarks")),
               let argentina {
                try Self.seedDemoBookmarks(book: argentina, bookmarks: bookmarkStore)
            }
            if let queued = queuedIncomingURL {
                queuedIncomingURL = nil
                await importIncoming(queued)
            } else if ProcessInfo.processInfo.arguments.contains("-importOpenURL") {
                let url = try BundleFixtureLoader.urlForFriendCanonEPUB()
                await importIncoming(url)
            } else if ProcessInfo.processInfo.arguments.contains("-importTestEPUB") {
                try await importBundledCanonEPUB()
            }
        } catch {
            failLibraryLoad(error)
        }
    }

    /// Files / Share “Open in GenBooks” and the Share Extension URL scheme.
    func handleIncomingURL(_ url: URL) async {
        guard versioning != nil else {
            queuedIncomingURL = url
            return
        }
        await importIncoming(url)
    }

    func importIncoming(_ url: URL) async {
        do {
            switch IncomingCanonURL.parse(url) {
            case .file(let fileURL):
                try await importCanonFile(at: fileURL)
            case .shareInbox:
                guard let container = CanonShareInbox.containerURL() else {
                    inboundImportError = "GenBooks Share is missing its App Group. Use Files → Open in GenBooks instead."
                    return
                }
                guard let payload = try CanonShareInbox.take(container: container) else {
                    inboundImportError = "Nothing was shared. Try Files → Open in GenBooks."
                    return
                }
                try await importCanonFile(at: payload.url)
            case .unsupported:
                inboundImportError = CreateBookError.unsupportedImportType.errorDescription
            }
        } catch {
            inboundImportError = error.localizedDescription
        }
    }

    func reloadBooks() async {
        guard let versioning else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            try await reloadBooks(using: versioning)
            await refreshProgress()
        } catch {
            failLibraryLoad(error)
        }
    }

    func makeCreateViewModel(
        modelPrefs: AIModelPreferenceStore,
        resumingBookID: UUID? = nil
    ) -> CreateBookViewModel? {
        guard loadError == nil, let versioning, let preferenceStore, let rootDirectory else { return nil }
        do {
            let packets = try FilePEPacketStore(rootDirectory: rootDirectory)
            let drafts = try FileCreateBookDraftStore(rootDirectory: rootDirectory)
            let draft: CreateBookDraft
            if let bookID = resumingBookID {
                // Read again on tap: a completed or removed draft must never
                // reopen as a blank book or as another book's latest draft.
                guard books.contains(where: { $0.id == bookID }),
                      let saved = try drafts.load(id: bookID),
                      saved.id == bookID, saved.path == .generate else {
                    resumableBookIDs.remove(bookID)
                    throw CreateBookError.generationFailed("The saved writing draft is no longer available for this book.")
                }
                draft = saved
            } else {
                draft = .blank()
            }
            // Resolve only when the reader opens Create — never on Library appear.
            let adaptation = AIServiceResolver.makeCreateGeneration(
                generationModel: modelPrefs.generationModel
            )
            let wizard = CreateBookWizardService(
                versioning: versioning,
                preferenceStore: preferenceStore,
                packets: packets,
                drafts: drafts,
                ai: adaptation
            )
            createError = nil
            return CreateBookViewModel(wizard: wizard, modelPrefs: modelPrefs, draft: draft)
        } catch {
            createError = error.localizedDescription
            return nil
        }
    }

    /// UITest / smoke: ingest the bundled Plaza Evening EPUB as Canon and open it.
    func importBundledCanonEPUB() async throws {
        let url = try BundleFixtureLoader.urlForFriendCanonEPUB()
        try await importCanonFile(at: url)
    }

    /// Shared Canon ingest for Create picker, Open In, and Share inbox.
    func importCanonFile(at url: URL) async throws {
        guard let versioning, let preferenceStore, let rootDirectory else { return }
        let prepared = try CanonFileIngest.prepare(from: url)
        var draft = CreateBookDraft.blank()
        draft.title = prepared.title ?? ""
        draft.author = prepared.author ?? ""
        draft.importedText = prepared.plainText
        draft.importSourceKind = prepared.sourceKind
        let packets = try FilePEPacketStore(rootDirectory: rootDirectory)
        let drafts = try FileCreateBookDraftStore(rootDirectory: rootDirectory)
        let wizard = CreateBookWizardService(
            versioning: versioning,
            preferenceStore: preferenceStore,
            packets: packets,
            drafts: drafts,
            ai: ai
        )
        let book = try await wizard.importAndSave(draft: draft)
        try await reloadBooks(using: versioning)
        inboundImportError = nil
        pendingOpenBookID = book.id
    }

    private func reloadBooks(using versioning: ManuscriptVersioningService) async throws {
        let snapshot: LibrarySnapshot
        do {
            snapshot = try await versioning.loadLibrarySnapshot()
        } catch {
            failLibraryLoad(error)
            throw error
        }
        books = LibraryBookOrdering.sorted(snapshot.books)
        let validIDs = Set(books.map(\.id))
        let failedFiles = Set(snapshot.issues.map(\.filename))
        // A readable partial book does not prove a failed bundled expansion was
        // recovered. Clear only once every expected bundled chapter is present.
        // Missing books with ledger history remain issues, not fresh seeds.
        bootstrapIssues.removeAll { issue in
            guard let id = issue.bookID, let expected = issue.expectedChapterIDs,
                  let book = books.first(where: { $0.id == id }) else { return false }
            return expected.isSubset(of: Set(book.chapters.map(\.id)))
        }
        loadIssues = (snapshot.issues + bootstrapIssues.filter { !failedFiles.contains($0.filename) })
            .sorted { $0.filename < $1.filename }
        loadError = nil
        if let id = pendingOpenBookID, !validIDs.contains(id) { pendingOpenBookID = nil }
        // A draft without a corresponding shelf book is not a resume action.
        var resumable: Set<UUID> = []
        if let rootDirectory,
           let drafts = try? FileCreateBookDraftStore(rootDirectory: rootDirectory) {
            for book in books {
                if let draft = try? drafts.load(id: book.id),
                   draft.id == book.id, draft.path == .generate {
                    resumable.insert(book.id)
                }
            }
        }
        resumableBookIDs = resumable
    }

    private func failLibraryLoad(_ error: Error) {
        books = []
        loadIssues = []
        resumableBookIDs = []
        progressByBookId = [:]
        chapterLabelByBookId = [:]
        minutesLeftByBookId = [:]
        pendingOpenBookID = nil
        didLoadOffline = false
        loadError = error.localizedDescription
    }

    func refreshProgress() async {
        guard let checkpoints else { return }
        var map: [UUID: Double] = [:]
        var chapters: [UUID: String] = [:]
        var minutes: [UUID: Int] = [:]
        let prefs = ReadingTimePreferences.default
        for book in books {
            let ordered = book.chapters.sorted { $0.orderIndex < $1.orderIndex }
            guard !ordered.isEmpty else {
                map[book.id] = 0
                chapters[book.id] = "No chapters"
                minutes[book.id] = 0
                continue
            }
            let idx: Int
            if let cp = try? checkpoints.loadCheckpoint(bookId: book.id),
               let found = ordered.firstIndex(where: { $0.id == cp.chapterId }) {
                idx = found
            } else {
                idx = 0
            }
            map[book.id] = Double(idx) / Double(ordered.count)
            let chapter = ordered[idx]
            chapters[book.id] = "Chapter \(idx + 1) · \(chapter.title)"
            let remainingBlocks = ordered[idx...].compactMap { $0.activeRevision?.blocks }
            let estimate = ReadingTimeEstimator.estimateRemaining(
                chapterBlocks: Array(remainingBlocks),
                preferences: prefs
            )
            minutes[book.id] = max(0, Int(estimate.remainingMinutes.rounded()))
        }
        progressByBookId = map
        chapterLabelByBookId = chapters
        minutesLeftByBookId = minutes
    }

    static func defaultRootDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let root = base.appendingPathComponent("LivingReader", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func seedDemoAnnotations(
        book: Book,
        annotations: AnnotationStoring,
        vocabulary: VocabularyStoring
    ) throws {
        let chapter = book.chapters.sorted { $0.orderIndex < $1.orderIndex }.first
        let revision = chapter?.activeRevision
        let block = revision?.blocks.first(where: { $0.id == ArgentinaFixtureIDs.block1Quote })
            ?? revision?.blocks.first
        guard let chapter, let revision, let block else { return }

        let range = ContentRangeAnchor(blockId: block.id, utf16Start: 0, utf16Length: min(24, (block.text as NSString).length))
        let highlight = HighlightAnnotation(
            id: UUID(uuidString: "00000000-0000-4000-8000-0000000000f1")!,
            bookId: book.id,
            chapterId: chapter.id,
            chapterTitle: chapter.title,
            revisionId: revision.id,
            range: range,
            selectedText: String((block.text as NSString).substring(to: min(24, (block.text as NSString).length))),
            color: .yellow,
            note: nil,
            createdAt: Date(),
            updatedAt: Date()
        )
        try annotations.saveHighlight(highlight)

        let note = NoteAnnotation(
            id: UUID(uuidString: "00000000-0000-4000-8000-0000000000f2")!,
            bookId: book.id,
            chapterId: chapter.id,
            chapterTitle: chapter.title,
            revisionId: revision.id,
            range: range,
            selectedText: highlight.selectedText,
            body: "Demo note for Phase 3 screenshots.",
            createdAt: Date(),
            updatedAt: Date()
        )
        try annotations.saveNote(note)

        let vocab = VocabularyEntry(
            id: UUID(uuidString: "00000000-0000-4000-8000-0000000000f3")!,
            bookId: book.id,
            bookTitle: book.title,
            chapterId: chapter.id,
            chapterTitle: chapter.title,
            revisionId: revision.id,
            blockId: block.id,
            phrase: "destiny",
            definition: DefineService.offlineFallbackDefinition(for: "destiny", sentenceContext: block.text),
            originalSentence: block.text,
            surroundingContext: block.text,
            note: nil,
            isKnown: false,
            createdAt: Date(),
            updatedAt: Date()
        )
        try vocabulary.save(vocab)
    }

    static func seedDemoBookmarks(book: Book, bookmarks: BookmarkStoring) throws {
        let chapter = book.chapters.sorted { $0.orderIndex < $1.orderIndex }.first
        let revision = chapter?.activeRevision
        let block = revision?.blocks.first(where: { $0.id == ArgentinaFixtureIDs.block1Quote })
            ?? revision?.blocks.first
        guard let chapter, let revision, let block else { return }
        let snippet = String((block.text as NSString).substring(to: min(28, (block.text as NSString).length)))
        let bookmark = NamedBookmark(
            id: UUID(uuidString: "00000000-0000-4000-8000-0000000000f4")!,
            bookId: book.id,
            chapterId: chapter.id,
            chapterTitle: chapter.title,
            revisionId: revision.id,
            blockId: block.id,
            utf16Offset: 0,
            title: NamedBookmark.defaultTitle(chapterTitle: chapter.title, snippet: snippet),
            snippet: snippet,
            createdAt: Date(),
            updatedAt: Date()
        )
        try bookmarks.saveBookmark(bookmark)
    }
}

/// Completion belongs to the sheet that started it, not a newer writing draft.
@MainActor
struct LibraryCreatePresentation {
    var item: CreateBookSheetItem?
    private(set) var latestID: UUID?

    mutating func present(_ model: CreateBookViewModel) -> UUID {
        let item = CreateBookSheetItem(model: model)
        self.item = item
        latestID = item.id
        return item.id
    }

    @discardableResult
    mutating func dismiss(id: UUID) -> Bool {
        guard item?.id == id else { return false }
        item = nil
        return true
    }

    func canOpenCompletedBook(id: UUID) -> Bool {
        latestID == id && item == nil
    }
}

struct LibraryView: View {
    @ObservedObject var model: LibraryViewModel
    var learningModel: LearningViewModel? = nil
    @EnvironmentObject private var settings: ReaderSettingsStore
    @EnvironmentObject private var modelPrefs: AIModelPreferenceStore
    @State private var showSettings = false
    @State private var createPresentation = LibraryCreatePresentation()
    @State private var openedBookID: UUID?
    @State private var showArchive = false

    var body: some View {
        NavigationStack {
            Group {
                if let loadError = model.loadError {
                    VStack {
                        ContentUnavailableView("Library error", systemImage: "exclamationmark.triangle", description: Text(loadError))
                        Button("Try again") { Task { await model.load() } }
                    }
                } else if model.isLoading && model.books.isEmpty {
                    ProgressView("Loading library…")
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            if !model.loadIssues.isEmpty { unavailableFilesNotice }
                            if let error = model.archiveError {
                                Text(error).font(.footnote).foregroundStyle(.red)
                                    .accessibilityIdentifier("library.archive.error")
                            }
                            if model.visibleBooks.isEmpty {
                                ContentUnavailableView(
                                    !model.archivedBooks.isEmpty ? "Your books are in Archive" :
                                        (model.loadIssues.isEmpty ? "Your library is empty" : "No readable books"),
                                    systemImage: "books.vertical",
                                    description: Text(!model.archivedBooks.isEmpty
                                        ? "Open Archive to restore a book, or add a new one with the plus button."
                                        : model.loadIssues.isEmpty
                                        ? "Add a book with the plus button."
                                        : "Existing saved files and reading history have not been replaced. You can add another book."))
                            }
                            ForEach(model.visibleBooks) { book in
                                bookCard(book)
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 12)
                        .padding(.bottom, 24)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(LRColor.cream.ignoresSafeArea())
            .navigationTitle("Library")
            .navigationBarTitleDisplayMode(.large)
            .genBooksNavigationBar()
            .accessibilityIdentifier("library.screen")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        if let vm = model.makeCreateViewModel(modelPrefs: modelPrefs) {
                            presentCreate(vm)
                        }
                    } label: {
                        Image(systemName: "plus")
                            .foregroundStyle(LRColor.navy)
                    }
                    .accessibilityIdentifier("library.create.button")
                    .accessibilityLabel("New Book")
                    .disabled(model.versioning == nil || model.loadError != nil || model.isLoading)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showArchive = true } label: {
                        Image(systemName: "archivebox")
                            .foregroundStyle(LRColor.navy)
                    }
                    .accessibilityIdentifier("library.archive.button")
                    .accessibilityLabel("Archive")
                    .accessibilityValue("\(model.archivedBooks.count) books")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                            .foregroundStyle(LRColor.navy)
                    }
                    .accessibilityIdentifier("library.settings.button")
                    .accessibilityLabel("Settings")
                }
            }
            .sheet(item: $createPresentation.item, onDismiss: {
                Task { await model.reloadBooks() }
            }) { item in
                CreateBookSheet(model: item.model) {
                    createPresentation.dismiss(id: item.id)
                }
            }
            .sheet(isPresented: $showSettings) {
                AppSettingsView(learningModel: learningModel)
            }
            .sheet(isPresented: $showArchive) { archiveSheet }
            .navigationDestination(item: $openedBookID) { id in
                reader(forBookID: id)
            }
            .onAppear {
                if let id = model.pendingOpenBookID {
                    openedBookID = id
                }
            }
            .onChange(of: model.pendingOpenBookID) { _, id in
                if let id {
                    openedBookID = id
                }
            }
            .alert(
                "Couldn’t add book",
                isPresented: Binding(
                    get: { model.inboundImportError != nil },
                    set: { if !$0 { model.inboundImportError = nil } }
                )
            ) {
                Button("OK") { model.inboundImportError = nil }
            } message: {
                Text(model.inboundImportError ?? "")
            }
            .alert(
                "Couldn’t open Create",
                isPresented: Binding(
                    get: { model.createError != nil },
                    set: { if !$0 { model.createError = nil } }
                )
            ) {
                Button("OK") { model.createError = nil }
            } message: {
                Text(model.createError ?? "")
            }
        }
    }

    private func presentCreate(_ viewModel: CreateBookViewModel) {
        let presentationID = createPresentation.present(viewModel)
        viewModel.onFinished = { book in
            Task { @MainActor in
                await model.reloadBooks()
                // A closed background generation still updates the shelf,
                // but cannot dismiss a newer sheet or steal its navigation.
                guard createPresentation.dismiss(id: presentationID) else { return }
                // Let the create sheet finish dismissing before push.
                try? await Task.sleep(nanoseconds: 80_000_000)
                guard createPresentation.canOpenCompletedBook(id: presentationID) else { return }
                openedBookID = book.id
            }
        }
    }

    private var archiveSheet: some View {
        NavigationStack {
            List {
                Section {
                    Text("Archived books stay on this iPhone with their notes, reading place and downloads. Restore a book to put it back in Library.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let error = model.archiveError {
                    Section { Text(error).foregroundStyle(.red) }
                }
                if model.archivedBooks.isEmpty {
                    ContentUnavailableView("No archived books", systemImage: "archivebox",
                        description: Text("Use a book’s More options button to archive it without deleting it."))
                }
                ForEach(model.archivedBooks) { book in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(book.title).font(.headline)
                        if !book.author.isEmpty { Text(book.author).font(.subheadline).foregroundStyle(.secondary) }
                        Button("Restore to Library") { model.restoreBook(id: book.id) }
                            .disabled(!model.canChangeArchive)
                            .accessibilityIdentifier("library.archive.restore.\(book.id.uuidString)")
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("Archive")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showArchive = false }
                        .accessibilityIdentifier("library.archive.done")
                }
            }
        }
        .presentationDetents([.large])
        .accessibilityIdentifier("library.archive.sheet")
    }

    private var unavailableFilesNotice: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                Text("Some content could not be loaded or updated. The affected files have not been replaced. Available books remain readable.")
                ForEach(model.loadIssues) { issue in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(issue.filename).fontWeight(.semibold)
                        Text(issue.reason)
                    }
                    .textSelection(.enabled)
                }
            }
            .font(.caption)
            .padding(.top, 8)
        } label: {
            Label(model.loadIssues.count == 1 ? "1 saved-file issue" : "\(model.loadIssues.count) saved-file issues",
                  systemImage: "exclamationmark.triangle")
                .font(.subheadline)
        }
        .foregroundStyle(LRColor.navy)
        .padding(12)
        .background(LRColor.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("library.unavailable.notice")
    }

    @ViewBuilder
    private func bookCard(_ book: Book) -> some View {
        let progress = model.progressByBookId[book.id] ?? 0
        let percent = Int((progress * 100).rounded())
        let minutes = model.minutesLeftByBookId[book.id] ?? 0
        let chapter = model.chapterLabelByBookId[book.id] ?? chapterSummary(book)

        if model.versioning != nil {
            Button {
                openedBookID = book.id
            } label: {
                compactCardContent(
                    book: book,
                    progress: progress,
                    percent: percent,
                    minutes: minutes,
                    chapter: chapter,
                    showsContinue: true
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("library.book.\(book.id.uuidString)")
            .contextMenu {
                bookMenuItems(book)
            }
            .overlay(alignment: .topTrailing) {
                Menu { bookMenuItems(book) } label: {
                    Image(systemName: "ellipsis")
                        .foregroundStyle(LRColor.secondaryText)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityIdentifier("library.book.more.\(book.id.uuidString)")
                .accessibilityLabel("More options for \(book.title)")
                .padding(.trailing, 6)
                .padding(.top, 4)
            }
        } else {
            compactCardContent(
                book: book,
                progress: progress,
                percent: percent,
                minutes: minutes,
                chapter: chapter,
                showsContinue: false
            )
            .accessibilityIdentifier("library.book.\(book.id.uuidString)")
        }
    }

    @ViewBuilder
    private func bookMenuItems(_ book: Book) -> some View {
        if model.resumableBookIDs.contains(book.id) {
            Button {
                if let vm = model.makeCreateViewModel(modelPrefs: modelPrefs, resumingBookID: book.id) {
                    presentCreate(vm)
                }
            } label: {
                Label("Continue writing", systemImage: "square.and.pencil")
            }
            .accessibilityIdentifier("library.book.continueWriting.\(book.id.uuidString)")
        }
        Button {
            model.archiveBook(id: book.id)
        } label: {
            Label("Archive — keep book and notes", systemImage: "archivebox")
        }
        .disabled(!model.canChangeArchive)
        .accessibilityIdentifier("library.book.archive.\(book.id.uuidString)")
        .accessibilityHint("Keeps book and notes on this iPhone. Restore from Archive.")
    }

    @ViewBuilder
    private func reader(forBookID id: UUID) -> some View {
        if let book = model.books.first(where: { $0.id == id }),
           let versioning = model.versioning,
           let checkpoints = model.checkpoints,
           let annotations = model.annotations,
           let bookmarks = model.bookmarks,
           let vocabulary = model.vocabulary,
           let feedbackStore = model.feedbackStore,
           let preferenceStore = model.preferenceStore {
            ReaderView(
                book: book,
                versioning: versioning,
                checkpoints: checkpoints,
                settings: settings,
                annotations: annotations,
                vocabulary: vocabulary,
                bookmarks: bookmarks,
                feedbackStore: feedbackStore,
                preferenceStore: preferenceStore,
                modelPrefs: modelPrefs,
                listenServices: model.listenServices
            )
            .toolbar(.hidden, for: .tabBar)
            .onDisappear {
                Task { await model.reloadBooks() }
            }
        } else if model.isLoading {
            ProgressView("Opening…")
                .accessibilityIdentifier("reader.loading")
        } else {
            ContentUnavailableView("Book unavailable", systemImage: "exclamationmark.triangle",
                description: Text("Return to the Library to see the saved-file error or choose another book. No saved file was changed."))
                .accessibilityIdentifier("reader.unavailable")
        }
    }

    private func compactCardContent(
        book: Book,
        progress: Double,
        percent: Int,
        minutes: Int,
        chapter: String,
        showsContinue: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: 18) {
            BookCoverView(book: book, width: 68, height: 96)
            VStack(alignment: .leading, spacing: 7) {
                Text(book.title)
                    .font(.system(.title3, design: .serif).weight(.semibold))
                    .foregroundStyle(LRColor.text)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.trailing, 26)
                if !book.author.isEmpty {
                    Text(book.author)
                        .font(.subheadline)
                        .foregroundStyle(LRColor.secondaryText)
                }
                Text("\(percent)% through chapters · about \(minutes) min left")
                    .font(.caption)
                    .foregroundStyle(LRColor.secondaryText)
                ProgressView(value: min(1, max(0, progress)))
                    .tint(LRColor.accent)
                    .accessibilityLabel("Chapter position")
                    .accessibilityValue("\(percent) percent")
                    .accessibilityIdentifier("library.progress.\(book.id.uuidString)")
                Text(chapter)
                    .font(.caption)
                    .foregroundStyle(LRColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if showsContinue {
                    Label(progress > 0 ? "Continue reading" : "Start reading", systemImage: "arrow.right")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(LRColor.accent)
                        .padding(.top, 5)
                        .accessibilityIdentifier("library.book.continue.button")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(18)
        .background(LRColor.surface, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(LRColor.separator.opacity(0.18)))
        .contentShape(RoundedRectangle(cornerRadius: 20))
    }

    private func chapterSummary(_ book: Book) -> String {
        let polished = book.polishedChapterCount
        let outline = book.outlineChapterCount
        let unit = book.id == QuranFixtureIDs.book ? "surahs" : "chapters"
        if outline > 0 {
            return "\(book.chapters.count) \(unit) · \(polished) polished · \(outline) outline"
        }
        return "\(book.chapters.count) \(unit)"
    }

    private func coverView(for book: Book) -> some View {
        BookCoverView(book: book)
    }

}

#Preview {
    LibraryView(model: LibraryViewModel())
        .environmentObject(ReaderSettingsStore())
        .environmentObject(AIModelPreferenceStore())
}
