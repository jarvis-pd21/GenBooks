import SwiftUI
import UniformTypeIdentifiers

enum CreateWizardStep: String, Equatable {
    case form
    case working
    case done
}

/// Identifiable box for `.sheet(item:)` so Create always mounts with a model.
/// Two-step `@State` (`createModel` then `showCreate`) can present an empty sheet.
@MainActor
struct CreateBookSheetItem: Identifiable {
    let id: UUID
    let model: CreateBookViewModel

    init(model: CreateBookViewModel) {
        self.id = UUID()
        self.model = model
    }
}

@MainActor
final class CreateBookViewModel: ObservableObject {
    @Published var draft: CreateBookDraft
    @Published var tab: CreateBookTab = .existingBooks
    @Published var step: CreateWizardStep = .form
    @Published var isWorking = false
    @Published var errorMessage: String?
    @Published var statusMessage: String?
    /// BookBot's Q&A for the Generate tab. Deterministic and offline.
    @Published var chat = CreateBookChat()
    @Published var chatDraft: String = ""
    @Published var referenceStylesText: String
    @Published var createdBook: Book?

    private let wizard: CreateBookWizardService
    private let modelPrefs: AIModelPreferenceStore
    private let initialDraft: CreateBookDraft
    var onFinished: ((Book) -> Void)?

    init(
        wizard: CreateBookWizardService,
        modelPrefs: AIModelPreferenceStore,
        draft: CreateBookDraft = .blank()
    ) {
        self.wizard = wizard
        self.modelPrefs = modelPrefs
        self.initialDraft = draft
        self.draft = draft
        self.referenceStylesText = draft.referenceStyles.joined(separator: ", ")
        self.tab = CreateBookTab(path: draft.path)
        if self.tab == .generateBook {
            var opening = CreateBookChat()
            opening.start()
            self.chat = opening
        }
    }

    func select(_ tab: CreateBookTab) {
        self.tab = tab
        draft.path = tab.path
        errorMessage = nil
        if tab == .generateBook { chat.start() }
    }

    var hasUnsavedChanges: Bool {
        guard step == .form, !isWorking else { return false }
        var edited = draft
        // Merely looking at the other pane is not an edit.
        edited.path = initialDraft.path
        return edited != initialDraft || !chatDraft.isEmpty
            || referenceStylesText != initialDraft.referenceStyles.joined(separator: ", ")
    }

    /// Paste is the only hard requirement on the Existing Books tab; a file picked
    /// through the importer fills it before this is read.
    var canAddBook: Bool {
        !draft.importedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isWorking
    }

    func sendChatMessage() {
        guard draft.sourcePilot == nil else { return }
        let text = chatDraft
        chatDraft = ""
        errorMessage = nil
        var updated = draft
        chat.answer(text, into: &updated)
        if updated.referenceStyles != draft.referenceStyles {
            referenceStylesText = updated.referenceStyles.joined(separator: ", ")
        }
        draft = updated
    }

    func importBook() async {
        guard !isWorking else { return }
        isWorking = true
        errorMessage = nil
        statusMessage = "Importing…"
        step = .working
        do {
            let book = try await wizard.importAndSave(draft: draft)
            createdBook = book
            statusMessage = "Imported “\(book.title)”."
            if onFinished != nil {
                onFinished?(book)
            } else {
                step = .done
            }
        } catch {
            errorMessage = error.localizedDescription
            step = .form
        }
        isWorking = false
    }

    func importFile(_ payload: CanonFileIngest.Payload) async {
        guard !isWorking else { return }
        isWorking = true
        errorMessage = nil
        statusMessage = "Preserving source…"
        do {
            draft = try await wizard.prepareImport(draft: draft, payload: payload)
            isWorking = false
            await importBook()
        } catch {
            errorMessage = error.localizedDescription
            isWorking = false
            step = .form
        }
    }

    func generateBook() async {
        guard !isWorking else { return }
        errorMessage = nil
        // Validate before the working screen so a missing basic reads as an
        // answerable prompt rather than a spinner that bounces back.
        if draft.trimmedTitle.isEmpty {
            errorMessage = CreateBookError.missingTitle.errorDescription
            return
        }
        if draft.trimmedTopic.isEmpty {
            errorMessage = CreateBookError.missingTopic.errorDescription
            return
        }
        if let message = draft.lengthValidationMessage {
            errorMessage = message
            return
        }
        isWorking = true
        statusMessage = "Writing your book…"
        step = .working
        await refreshAI()
        do {
            let result = try await wizard.generateAndSave(draft: draft)
            presentGeneration(result)
        } catch {
            errorMessage = error.localizedDescription
            step = .form
        }
        isWorking = false
    }

