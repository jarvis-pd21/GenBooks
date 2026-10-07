import Foundation

/// Builds spoiler-safe Ask prompts from reading state.
/// Canonical book knowledge vs The reader’s consumed knowledge are kept distinct.
enum AskContextBuilder {
    static let spoilerWarningText = """
    That gets ahead of where you’ve read. I can answer using only what you’ve already consumed \
    (and the passage you selected), or you can deliberately reveal later material.
    """

    struct ReadingSlice: Equatable, Sendable {
        var chapterId: UUID
        var title: String
        var orderIndex: Int
        var revisionId: UUID
        var plainText: String
        var isConsumed: Bool
        var isCurrent: Bool
    }

    /// Assembles consumed vs unread slices. Unread text is returned separately and must not
    /// be injected into normal prompts unless the user opts into spoilers.
    static func buildRequest(
        question: String,
        book: Book,
        slices: [ReadingSlice],
        selectedText: String?,
        surroundingContext: String?,
        currentChapterId: UUID?,
        notesAndQuestions: String?,
        readerPreferencesSummary: String?,
        allowUnreadSpoilers: Bool,
        forceMock: Bool = false
    ) -> AskRequest {
        let ordered = slices.sorted { $0.orderIndex < $1.orderIndex }
        let consumed = ordered.filter { $0.isConsumed || $0.isCurrent || $0.chapterId == currentChapterId }
        let unread = ordered.filter { slice in
            !slice.isConsumed && !slice.isCurrent && slice.chapterId != currentChapterId
        }

        let consumedText = consumed.map { slice in
            let tag = slice.isCurrent ? "CURRENT" : "CONSUMED"
            return "[\(tag) Ch \(slice.orderIndex + 1): \(slice.title)]\n\(truncate(slice.plainText, limit: 2_400))"
        }.joined(separator: "\n\n")

        let unreadText: String? = {
            guard !unread.isEmpty else { return nil }
            return unread.map { slice in
                "[UNREAD Ch \(slice.orderIndex + 1): \(slice.title)]\n\(truncate(slice.plainText, limit: 2_400))"
            }.joined(separator: "\n\n")
        }()

        let currentTitle = ordered.first(where: { $0.chapterId == currentChapterId })?.title
            ?? ordered.first(where: \.isCurrent)?.title

        return AskRequest(
            userQuestion: question,
            selectedText: selectedText,
            surroundingContext: surroundingContext,
            currentChapterTitle: currentTitle,
            currentChapterId: currentChapterId,
            bookTitle: book.title,
            bookAuthor: book.author,
            consumedContext: consumedText,
            unreadContext: unreadText,
            notesAndQuestions: notesAndQuestions,
            readerPreferencesSummary: readerPreferencesSummary,
            allowUnreadSpoilers: allowUnreadSpoilers,
            forceMock: forceMock
        )
    }

    /// True when the question likely needs later material (heuristic for spoiler gate).
    static func questionAppearsToNeedUnread(_ question: String, hasUnread: Bool) -> Bool {
        guard hasUnread else { return false }
        let q = question.lowercased()
        let spoilery = [
            "what happens later", "spoiler", "end of the book", "final chapter",
            "what happens next chapter", "later in the book", "at the end",
            "who dies", "how does it end", "future chapter"
        ]
        return spoilery.contains { q.contains($0) }
    }

    static func systemPrompt(for request: AskRequest) -> String {
        var lines: [String] = []
        lines.append("You are BookBot, GenBooks’ friendly book-aware reading companion for a private MVP.")
        lines.append("Distinguish CANONICAL book knowledge from the reader’s CONSUMED knowledge state.")
        lines.append("Use CONSUMED / CURRENT chapter excerpts as available reading context. A visible passage or reading-completion record does not prove the reader has understood it.")
        if request.allowUnreadSpoilers {
            lines.append("The reader deliberately allowed UNREAD spoilers for this answer. You may use UNREAD excerpts when needed, and say when you do.")
        } else {
            lines.append("CRITICAL: Do NOT use unread/future book content as if the reader has read it. If you would need later material, say it gets ahead of where they’ve read and stop short of spoiling.")
        }
        lines.append("No external source retrieval or independent source check was performed for this reply. You may explain using general knowledge, but distinguish it from the supplied text. Never claim to have fetched or verified a source, and never invent quotations or citations.")
        lines.append("Be concise, clear, and helpful for comprehension. Prefer the selected passage and surrounding context when present.")
        if let prefs = request.readerPreferencesSummary, !prefs.isEmpty {
            lines.append("Reader preferences: \(prefs)")
        }
        return lines.joined(separator: "\n")
    }

    static func userPrompt(for request: AskRequest) -> String {
        var parts: [String] = []
        parts.append("Book: \(request.bookTitle) by \(request.bookAuthor)")
        if let chapter = request.currentChapterTitle {
            parts.append("Current chapter: \(chapter)")
        }
        if let selected = request.selectedText, !selected.isEmpty {
            parts.append("Selected text:\n\"\(selected)\"")
        }
        if let surrounding = request.surroundingContext, !surrounding.isEmpty {
            parts.append("Surrounding context:\n\(truncate(surrounding, limit: 1_200))")
        }
        if !request.consumedContext.isEmpty {
            parts.append("The reader’s consumed / current reading state (safe):\n\(request.consumedContext)")
        } else {
            parts.append("The reader’s consumed reading state: (none recorded yet — treat only the selection/surroundings as read).")
        }
        if request.allowUnreadSpoilers, let unread = request.unreadContext, !unread.isEmpty {
            parts.append("UNREAD material (deliberate reveal enabled):\n\(unread)")
        }
        if let notes = request.notesAndQuestions, !notes.isEmpty {
            parts.append("Relevant notes/questions:\n\(truncate(notes, limit: 800))")
        }
        parts.append("Question:\n\(request.userQuestion)")
        return parts.joined(separator: "\n\n")
    }

    /// Full prompt text actually sent to a model (unread omitted unless reveal enabled).
    static func contextPayload(for request: AskRequest) -> String {
        systemPrompt(for: request) + "\n\n" + userPrompt(for: request)
    }

    /// Returns whether the assembled payload contains unread markers.
    static func payloadContainsUnreadMarker(_ payload: String) -> Bool {
        payload.contains("[UNREAD")
    }

    static func truncate(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let idx = text.index(text.startIndex, offsetBy: limit)
        return String(text[..<idx]) + "…"
    }

    static func plainText(from revision: ChapterRevision) -> String {
        revision.blocks
            .sorted { $0.orderIndex < $1.orderIndex }
            .map(\.text)
            .joined(separator: "\n\n")
    }
}
