import Foundation
import CryptoKit

#if DEBUG
/// A distinct, opt-in acceptance route. Its old Create counterpart remains closed.
enum SourceContinuationTrial {
    static let bundleID = "com.jarvis.livingreader.codex.continuationtrial"
    static let endpoint = URL(string: "http://127.0.0.1:8791/openai/v1/chat/completions")!
    static let proxyLabel = "source-continuation-trial-no-provider-key"
    static let argument = "-sourceContinuationTrial"
    static let environmentKey = "SOURCE_CONTINUATION_TRIAL_ID"

    static func requested(arguments: [String] = ProcessInfo.processInfo.arguments,
                          environment: [String: String] = ProcessInfo.processInfo.environment,
                          bundleID: String? = Bundle.main.bundleIdentifier) -> Bool {
        bundleID == Self.bundleID || arguments.contains(argument)
            || arguments.contains("-sourceContinuationTrialSelection") || environment[environmentKey] != nil
    }

    static func identifier(arguments: [String], environment: [String: String],
                           bundleID: String?, model: OpenAIModelOption) -> UUID? {
        let forbidden = ["-uitesting", "-useMockAI", "-phase4MockAsk", "-phase5AdaptationDemo",
                         "-sourcePreviewTrial", "-sourceContinuationOfflineFixture", "-argentinaQualityRegen",
                         "-phase3DemoSelection", "-wordRegenDemoSelection", "-resetConsumedLedger",
                         "-sourceContinuationDemoSelection", "-phase3SeedAnnotations", "-seedBookmarks",
                         "-importOpenURL", "-importTestEPUB"]
        guard arguments.contains(argument), bundleID == Self.bundleID, model == .defaultGeneration,
              !arguments.contains(where: forbidden.contains),
              environment["SOURCE_PREVIEW_TRIAL_ID"] == nil,
              environment["SOURCE_CONTINUATION_FIXTURE_ID"] == nil,
              let raw = environment[environmentKey], let id = UUID(uuidString: raw),
              raw.lowercased() == id.uuidString.lowercased() else { return nil }
        return id
    }

    static func resolve(arguments: [String], environment: [String: String], bundleID: String?,
                        model: OpenAIModelOption, directory: URL? = nil) -> SourceContinuationTrialService {
        guard let id = identifier(arguments: arguments, environment: environment, bundleID: bundleID, model: model)
        else { return SourceContinuationTrialService(live: nil) }
        do {
            let root = try directory ?? FileManager.default.url(for: .applicationSupportDirectory,
                in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("SourceContinuationTrial", isDirectory: true)
            let gate = try SourceContinuationTrialGate(directory: root.appendingPathComponent(id.uuidString, isDirectory: true), id: id)
            guard SourceContinuationTrialTransport.configure(gate) else { return SourceContinuationTrialService(live: nil) }
            let config = SourceContinuationTrialTransport.configuration()
            config.protocolClasses = [SourceContinuationTrialTransport.self]
            return SourceContinuationTrialService(live: LiveOpenAIService(apiKeyProvider: { proxyLabel },
                preferredModel: .defaultGeneration, session: URLSession(configuration: config), endpoint: endpoint))
        } catch { return SourceContinuationTrialService(live: nil) }
    }
}

final class SourceContinuationTrialService: AIService, SourceGroundedAI, @unchecked Sendable {
    private let live: LiveOpenAIService?
    init(live: LiveOpenAIService?) { self.live = live }
    var sourceReviewModelID: String { live == nil ? "continuation-trial-unavailable" : OpenAIModelOption.defaultGeneration.rawValue }
    var supportsSourceContinuation: Bool { live != nil }
    private var unavailable: Error { SourceGroundingError.invalid("The isolated continuation trial is unavailable for this action. No alternate AI route was used.") }
    func writeSourceContinuation(_ request: SourceContinuationWritingRequest) async throws -> [SourceDraftParagraph] {
        guard let live else { throw unavailable }; return try await live.writeSourceContinuation(request)
    }
    func reviewSourcePreview(_ request: SourceReviewRequest) async throws -> SourceReviewResponse {
        guard let live else { throw unavailable }; return try await live.reviewSourcePreview(request)
    }
    func writeSourcePreview(_ request: SourceWritingRequest) async throws -> [SourceDraftParagraph] { throw unavailable }
    func ask(_ request: AskRequest) async throws -> AskResponse { throw unavailable }
    func adaptChapter(chapterId: UUID, promptContext: String) async throws -> ChapterRevision { throw unavailable }
    func makeAdaptationPlan(_ request: AdaptationPlanRequest) async throws -> AdaptationPlan { throw unavailable }
    func generateAdaptedChapter(_ request: AdaptationGenerateRequest) async throws -> [ContentBlock] { throw unavailable }
}

/// Files consume an attempt before transmission, including uncertain or failed calls.
/// Exclusive writes enforce the two-slot ceiling across gate instances/processes.
final class SourceContinuationTrialGate: @unchecked Sendable {
    let directory: URL
    let id: UUID
    private let lock = NSLock()
    static let requestLimit = 24_000
    static let responseLimit = 256_000
    struct WriterInput: Decodable {
        let title: String; let instructions: String; let frozenParagraphs: [String]
        let oldSuffix: [String]; let source1: String; let joinsSelectedParagraph: Bool
        let minimumTailParagraphs: Int; let maximumTailParagraphs: Int
    }
    private struct Witness: Codable { let requestSHA: String; let responseSHA: String }