    func prepareSourcePreview(articleTitle: String,
                              scope: RetrievedResearchSource.Scope = .wikipediaIntroduction) throws {
        // A retry keeps the exact approved brief and its saved writing draft.
        if draft.sourcePilot != nil { return }
        let article = articleTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !article.isEmpty else { throw SourceGroundingError.invalid("Enter a Wikipedia article title.") }
        draft.path = .generate
        if draft.trimmedTitle.isEmpty { draft.title = article + " · Preview" }
        if draft.trimmedTopic.isEmpty {
            draft.topic = scope == .wikipediaIntroduction ? "A concise overview of " + article
                : "Explain only the historical periods or subjects covered by the opening excerpt of " + article
        }
        draft.length = .short
        draft.readingTimeInput = nil
        draft.outlineTitles = [draft.trimmedTitle]
        draft.sourcePilot = try SourcePilotPlan.approved(articleTitle: article, draft: draft, scope: scope)
    }

    func startNewSourcePreview() {
        // Preserve every saved draft/book. Only this sheet switches to a new ID.
        draft.id = UUID()
        draft.sourcePilot = nil
        draft.updatedAt = Date()
        errorMessage = nil
        statusMessage = nil
    }

    func presentGeneration(_ result: CreateBookGenerationResult) {
        createdBook = result.book
        statusMessage = result.completionMessage
        guard result.isComplete else {
            errorMessage = result.completionMessage
            step = .form
            return
        }
        if let onFinished {
            onFinished(result.book)
        } else {
            step = .done
        }
    }

    private func refreshAI() async {
        let generation = AIServiceResolver.makeCreateGeneration(
            generationModel: modelPrefs.generationModel
        )
        await wizard.updateAI(generation)
    }
}

struct CreateBookSheet: View {
    @ObservedObject var model: CreateBookViewModel
    var onClose: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @FocusState private var readingTimeFocused: Bool

    @State private var showDocumentImporter = false
    @State private var documentImporterKind: ImportDocumentKind = .epub
    @State private var showEPUBHelp = false
    @State private var showDiscardConfirmation = false
    @State private var copiedPrompt = false
    @State private var showSourcePreview = false
    @State private var sourceArticle = "History of Argentina"
    @State private var sourceScope: RetrievedResearchSource.Scope = .wikipediaIntroduction

