import Foundation

struct SpeechSynthesisRequest: Equatable, Sendable {
    var text: String
    var voice: ListenVoice
    var plan: ListenPlan

    init(text: String, voice: ListenVoice, plan: ListenPlan = .current) {
        self.text = text
        self.voice = voice
        self.plan = plan
    }
}

/// Turns one chunk of prose into encoded audio. Implementations must throw
/// `ListenError` so the Listen UI can always show recovery copy instead of a
/// raw networking message.
protocol SpeechSynthesizing: Sendable {
    func synthesize(_ request: SpeechSynthesisRequest) async throws -> Data
}

/// HTTP status → soft-fail Listen error.
///
/// Kept out of the URLSession client so the copy a reader sees for a rejected
/// key or a rate limit can be asserted without a network stack.
enum ListenErrorMapper {
    static func http(status: Int, message: String?, model: String) -> ListenError {
        switch status {
        case 401, 403:
            return .invalidAPIKey
        case 404:
            return .modelUnavailable(model)
        case 429:
            return .rateLimited
        case 400:
            if let message, message.lowercased().contains("model") {
                return .modelUnavailable(model)
            }
            return .httpStatus(400, sanitize(message))
        default:
            return .httpStatus(status, sanitize(message))
        }
    }

    /// Never echo anything unbounded (or key-shaped) back into the UI.
    static func sanitize(_ message: String?) -> String? {
        guard var message else { return nil }
        if message.count > 200 {
            message = String(message.prefix(200)) + "…"
        }
        return message
    }
}

/// Cheap sanity check before anything is written to the cache: a truncated or
/// JSON error body must never be stored as if it were a chapter's narration.
enum ListenAudioValidator {
    /// Smallest plausible MP3 for a sentence of speech.
    static let minimumByteCount = 512

    static func looksLikeMP3(_ data: Data) -> Bool {
        guard data.count >= minimumByteCount else { return false }
        let bytes = [UInt8](data.prefix(3))
        // "ID3" tag.
        if bytes.count >= 3, bytes[0] == 0x49, bytes[1] == 0x44, bytes[2] == 0x33 {
            return true
        }
        // MPEG frame sync (11 set bits).
        if bytes.count >= 2, bytes[0] == 0xFF, (bytes[1] & 0xE0) == 0xE0 {
            return true
        }
        return false
    }
}
