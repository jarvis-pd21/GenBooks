import Foundation

/// Narrator voices offered for chapter audio. Kept deliberately short: two
/// voices is a choice, six is a menu.
enum ListenVoice: String, CaseIterable, Identifiable, Codable, Sendable {
    case marin
    case cedar

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .marin: return "Marin"
        case .cedar: return "Cedar"
        }
    }

    var blurb: String {
        switch self {
        case .marin: return "Warm, unhurried"
        case .cedar: return "Lower, steady"
        }
    }

    static let `default`: ListenVoice = .marin
}

/// Playback speeds. Values map straight onto `AVAudioPlayer.rate`.
enum ListenSpeed: Double, CaseIterable, Identifiable, Codable, Sendable {
    case slow = 0.75
    case normal = 1.0
    case brisk = 1.25
    case fast = 1.5
    case double = 2.0

    var id: Double { rawValue }

    var label: String {
        switch self {
        case .slow: return "0.75×"
        case .normal: return "1×"
        case .brisk: return "1.25×"
        case .fast: return "1.5×"
        case .double: return "2×"
        }
    }

    static let `default`: ListenSpeed = .normal
}

/// The narration instructions sent with every request.
///
/// This is an audiobook, not a summary: the model must read the supplied prose
/// verbatim. Spanish names inside English narration are the main pronunciation
/// risk in *A Little History of Argentina*, so they are called out explicitly.
enum ListenNarrationInstructions {
    static let audiobook = """
    Narrate this passage from a history book as a warm, unhurried audiobook.
    Read the supplied text aloud word for word, in order, exactly as written, and stop when it ends.
    Never summarize, shorten, skip, paraphrase, or reorder anything.
    Never add commentary, opinions, introductions, section announcements, or closing remarks.
    Pronounce Spanish and Latin American names, places, and phrases naturally in Spanish inside
    otherwise English narration, keeping accents and stress correct.
    Read numbers, dates, and years the way a person reading aloud would.
    Keep an even pace, honour sentence and paragraph pauses, and let the prose carry the drama.
    """
}

/// Everything that determines what the produced audio sounds like.
///
/// The plan is folded into the cache identity, so changing the model, the
/// instructions, or the chunk sizes can never play stale audio from an older
/// recipe.
struct ListenPlan: Equatable, Codable, Sendable {
    var model: String
    var responseFormat: String
    var instructions: String
    var preferredChunkUTF16: Int
    var maximumChunkUTF16: Int

    static let current = ListenPlan(
        model: "gpt-4o-mini-tts",
        responseFormat: "mp3",
        instructions: ListenNarrationInstructions.audiobook,
        preferredChunkUTF16: 900,
        maximumChunkUTF16: 1800
    )

    /// Short, stable token used inside cache paths.
    var fingerprint: String {
        ListenFingerprint.token(
            "\(model)|\(responseFormat)|\(preferredChunkUTF16)|\(maximumChunkUTF16)|\(instructions)"
        )
    }
}

/// FNV-1a, because `hashValue` is randomly seeded per process and cache paths
/// must survive relaunches.
enum ListenFingerprint {
    static func token(_ value: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return String(hash, radix: 36)
    }
}

/// One synthesis unit: a sentence-aligned slice of a chapter's narration text.
struct ListenChunk: Identifiable, Equatable, Codable, Sendable {
    var index: Int
    var text: String
    /// Where this chunk starts in the chapter's narration text (UTF-16 units).
    var utf16Start: Int
    var utf16Length: Int

    var id: Int { index }
}

/// Identity of a cached narration. Revision-first on purpose: once Living
/// adaptation writes a new revision of a chapter, its audio lives under a new
/// key and the previous revision's files can never be selected for it.
struct ListenCacheKey: Equatable, Hashable, Codable, Sendable {
    var bookId: UUID
    var chapterId: UUID
    var revisionId: UUID
    var voice: ListenVoice
    var planFingerprint: String

    /// Filesystem-safe identity for one (revision, voice, plan) triple.
    var storageKey: String {
        "\(revisionId.uuidString)-\(voice.rawValue)-\(planFingerprint)"
    }

    func fileName(chunkIndex: Int) -> String {
        String(format: "chunk-%03d.mp3", chunkIndex)
    }
}

