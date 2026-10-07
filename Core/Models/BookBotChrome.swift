import Foundation

/// User-facing names for the in-app AI companion.
///
/// Product rule: the control that opens the companion is never labelled with the
/// bare bot name. `askAction` is the label; `askActionCompact` is the fallback
/// for chrome too tight for it (large Dynamic Type, two-up selection grid).
enum BookBotChrome {
    /// The companion's name. Used in prose and titles, never alone on a button.
    static let botName = "BookBot"

    static let askAction = "Ask BookBot"

    /// Same intent, fewer glyphs, sanctioned for chrome that genuinely cannot
    /// paint the full label. Still never the bare bot name. Every surface
    /// currently fits `askAction`, so nothing paints this today — it exists so
    /// a tight control shortens to an agreed string instead of inventing one.
    static let askActionCompact = "Ask Bot"

    static let sheetTitle = askAction

    static let composerPlaceholder = "Ask BookBot…"

    static let emptyStateTitle = "Ask BookBot"

    static let emptyStateBlurb = """
    Answers use only what you’ve already read. Nothing from later chapters is spoiled unless you ask for it.
    """

    static let thinkingLabel = "BookBot is thinking…"

    static let softFailBanner = "BookBot couldn’t answer. Reading is unaffected."

    /// Label above the suggestion chips. iOS taps, it does not click.
    static let suggestionsPrompt = "Tap to ask:"

    /// How much of a selected passage the pinned context line shows.
    static let contextQuoteLimit = 88

    /// "Asking about: …" for the pinned context line. Long selections are cut on
    /// a word boundary so the line never ends mid-word.
    static func contextLine(for selection: String) -> String {
        "Asking about: “\(truncatedAtWordBoundary(selection, limit: contextQuoteLimit))”"
    }

    /// Collapses whitespace, then clips to `limit` on the last word boundary
    /// before it and appends a single ellipsis.
    static func truncatedAtWordBoundary(_ text: String, limit: Int) -> String {
        let collapsed = text
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
        guard limit > 0 else { return collapsed.isEmpty ? "" : "…" }
        guard collapsed.count > limit else { return collapsed }

        let head = String(collapsed.prefix(limit))
        let trimSet = CharacterSet(charactersIn: " ,;:.!?—–-")
        if let lastSpace = head.lastIndex(of: " ") {
            let clipped = String(head[head.startIndex..<lastSpace])
                .trimmingCharacters(in: trimSet)
            if !clipped.isEmpty { return clipped + "…" }
        }
        return head.trimmingCharacters(in: trimSet) + "…"
    }

    /// Guard for the rename: a label must say what the control does, not just
    /// name the bot. Asserted by unit tests and mirrored by the UI test.
    static func isAcceptableAskLabel(_ label: String) -> Bool {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard trimmed.caseInsensitiveCompare(botName) != .orderedSame else { return false }
        return trimmed.localizedCaseInsensitiveContains("ask")
    }
}
