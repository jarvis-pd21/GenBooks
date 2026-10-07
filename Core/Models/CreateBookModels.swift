import Foundation

/// Library → New Book path. Import is local/offline; Generate uses Astra + PE.
enum CreateBookPath: String, Codable, CaseIterable, Identifiable, Sendable {
    case importManuscript
    case generate

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .importManuscript: return "Import"
        case .generate: return "Generate"
        }
    }
}

/// The two panes of New Book. Canon vs Living stays a code rule — the pane a
/// reader picks decides the path, so no UI copy has to explain the difference.
enum CreateBookTab: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case existingBooks
    case generateBook

    var id: String { rawValue }

    var title: String {
        switch self {
        case .existingBooks: return "Existing Books"
        case .generateBook: return "Generate Book"
        }
    }

    /// Classic bookshelf vs the AI sparkle: the symbol carries the mode.
    var systemImage: String {
        switch self {
        case .existingBooks: return "books.vertical"
        case .generateBook: return "sparkles"
        }
    }

    var accessibilityIdentifier: String {
        switch self {
        case .existingBooks: return "create.tab.existing"
        case .generateBook: return "create.tab.generate"
        }
    }

    /// Imported books stay verbatim Canon; generated books are Living.
    var path: CreateBookPath {
        switch self {
        case .existingBooks: return .importManuscript
        case .generateBook: return .generate
        }
    }

    init(path: CreateBookPath) {
        self = path == .generate ? .generateBook : .existingBooks
    }
}

enum ImportSourceKind: String, Codable, Equatable, Hashable, Sendable {
    case pastedText
    case pdfExtract
    case epubExtract

    var provenanceLabel: String {
        switch self {
        case .pastedText: return "pasted text"
        case .pdfExtract: return "PDF extract"
        case .epubExtract: return "EPUB"
        }
    }

    var canonSubtitle: String {
        switch self {
        case .pastedText: return "Canon · pasted text"
        case .pdfExtract: return "Canon · PDF"
        case .epubExtract: return "Canon · EPUB"
        }
    }
}

/// Retained for decoding and resuming drafts created before editable durations.
enum CreateBookLength: String, Codable, CaseIterable, Identifiable, Sendable {
    case short
    case medium
    case long

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .short: return "Short"
        case .medium: return "Medium"
        case .long: return "Long"
        }
    }

    var chapterCount: Int {
        switch self {
        case .short: return 3
        case .medium: return 6
        case .long: return 8
        }
    }

    var targetWordsPerChapter: Int {
        switch self {
        case .short: return 400
        case .medium: return 800
        case .long: return 1_200
        }
    }

    /// Whole-book word budget the generator aims for at this length.
    var targetWordCount: Int { chapterCount * targetWordsPerChapter }

    /// Trade-paperback density. These pages approximate the word budget;
    /// on-screen page counts also depend on type size and the viewport.
    static let wordsPerPage = 250

    var approximatePageCount: Int {
        approximatePageCount(chapterCount: chapterCount)
    }

    func approximatePageCount(chapterCount: Int) -> Int {
        max(1, Int((Double(chapterCount * targetWordsPerChapter) / Double(Self.wordsPerPage)).rounded()))
    }

    /// Reuses the shared word-based estimator so pages and time cannot disagree.
    var estimatedReadingTime: ReadingTimeEstimate {
        estimatedReadingTime(chapterCount: chapterCount)
    }

    func estimatedReadingTime(chapterCount: Int) -> ReadingTimeEstimate {
        ReadingTimeEstimate(
            proseWordCount: chapterCount * targetWordsPerChapter,
            visualBlockCount: 0,
            wordsPerMinute: ReadingTimePreferences.default.wordsPerMinute,
            secondsPerVisual: ReadingTimePreferences.default.secondsPerVisual
        )
    }

    /// Legacy preset labels; the current generator offers a typed duration.
    var pagesLabel: String { "\(approximatePageCount) pages" }

    var readingTimeLabel: String { "About \(estimatedReadingTime.compactLabel) to read" }
}

enum CreateReadingTime {
    static let wordsPerMinute = ReadingTimePreferences.default.wordsPerMinute
    static let wordsPerPage = CreateBookLength.wordsPerPage
    static let wordsPerChapter = 1_200
    static let maximumChapters = 1_000