    init(directory: URL, id: UUID) throws {
        self.directory = directory.standardizedFileURL; self.id = id
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    func file(_ name: String) -> URL { directory.appendingPathComponent(name) }
    private func bytes(_ name: String, limit: Int) throws -> Data {
        let url = file(name)
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        guard size <= limit else { throw URLError(.dataLengthExceedsMaximum) }
        let data = try Data(contentsOf: url)
        guard data.count <= limit else { throw URLError(.dataLengthExceedsMaximum) }
        return data
    }
    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func body(_ request: URLRequest) throws -> Data {
        if let body = request.httpBody {
            guard body.count <= Self.requestLimit else { throw URLError(.dataLengthExceedsMaximum) }
            return body
        }
        guard let stream = request.httpBodyStream else { throw URLError(.badURL) }
        stream.open(); defer { stream.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            guard n >= 0 else { throw URLError(.cannotDecodeRawData) }
            if n == 0 { break }
            guard data.count + n <= Self.requestLimit else { throw URLError(.dataLengthExceedsMaximum) }
            data.append(contentsOf: buffer.prefix(n))
        }
        return data
    }
    private func payload(_ data: Data, index: Int) throws -> (Data, [String: Any]) {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(json.keys) == Set(["model", "messages", "max_completion_tokens", "response_format"]),
              json["model"] as? String == "gpt-6-astra",
              json["max_completion_tokens"] as? Int == (index == 0 ? 2500 : 3500),
              json["response_format"] as? [String: String] == ["type": "json_object"],
              let messages = json["messages"] as? [[String: String]], messages.count == 2,
              Set(messages[0].keys) == Set(["role", "content"]), messages[0]["role"] == "system",
              Set(messages[1].keys) == Set(["role", "content"]), messages[1]["role"] == "user",
              let content = messages[1]["content"], let input = content.data(using: .utf8),
              let values = try JSONSerialization.jsonObject(with: input) as? [String: Any]
        else { throw URLError(.badURL) }
        return (input, values)
    }
    private func writerInput(_ data: Data) throws -> WriterInput {
        let (input, values) = try payload(data, index: 0)
        guard Set(values.keys) == Set(["title", "instructions", "frozenParagraphs", "oldSuffix", "source1",
                                      "joinsSelectedParagraph", "minimumTailParagraphs", "maximumTailParagraphs"])
        else { throw URLError(.badURL) }
        let decoded = try JSONDecoder().decode(WriterInput.self, from: input)
        guard !decoded.title.isEmpty, decoded.title.count <= 500, decoded.instructions.count <= 4_000,
              !decoded.source1.isEmpty, decoded.source1.count <= 8_000,
              (1...12).contains(decoded.frozenParagraphs.count), (1...12).contains(decoded.oldSuffix.count),
              decoded.frozenParagraphs.allSatisfy({ !$0.isEmpty && $0.count <= 4_000 }),
              decoded.oldSuffix.allSatisfy({ !$0.isEmpty && $0.count <= 4_000 }),
              (1...6).contains(decoded.minimumTailParagraphs),
              (decoded.minimumTailParagraphs...6).contains(decoded.maximumTailParagraphs)
        else { throw URLError(.badURL) }
        return decoded
    }
    private func reviewParagraphs(input: WriterInput, response: Data) throws -> [String] {
        guard let json = try JSONSerialization.jsonObject(with: response) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]], choices.count == 1,
              choices[0]["finish_reason"] as? String == "stop",
              let message = choices[0]["message"] as? [String: Any],
              message["refusal"] == nil || message["refusal"] is NSNull,
              let content = message["content"] as? String,
              let data = content.data(using: .utf8)
        else { throw URLError(.cannotDecodeContentData) }
        struct Output: Decodable { let paragraphs: [SourceDraftParagraph] }
        let output = try JSONDecoder().decode(Output.self, from: data).paragraphs
        guard (input.minimumTailParagraphs...input.maximumTailParagraphs).contains(output.count),
              output.allSatisfy({ $0.citations == ["source1"] && $0.text.count <= 4_000
                  && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.text.contains("[1]") })
        else { throw URLError(.cannotDecodeContentData) }
        var paragraphs = input.frozenParagraphs
        var tail = output.map(\.text)
        if input.joinsSelectedParagraph { paragraphs[paragraphs.count - 1] += tail.removeFirst() }
        paragraphs += tail
        guard (2...12).contains(paragraphs.count) else { throw URLError(.cannotDecodeContentData) }
        return paragraphs.map { $0 + " [1]" }
    }

