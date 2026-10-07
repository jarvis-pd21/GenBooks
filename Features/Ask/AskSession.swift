import Foundation
import SwiftUI

/// Owns Ask chat state. Soft-fails; never blocks reading chrome.
@MainActor
final class AskSession: ObservableObject {
    @Published var messages: [AskMessage] = []
    @Published var draft: String = ""
    @Published var isSending = false
    @Published var lastError: String?
    @Published var pendingSpoilerReveal = false
    @Published private(set) var allowUnreadSpoilers = false

    /// The passage the sheet was opened on, for the pinned context line.
    @Published private(set) var selectionContext: String?

    private var ai: any AIService
    private var seedQuestion: String?
    private var buildRequest: ((String, Bool) -> AskRequest)?
    private var inFlightSend: Task<AskResponse, Error>?
    /// Cancelling a provider is best effort; only the current request may publish.
    private var requestID = UUID()

    init(ai: any AIService) {
        self.ai = ai
    }

    /// Replace the backing AIService (e.g. after saving an API key mid-session).
    func updateAI(_ service: any AIService) {
        ai = service
    }

    /// The composer opens empty on purpose: a pre-filled question has to be
    /// deleted before a reader can ask their own. Openers are offered as
    /// one-tap chips instead.
    func configure(
        seedQuestion: String?,
        selectedText: String?,
        buildRequest: @escaping (String, Bool) -> AskRequest
    ) {
        invalidateInFlight()
        self.buildRequest = buildRequest
        self.seedQuestion = seedQuestion?.trimmingCharacters(in: .whitespacesAndNewlines)
        selectionContext = (selectedText?.isEmpty ?? true) ? nil : selectedText
        messages = []
        draft = ""
        lastError = nil
        pendingSpoilerReveal = false
        allowUnreadSpoilers = false
    }

    /// True once anything has been asked — drives the empty state.
    var hasConversation: Bool {
        messages.contains { $0.role == .user || $0.role == .assistant }
    }

    var hasSelectionContext: Bool { selectionContext != nil }

    var contextLine: String? {
        selectionContext.map { BookBotChrome.contextLine(for: $0) }
    }

    /// One-tap openers. A question the reader arrived with (Define → Explain in
    /// context) leads, then the generic spoiler-safe set.
    var suggestions: [AskSuggestion] {
        let base = AskSuggestions.suggestions(hasSelection: hasSelectionContext)
        guard let seedQuestion, !seedQuestion.isEmpty else { return base }
        let seeded = AskSuggestion(id: "seed", title: seedQuestion, prompt: seedQuestion)
        return [seeded] + base.filter { $0.prompt != seedQuestion }
    }

    var canSendDraft: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSending
    }

    var lastUserQuestion: String? {
        messages.last(where: { $0.role == .user })?.content
    }

    func sendDraft() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }
        draft = ""
        await send(question: text, allowUnreadSpoilers: allowUnreadSpoilers)
    }

    /// A suggestion chip asks immediately rather than filling the field.
    func send(suggestion: AskSuggestion) async {
        guard !isSending else { return }
        draft = ""
        await send(question: suggestion.prompt, allowUnreadSpoilers: allowUnreadSpoilers)
    }

    /// Used by demo/screenshot launches that arrive with a question already chosen.
    func sendSeedQuestion() async {
        guard let seedQuestion, !seedQuestion.isEmpty else { return }
        await send(question: seedQuestion, allowUnreadSpoilers: allowUnreadSpoilers)
    }

    func revealSpoilersAndResend() async {
        guard let lastUser = messages.last(where: { $0.role == .user }) else { return }
        allowUnreadSpoilers = true
        pendingSpoilerReveal = false
        await send(question: lastUser.content, allowUnreadSpoilers: true)
    }

    /// Retry after a soft failure. The failed bubble is replaced rather than
    /// stacked, and the question is not asked twice in the transcript.
    func retryLastQuestion() async {
        guard !isSending, let question = lastUserQuestion else { return }
        if let last = messages.last, last.role == .assistant, last.isSoftFailure {
            messages.removeLast()
        }
        lastError = nil
        await send(question: question, allowUnreadSpoilers: allowUnreadSpoilers, recordUserMessage: false)
    }

    func send(question: String, allowUnreadSpoilers: Bool, recordUserMessage: Bool = true) async {
        guard let buildRequest else {
            lastError = "BookBot isn’t ready yet. Close and try again — reading still works."
            return
        }
        invalidateInFlight()
        let id = requestID
        isSending = true
        lastError = nil
        if recordUserMessage {
            messages.append(AskMessage(role: .user, content: question))
        }

        let request = buildRequest(question, allowUnreadSpoilers)
        let task = Task { [ai] in
            try await ai.ask(request)
        }
        inFlightSend = task
        defer {
            if requestID == id {
                isSending = false
                inFlightSend = nil
            }
        }
        do {
            let response = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            guard requestID == id, !Task.isCancelled, !task.isCancelled else { return }
            if response.isSpoilerWarning {
                pendingSpoilerReveal = true
                messages.append(
                    AskMessage(
                        role: .assistant,
                        content: response.answer,
                        isSpoilerWarning: true
                    )
                )
            } else {
                pendingSpoilerReveal = false
                messages.append(
                    AskMessage(
                        role: .assistant,
                        content: response.answer,
                        usedUnreadReveal: response.usedUnreadSpoilers
                    )
                )
            }
        } catch is CancellationError {
            guard requestID == id else { return }
            lastError = nil
            messages.append(
                AskMessage(
                    role: .assistant,
                    content: "BookBot cancelled — reading is unaffected.",
                    isSoftFailure: true
                )
            )
        } catch let error as AIServiceError {
            guard requestID == id, !Task.isCancelled, !task.isCancelled else { return }
            lastError = error.localizedDescription
            messages.append(
                AskMessage(
                    role: .assistant,
                    content: error.localizedDescription,
                    isSoftFailure: true
                )
            )
        } catch {
            guard requestID == id, !Task.isCancelled, !task.isCancelled else { return }
            let message = "BookBot failed softly: \(error.localizedDescription). Reading is unaffected."
            lastError = message
            messages.append(AskMessage(role: .assistant, content: message, isSoftFailure: true))
        }
    }

    /// Soft-cancel mid-Ask. Reading chrome is never blocked.
    func cancelInFlight() {
        let wasSending = isSending
        invalidateInFlight()
        if wasSending {
            lastError = nil
            pendingSpoilerReveal = false
            messages.append(AskMessage(role: .assistant,
                content: "BookBot cancelled — reading is unaffected.", isSoftFailure: true))
        }
    }

    private func invalidateInFlight() {
        requestID = UUID()
        inFlightSend?.cancel()
        inFlightSend = nil
        isSending = false
    }

    func resetConversation() {
        invalidateInFlight()
        messages = []
        draft = ""
        lastError = nil
        pendingSpoilerReveal = false
        allowUnreadSpoilers = false
    }
}