    /// Bare numbers mean minutes. Units are explicit; never guess a preset or
    /// retain the previous valid value when an edit is incomplete or invalid.
    static func targetWords(for input: String) throws -> Int {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let number = #"(\d+(?:[.,]\d+)?|[.,]\d+)"#
        let pattern = "^(?:" + number + #"\s*(?:hours?|hrs?|h)\s*)?(?:"#
            + number + #"\s*(?:minutes?|mins?|m)?\s*)?$"#
        let regex = try NSRegularExpression(pattern: pattern)
        guard !text.isEmpty, text.count <= 80,
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else {
            throw CreateBookError.generationFailed("Enter a reading time, such as 45 min or 2 h 15 min.")
        }
        func value(_ group: Int) -> Decimal {
            guard let range = Range(match.range(at: group), in: text) else { return 0 }
            return Decimal(string: text[range].replacingOccurrences(of: ",", with: "."),
                           locale: Locale(identifier: "en_US_POSIX")) ?? .nan
        }
        var exactWords = (value(1) * 60 + value(2)) * Decimal(wordsPerMinute)
        var roundedWords = Decimal()
        NSDecimalRound(&roundedWords, &exactWords, 0, .plain)
        let words = NSDecimalNumber(decimal: roundedWords)
        guard words != .notANumber,
              words.compare(NSDecimalNumber(value: maximumChapters * wordsPerChapter)) != .orderedDescending else {
            throw CreateBookError.generationFailed("That reading time exceeds 1,000 chapters. Enter a shorter duration.")
        }
        guard words.compare(NSDecimalNumber(value: 20)) != .orderedAscending else {
            throw CreateBookError.generationFailed("Enter a positive duration for at least 20 words (about 0.1 min).")
        }
        return words.intValue
    }
}

enum CreateBookStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case narrative
    case explainer
    case reference

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .narrative: return "Narrative"
        case .explainer: return "Explainer"
        case .reference: return "Reference"
        }
    }
}

/// Editable card produced by the optional ChatGPT / other-AI paste-back.
struct CreateProfileCard: Identifiable, Codable, Equatable, Hashable, Sendable {
    var id: UUID
    var title: String
    var body: String

    init(id: UUID = UUID(), title: String, body: String) {
        self.id = id
        self.title = title
        self.body = body
    }
}

/// File-backed wizard draft. Not a manuscript — the canonical store stays Codable Book.
struct CreateBookDraft: Identifiable, Codable, Equatable, Hashable, Sendable {
    var id: UUID
    var path: CreateBookPath
    var title: String
    var author: String
    var topic: String
    var voice: String
    var length: CreateBookLength
    var style: CreateBookStyle
    var referenceStyles: [String]
    var moreOf: [FeedbackMoreTopic]
    var lessOf: [FeedbackLessTopic]
    var readerNotes: String
    var outlineTitles: [String]
    var researchNotes: String
    var profileCards: [CreateProfileCard]
    var importedText: String
    var importSourceKind: ImportSourceKind
    var updatedAt: Date

    /// Explicit one-source preview; absent in legacy and ordinary book drafts.
    var sourcePilot: SourcePilotPlan? = nil

    /// Nil preserves legacy preset budgets and existing source approvals. Keep
    /// the exact input so invalid edits cannot silently reuse another duration.
    var readingTimeInput: String? = nil

    static func blank(id: UUID = UUID(), at date: Date = Date()) -> CreateBookDraft {
        CreateBookDraft(
            id: id,
            path: .importManuscript,
            title: "",
            author: "",
            topic: "",
            voice: "neutral",
            length: .medium,
            style: .narrative,
            referenceStyles: [],
            moreOf: [.stories, .explanation],
            lessOf: [.repetition],
            readerNotes: "",
            outlineTitles: [],
            researchNotes: "",
            profileCards: [],
            importedText: "",
            importSourceKind: .pastedText,
            updatedAt: date
        )
    }

