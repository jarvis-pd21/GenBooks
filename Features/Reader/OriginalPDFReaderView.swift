import SwiftUI
import PDFKit

/// Displays a retained source PDF. It never changes manuscript checkpoints or writes the PDF.
struct OriginalPDFReaderView: View {
    @StateObject private var model: OriginalPDFReaderModel
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("genbooks.originalPDF.dismissedHelp") private var dismissedHelp = false
    @State private var showsContents = false
    @State private var showsSearch = false
    @State private var showsPageJump = false
    @State private var pageInput = ""
    @State private var query = ""
    @State private var showsPageGrid = false
    private let title: String
    private let onShowText: () -> Void

    init(url: URL, title: String, initialPageIndex: Int = 0, initialPoint: CGPoint? = nil,
         chapterLocations: [OriginalChapterLocation] = [],
         onPositionChange: @escaping (Int, CGPoint?) -> Bool, onShowText: @escaping () -> Void) {
        self.title = title
        self.onShowText = onShowText
        _model = StateObject(wrappedValue: OriginalPDFReaderModel(url: url, initialPageIndex: initialPageIndex,
            initialPoint: initialPoint, chapterLocations: chapterLocations, onPositionChange: onPositionChange))
    }

    var body: some View {
        Group {
            if let error = model.error {
                ContentUnavailableView {
                    Label("Couldn’t open original PDF", systemImage: "doc.questionmark")
                } description: {
                    Text(error)
                } actions: {
                    Button("Open text view", action: showText).buttonStyle(.borderedProminent)
                }
                .accessibilityIdentifier("original.pdf.error")
            } else if model.document != nil {
                OriginalPDFCanvas(model: model)
                    .accessibilityIdentifier("original.pdf.document")
            } else {
                ProgressView("Opening original pages…")
            }
        }
        .background(Color(uiColor: .secondarySystemBackground))
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Text view", action: showText)
                    .accessibilityIdentifier("original.pdf.text")
                Button { showsPageGrid = model.outline.isEmpty; showsContents = true } label: {
                    Label("PDF contents", systemImage: "list.bullet")
                }
                .disabled(model.document == nil)
                .accessibilityIdentifier("original.pdf.contents")
                Button { showsSearch = true } label: {
                    Label("Search PDF", systemImage: "magnifyingglass")
                }
                .disabled(model.document == nil)
                .accessibilityIdentifier("original.pdf.search")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.document != nil { footer }
        }
        .sheet(isPresented: $showsContents) { contentsSheet }
        .sheet(isPresented: $showsSearch, onDismiss: { model.cancelSearch() }) { searchSheet }
        .alert("Go to PDF page", isPresented: $showsPageJump) {
            TextField("1–\(model.pageCount)", text: $pageInput).keyboardType(.numberPad)
            Button("Cancel", role: .cancel) {}
            Button("Go") {
                if let page = Int(pageInput), (1...model.pageCount).contains(page) { model.go(to: page - 1) }
            }
            .disabled(Int(pageInput).map { !(1...model.pageCount).contains($0) } ?? true)
        } message: {
            Text("Enter the file page number, from 1 to \(model.pageCount). It may differ from the number printed on the page.")
        }
        .onAppear { model.resumeReading(); model.load() }
        .onDisappear { model.finishReading(); model.cancelSearch() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { model.persistPosition() }
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 4) {
                Button { model.goBack() } label: {
                    Image(systemName: "arrow.uturn.backward").frame(minWidth: 44, minHeight: 44)
                }
                    .disabled(!model.canGoBack)
                    .accessibilityLabel("Back to previous PDF location")
                    .accessibilityIdentifier("original.pdf.back")
                Button { model.go(to: model.pageIndex - 1) } label: {
                    Image(systemName: "chevron.left").frame(minWidth: 44, minHeight: 44)
                }
                    .disabled(model.pageIndex == 0)
                    .accessibilityLabel("Previous PDF page")
                    .accessibilityIdentifier("original.pdf.previous")
                Button {
                    pageInput = String(model.pageIndex + 1)
                    showsPageJump = true
                } label: {
                    Text("PDF page \(model.pageIndex + 1) of \(model.pageCount)")
                        .font(.subheadline).monospacedDigit().multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .accessibilityHint("Opens a page number field. These are PDF file pages, not printed page numbers.")
                .accessibilityIdentifier("original.pdf.goToPage")
                Button { model.go(to: model.pageIndex + 1) } label: {
                    Image(systemName: "chevron.right").frame(minWidth: 44, minHeight: 44)
                }
                    .disabled(model.pageIndex + 1 >= model.pageCount)
                    .accessibilityLabel("Next PDF page")
                    .accessibilityIdentifier("original.pdf.next")
            }
            .padding(.horizontal, 8)
            if !dismissedHelp {
                HStack(alignment: .center, spacing: 8) {
                    Text("Pinch to zoom. Text view keeps its own place and notes.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button { dismissedHelp = true } label: {
                        Image(systemName: "xmark").frame(minWidth: 44, minHeight: 44)
                    }
                        .accessibilityLabel("Dismiss original-page reading tip")
                }
                .padding(.leading, 20).padding(.trailing, 8)
            }
        }
        .background(.regularMaterial)
    }

    private var contentsSheet: some View {
        NavigationStack {
            Group {
                if showsPageGrid {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 16)], spacing: 16) {
                            ForEach(0..<model.pageCount, id: \.self) { index in
                                Button { model.go(to: index); showsContents = false } label: {
                                    OriginalPDFThumbnail(model: model, pageIndex: index)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("PDF page \(index + 1)")
                                .accessibilityIdentifier("original.pdf.thumbnail.\(index)")
                            }
                        }
                        .padding()
                    }
                } else {
                    List(model.outline) { item in
                        Button {
                            model.go(to: item.destination)
                            showsContents = false
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.title).foregroundStyle(.primary)
                                if let index = item.pageIndex {
                                    Text("PDF page \(index + 1)").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .padding(.leading, CGFloat(min(item.depth, 4)) * 12)
                        }
                        .disabled(item.destination == nil)
                    }
                }
            }
            .navigationTitle(showsPageGrid ? "PDF pages" : "PDF contents")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !model.outline.isEmpty {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(showsPageGrid ? "Contents" : "All pages") { showsPageGrid.toggle() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { showsContents = false } }
            }
        }
    }

    private var searchSheet: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("Search this PDF", text: $query)
                            .submitLabel(.search)
                            .onSubmit { model.search(query) }
                            .accessibilityIdentifier("original.pdf.search.field")
                        if model.isSearching {
                            Button("Cancel") { model.cancelSearch() }
                        } else {
                            Button("Search") { model.search(query) }
                                .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                } footer: {
                    Text("Search uses the PDF’s existing text layer. Scanned images may not contain searchable text.")
                }
                if model.isSearching {
                    ProgressView("Searching PDF…")
                } else if let message = model.searchMessage {
                    Text(message).foregroundStyle(.secondary)
                }
                ForEach(model.matches) { match in
                    Button {
                        model.show(match)
                        showsSearch = false
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("PDF page \(match.pageIndex + 1)").font(.caption).foregroundStyle(.secondary)
                            Text(match.excerpt).foregroundStyle(.primary).lineLimit(4)
                        }
                    }
                    .accessibilityIdentifier("original.pdf.search.result.\(match.id)")
                }
            }
            .navigationTitle("Search PDF")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showsSearch = false } } }
        }
    }

    private func showText() { model.finishReading(); onShowText() }
}