/// A chapter prepared for narration. Built read-only from the readable
/// revision: producing one never touches the manuscript, the consumed ledger,
/// or the reader's place.
struct ListenDocument: Equatable, Codable, Sendable {
    var bookId: UUID
    var chapterId: UUID
    var chapterTitle: String
    var revisionId: UUID
    var voice: ListenVoice
    var plan: ListenPlan
    var chunks: [ListenChunk]

    var cacheKey: ListenCacheKey {
        ListenCacheKey(
            bookId: bookId,
            chapterId: chapterId,
            revisionId: revisionId,
            voice: voice,
            planFingerprint: plan.fingerprint
        )
    }

    var chunkCount: Int { chunks.count }
    var isEmpty: Bool { chunks.isEmpty }

    func chunk(at index: Int) -> ListenChunk? {
        chunks.indices.contains(index) ? chunks[index] : nil
    }

    /// Same chapter text and recipe, different narrator.
    func with(voice newVoice: ListenVoice) -> ListenDocument {
        var copy = self
        copy.voice = newVoice
        return copy
    }
}

/// Where listening stopped inside a chapter. Deliberately separate from
/// `ReadingCheckpoint`: hearing a chapter must never move the reader's place or
/// mark anything consumed.
struct ListenProgress: Identifiable, Equatable, Codable, Sendable {
    var id: UUID
    var bookId: UUID
    var chapterId: UUID
    var revisionId: UUID
    var voice: ListenVoice
    var chunkIndex: Int
    var offsetSeconds: Double
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        bookId: UUID,
        chapterId: UUID,
        revisionId: UUID,
        voice: ListenVoice,
        chunkIndex: Int,
        offsetSeconds: Double,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.bookId = bookId
        self.chapterId = chapterId
        self.revisionId = revisionId
        self.voice = voice
        self.chunkIndex = chunkIndex
        self.offsetSeconds = offsetSeconds
        self.updatedAt = updatedAt
    }

    /// Resume applies to the same chapter *revision* only. A regenerated
    /// chapter is different prose, so an old offset would land nowhere.
    /// Voice is ignored: the position in the text is the same either way.
    func canResume(_ document: ListenDocument) -> Bool {
        chapterId == document.chapterId
            && revisionId == document.revisionId
            && document.chunks.indices.contains(chunkIndex)
    }
}

/// Soft-fail surface for Listen. Nothing here may crash reading — narration is
/// an optional companion, and the copy always says so.
enum ListenError: Error, Equatable, LocalizedError, Sendable {
    case missingAPIKey
    case invalidAPIKey
    case offline
    case timedOut
    case cancelled
    case emptyChapter
    case malformedAudio
    case notDownloaded
    case rateLimited
    case modelUnavailable(String)
    case httpStatus(Int, String?)
    case storageFailed(String)
    case underlying(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Narration needs an API key. Add one in Reading settings → AI. Reading still works offline."
        case .invalidAPIKey:
            return "The API key was rejected, so narration can’t be made. Update it in Reading settings → AI."
        case .offline:
            return "You’re offline. Chapters you’ve already downloaded still play; making new audio needs a connection."
        case .timedOut:
            return "Making the narration timed out. Already-downloaded audio still plays; try again on a better connection."
        case .cancelled:
            return "Narration stopped. Nothing was lost."
        case .emptyChapter:
            return "There’s nothing to read aloud in this chapter yet."
        case .malformedAudio:
            return "The narration came back unreadable, so it wasn’t saved. Try again."
        case .notDownloaded:
            return "This part isn’t downloaded yet. Tap Download narration while you have a connection."
        case .rateLimited:
            return "OpenAI is rate-limiting narration requests. Wait a moment and continue — finished parts are kept."
        case .modelUnavailable(let model):
            return "The narration model “\(model)” isn’t available on this key right now."
        case .httpStatus(let code, let message):
            if let message, !message.isEmpty {
                return "Narration request failed (\(code)): \(message)"
            }
            return "Narration request failed (HTTP \(code))."
        case .storageFailed(let message):
            return "Couldn’t save the narration to this device: \(message)"
        case .underlying(let message):
            return message
        }
    }

    /// Every Listen failure is recoverable — reading and cached audio continue.
    var isSoftFailure: Bool { true }
}