    var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedAuthor: String {
        author.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedTopic: String {
        topic.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var cleanedOutlineTitles: [String] {
        outlineTitles
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// The same outline drives generation and the length choices. Pasted chapter
    /// titles are preserved, so their count can differ from a preset's default.
    func resolvedOutline(for length: CreateBookLength) -> [String] {
        if let readingTimeInput {
            guard let words = try? CreateReadingTime.targetWords(for: readingTimeInput) else { return [] }
            let existing = cleanedOutlineTitles
            if !existing.isEmpty { return existing }
            let fromCards = CreateProfileCardParser.outlineTitles(from: profileCards)
            if !fromCards.isEmpty { return fromCards }
            let count = (words + CreateReadingTime.wordsPerChapter - 1) / CreateReadingTime.wordsPerChapter
            return CreateBookOutline.defaultTitles(topic: trimmedTopic, count: count)
        }
        let existing = cleanedOutlineTitles
        if !existing.isEmpty { return existing }
        let fromCards = CreateProfileCardParser.outlineTitles(from: profileCards)
        if !fromCards.isEmpty { return Array(fromCards.prefix(length.chapterCount)) }
        return CreateBookOutline.defaultTitles(topic: trimmedTopic, count: length.chapterCount)
    }

    func pagesLabel(for length: CreateBookLength) -> String {
        "\(length.approximatePageCount(chapterCount: resolvedOutline(for: length).count)) pages"
    }

    var estimatedReadingTime: ReadingTimeEstimate {
        if let readingTimeInput {
            return ReadingTimeEstimate(
                proseWordCount: (try? CreateReadingTime.targetWords(for: readingTimeInput)) ?? 0,
                visualBlockCount: 0, wordsPerMinute: CreateReadingTime.wordsPerMinute,
                secondsPerVisual: ReadingTimePreferences.default.secondsPerVisual
            )
        }
        return length.estimatedReadingTime(chapterCount: resolvedOutline(for: length).count)
    }

    var readingTimeLabel: String { "About \(estimatedReadingTime.compactLabel) to read" }

    var lengthInputText: String {
        readingTimeInput ?? estimatedReadingTime.remainingMinutes.formatted(
            .number.precision(.fractionLength(0...3)).grouping(.never)
        ) + " min"
    }

    var approximatePagesLabel: String {
        guard lengthValidationMessage == nil else { return "— pages" }
        let pages = max(1, Int((Double(estimatedReadingTime.proseWordCount) / Double(CreateReadingTime.wordsPerPage)).rounded()))
        return "About \(pages) \(pages == 1 ? "page" : "pages")"
    }

    var lengthValidationMessage: String? {
        do { _ = try validatedTargetWordCount(); return nil }
        catch { return error.localizedDescription }
    }

    func validatedTargetWordCount() throws -> Int {
        if sourcePilot != nil, readingTimeInput != nil {
            throw CreateBookError.generationFailed("The approved source preview has a fixed 400-word length.")
        }
        guard let readingTimeInput else { return estimatedReadingTime.proseWordCount }
        let words = try CreateReadingTime.targetWords(for: readingTimeInput)
        _ = try chapterWordTargets(chapterCount: resolvedOutline(for: length).count)
        return words
    }

    /// Allocate across ALL chapter positions before filtering completed ones.
    /// Remainder words stay attached to the same position after a retry.
    func chapterWordTargets(chapterCount: Int) throws -> [Int] {
        guard let readingTimeInput else {
            return Array(repeating: length.targetWordsPerChapter, count: chapterCount)
        }
        let words = try CreateReadingTime.targetWords(for: readingTimeInput)
        guard chapterCount > 0, chapterCount <= CreateReadingTime.maximumChapters,
              words / chapterCount >= 20,
              (words + chapterCount - 1) / chapterCount <= CreateReadingTime.wordsPerChapter else {
            let minimum = (words + CreateReadingTime.wordsPerChapter - 1) / CreateReadingTime.wordsPerChapter
            throw CreateBookError.generationFailed("For this reading time, use \(minimum)–\(min(words / 20, CreateReadingTime.maximumChapters)) outline chapters, or change the reading time.")
        }
        return (0..<chapterCount).map { words / chapterCount + ($0 < words % chapterCount ? 1 : 0) }
    }

    /// Copy-to-clipboard prompt for the optional ChatGPT / other-AI profile import.
    static let chatgptExportPrompt = """
    Help me draft a GenBooks book. Reply in this exact markdown — I will paste it back:

    ## Voice
    (tone in one line)

    ## More of
    (comma-separated: stories, explanation, places, economics, global context)

    ## Less of
    (comma-separated: names, dates, political detail, repetition)

    ## Outline
    - Chapter title 1
    - Chapter title 2

    ## Research notes
    (claims to research, with source citations when available; unsupported assertions must not be presented as facts)

    ## Reference styles
    (authors or books whose voice I want as a reference — not to copy)
    """
}

enum CreateBookError: Error, Equatable, LocalizedError, Sendable {
    case emptySource
    case missingTitle
    case missingTopic
    case noChapters
    case generationFailed(String)
    case factGate(String)
    case argentinaProtected
    case quranProtected
    case epubUnreadable(String)
    case drmProtected
    case unsupportedImportType

    var errorDescription: String? {
        switch self {
        case .emptySource:
            return "Paste text, choose an EPUB, or extract a PDF before importing."
        case .missingTitle:
            return "Give the book a title before generating."
        case .missingTopic:
            return "Describe the book in a sentence before generating."
        case .noChapters:
            return "Could not find any chapters to save."
        case .generationFailed(let reason):
            return reason
        case .factGate(let reason):
            return "Fact gate blocked a chapter: \(reason)"
        case .argentinaProtected:
            return "The Argentina seed cannot be overwritten by Create."
        case .quranProtected:
            return "The Quran seed cannot be overwritten by Create."
        case .epubUnreadable(let reason):
            return reason
        case .drmProtected:
            return "This file is DRM-protected. GenBooks opens DRM-free EPUB and PDF only — it will not strip or bypass DRM."
        case .unsupportedImportType:
            return "GenBooks can open a DRM-free EPUB or PDF as Canon."
        }
    }
}

/// Argentina stays first, then the Quran seed, then other books by title.
enum CreateBookOutline {
    static func defaultTitles(topic: String, count: Int) -> [String] {
        let subject = topic.isEmpty ? "the subject" : topic
        let templates = [
            "Opening: \(subject)",
            "How \(subject) took shape",
            "People inside \(subject)",
            "Turning points of \(subject)",
            "Places that still hold \(subject)",
            "Arguments about \(subject)",
            "What \(subject) costs",
            "Where \(subject) goes next"
        ]
        if count <= templates.count {
            return Array(templates.prefix(count))
        }
        var titles = templates
        for index in templates.count..<count {
            titles.append("Chapter \(index + 1): \(subject)")
        }
        return titles
    }
}

enum LibraryBookOrdering {
    static func sorted(_ books: [Book]) -> [Book] {
        books.sorted { lhs, rhs in
            if lhs.id == ArgentinaFixtureIDs.book { return true }
            if rhs.id == ArgentinaFixtureIDs.book { return false }
            if lhs.id == QuranFixtureIDs.book { return true }
            if rhs.id == QuranFixtureIDs.book { return false }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }
}

/// Outcome of Path B generate: the saved book plus which chapters the gate skipped.
struct CreateBookGenerationResult: Equatable, Sendable {
    var book: Book
    var generatedChapterIds: [UUID]
    var skippedChapterIds: [UUID]
    var usedDeterministicFallback: Bool
    var packet: PEContinuityPacket
    var failureMessages: [String] = []

    var isComplete: Bool {
        !book.chapters.isEmpty && skippedChapterIds.isEmpty && book.outlineChapterCount == 0
    }

    var completionMessage: String {
        if isComplete {
            return usedDeterministicFallback
                ? "Created bundled demo “\(book.title)”. No live AI was used."
                : "Created “\(book.title)”."
        }
        let written = book.chapters.count - book.outlineChapterCount
        let progress = written == 0 ? "No chapters were written." : "\(written) of \(book.chapters.count) chapters are ready."
        let reason = failureMessages.first ?? "The remaining chapters could not be published."
        let demo = usedDeterministicFallback ? " Bundled demo; no live AI was used." : ""
        return "\(progress) \(reason) Your draft and saved chapters are kept. Retry only unfinished, unread outlines.\(demo)"
    }
}
