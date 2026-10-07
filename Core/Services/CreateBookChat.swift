import Foundation

/// Who said a line in the Generate Book transcript.
enum CreateChatRole: String, Codable, Equatable, Hashable, Sendable {
    case bot
    case reader
}

struct CreateChatMessage: Identifiable, Codable, Equatable, Hashable, Sendable {
    var id: UUID
    var role: CreateChatRole
    var text: String

    init(id: UUID = UUID(), role: CreateChatRole, text: String) {
        self.id = id
        self.role = role
        self.text = text
    }
}

/// One thing BookBot still needs before it generates. These replace the old
/// always-visible More of / Less of toggle lists: asked one short line at a time,
/// and only after the essentials are in.
enum CreateChatSlot: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case topic
    case voice
    case moreOf
    case lessOf
    case research

    var id: String { rawValue }

    /// One line, no preamble. Keep it answerable in a few words.
    var question: String {
        switch self {
        case .topic: return "What is the book about?"
        case .voice: return "What voice? Warm, plain, funny…"
        case .moreOf: return "More of what? Stories, places, economics…"
        case .lessOf: return "Anything to leave out?"
        case .research: return "Facts I must keep true? Or say skip."
        }
    }

    /// Only the topic blocks Generate; everything else is optional colour.
    var isRequired: Bool { self == .topic }
}

/// Deterministic, offline slot-filling for the Generate Book tab. BookBot's questions
/// and its reading of an answer are local, so the tab converses with no key and no
/// network — generation itself stays the only AI step.
enum CreateBookChatScript {
    static let readyLine = "Ready — tap Generate when you are."

    /// Short ack for anything said after every slot is filled.
    static let extraNoteAck = "Noted. Tap Generate when you are."

    /// Answers that fill a slot without setting anything.
    static let skipAnswers: Set<String> = [
        "skip", "no", "none", "nope", "nothing", "na", "n a", "pass",
        "dont care", "don t care", "no preference", "you pick", "whatever"
    ]

    static func isSkip(_ answer: String) -> Bool {
        let letters = answer.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " }
        let normalized = String(letters)
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        return skipAnswers.contains(normalized)
    }

    /// Folds one reader answer into the draft. Free text always survives in the
    /// brief notes, because the topic enums are a lossy projection of what was said.
    static func apply(answer: String, for slot: CreateChatSlot, to draft: inout CreateBookDraft) {
        let text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        switch slot {
        case .topic:
            draft.topic = text
        case .voice:
            draft.voice = text
        case .moreOf:
            let matched = moreTopics(in: text)
            if !matched.isEmpty { draft.moreOf = matched }
            appendNote("More of: \(text)", to: &draft)
        case .lessOf:
            let matched = lessTopics(in: text)
            if !matched.isEmpty { draft.lessOf = matched }
            appendNote("Less of: \(text)", to: &draft)
        case .research:
            let existing = draft.researchNotes.trimmingCharacters(in: .whitespacesAndNewlines)
            draft.researchNotes = existing.isEmpty ? text : existing + "\n" + text
        }
    }

    static func appendNote(_ line: String, to draft: inout CreateBookDraft) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let existing = draft.readerNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.readerNotes = existing.isEmpty ? trimmed : existing + "\n" + trimmed
    }

    /// Ordered so a matched set is stable for the same answer.
    private static let moreKeywords: [(FeedbackMoreTopic, [String])] = [
        (.stories, ["stor", "narrative", "anecdote", "character", "people", "scene"]),
        (.globalContext, ["global", "world", "context", "compar", "elsewhere", "empire"]),
        (.economics, ["econom", "money", "trade", "price", "cost", "inflation", "business"]),
        (.placesIllVisit, ["place", "visit", "travel", "map", "geograph", "street", "city"]),
        (.explanation, ["explain", "explanation", "why", "clear", "detail", "background"])
    ]

    private static let lessKeywords: [(FeedbackLessTopic, [String])] = [
        (.names, ["name", "roster", "who is who"]),
        (.dates, ["date", "year", "chronolog", "timeline"]),
        (.politicalDetail, ["politic", "party", "parliament", "election", "government"]),
        (.repetition, ["repet", "repeat", "filler", "padding", "recap"])
    ]

    static func moreTopics(in answer: String) -> [FeedbackMoreTopic] {
        let text = answer.lowercased()
        return moreKeywords
            .filter { _, keys in keys.contains(where: text.contains) }
            .map(\.0)
    }

    static func lessTopics(in answer: String) -> [FeedbackLessTopic] {
        let text = answer.lowercased()
        return lessKeywords
            .filter { _, keys in keys.contains(where: text.contains) }
            .map(\.0)
    }

    /// A pasted `## Voice` / `## Outline` block from another AI is context, not an
    /// answer to the open question. Two or more cards is the signal.
    static func looksLikeProfileCardPaste(_ text: String) -> Bool {
        CreateProfileCardParser.parse(text).count >= 2
    }
}

/// Owns the Generate Book transcript and which questions are still open.
/// Value type so the conversation is unit-testable without any UI.
struct CreateBookChat: Equatable, Sendable {
    private(set) var messages: [CreateChatMessage] = []
    private(set) var answered: Set<CreateChatSlot> = []

    init() {}

    /// First unanswered slot, or nil once BookBot has everything it asks for.
    var pendingSlot: CreateChatSlot? {
        CreateChatSlot.allCases.first { !answered.contains($0) }
    }

    var isComplete: Bool { pendingSlot == nil }

    /// Opens the conversation with the first question. Idempotent.
    mutating func start() {
        guard messages.isEmpty else { return }
        ask()
    }

    /// Records the reader's line, folds it into the draft, and queues the next question.
    mutating func answer(_ raw: String, into draft: inout CreateBookDraft) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        messages.append(CreateChatMessage(role: .reader, text: text))

        if CreateBookChatScript.looksLikeProfileCardPaste(text) {
            let cards = CreateProfileCardParser.importCards(from: text, into: &draft)
            messages.append(
                CreateChatMessage(
                    role: .bot,
                    text: "Imported \(cards) card\(cards == 1 ? "" : "s")."
                )
            )
            ask()
            return
        }

        guard let slot = pendingSlot else {
            CreateBookChatScript.appendNote(text, to: &draft)
            messages.append(CreateChatMessage(role: .bot, text: CreateBookChatScript.extraNoteAck))
            return
        }
        // A required topic must remain answerable. Advancing on "skip" used to
        // leave the draft permanently undescribed, even after the chat said Ready.
        if slot.isRequired && CreateBookChatScript.isSkip(text) {
            messages.append(CreateChatMessage(role: .bot, text: "Give me a topic in a few words to get started."))
            return
        }
        answered.insert(slot)
        if !CreateBookChatScript.isSkip(text) {
            CreateBookChatScript.apply(answer: text, for: slot, to: &draft)
        }
        ask()
    }

    private mutating func ask() {
        let line = pendingSlot?.question ?? CreateBookChatScript.readyLine
        guard messages.last?.text != line else { return }
        messages.append(CreateChatMessage(role: .bot, text: line))
    }
}
