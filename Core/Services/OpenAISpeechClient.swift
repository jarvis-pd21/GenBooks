import Foundation

/// OpenAI `/v1/audio/speech` client for chapter narration.
///
/// Shares the single Keychain API key with Ask and adaptation — Listen never
/// asks for a second key. Never logs the request or the Authorization header.
///
/// Private MVP may call OpenAI directly with a user-supplied Keychain key.
/// Public production apps should proxy through a backend (see DECISIONS.md).
final class OpenAISpeechClient: SpeechSynthesizing, @unchecked Sendable {
    typealias APIKeyProvider = @Sendable () throws -> String?

    private let sharingPermission: AISharingConsentStore.PermissionProvider
    private let apiKeyProvider: APIKeyProvider
    private let session: URLSession
    private let endpoint: URL
    private let timeout: TimeInterval

    init(
        sharingPermission: @escaping AISharingConsentStore.PermissionProvider = { AISharingConsentStore.shared.isAllowed },
        apiKeyProvider: @escaping APIKeyProvider,
        session: URLSession? = nil,
        endpoint: URL = URL(string: "https://api.openai.com/v1/audio/speech")!,
        timeout: TimeInterval = 90
    ) {
        self.sharingPermission = sharingPermission
        self.apiKeyProvider = apiKeyProvider
        self.endpoint = endpoint
        self.timeout = timeout
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = timeout
            config.timeoutIntervalForResource = timeout
            config.waitsForConnectivity = false
            self.session = URLSession(configuration: config)
        }
    }

    func synthesize(_ request: SpeechSynthesisRequest) async throws -> Data {
        let text = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ListenError.emptyChapter }
        let key = try requireAPIKey()

        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = timeout
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        // Never log urlRequest / Authorization.

        let body = SpeechRequestBody(
            model: request.plan.model,
            input: text,
            voice: request.voice.rawValue,
            instructions: request.plan.instructions,
            response_format: request.plan.responseFormat
        )
        do {
            urlRequest.httpBody = try JSONEncoder().encode(body)
        } catch {
            throw ListenError.underlying("Couldn’t build the narration request.")
        }

        try AISharingConsentStore.requirePermission(using: sharingPermission)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch let urlError as URLError {
            throw Self.mapped(urlError)
        } catch is CancellationError {
            throw ListenError.cancelled
        } catch {
            throw ListenError.underlying(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ListenError.malformedAudio
        }
        if http.statusCode != 200 {
            throw ListenErrorMapper.http(
                status: http.statusCode,
                message: Self.errorMessage(in: data),
                model: request.plan.model
            )
        }
        guard ListenAudioValidator.looksLikeMP3(data) else {
            throw ListenError.malformedAudio
        }
        return data
    }

    static func mapped(_ error: URLError) -> ListenError {
        switch error.code {
        case .timedOut:
            return .timedOut
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed,
             .cannotFindHost, .cannotConnectToHost:
            return .offline
        case .cancelled:
            return .cancelled
        default:
            return .underlying(error.localizedDescription)
        }
    }

    private func requireAPIKey() throws -> String {
        let raw: String?
        do {
            raw = try apiKeyProvider()
        } catch {
            throw ListenError.underlying("Couldn’t read the API key from Keychain.")
        }
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            throw ListenError.missingAPIKey
        }
        return trimmed
    }

    /// A failed speech call returns JSON even though success returns audio.
    private static func errorMessage(in data: Data) -> String? {
        (try? JSONDecoder().decode(SpeechErrorEnvelope.self, from: data))?.error?.message
    }
}

private struct SpeechRequestBody: Encodable {
    var model: String
    var input: String
    var voice: String
    var instructions: String
    var response_format: String
}

private struct SpeechErrorEnvelope: Decodable {
    struct SpeechError: Decodable {
        var message: String?
        var type: String?
        var code: String?
    }
    var error: SpeechError?
}