@MainActor
final class OriginalPDFReaderModel: ObservableObject {
    @Published private(set) var document: PDFDocument?
    @Published private(set) var error: String?
    @Published private(set) var pageIndex = 0
    @Published private(set) var canGoBack = false
    @Published private(set) var outline: [OriginalPDFOutlineItem] = []
    @Published private(set) var matches: [OriginalPDFSearchMatch] = []
    @Published private(set) var isSearching = false
    @Published private(set) var searchMessage: String?
    let url: URL
    private let initialPageIndex: Int
    private let initialPoint: CGPoint?
    private let chapterLocations: [OriginalChapterLocation]
    private let onPositionChange: (Int, CGPoint?) -> Bool
    private var didLoad = false
    private var hasRestoredPosition = false
    private var isReading = true
    private var lastPosition: (Int, CGPoint?)?
    private var searchTask: Task<[OriginalPDFSearchMatch], Error>?
    private var searchID = UUID()
    private let thumbnails = NSCache<NSNumber, UIImage>()
    weak var pdfView: PDFView?
    var pageCount: Int { document?.pageCount ?? 0 }

    init(url: URL, initialPageIndex: Int, initialPoint: CGPoint?, chapterLocations: [OriginalChapterLocation] = [],
         onPositionChange: @escaping (Int, CGPoint?) -> Bool) {
        self.url = url
        self.initialPageIndex = initialPageIndex
        self.initialPoint = initialPoint
        self.chapterLocations = chapterLocations
        self.onPositionChange = onPositionChange
        thumbnails.countLimit = 24
    }