    func claim(_ request: URLRequest) throws -> (URLRequest, Int) {
        lock.lock(); defer { lock.unlock() }
        let index = FileManager.default.fileExists(atPath: file("request-0.json").path) ? 1 : 0
        guard request.url == SourceContinuationTrial.endpoint, request.httpMethod == "POST",
              request.timeoutInterval == (index == 0 ? 60 : 90),
              request.value(forHTTPHeaderField: "Authorization") == "Bearer " + SourceContinuationTrial.proxyLabel
        else { throw URLError(.badURL) }
        let data = try body(request)
        if index == 0 { _ = try writerInput(data) }
        else {
            let (_, values) = try payload(data, index: 1)
            guard Set(values.keys) == Set(["paragraphs", "source1"]),
                  let source = values["source1"] as? String,
                  let paragraphs = values["paragraphs"] as? [String]
            else { throw URLError(.badURL) }
            let first = try bytes("request-0.json", limit: Self.requestLimit)
            let response = try bytes("response-0.json", limit: Self.responseLimit)
            let witness = try JSONDecoder().decode(Witness.self, from: bytes("success-0.json", limit: 1024))
            guard witness.requestSHA == Self.hash(first), witness.responseSHA == Self.hash(response),
                  String(decoding: try bytes("status-0.txt", limit: 16), as: UTF8.self) == "200"
            else { throw URLError(.resourceUnavailable) }
            let input = try writerInput(first)
            let expected = try reviewParagraphs(input: input, response: response)
            guard source.utf8.elementsEqual(input.source1.utf8), paragraphs.count == expected.count,
                  zip(paragraphs, expected).allSatisfy({ $0.utf8.elementsEqual($1.utf8) })
            else { throw URLError(.resourceUnavailable) }
        }
        try data.write(to: file("request-\(index).json"), options: .withoutOverwriting)
        var forwarded = URLRequest(url: SourceContinuationTrial.endpoint)
        forwarded.httpMethod = "POST"; forwarded.httpBody = data; forwarded.timeoutInterval = request.timeoutInterval
        forwarded.allHTTPHeaderFields = ["Content-Type": "application/json", "x-jarvis-estimated-usd": "1.5",
            "x-jarvis-work-package-id": "genbooks-source-continuation-trial",
            "x-jarvis-attempt-id": id.uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
            "x-jarvis-caller-request-id": "source-continuation-\(index)"]
        return (forwarded, index)
    }
    func record(data: Data, status: Int, index: Int) throws {
        lock.lock(); defer { lock.unlock() }
        guard (0...1).contains(index), data.count <= Self.responseLimit,
              FileManager.default.fileExists(atPath: file("request-\(index).json").path)
        else { throw URLError(.dataLengthExceedsMaximum) }
        try data.write(to: file("response-\(index).json"), options: .withoutOverwriting)
        try Data(String(status).utf8).write(to: file("status-\(index).txt"), options: .withoutOverwriting)
        if index == 0 && status == 200 {
            let request = try bytes("request-0.json", limit: Self.requestLimit)
            _ = try reviewParagraphs(input: writerInput(request), response: data)
            let witness = Witness(requestSHA: Self.hash(request), responseSHA: Self.hash(data))
            try JSONEncoder().encode(witness).write(to: file("success-0.json"), options: .withoutOverwriting)
        }
    }
}

