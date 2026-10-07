import Foundation

extension AIServiceResolver {
    /// Ordinary Create uses the existing selected model/key path. The isolated
    /// DEBUG acceptance route never reads that key and cannot serve other AI work.
    static func makeCreateGeneration(
        keyStore: APIKeyStoring = KeychainAPIKeyStore.shared,
        generationModel: OpenAIModelOption = .defaultGeneration,
        processInfo: ProcessInfo = .processInfo,
        bundleID: String? = Bundle.main.bundleIdentifier
    ) -> any AIService {
        #if DEBUG
        // Mixed trial signals cannot take the older Create route or an ordinary key.
        if SourceContinuationTrial.requested(arguments: processInfo.arguments, environment: processInfo.environment, bundleID: bundleID) {
            return SourceContinuationTrial.resolve(arguments: processInfo.arguments, environment: processInfo.environment,
                bundleID: bundleID, model: generationModel)
        }
        if processInfo.arguments.contains("-sourcePreviewTrial")
            || processInfo.environment["SOURCE_PREVIEW_TRIAL_ID"] != nil
            || bundleID == SourcePreviewTrial.bundleID {
            return SourcePreviewTrial.resolve(arguments: processInfo.arguments,
                environment: processInfo.environment, bundleID: bundleID,
                model: generationModel)
        }
        #endif
        return makeDefault(keyStore: keyStore, modelPreference: generationModel, processInfo: processInfo)
    }
}

#if DEBUG
enum SourcePreviewTrial {
    static let bundleID = "com.jarvis.livingreader.codex.createtrial"
    static let endpoint = URL(string: "http://127.0.0.1:8791/openai/v1/chat/completions")!
    static let proxyLabel = "source-preview-trial-no-provider-key"