    func load() {
        guard !didLoad else { return }
        didLoad = true
        guard url.isFileURL, FileManager.default.fileExists(atPath: url.path) else {
            error = "The saved original PDF is missing. Your text view and its notes are still available."
            return
        }
        guard let loaded = PDFDocument(url: url), loaded.pageCount > 0 else {
            error = "The saved file could not be read as a PDF. Your text view and its notes are still available."
            return
        }
        guard !loaded.isLocked, !loaded.isEncrypted else {
            error = "This PDF is protected and cannot be opened here. Your text view is still available."
            return
        }
        pageIndex = OriginalPDFLocation.clampPage(initialPageIndex, count: loaded.pageCount)
        outline = OriginalPDFOutlineItem.entries(in: loaded)
        if outline.isEmpty {
            outline = chapterLocations.compactMap { location in
                guard (0..<loaded.pageCount).contains(location.pageIndex),
                      let page = loaded.page(at: location.pageIndex) else { return nil }
                let bounds = page.bounds(for: .cropBox)
                return OriginalPDFOutlineItem(id: location.chapterID.uuidString, title: location.title, depth: 0,
                    destination: PDFDestination(page: page, at: CGPoint(x: bounds.minX, y: bounds.maxY)),
                    pageIndex: location.pageIndex)
            }
        }
        document = loaded
    }

    func restorePosition(in view: PDFView) {
        guard !hasRestoredPosition, let document, let page = document.page(at: pageIndex) else { return }
        pdfView = view
        if let point = OriginalPDFLocation.finitePoint(initialPoint) {
            view.go(to: PDFDestination(page: page, at: point))
        } else {
            view.go(to: page)
        }
        hasRestoredPosition = true
        updatePosition(persist: false)
    }

    func updatePosition(persist: Bool = true) {
        guard isReading, hasRestoredPosition, let view = pdfView, let document, let page = view.currentPage else { return }
        let index = document.index(for: page)
        guard (0..<document.pageCount).contains(index) else { return }
        pageIndex = index
        canGoBack = view.canGoBack
        if persist { persistPosition() }
    }

    func persistPosition() {
        guard isReading, hasRestoredPosition, let view = pdfView, let document,
              view.bounds.width > 0, view.bounds.height > 0, let page = view.currentPage else { return }
        let index = document.index(for: page)
        guard (0..<document.pageCount).contains(index) else { return }
        // In continuous mode currentDestination can identify the adjacent page even
        // when currentPage (and our footer) identifies this page. Save the same page
        // the reader displays and explicitly convert the viewport's top-left anchor.
        // The anchor may be outside this page when part of the preceding page is
        // visible; clipping it to the crop box would change the restored viewport.
        let point = OriginalPDFLocation.finitePoint(view.convert(view.bounds.origin, to: page))
        if let lastPosition, lastPosition.0 == index, lastPosition.1 == point { return }
        // A failed write must remain retryable on backgrounding or leaving the reader.
        if onPositionChange(index, point) { lastPosition = (index, point) }
    }

    func resumeReading() { isReading = true }

    func finishReading() {
        guard isReading else { return }
        persistPosition()
        // Dismantling the canvas can resize/reposition PDFKit. Notifications queued
        // by that teardown must never replace the location captured before leaving.
        isReading = false
    }

    func go(to index: Int) {
        guard let document, let page = document.page(at: OriginalPDFLocation.clampPage(index, count: pageCount)) else { return }
        pdfView?.go(to: page)
        updatePosition()
    }

