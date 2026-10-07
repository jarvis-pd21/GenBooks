import XCTest
@testable import LivingReader

#if DEBUG
final class SourcePreviewTrialTests: XCTestCase {
    private var root: URL!
    private let id = UUID()
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("TrialGateTests-" + UUID().uuidString)
    }
    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
    }
    private func gate() throws -> SourcePreviewTrialGate { try .init(directory: root, id: id) }
    private func request(review: Bool = false, source: String = "Saved exact source", extra: [String: Any] = [:]) throws -> URLRequest {
        var request = URLRequest(url: SourcePreviewTrial.endpoint)
        request.httpMethod = "POST"; request.timeoutInterval = review ? 90 : 60
        request.setValue("Bearer " + SourcePreviewTrial.proxyLabel, forHTTPHeaderField: "Authorization")
        let input: [String: Any] = review ? ["source1": source, "paragraphs": ["First", "Second"]]
            : ["source1": source, "title": "Title", "topic": "Topic", "voice": "Clear"]
        var body: [String: Any] = ["model": "gpt-6-astra", "max_completion_tokens": review ? 3500 : 2500,
            "response_format": ["type": "json_object"],
            "messages": [["role": "system", "content": "Source contract"],
                         ["role": "user", "content": String(decoding: try JSONSerialization.data(withJSONObject: input), as: UTF8.self)]]]
        body.merge(extra) { _, new in new }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }
    func testExactlyTwoOrderedSlotsPersistAcrossResolverAndProcessEquivalentGateRecreation() throws {
        let first = try gate()
        let (forwarded, index) = try first.claim(request())
        XCTAssertEqual(index, 0)
        XCTAssertEqual(forwarded.url, SourcePreviewTrial.endpoint)
        XCTAssertEqual(forwarded.timeoutInterval, 60)
        XCTAssertNil(forwarded.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(forwarded.value(forHTTPHeaderField: "x-jarvis-estimated-usd"), "1.5")
        XCTAssertEqual(forwarded.value(forHTTPHeaderField: "x-jarvis-attempt-id"), id.uuidString.replacingOccurrences(of: "-", with: "").lowercased())
        XCTAssertThrowsError(try gate().claim(request()))
        XCTAssertThrowsError(try gate().claim(request(review: true)))
        try first.record(data: Data("{}".utf8), status: 200, index: 0)
        let (review, second) = try gate().claim(request(review: true))
        XCTAssertEqual(second, 1); XCTAssertEqual(review.timeoutInterval, 90)
        XCTAssertEqual(review.value(forHTTPHeaderField: "x-jarvis-estimated-usd"), "1.5")
        XCTAssertThrowsError(try gate().claim(request(review: true)))
        XCTAssertThrowsError(try gate().claim(request()))
        let snapshot = try String(contentsOf: first.file("request-0.json"))
        XCTAssertFalse(snapshot.contains(SourcePreviewTrial.proxyLabel))
        XCTAssertFalse(snapshot.contains("Authorization"))
    }
    func testTransportFailureAndProxyBudgetRejectionNeverReplenishWriterSlot() throws {
        let gate = try gate()
        _ = try gate.claim(request())
        try gate.record(data: Data("budget rejected".utf8), status: 429, index: 0)
        XCTAssertThrowsError(try self.gate().claim(request()))
        XCTAssertThrowsError(try self.gate().claim(request(review: true)))
    }
    func testReviewCannotChangeSourceOrRunBeforeWriter() throws {
        let gate = try gate()
        XCTAssertThrowsError(try gate.claim(request(review: true)))
        _ = try gate.claim(request())
        try gate.record(data: Data("{}".utf8), status: 200, index: 0)
        XCTAssertThrowsError(try gate.claim(request(review: true, source: "Another source")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: gate.file("request-1.json").path))
    }
    func testInvalidRoutesModelsBudgetsSamplingAndArbitraryOperationsFailBeforeClaim() throws {
        let gate = try gate()
        for extra: [String: Any] in [["model": "gpt-5.6-luna"], ["max_completion_tokens": 5000],
                                    ["temperature": 0], ["max_tokens": 2500], ["stream": true], ["tools": []]] {
            XCTAssertThrowsError(try gate.claim(request(extra: extra)))
        }
        var wrong = try request(); wrong.url = URL(string: "https://api.openai.com/v1/chat/completions")!
        XCTAssertThrowsError(try gate.claim(wrong))
        wrong = try request(); wrong.httpMethod = "GET"; XCTAssertThrowsError(try gate.claim(wrong))
        wrong = try request(); wrong.timeoutInterval = 120; XCTAssertThrowsError(try gate.claim(wrong))
        wrong = try request(); wrong.setValue("Bearer stored-key-must-not-enter", forHTTPHeaderField: "Authorization")
        XCTAssertThrowsError(try gate.claim(wrong))
        wrong = try request(source: String(repeating: "a", count: 24_000)); XCTAssertThrowsError(try gate.claim(wrong))
        XCTAssertFalse(FileManager.default.fileExists(atPath: gate.file("request-0.json").path))
    }
    func testStreamBodyUsesSameValidationAndNonOverwritingSlots() throws {
        var streamed = try request(); let original = try XCTUnwrap(streamed.httpBody)
        streamed.httpBody = nil; streamed.httpBodyStream = InputStream(data: original)
        let (forwarded, _) = try gate().claim(streamed)
        XCTAssertEqual(forwarded.httpBody, original)
        XCTAssertNil(forwarded.httpBodyStream)
    }
    func testAllMockFlagsMissingConfigurationWrongBundleAndModelRejectWithoutFallback() throws {
        let env = ["SOURCE_PREVIEW_TRIAL_ID": id.uuidString]
        for args in [["-sourcePreviewTrial", "-uitesting"], ["-sourcePreviewTrial", "-useMockAI"],
                     ["-sourcePreviewTrial", "-phase4MockAsk"], ["-sourcePreviewTrial", "-phase5AdaptationDemo"], []] {
            let result = SourcePreviewTrial.resolve(arguments: args, environment: env,
                bundleID: SourcePreviewTrial.bundleID, model: .defaultGeneration, directory: root)
            XCTAssertEqual(result.sourceReviewModelID, "trial-unavailable")
            XCTAssertFalse(result.usesDeterministicGeneration)
        }
        for (environment, bundle, model) in [(env, "com.jarvis.livingreader", OpenAIModelOption.defaultGeneration),
                                             ([:], SourcePreviewTrial.bundleID, .defaultGeneration),
                                             (["SOURCE_PREVIEW_TRIAL_ID": "../escape"], SourcePreviewTrial.bundleID, .defaultGeneration),
                                             (env, SourcePreviewTrial.bundleID, .defaultAsk)] {
            XCTAssertEqual(SourcePreviewTrial.resolve(arguments: ["-sourcePreviewTrial"], environment: environment,
                bundleID: bundle, model: model, directory: root).sourceReviewModelID, "trial-unavailable")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }
    func testCreateFactoryNeverReadsOrWritesNormalKeyForTrialAndRetainsOrdinaryModelSelection() async throws {
        let key = TrialKeySpy()
        let trial = AIServiceResolver.makeCreateGeneration(keyStore: key,
            processInfo: TrialProcessInfo(arguments: ["-sourcePreviewTrial"], environment: ["SOURCE_PREVIEW_TRIAL_ID": "invalid"]))
        XCTAssertTrue(trial is SourcePreviewTrialService)
        do { _ = try await trial.ask(AskRequest(userQuestion: "No other operations", bookTitle: "T", bookAuthor: "A", consumedContext: "")); XCTFail() }
        catch { XCTAssertTrue(error is SourceGroundingError) }
        XCTAssertEqual(key.reads, 0); XCTAssertEqual(key.writes, 0)
        let normal = AIServiceResolver.makeCreateGeneration(keyStore: key, generationModel: .gpt41,
            processInfo: TrialProcessInfo(arguments: [], environment: [:]))
        XCTAssertEqual((normal as? LiveOpenAIService)?.preferredModelID, OpenAIModelOption.gpt41.rawValue)
        let mock = AIServiceResolver.makeCreateGeneration(keyStore: key,
            processInfo: TrialProcessInfo(arguments: ["-uitesting"], environment: [:]))
        XCTAssertTrue(mock is MockAIService); XCTAssertEqual(key.reads, 0)
    }
    func testValidTrialIsSourceOnlyAndDoesNotLoadAKey() async throws {
        let service = SourcePreviewTrial.resolve(arguments: ["-sourcePreviewTrial"],
            environment: ["SOURCE_PREVIEW_TRIAL_ID": id.uuidString], bundleID: SourcePreviewTrial.bundleID,
            model: .defaultGeneration, directory: root)
        XCTAssertEqual(service.sourceReviewModelID, "gpt-6-astra")
        // Create resolves once when opened and again immediately before Generate.
        // Directory creation must not make the second URL compare differently.
        let refreshed = SourcePreviewTrial.resolve(arguments: ["-sourcePreviewTrial"],
            environment: ["SOURCE_PREVIEW_TRIAL_ID": id.uuidString], bundleID: SourcePreviewTrial.bundleID,
            model: .defaultGeneration, directory: root)
        XCTAssertEqual(refreshed.sourceReviewModelID, "gpt-6-astra")
        do { _ = try await service.adaptChapter(chapterId: UUID(), promptContext: "Must not forward"); XCTFail() }
        catch { XCTAssertTrue(error is SourceGroundingError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(id.uuidString).appendingPathComponent("request-0.json").path))
    }
    func testIsolatedAppWithoutLaunchMetadataNeverFallsBackToStoredKeyOrMock() {
        let key = TrialKeySpy()
        for args in [[], ["-uitesting"]] {
            let service = AIServiceResolver.makeCreateGeneration(keyStore: key,
                processInfo: TrialProcessInfo(arguments: args, environment: [:]), bundleID: SourcePreviewTrial.bundleID)
            XCTAssertEqual((service as? SourcePreviewTrialService)?.sourceReviewModelID, "trial-unavailable")
            XCTAssertFalse(service is LiveOpenAIService); XCTAssertFalse(service is MockAIService)
        }
        XCTAssertEqual(key.reads, 0); XCTAssertEqual(key.writes, 0)
    }
    func testClientRedirectsAreRefused() {
        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: SourcePreviewTrial.endpoint)
        let response = HTTPURLResponse(url: SourcePreviewTrial.endpoint, statusCode: 302, httpVersion: nil,
                                       headerFields: ["Location": "https://api.openai.com/"])!
        var called = false
        SourcePreviewTrialNoRedirect().urlSession(session, task: task, willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: URL(string: "https://api.openai.com/")!)) { request in
                called = true; XCTAssertNil(request)
            }
        XCTAssertTrue(called); session.invalidateAndCancel()
    }
}

