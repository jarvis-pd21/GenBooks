import Foundation

/// A one-tap opener for the Ask sheet.
///
/// `title` is the chip label (short enough for a scrolling row); `prompt` is the
/// question actually sent. Every prompt is phrased so it can be answered from
/// consumed material alone — chips must never be the thing that trips the
/// spoiler gate.
struct AskSuggestion: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let prompt: String

    init(id: String, title: String, prompt: String) {
        self.id = id
        self.title = title
        self.prompt = prompt
    }
}

enum AskSuggestions {
    static let selection: [AskSuggestion] = [
        AskSuggestion(
            id: "meaning",
            title: "What does this mean?",
            prompt: "What does this passage mean in context?"
        ),
        AskSuggestion(
            id: "who",
            title: "Who or what is this?",
            prompt: "Who or what is named here, and what have I been told about them so far?"
        ),
        AskSuggestion(
            id: "why",
            title: "Why does it matter?",
            prompt: "Why does this passage matter to the chapter I’m reading?"
        ),
        AskSuggestion(
            id: "simpler",
            title: "Say it simpler",
            prompt: "Rephrase this passage in plain language, using only what I’ve already read."
        )
    ]

    static let reading: [AskSuggestion] = [
        AskSuggestion(
            id: "recap",
            title: "Recap where I am",
            prompt: "Summarize what I’ve read so far without spoiling later chapters."
        ),
        AskSuggestion(
            id: "people",
            title: "Who’s who so far",
            prompt: "Who are the key people I’ve met so far, and how are they connected?"
        ),
        AskSuggestion(
            id: "chapter",
            title: "This chapter’s point",
            prompt: "What is this chapter arguing, based only on what I’ve read of it?"
        ),
        AskSuggestion(
            id: "confused",
            title: "I’m lost — help",
            prompt: "I’ve lost the thread. Re-orient me using only the chapters I’ve already read."
        )
    ]

    static func suggestions(hasSelection: Bool) -> [AskSuggestion] {
        hasSelection ? selection : reading
    }
}