    static func resolve(arguments: [String], environment: [String: String], bundleID: String?,
                        model: OpenAIModelOption, directory: URL? = nil) -> SourcePreviewTrialService {
        let mocks = ["-uitesting", "-useMockAI", "-phase4MockAsk", "-phase5AdaptationDemo"]
        guard arguments.contains("-sourcePreviewTrial"), !arguments.contains(where: mocks.contains),
              bundleID == Self.bundleID, model == .defaultGeneration,
              let rawID = environment["SOURCE_PREVIEW_TRIAL_ID"], let id = UUID(uuidString: rawID),
              rawID.lowercased() == id.uuidString.lowercased() else {
            return SourcePreviewTrialService(live: nil)
        }
        do {
            let root = try directory ?? FileManager.default.url(for: .applicationSupportDirectory,
                in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("SourcePreviewTrial", isDirectory: true)
            let gate = try SourcePreviewTrialGate(directory: root.appendingPathComponent(id.uuidString, isDirectory: true), id: id)
            guard SourcePreviewTrialTransport.configure(gate) else { return SourcePreviewTrialService(live: nil) }
            let config = SourcePreviewTrialTransport.configuration()
            config.protocolClasses = [SourcePreviewTrialTransport.self]
            let session = URLSession(configuration: config)
            return SourcePreviewTrialService(live: LiveOpenAIService(apiKeyProvider: { proxyLabel },
                preferredModel: .defaultGeneration, session: session, endpoint: endpoint))
        } catch { return SourcePreviewTrialService(live: nil) }
    }
}

/// A failed/mixed configuration cannot become Mock or direct OpenAI. The invalid
/// model marker also makes the wizard reject it before source retrieval.
final class SourcePreviewTrialService: AIService, SourceGroundedAI, @unchecked Sendable {
    private let live: LiveOpenAIService?
    init(live: LiveOpenAIService?) { self.live = live }
    var sourceReviewModelID: String { live == nil ? "trial-unavailable" : OpenAIModelOption.defaultGeneration.rawValue }
    private var unavailable: Error { SourceGroundingError.invalid("The isolated source trial is unavailable. No alternate AI route was used.") }
    func writeSourcePreview(_ request: SourceWritingRequest) async throws -> [SourceDraftParagraph] {
        guard let live else { throw unavailable }; return try await live.writeSourcePreview(request)
    }
    func reviewSourcePreview(_ request: SourceReviewRequest) async throws -> SourceReviewResponse {
        guard let live else { throw unavailable }; return try await live.reviewSourcePreview(request)
    }
    func ask(_ request: AskRequest) async throws -> AskResponse { throw unavailable }
    func adaptChapter(chapterId: UUID, promptContext: String) async throws -> ChapterRevision { throw unavailable }
    func makeAdaptationPlan(_ request: AdaptationPlanRequest) async throws -> AdaptationPlan { throw unavailable }
    func generateAdaptedChapter(_ request: AdaptationGenerateRequest) async throws -> [ContentBlock] { throw unavailable }
}

/// Request files are durable consumed slots, including failures. Recreating the
/// resolver or relaunching the app does not replenish them. Never erase a trial.
final class SourcePreviewTrialGate: @unchecked Sendable {
    let directory: URL
    let id: UUID
    private let lock = NSLock()
    init(directory: URL, id: UUID) throws {
        self.directory = directory; self.id = id
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    func file(_ name: String) -> URL { directory.appendingPathComponent(name) }
    func claim(_ original: URLRequest) throws -> (URLRequest, Int) {
        lock.lock(); defer { lock.unlock() }
        var request = original
        if request.httpBody == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count >= 0 else { throw URLError(.cannotDecodeRawData) }
                if count == 0 { break }
                bytes.append(contentsOf: buffer.prefix(count))
                guard bytes.count <= 24_000 else { throw URLError(.dataLengthExceedsMaximum) }
            }
            request.httpBodyStream = nil; request.httpBody = bytes
        }
        let index = FileManager.default.fileExists(atPath: file("request-0.json").path) ? 1 : 0
        guard request.url == SourcePreviewTrial.endpoint, request.httpMethod == "POST",
              request.value(forHTTPHeaderField: "Authorization") == "Bearer " + SourcePreviewTrial.proxyLabel,
              let body = request.httpBody, body.count <= 24_000,
              let json = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              Set(json.keys) == Set(["model", "messages", "max_completion_tokens", "response_format"]),
              json["model"] as? String == "gpt-6-astra",
              json["max_completion_tokens"] as? Int == (index == 0 ? 2500 : 3500),
              request.timeoutInterval == (index == 0 ? 60 : 90),
              let format = json["response_format"] as? [String: String], format == ["type": "json_object"],
              let messages = json["messages"] as? [[String: String]], messages.count == 2,
              Set(messages[0].keys) == Set(["role", "content"]), messages[0]["role"] == "system",
              Set(messages[1].keys) == Set(["role", "content"]), messages[1]["role"] == "user",
              let input = messages[1]["content"], let data = input.data(using: .utf8),
              let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let source = payload["source1"] as? String, !source.isEmpty else { throw URLError(.badURL) }
        if index == 0 {
            guard Set(payload.keys) == Set(["title", "topic", "voice", "source1"]),
                  ["title", "topic", "voice"].allSatisfy({ payload[$0] is String }) else { throw URLError(.badURL) }
        } else {
            guard FileManager.default.fileExists(atPath: file("success-0.txt").path),
                  !FileManager.default.fileExists(atPath: file("request-1.json").path),
                  Set(payload.keys) == Set(["paragraphs", "source1"]),
                  let paragraphs = payload["paragraphs"] as? [String], (2...6).contains(paragraphs.count),
                  let first = try JSONSerialization.jsonObject(with: Data(contentsOf: file("request-0.json"))) as? [String: Any],
                  let firstMessages = first["messages"] as? [[String: String]],
                  let firstContent = firstMessages.last?["content"],
                  let firstPayload = try JSONSerialization.jsonObject(with: Data(firstContent.utf8)) as? [String: Any],
                  firstPayload["source1"] as? String == source else { throw URLError(.resourceUnavailable) }
        }
        // Atomic exclusive creation fails closed across instances/processes too.
        try body.write(to: file("request-\(index).json"), options: .withoutOverwriting)
        // Build a fresh request: assigning allHTTPHeaderFields can preserve
        // existing Authorization in Foundation's bridged request storage.
        var forwarded = URLRequest(url: SourcePreviewTrial.endpoint)
        forwarded.httpMethod = "POST"; forwarded.httpBody = body
        forwarded.timeoutInterval = request.timeoutInterval
        forwarded.allHTTPHeaderFields = ["Content-Type": "application/json", "x-jarvis-estimated-usd": "1.5",
            "x-jarvis-work-package-id": "genbooks-create-source-trial",
            "x-jarvis-attempt-id": id.uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
            "x-jarvis-caller-request-id": "source-preview-\(index)"]
        return (forwarded, index)
    }
    func record(data: Data, status: Int, index: Int) throws {
        guard data.count <= 256_000 else { throw URLError(.dataLengthExceedsMaximum) }
        try data.write(to: file("response-\(index).json"), options: .withoutOverwriting)
        try Data(String(status).utf8).write(to: file("status-\(index).txt"), options: .withoutOverwriting)
        if status == 200 { try Data("200".utf8).write(to: file("success-\(index).txt"), options: .withoutOverwriting) }
    }
}

final class SourcePreviewTrialTransport: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var gate: SourcePreviewTrialGate?
    private var forwardedTask: URLSessionDataTask?
    private var transport: URLSession?
    static func configure(_ candidate: SourcePreviewTrialGate) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard gate == nil || (gate?.id == candidate.id && gate?.directory == candidate.directory) else { return false }
        if gate == nil { gate = candidate }; return true
    }
    static func configuration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = []
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.urlCache = nil
        config.timeoutIntervalForResource = 95; config.waitsForConnectivity = false
        return config
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            Self.lock.lock(); let gate = Self.gate; Self.lock.unlock()
            guard let gate else { throw URLError(.resourceUnavailable) }
            let (request, index) = try gate.claim(request)
            let session = URLSession(configuration: Self.configuration(), delegate: SourcePreviewTrialNoRedirect(), delegateQueue: nil)
            transport = session
            forwardedTask = session.dataTask(with: request) { [weak self] data, response, error in
                defer { session.finishTasksAndInvalidate() }
                guard let self else { return }
                do {
                    if let error { throw error }
                    guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                    let data = data ?? Data()
                    try gate.record(data: data, status: response.statusCode, index: index)
                    self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                    self.client?.urlProtocol(self, didLoad: data)
                    self.client?.urlProtocolDidFinishLoading(self)
                } catch { self.client?.urlProtocol(self, didFailWithError: error) }
            }
            forwardedTask?.resume()
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { forwardedTask?.cancel() }
}

final class SourcePreviewTrialNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
#endif