    func go(to destination: PDFDestination?) {
        guard let destination else { return }
        pdfView?.go(to: destination)
        updatePosition()
    }

    func goBack() { pdfView?.goBack(nil); updatePosition() }

    func thumbnail(at index: Int) -> UIImage? {
        let key = NSNumber(value: index)
        if let image = thumbnails.object(forKey: key) { return image }
        guard let page = document?.page(at: index) else { return nil }
        let image = page.thumbnail(of: CGSize(width: 160, height: 220), for: .cropBox)
        thumbnails.setObject(image, forKey: key)
        return image
    }

    func search(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        cancelSearch()
        let id = UUID()
        searchID = id
        matches = []
        searchMessage = nil
        isSearching = true
        let sourceURL = url
        let worker = Task.detached(priority: .userInitiated) {
            try OriginalPDFSearch.find(trimmed, in: sourceURL)
        }
        searchTask = worker
        Task { [weak self] in
            do {
                let found = try await worker.value
                guard let self, self.searchID == id else { return }
                self.matches = found
                self.isSearching = false
                self.searchTask = nil
                self.searchMessage = found.isEmpty ? "No matches in the PDF text layer."
                    : (found.count == OriginalPDFSearch.resultLimit ? "Showing the first \(OriginalPDFSearch.resultLimit) matches. Refine your search for more specific results." : nil)
            } catch {
                guard let self, self.searchID == id else { return }
                self.isSearching = false
                self.searchTask = nil
                self.searchMessage = "Search could not finish. Try again or use PDF contents."
            }
        }
    }

    func cancelSearch() {
        searchID = UUID()
        searchTask?.cancel()
        searchTask = nil
        isSearching = false
    }

    func show(_ match: OriginalPDFSearchMatch) {
        guard let page = document?.page(at: match.pageIndex) else { return }
        if let selection = page.selection(for: match.range) {
            pdfView?.setCurrentSelection(selection, animate: true)
            pdfView?.go(to: selection)
        } else {
            pdfView?.go(to: page)
        }
        updatePosition()
    }
}

enum OriginalPDFLocation {
    static func clampPage(_ index: Int, count: Int) -> Int { min(max(0, index), max(0, count - 1)) }
    static func finitePoint(_ point: CGPoint?) -> CGPoint? {
        guard let point, point.x.isFinite, point.y.isFinite else { return nil }
        return point
    }
}

struct OriginalPDFOutlineItem: Identifiable {
    let id: String
    let title: String
    let depth: Int
    let destination: PDFDestination?
    let pageIndex: Int?

    static func entries(in document: PDFDocument) -> [Self] {
        guard let root = document.outlineRoot else { return [] }
        var result: [Self] = []
        var visited: Set<ObjectIdentifier> = []
        func visit(_ parent: PDFOutline, path: String, depth: Int) {
            guard depth < 32, visited.insert(ObjectIdentifier(parent)).inserted else { return }
            for index in 0..<parent.numberOfChildren {
                guard result.count < 5_000, let child = parent.child(at: index) else { return }
                let id = "\(path).\(index)"
                let destination = child.destination
                let pageIndex = destination?.page.map { document.index(for: $0) }
                result.append(Self(id: id, title: child.label ?? "Untitled section", depth: depth,
                    destination: destination, pageIndex: pageIndex.flatMap { (0..<document.pageCount).contains($0) ? $0 : nil }))
                visit(child, path: id, depth: depth + 1)
            }
        }
        visit(root, path: "root", depth: 0)
        return result
    }
}

struct OriginalPDFSearchMatch: Identifiable, Sendable {
    var id: String { "\(pageIndex)-\(range.location)" }
    let pageIndex: Int
    let range: NSRange
    let excerpt: String
}