/// All intercepted requests are validated before the sole fixed-proxy forwarder.
final class SourceContinuationTrialTransport: URLProtocol, URLSessionDataDelegate, @unchecked Sendable {
    private static let lock = NSLock()
    private static var gate: SourceContinuationTrialGate?
    private var transport: URLSession?
    private var forwardingTask: URLSessionDataTask?
    private var activeGate: SourceContinuationTrialGate?
    private var slot = 0
    private var response: HTTPURLResponse?
    private var received = Data()
    private var receivingError: Error?
    static func configure(_ candidate: SourceContinuationTrialGate) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard gate == nil || (gate?.id == candidate.id && gate?.directory.path == candidate.directory.path) else { return false }
        if gate == nil { gate = candidate }; return true
    }
    static func configuration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = []; config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.urlCache = nil
        config.timeoutIntervalForResource = 95; config.waitsForConnectivity = false
        return config
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            Self.lock.lock(); let gate = Self.gate; Self.lock.unlock()
            guard let gate else { throw URLError(.resourceUnavailable) }
            let (forwarded, index) = try gate.claim(request)
            activeGate = gate; slot = index
            let session = URLSession(configuration: Self.configuration(), delegate: self, delegateQueue: nil)
            transport = session; forwardingTask = session.dataTask(with: forwarded); forwardingTask?.resume()
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { forwardingTask?.cancel(); transport?.invalidateAndCancel() }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse,
              response.expectedContentLength <= SourceContinuationTrialGate.responseLimit else {
            receivingError = URLError(.dataLengthExceedsMaximum)
            completionHandler(.cancel); return
        }
        self.response = http; completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard receivingError == nil else { return }
        guard received.count + data.count <= SourceContinuationTrialGate.responseLimit else {
            receivingError = URLError(.dataLengthExceedsMaximum)
            dataTask.cancel(); return
        }
        received.append(data)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer { session.finishTasksAndInvalidate() }
        do {
            if let receivingError { throw receivingError }
            if let error { throw error }
            guard let gate = activeGate, let response else { throw URLError(.badServerResponse) }
            try gate.record(data: received, status: response.statusCode, index: slot)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: received); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
}
#endif
