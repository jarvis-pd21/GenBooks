import Foundation

/// Preferred OpenAI Chat Completions models.
enum OpenAIModelOption: String, CaseIterable, Identifiable, Codable, Sendable {
    case gpt56Luna = "gpt-5.6-luna"
    case gpt6Astra = "gpt-6-astra"
    case gpt41Mini = "gpt-4.1-mini"
    case gpt41 = "gpt-4.1"
    case gpt4oMini = "gpt-4o-mini"
    case gpt4o = "gpt-4o"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .gpt56Luna: return "GPT-5.6 Luna (Ask default)"
        case .gpt6Astra: return "GPT-6 Astra (Generation default)"
        case .gpt41Mini: return "GPT-4.1 mini"
        case .gpt41: return "GPT-4.1"
        case .gpt4oMini: return "GPT-4o mini"
        case .gpt4o: return "GPT-4o"
        }
    }

    /// Ask default — fast/cheap.
    static let defaultAsk: OpenAIModelOption = .gpt56Luna

    /// Book generation / adaptation default.
    static let defaultGeneration: OpenAIModelOption = .gpt6Astra

    /// Legacy alias kept for older call sites; prefer `defaultAsk`.
    static let `default`: OpenAIModelOption = .defaultAsk

    /// Ordered fallbacks when the preferred model is unavailable (404 / model_not_found).
    var fallbacks: [OpenAIModelOption] {
        switch self {
        case .gpt56Luna: return [.gpt41Mini, .gpt4oMini, .gpt41, .gpt4o]
        case .gpt6Astra: return [.gpt41, .gpt41Mini, .gpt4o, .gpt4oMini]
        case .gpt41Mini: return [.gpt56Luna, .gpt4oMini, .gpt41, .gpt4o]
        case .gpt41: return [.gpt6Astra, .gpt41Mini, .gpt4o, .gpt4oMini]
        case .gpt4oMini: return [.gpt56Luna, .gpt41Mini, .gpt4o]
        case .gpt4o: return [.gpt6Astra, .gpt41, .gpt41Mini, .gpt4oMini]
        }
    }
}

/// Soft-fail errors for Ask — never fatal to reading.
enum AIServiceError: Error, Equatable, LocalizedError, Sendable {
    case missingAPIKey
    case invalidAPIKey
    case timedOut
    case offline
    case malformedResponse
    case modelUnavailable(String)
    case httpStatus(Int, String?)
    case cancelled
    case underlying(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "No API key yet. Add one in Reading settings → AI, or use Mock answers for demos. Reading still works offline."
        case .invalidAPIKey:
            return "API key was rejected. Update it in Reading settings → AI. Reading is unaffected."
        case .timedOut:
            return "The AI request timed out. Try again when you have a better connection."
        case .offline:
            return "You’re offline. Ask needs a network connection; reading and Define still work."
        case .malformedResponse:
            return "Got an unexpected AI response. Nothing was saved; try again."
        case .modelUnavailable(let model):
            return "Model “\(model)” isn’t available right now. Try another model in settings."
        case .httpStatus(let code, let message):
            if let message, !message.isEmpty {
                return "AI request failed (\(code)): \(message)"
            }
            return "AI request failed (HTTP \(code))."
        case .cancelled:
            return "Request cancelled."
        case .underlying(let message):
            return message
        }
    }

    /// True when the user can fix by revealing spoilers or changing settings — not a crash.
    var isSoftFailure: Bool { true }
}

struct AskMessage: Identifiable, Equatable, Sendable, Codable {
    enum Role: String, Codable, Sendable {
        case user
        case assistant
        case system
    }

    let id: UUID
    let role: Role
    let content: String
    let createdAt: Date
    /// When true, assistant warned that an answer would spoil unread material.
    var isSpoilerWarning: Bool
    /// When true, assistant deliberately used unread content after user confirmation.
    var usedUnreadReveal: Bool
    /// When true, this bubble reports a soft failure rather than an answer, so
    /// the chat can style it as recovery copy and offer a retry.
    var isSoftFailure: Bool

    init(
        id: UUID = UUID(),
        role: Role,
        content: String,
        createdAt: Date = Date(),
        isSpoilerWarning: Bool = false,
        usedUnreadReveal: Bool = false,
        isSoftFailure: Bool = false
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.createdAt = createdAt
        self.isSpoilerWarning = isSpoilerWarning
        self.usedUnreadReveal = usedUnreadReveal
        self.isSoftFailure = isSoftFailure
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        role = try container.decode(Role.self, forKey: .role)
        content = try container.decode(String.self, forKey: .content)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        isSpoilerWarning = try container.decodeIfPresent(Bool.self, forKey: .isSpoilerWarning) ?? false
        usedUnreadReveal = try container.decodeIfPresent(Bool.self, forKey: .usedUnreadReveal) ?? false
        isSoftFailure = try container.decodeIfPresent(Bool.self, forKey: .isSoftFailure) ?? false
    }
}

/// Book-aware Ask request. Distinguishes The reader’s consumed knowledge from the full canonical book.
struct AskRequest: Equatable, Sendable {
    var userQuestion: String
    var selectedText: String?
    var surroundingContext: String?
    var currentChapterTitle: String?
    var currentChapterId: UUID?
    var bookTitle: String
    var bookAuthor: String
    /// Chapters / passages the reader has already consumed (safe to use freely).
    var consumedContext: String
    /// Unread / future material. NEVER included unless `allowUnreadSpoilers` is true.
    var unreadContext: String?
    var notesAndQuestions: String?
    var readerPreferencesSummary: String?
    /// When false (default), unreadContext must not be sent to the model as if read.
    var allowUnreadSpoilers: Bool
    /// Prefer mock deterministic answers (UI tests / no key).
    var forceMock: Bool

    init(
        userQuestion: String,
        selectedText: String? = nil,
        surroundingContext: String? = nil,
        currentChapterTitle: String? = nil,
        currentChapterId: UUID? = nil,
        bookTitle: String,
        bookAuthor: String,
        consumedContext: String,
        unreadContext: String? = nil,
        notesAndQuestions: String? = nil,
        readerPreferencesSummary: String? = nil,
        allowUnreadSpoilers: Bool = false,
        forceMock: Bool = false
    ) {
        self.userQuestion = userQuestion
        self.selectedText = selectedText
        self.surroundingContext = surroundingContext
        self.currentChapterTitle = currentChapterTitle
        self.currentChapterId = currentChapterId
        self.bookTitle = bookTitle
        self.bookAuthor = bookAuthor
        self.consumedContext = consumedContext
        self.unreadContext = unreadContext
        self.notesAndQuestions = notesAndQuestions
        self.readerPreferencesSummary = readerPreferencesSummary
        self.allowUnreadSpoilers = allowUnreadSpoilers
        self.forceMock = forceMock
    }
}

struct AskResponse: Equatable, Sendable {
    var answer: String
    var modelUsed: String
    var usedUnreadSpoilers: Bool
    var isSpoilerWarning: Bool
    var isMock: Bool

    static func spoilerWarning(message: String) -> AskResponse {
        AskResponse(
            answer: message,
            modelUsed: "policy",
            usedUnreadSpoilers: false,
            isSpoilerWarning: true,
            isMock: false
        )
    }
}