private final class TrialProcessInfo: ProcessInfo, @unchecked Sendable {
    private let args: [String]; private let env: [String: String]
    init(arguments: [String], environment: [String: String]) { args = arguments; env = environment; super.init() }
    override var arguments: [String] { args }
    override var environment: [String: String] { env }
}
private final class TrialKeySpy: APIKeyStoring, @unchecked Sendable {
    var reads = 0; var writes = 0
    func loadAPIKey() throws -> String? { reads += 1; return "unused-test-key" }
    func saveAPIKey(_ key: String?) throws { writes += 1 }
}

/// A separately opted-in, read-only check in the actual trial app host. This
/// tests local transport policy before the one-shot source/writer attempt.
final class SourcePreviewTrialPreflightTests: XCTestCase {
    func testOptInAppHostCanReachProxyAndHasReservedAllowance() async throws {
        guard ProcessInfo.processInfo.environment["SOURCE_PREVIEW_HEALTH_ACCEPTANCE"] == "1" else {
            throw XCTSkip("Explicit read-only local proxy preflight only.")
        }
        XCTAssertEqual(Bundle.main.bundleIdentifier, SourcePreviewTrial.bundleID)
        let config = SourcePreviewTrialTransport.configuration()
        config.timeoutIntervalForResource = 5
        let session = URLSession(configuration: config, delegate: SourcePreviewTrialNoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:8791/health")!)
        request.timeoutInterval = 5
        let (data, response) = try await session.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let cap = try XCTUnwrap(json["dailyCapUsd"] as? Double)
        let usage = try XCTUnwrap(json["usage"] as? [String: Any])
        let used = try XCTUnwrap(usage["totalUsd"] as? Double)
        let limits = try XCTUnwrap(json["providerLimits"] as? [String: Double])
        let providerUsed = try XCTUnwrap(json["providerUsage"] as? [String: Double])
        let openAI = try XCTUnwrap(limits["openai"])
        let openAIUsed = try XCTUnwrap(providerUsed["openai"])
        XCTAssertEqual(cap, 9); XCTAssertEqual(openAI, 9)
        XCTAssertGreaterThanOrEqual(cap - used, 3)
        XCTAssertGreaterThanOrEqual(openAI - openAIUsed, 3)
        let report = try JSONSerialization.data(withJSONObject: ["dailyCapUsd": cap, "reservedUsd": used,
            "openAICapUsd": openAI, "openAIReservedUsd": openAIUsed], options: [.sortedKeys])
        let attachment = XCTAttachment(data: report, uniformTypeIdentifier: "public.json")
        attachment.name = "source-trial-preflight-accounting"; attachment.lifetime = .keepAlways
        add(attachment)
    }
}
#endif