enum OriginalPDFSearch {
    static let resultLimit = 200
    /// A separate PDFDocument belongs only to this worker, never to the visible PDFView.
    static func find(_ query: String, in url: URL) throws -> [OriginalPDFSearchMatch] {
        guard url.isFileURL, let document = PDFDocument(url: url), !document.isLocked else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        var result: [OriginalPDFSearchMatch] = []
        for pageIndex in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let text = document.page(at: pageIndex)?.string as NSString?, text.length > 0 else { continue }
            var offset = 0
            while offset < text.length {
                try Task.checkCancellation()
                let range = text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive],
                    range: NSRange(location: offset, length: text.length - offset))
                guard range.location != NSNotFound else { break }
                let start = max(0, range.location - 70)
                let end = min(text.length, NSMaxRange(range) + 100)
                let excerptRange = text.rangeOfComposedCharacterSequences(for: NSRange(location: start, length: end - start))
                let excerpt = text.substring(with: excerptRange).replacingOccurrences(of: "\n", with: " ")
                result.append(OriginalPDFSearchMatch(pageIndex: pageIndex, range: range, excerpt: excerpt))
                if result.count == resultLimit { return result }
                offset = NSMaxRange(range)
            }
        }
        return result
    }
}

private struct OriginalPDFThumbnail: View {
    @ObservedObject var model: OriginalPDFReaderModel
    let pageIndex: Int
    @State private var image: UIImage?
    var body: some View {
        VStack(spacing: 6) {
            Group {
                if let image { Image(uiImage: image).resizable().scaledToFit() }
                else { Rectangle().fill(.quaternary).overlay(ProgressView()) }
            }
            .frame(height: 150)
            Text("PDF page \(pageIndex + 1)").font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { image = model.thumbnail(at: pageIndex) }
        .onDisappear { image = nil }
    }
}

private struct OriginalPDFCanvas: UIViewRepresentable {
    @ObservedObject var model: OriginalPDFReaderModel
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeUIView(context: Context) -> OriginalPDFCanvasView {
        let view = OriginalPDFCanvasView()
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displaysPageBreaks = true
        view.autoScales = true
        view.backgroundColor = .secondarySystemBackground
        view.delegate = context.coordinator
        context.coordinator.observe(view)
        view.onLayoutReady = { [weak coordinator = context.coordinator, weak view] in
            guard let coordinator, let view, !coordinator.didScheduleRestore else { return }
            coordinator.didScheduleRestore = true
            DispatchQueue.main.async { [weak coordinator, weak view] in
                guard let coordinator, let view else { return }
                view.minScaleFactor = min(0.25, view.scaleFactorForSizeToFit)
                view.maxScaleFactor = max(8, view.scaleFactorForSizeToFit * 4)
                coordinator.model.restorePosition(in: view)
            }
        }
        return view
    }
    func updateUIView(_ view: OriginalPDFCanvasView, context: Context) {
        // Reassigning a PDFDocument during progress or sheet updates jumps back to page one.
        if view.document !== model.document { view.document = model.document }
        model.pdfView = view
    }
    static func dismantleUIView(_ view: OriginalPDFCanvasView, coordinator: Coordinator) {
        coordinator.stopObserving()
        view.delegate = nil
    }

    final class Coordinator: NSObject, PDFViewDelegate {
        let model: OriginalPDFReaderModel
        var didScheduleRestore = false
        private var observations: [NSObjectProtocol] = []
        init(model: OriginalPDFReaderModel) { self.model = model }
        func observe(_ view: PDFView) {
            for name in [Notification.Name.PDFViewPageChanged, .PDFViewScaleChanged, .PDFViewChangedHistory] {
                observations.append(NotificationCenter.default.addObserver(forName: name, object: view, queue: .main) { [weak self] _ in
                    // PDFKit may post while SwiftUI installs the document; defer state writes.
                    DispatchQueue.main.async { self?.model.updatePosition() }
                })
            }
        }
        func stopObserving() {
            observations.forEach { NotificationCenter.default.removeObserver($0) }
            observations.removeAll()
        }
        func pdfViewWillClick(onLink sender: PDFView, with url: URL) {
            // This delegate is invoked only for an explicit link tap, never document loading.
            guard let scheme = url.scheme?.lowercased(), ["https", "http", "mailto"].contains(scheme) else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.model.persistPosition()
                UIApplication.shared.open(url)
            }
        }
    }
}

private final class OriginalPDFCanvasView: PDFView {
    var onLayoutReady: (() -> Void)?
    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.width > 0, bounds.height > 0, document != nil { onLayoutReady?() }
    }
}