    var body: some View {
        NavigationStack {
            Group {
                switch model.step {
                case .form:
                    panes
                case .working:
                    workingView
                case .done:
                    doneView
                }
            }
            .navigationTitle("New Book")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showSourcePreview) {
                NavigationStack {
                    Form {
                        Section("One-source preview") {
                            TextField("Wikipedia article title", text: $sourceArticle)
                                .accessibilityIdentifier("create.source.article")
                                .disabled(model.draft.sourcePilot != nil)
                            Picker("Source material", selection: $sourceScope) {
                                Text("Introduction").tag(RetrievedResearchSource.Scope.wikipediaIntroduction)
                                Text("Opening excerpt").tag(RetrievedResearchSource.Scope.wikipediaOpeningExcerpt)
                            }
                            .pickerStyle(.menu)
                            .disabled(model.draft.sourcePilot != nil)
                            .accessibilityIdentifier("create.source.scope")
                            Text(sourceScope == .wikipediaIntroduction
                                 ? "One chapter, about 400 words. Uses the English Wikipedia introduction, saved with its revision and attribution."
                                 : "One chapter, about 400 words. Uses the opening prose paragraphs of the English Wikipedia article, up to 8,000 characters—not the full article. Covered sections and attribution are saved in Book Guide.")
                            Text(SourcePilotPlan.disclosure(for: sourceScope))
                                .accessibilityIdentifier("create.source.disclosure")
                            if sourceScope == .wikipediaOpeningExcerpt {
                                Text("The exact excerpt is saved from the recorded article revision's rendering. Templates may reflect later changes.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Section("Before you start") {
                            Text("Sends the article title to Wikipedia, then the source, title, topic and voice to OpenAI. Requires your API key and Astra; one writing request and one separate review request may incur charges.")
                            Text("A failed review keeps the writing draft. Retrying reviews it again without rewriting. After publication, you can change text after a selected word or restore a reviewed version. Images and later-chapter adaptation are not supported for this preview.")
                        }
                        if model.draft.sourcePilot != nil {
                            Section {
                                Button("Start new preview") { model.startNewSourcePreview() }
                                    .accessibilityIdentifier("create.source.new")
                                Text("Leaves existing previews unchanged and opens a new draft so you can change the article or brief.")
                            }
                        }
                    }
                    .navigationTitle("Source preview")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { showSourcePreview = false }
                                .accessibilityIdentifier("create.source.cancel")
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button(model.draft.sourcePilot == nil ? "Generate" : "Retry") {
                                do {
                                    try model.prepareSourcePreview(articleTitle: sourceArticle, scope: sourceScope)
                                    showSourcePreview = false
                                    Task { await model.generateBook() }
                                } catch { model.errorMessage = error.localizedDescription }
                            }
                            .disabled(sourceArticle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityIdentifier("create.source.generate")
                        }
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        if model.hasUnsavedChanges { showDiscardConfirmation = true }
                        else { onClose() }
                    }
                        .accessibilityIdentifier("create.close")
                }
                if model.step == .form {
                    ToolbarItem(placement: .confirmationAction) {
                        switch model.tab {
                        case .existingBooks:
                            Button("Add book") {
                                Task { await model.importBook() }
                            }
                            .disabled(!model.canAddBook)
                            .accessibilityIdentifier("create.import.submit")
                        case .generateBook:
                            Button("Generate") {
                                Task { await model.generateBook() }
                            }
                            .disabled(model.isWorking || model.draft.lengthValidationMessage != nil)
                            .accessibilityIdentifier("create.gen.submit")
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier("create.sheet")
        .interactiveDismissDisabled(model.hasUnsavedChanges)
        .alert("Discard changes to this draft?", isPresented: $showDiscardConfirmation) {
            Button("Discard changes", role: .destructive) { onClose() }
            Button("Keep editing", role: .cancel) {}
        } message: {
            Text("Unsaved text and answers will be lost. Books and writing drafts already saved are not removed.")
        }
        .sheet(isPresented: $showEPUBHelp) { epubHelpSheet }
        .fileImporter(
            isPresented: $showDocumentImporter,
            allowedContentTypes: documentImporterKind.contentTypes,
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                ingestPickedFile(url)
            case .failure(let error):
                model.errorMessage = error.localizedDescription
            }
        }
    }

    /// Stacked rather than inset: a `safeAreaInset` shrinks the safe area without
    /// resizing non-scrolling content, so the Generate basics could lay out beneath
    /// the switcher bar.
    private var panes: some View {
        VStack(spacing: 0) {
            tabSwitcher
                .background(.bar)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(2)
            Divider()
            Group {
                switch model.tab {
                case .existingBooks:
                    existingBooksPane
                case .generateBook:
                    generatePane
                }
            }
            // Without this, the stacked switcher can leave the Generate basics
            // with zero offered height so UITests never see create.gen.title.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    /// Keep both panes visible at standard sizes; give the selected mode the full
    /// width at accessibility sizes so fixed navigation leaves room for the form.
    @ViewBuilder
    private var tabSwitcher: some View {
        if dynamicTypeSize.isAccessibilitySize {
            Menu {
                ForEach(CreateBookTab.allCases) { tab in
                    Button {
                        model.select(tab)
                    } label: {
                        Label(tab.title, systemImage: model.tab == tab ? "checkmark" : tab.systemImage)
                    }
                    .accessibilityIdentifier(tab.accessibilityIdentifier)
                    .accessibilityAddTraits(model.tab == tab ? .isSelected : [])
                }
            } label: {
                HStack(spacing: 12) {
                    Text(model.tab.title)
                        .font(.headline)
                        .layoutPriority(1)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.down")
                        .font(.caption)
                        .accessibilityHidden(true)
                }
                .foregroundStyle(LRColor.accent)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(LRColor.surface, in: RoundedRectangle(cornerRadius: 16))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.tab.title)
            .accessibilityHint("Choose Existing Books or Generate Book")
            .accessibilityIdentifier("create.mode")
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        } else {
            standardTabSwitcher
        }
    }

    private var standardTabSwitcher: some View {
        HStack(spacing: 6) {
            ForEach(CreateBookTab.allCases) { tab in
                Button {
                    model.select(tab)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: tab.systemImage)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(model.tab == tab ? LRColor.mustard : LRColor.navy)
                        Text(tab.title)
                            .font(LRFont.sans(14, weight: model.tab == tab ? .semibold : .medium))
                            .foregroundStyle(LRColor.navy)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background {
                        if model.tab == tab {
                            Capsule(style: .continuous)
                                .fill(LRColor.pillActiveFill)
                                .shadow(color: Color.black.opacity(0.06), radius: 2, y: 1)
                        }
                    }
                    .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(tab.accessibilityIdentifier)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(model.tab == tab ? .isSelected : [])
            }
        }
        .padding(5)
        .background {
            Capsule(style: .continuous).fill(LRColor.pillInactive)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("create.tab.switcher")
    }

    // MARK: - Existing Books

    private var existingBooksPane: some View {
        Form {
            Section {
                Button {
                    presentDocumentImporter(.epub)
                } label: {
                    Label("Choose EPUB", systemImage: "book.closed")
                }
                .accessibilityIdentifier("create.import.epub")
                Button {
                    presentDocumentImporter(.pdf)
                } label: {
                    Label("Choose PDF", systemImage: "doc.richtext")
                }
                .accessibilityIdentifier("create.import.pdf")
                Button("How to add an EPUB") {
                    showEPUBHelp = true
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .buttonStyle(.plain)
                .accessibilityIdentifier("create.import.epub.help")
            } footer: {
                Text("PDF imports keep the supplied pages, tables, and illustrations in Original pages, including scans. Text view and EPUB imports can lose layout. Scans without a text layer have no text search; GenBooks does not perform OCR.")
            }
            Section("Or paste") {
                TextField("Paste plain text", text: Binding(
                    get: { model.draft.importedText },
                    set: {
                        model.draft.importedText = $0
                        model.draft.importSourceKind = .pastedText
                        model.draft.importedOriginal = nil
                    }), axis: .vertical)
                    .lineLimit(4...10)
                    .accessibilityIdentifier("create.import.paste")
                if clipboardHasText {
                    Button {
                        pasteFromClipboard()
                    } label: {
                        Label("Use clipboard", systemImage: "clipboard")
                    }
                    .accessibilityIdentifier("create.import.clipboard")
                }
            }
            Section("Details (optional)") {
                TextField("Title", text: $model.draft.title)
                    .accessibilityIdentifier("create.import.title")
                TextField("Author", text: $model.draft.author)
                    .accessibilityIdentifier("create.import.author")
            }
            if let error = model.errorMessage {
                Section {
                    Text(error)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("create.import.error")
                }
            }
        }
        .accessibilityIdentifier("create.import.form")
    }

    // MARK: - Generate Book

    private var generatePane: some View {
        VStack(spacing: 0) {
            // At accessibility sizes the basics join the transcript's single
            // scroll view; pinning both large basics and composer can exceed
            // the keyboard-reduced viewport and push tabs under the toolbar.
            if !dynamicTypeSize.isAccessibilitySize {
                basics
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
                Divider()
            }
            transcript
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            chatInput
                .disabled(model.draft.sourcePilot != nil)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("create.gen.pane")
    }

    /// The only fixed controls: they apply to every generated book. Everything else
    /// BookBot asks for, one line at a time, in the transcript below.
    private var basics: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Title", text: $model.draft.title)
                .disabled(model.draft.sourcePilot != nil)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Title")
                .accessibilityIdentifier("create.gen.title")
            HStack {
                Text("Reading time")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(model.draft.approximatePagesLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("create.gen.length.estimate")
            }
            TextField("e.g. 45 min or 2 h 15 min", text: Binding(
                get: { model.draft.lengthInputText },
                set: { model.draft.readingTimeInput = $0 }
            ))
                .textFieldStyle(.roundedBorder)
                .keyboardType(.numbersAndPunctuation)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($readingTimeFocused)
                .submitLabel(.done)
                .onSubmit { readingTimeFocused = false }
                .accessibilityLabel("Estimated reading time")
                .accessibilityHint("Enter minutes, or hours and minutes. Page estimate updates as you type.")
                .accessibilityIdentifier("create.gen.length")
                .disabled(model.draft.sourcePilot != nil)
            if let message = model.draft.lengthValidationMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("create.gen.length.error")
            }
            Text("Estimates: 230 words/min · 250 words/page. Actual length varies.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("create.gen.length.note")
            TextField("References — books or authors to emulate", text: referenceStylesBinding)
                .disabled(model.draft.sourcePilot != nil)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("References")
                .accessibilityIdentifier("create.gen.references")
            HStack {
              Button(copiedPrompt ? "Copied" : "Copy prompt for another AI") {
                #if canImport(UIKit)
                UIPasteboard.general.string = CreateBookDraft.chatgptExportPrompt
                #endif
                copiedPrompt = true
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .buttonStyle(.plain)
            .accessibilityIdentifier("create.gen.profile.copy")
              Spacer()
              Button("Source preview") {
                  sourceArticle = model.draft.sourcePilot?.articleTitle ?? "History of Argentina"
                  sourceScope = model.draft.sourcePilot?.selectedScope ?? .wikipediaIntroduction
                  showSourcePreview = true
              }
              .font(.footnote)
              .accessibilityIdentifier("create.source.open")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    if dynamicTypeSize.isAccessibilitySize {
                        basics
                        Divider()
                    }
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(model.chat.messages) { message in
                            chatBubble(message)
                                .id(message.id)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: model.chat.messages.count) { _, _ in
                guard let last = model.chat.messages.last else { return }
                withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
        .accessibilityIdentifier("create.gen.chat")
    }

    @ViewBuilder
    private func chatBubble(_ message: CreateChatMessage) -> some View {
        switch message.role {
        case .bot:
            Text(message.text)
                .padding(10)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 40)
                .accessibilityIdentifier("create.gen.message.bot")
        case .reader:
            HStack {
                Spacer(minLength: 40)
                Text(message.text)
                    .padding(10)
                    .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityIdentifier("create.gen.message.reader")
            }
        }
    }

    private var chatInput: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error = model.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("create.gen.error")
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Reply…", text: $model.chatDraft, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Reply to BookBot")
                    .accessibilityIdentifier("create.gen.input")
                Button {
                    model.sendChatMessage()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .disabled(model.chatDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("create.gen.send")
                .accessibilityLabel("Send")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Shared

    private var workingView: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text(model.statusMessage ?? "Working…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("create.wizard.working")
    }

    private var doneView: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle")
                .font(.largeTitle)
            Text(model.statusMessage ?? "Done")
                .font(.headline)
                .multilineTextAlignment(.center)
            if let book = model.createdBook {
                Text("\(book.chapters.count) chapters · \(book.author)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Button("Done") { onClose() }
                .accessibilityIdentifier("create.done")
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("create.wizard.done")
    }

    private var referenceStylesBinding: Binding<String> {
        Binding(
            get: { model.referenceStylesText },
            set: { text in
                // Preserve spaces and a trailing separator while the reader types.
                model.referenceStylesText = text
                model.draft.referenceStyles = text
                    .components(separatedBy: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            }
        )
    }

    private var clipboardHasText: Bool {
        #if canImport(UIKit)
        return UIPasteboard.general.hasStrings
        #else
        return false
        #endif
    }

    private func pasteFromClipboard() {
        #if canImport(UIKit)
        guard let value = UIPasteboard.general.string?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else { return }
        model.draft.importedText = value
        model.draft.importSourceKind = .pastedText
        model.draft.importedOriginal = nil
        model.errorMessage = nil
        model.statusMessage = "Pasted from clipboard."
        #endif
    }

    private var epubHelpSheet: some View {
        NavigationStack {
            ScrollView {
              VStack(alignment: .leading, spacing: 16) {
                Text("1. Buy a DRM-free EPUB you own.")
                Text("2. Save it to Files on this iPhone.")
                Text("3. Share the file → Open in GenBooks.")
                Text("EPUB import extracts text and can lose illustrations and equation formatting. PDF imports keep the supplied pages, tables, and figures in Original pages, including scans. Text view can lose layout; GenBooks does not perform OCR on scans.")
                Text("Or tap Choose EPUB here. DRM-protected files are refused.")
                    .foregroundStyle(.secondary)
              }
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding()
            }
            .font(.body)
            .frame(maxWidth: .infinity, alignment: .leading)
            .navigationTitle("Add an EPUB you own")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showEPUBHelp = false }
                        .accessibilityIdentifier("create.import.epub.help.done")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("create.import.epub.help.sheet")
    }

    private func presentDocumentImporter(_ kind: ImportDocumentKind) {
        documentImporterKind = kind
        // Next turn so fileImporter sees the updated UTTypes before presenting.
        Task { @MainActor in
            showDocumentImporter = true
        }
    }

    private func ingestPickedFile(_ url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let prepared = try CanonFileIngest.prepare(from: url)
            Task { await model.importFile(prepared) }
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }
}

private enum ImportDocumentKind {
    case epub
    case pdf

    var contentTypes: [UTType] {
        switch self {
        case .epub:
            return Self.epubTypes
        case .pdf:
            return [.pdf]
        }
    }

    static var epubTypes: [UTType] {
        var types: [UTType] = []
        if let ext = UTType(filenameExtension: "epub") {
            types.append(ext)
        }
        types.append(UTType(importedAs: "org.idpf.epub-container"))
        return types.isEmpty ? [.data] : types
    }
}
