import XCTest
import CryptoKit
@testable import LivingReader

#if DEBUG
/// Offline contracts only. The real continuation URLProtocol is never started.
@MainActor
final class SourceContinuationTrialTests: XCTestCase {
    private var root: URL!
    private var id: UUID!
    private let frozen = ["River communities kept records."]
    private let tail = ["Seasonal journeys were recorded.", "Public meetings were recorded too."]

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ContinuationTrialTests-" + UUID().uuidString, isDirectory: true)
        id = UUID()
        MockURLProtocol.reset()
    }
    override func tearDownWithError() throws {
        MockURLProtocol.reset()
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
    }

    func testEveryTrialSignalRequestsClosedRoutingWithoutCompleteConfiguration() {
        XCTAssertFalse(SourceContinuationTrial.requested(arguments: [], environment: [:], bundleID: "ordinary"))
        XCTAssertTrue(SourceContinuationTrial.requested(arguments: [SourceContinuationTrial.argument], environment: [:], bundleID: "ordinary"))
        XCTAssertTrue(SourceContinuationTrial.requested(arguments: ["-sourceContinuationTrialSelection"], environment: [:], bundleID: nil))
        XCTAssertTrue(SourceContinuationTrial.requested(arguments: [], environment: [SourceContinuationTrial.environmentKey: "invalid"], bundleID: nil))
        XCTAssertTrue(SourceContinuationTrial.requested(arguments: [], environment: [:], bundleID: SourceContinuationTrial.bundleID))
    }

    func testIdentifierRequiresExactBundleAstraExplicitFlagAndUUID() {
        let environment = [SourceContinuationTrial.environmentKey: id.uuidString]
        XCTAssertEqual(SourceContinuationTrial.identifier(arguments: [SourceContinuationTrial.argument], environment: environment,
            bundleID: SourceContinuationTrial.bundleID, model: .defaultGeneration), id)
        for (args, env, bundle, model) in [
            ([], environment, SourceContinuationTrial.bundleID, OpenAIModelOption.defaultGeneration),
            ([SourceContinuationTrial.argument], [:], SourceContinuationTrial.bundleID, .defaultGeneration),
            ([SourceContinuationTrial.argument], [SourceContinuationTrial.environmentKey: "../invalid"], SourceContinuationTrial.bundleID, .defaultGeneration),
            ([SourceContinuationTrial.argument], environment, "com.jarvis.livingreader", .defaultGeneration),
            ([SourceContinuationTrial.argument], environment, SourceContinuationTrial.bundleID, .defaultAsk),
            ([SourceContinuationTrial.argument], environment, SourceContinuationTrial.bundleID, .gpt41)
        ] {
            XCTAssertNil(SourceContinuationTrial.identifier(arguments: args, environment: env, bundleID: bundle, model: model))
        }
    }

    func testMixedMockCreateOfflineImportAndMutationFlagsRejectBeforeDirectoryCreation() {
        let forbidden = ["-uitesting", "-useMockAI", "-phase4MockAsk", "-phase5AdaptationDemo", "-sourcePreviewTrial",
            "-sourceContinuationOfflineFixture", "-argentinaQualityRegen", "-phase3DemoSelection", "-wordRegenDemoSelection",
            "-resetConsumedLedger", "-sourceContinuationDemoSelection", "-phase3SeedAnnotations", "-seedBookmarks",
            "-importOpenURL", "-importTestEPUB"]
        for flag in forbidden {
            let result = SourceContinuationTrial.resolve(arguments: [SourceContinuationTrial.argument, flag],
                environment: [SourceContinuationTrial.environmentKey: id.uuidString], bundleID: SourceContinuationTrial.bundleID,
                model: .defaultGeneration, directory: root)
            XCTAssertFalse(result.supportsSourceContinuation, flag)
            XCTAssertFalse(result.usesDeterministicGeneration)
        }
        for otherKey in ["SOURCE_PREVIEW_TRIAL_ID", "SOURCE_CONTINUATION_FIXTURE_ID"] {
            let result = SourceContinuationTrial.resolve(arguments: [SourceContinuationTrial.argument],
                environment: [SourceContinuationTrial.environmentKey: id.uuidString, otherKey: UUID().uuidString],
                bundleID: SourceContinuationTrial.bundleID, model: .defaultGeneration, directory: root)
            XCTAssertFalse(result.supportsSourceContinuation)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testAllResolverEntryPointsFailClosedBeforeMockOrKeyAccess() async throws {
        let key = ContinuationTrialKeySpy()
        for process in [
            ContinuationTrialProcessInfo(arguments: [], environment: [:]),
            ContinuationTrialProcessInfo(arguments: ["-uitesting"], environment: [:]),
            ContinuationTrialProcessInfo(arguments: [SourceContinuationTrial.argument, "-sourcePreviewTrial"],
                environment: [SourceContinuationTrial.environmentKey: "invalid", "SOURCE_PREVIEW_TRIAL_ID": UUID().uuidString])
        ] {
            let pair = AIServiceResolver.makeAskAndAdaptation(keyStore: key, processInfo: process, bundleID: SourceContinuationTrial.bundleID)
            let create = AIServiceResolver.makeCreateGeneration(keyStore: key, processInfo: process, bundleID: SourceContinuationTrial.bundleID)
            let direct = AIServiceResolver.makeDefault(keyStore: key, processInfo: process, bundleID: SourceContinuationTrial.bundleID)
            for service in [pair.ask, pair.adaptation, create, direct] {
                let closed = try XCTUnwrap(service as? SourceContinuationTrialService)
                XCTAssertFalse(closed.supportsSourceContinuation)
                XCTAssertFalse(service.usesDeterministicGeneration)
                do { _ = try await service.ask(askRequest); XCTFail("Trial must not use Ask or fallback") }
                catch { XCTAssertTrue(error is SourceGroundingError) }
            }
        }
        XCTAssertEqual(key.reads, 0); XCTAssertEqual(key.writes, 0)
    }

    func testOrdinaryAndOldCreateResolversRetainTheirExistingRoutes() {
        let key = ContinuationTrialKeySpy()
        let ordinary = ContinuationTrialProcessInfo(arguments: [], environment: [:])
        let service = AIServiceResolver.makeDefault(keyStore: key, modelPreference: .gpt41,
            processInfo: ordinary, bundleID: "com.jarvis.livingreader")
        XCTAssertEqual((service as? LiveOpenAIService)?.preferredModelID, OpenAIModelOption.gpt41.rawValue)
        let mock = AIServiceResolver.makeDefault(keyStore: key,
            processInfo: ContinuationTrialProcessInfo(arguments: ["-uitesting"], environment: [:]), bundleID: "ordinary")
        XCTAssertTrue(mock is MockAIService)
        let old = AIServiceResolver.makeCreateGeneration(keyStore: key,
            processInfo: ContinuationTrialProcessInfo(arguments: ["-sourcePreviewTrial"], environment: ["SOURCE_PREVIEW_TRIAL_ID": "invalid"]),
            bundleID: SourcePreviewTrial.bundleID)
        XCTAssertTrue(old is SourcePreviewTrialService)
        XCTAssertFalse((old as? SourceGroundedAI)?.supportsSourceContinuation ?? true)
        XCTAssertEqual(key.reads, 0); XCTAssertEqual(key.writes, 0)
    }

    func testOneValidConfigurationCanRefreshButCannotChangeAttemptOrDirectory() async throws {
        // The sole positive production configure in this class. No allowed operation is invoked.
        let environment = [SourceContinuationTrial.environmentKey: id.uuidString]
        let first = SourceContinuationTrial.resolve(arguments: [SourceContinuationTrial.argument], environment: environment,
            bundleID: SourceContinuationTrial.bundleID, model: .defaultGeneration, directory: root)
        XCTAssertTrue(first.supportsSourceContinuation)
        let refreshed = SourceContinuationTrial.resolve(arguments: [SourceContinuationTrial.argument], environment: environment,
            bundleID: SourceContinuationTrial.bundleID, model: .defaultGeneration, directory: root)
        XCTAssertTrue(refreshed.supportsSourceContinuation)
        XCTAssertEqual(refreshed.sourceReviewModelID, "gpt-6-astra")
        let changed = SourceContinuationTrial.resolve(arguments: [SourceContinuationTrial.argument],
            environment: [SourceContinuationTrial.environmentKey: UUID().uuidString], bundleID: SourceContinuationTrial.bundleID,
            model: .defaultGeneration, directory: root)
        XCTAssertFalse(changed.supportsSourceContinuation)
        let relocated = SourceContinuationTrial.resolve(arguments: [SourceContinuationTrial.argument], environment: environment,
            bundleID: SourceContinuationTrial.bundleID, model: .defaultGeneration, directory: root.appendingPathComponent("other"))
        XCTAssertFalse(relocated.supportsSourceContinuation)
        do { _ = try await refreshed.adaptChapter(chapterId: UUID(), promptContext: "Forbidden"); XCTFail() }
        catch { XCTAssertTrue(error is SourceGroundingError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(id.uuidString).appendingPathComponent("request-0.json").path))
    }

    func testClosedWrapperRejectsWriterAndReviewWithoutAnyInjectedRequest() async throws {
        let service = SourceContinuationTrialService(live: nil)
        var calls = 0
        MockURLProtocol.requestHandler = { _ in calls += 1; throw URLError(.badServerResponse) }
        do { _ = try await service.writeSourceContinuation(writingRequest()); XCTFail() }
        catch { XCTAssertTrue(error is SourceGroundingError) }
        do { _ = try await service.reviewSourcePreview(.init(paragraphs: expectedParagraphs(), source: source())); XCTFail() }
        catch { XCTAssertTrue(error is SourceGroundingError) }
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(service.sourceReviewModelID, "continuation-trial-unavailable")
    }

    func testOpenInjectedWrapperStillRejectsAskCreateAndLegacyAdaptationBeforeKeyRead() async throws {
        let key = ContinuationTrialKeySpy()
        let live = LiveOpenAIService(apiKeyProvider: { try key.loadAPIKey() }, preferredModel: .defaultGeneration,
            session: MockURLProtocol.makeSession(), endpoint: SourceContinuationTrial.endpoint)
        let service = SourceContinuationTrialService(live: live)
        do { _ = try await service.ask(askRequest); XCTFail() } catch { XCTAssertTrue(error is SourceGroundingError) }
        do { _ = try await service.adaptChapter(chapterId: UUID(), promptContext: "No legacy adaptation"); XCTFail() }
        catch { XCTAssertTrue(error is SourceGroundingError) }
        do { _ = try await service.writeSourcePreview(.init(title: "River", topic: "Records", voice: "Plain", source: source())); XCTFail() }
        catch { XCTAssertTrue(error is SourceGroundingError) }
        XCTAssertEqual(key.reads, 0); XCTAssertEqual(key.writes, 0)
        XCTAssertNil(MockURLProtocol.lastRequest)
    }

    func testTwoOrderedSlotsPersistAcrossGateRecreationAndStripAllCallerCredentials() throws {
        let gate = try makeGate()
        var writer = try request()
        writer.setValue("private-cookie", forHTTPHeaderField: "Cookie")
        writer.setValue("untrusted-value", forHTTPHeaderField: "X-Untrusted")
        writer.setValue("0", forHTTPHeaderField: "x-jarvis-estimated-usd")
        let (forwarded, first) = try gate.claim(writer)
        XCTAssertEqual(first, 0); XCTAssertEqual(forwarded.url, SourceContinuationTrial.endpoint)
        XCTAssertEqual(forwarded.timeoutInterval, 60)
        XCTAssertNil(forwarded.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(forwarded.value(forHTTPHeaderField: "Cookie"))
        XCTAssertNil(forwarded.value(forHTTPHeaderField: "X-Untrusted"))
        XCTAssertEqual(forwarded.value(forHTTPHeaderField: "x-jarvis-estimated-usd"), "1.5")
        XCTAssertEqual(forwarded.value(forHTTPHeaderField: "x-jarvis-caller-request-id"), "source-continuation-0")
        XCTAssertEqual(forwarded.value(forHTTPHeaderField: "x-jarvis-attempt-id"), id.uuidString.replacingOccurrences(of: "-", with: "").lowercased())
        XCTAssertEqual(try Data(contentsOf: gate.file("request-0.json")), writer.httpBody)
        try gate.record(data: writerResponse(), status: 200, index: 0)
        let (review, second) = try makeGate().claim(request(review: true))
        XCTAssertEqual(second, 1); XCTAssertEqual(review.timeoutInterval, 90)
        XCTAssertEqual(review.value(forHTTPHeaderField: "x-jarvis-estimated-usd"), "1.5")
        XCTAssertThrowsError(try makeGate().claim(request(review: true)))
        XCTAssertThrowsError(try makeGate().claim(request()))
        XCTAssertFalse(String(decoding: try Data(contentsOf: gate.file("request-0.json")), as: UTF8.self).contains(SourceContinuationTrial.proxyLabel))
    }

    func testWriterNetworkFailureOrBudgetRejectionNeverReplenishesSlot() throws {
        for status in [nil, 429, 500] as [Int?] {
            let gate = try makeGate("failure-\(status ?? 0)")
            _ = try gate.claim(request())
            if let status { try gate.record(data: Data("budget or provider failure".utf8), status: status, index: 0) }
            let reopened = try SourceContinuationTrialGate(directory: gate.directory, id: id)
            XCTAssertThrowsError(try reopened.claim(request()))
            XCTAssertThrowsError(try reopened.claim(request(review: true)))
            XCTAssertFalse(FileManager.default.fileExists(atPath: gate.file("success-0.json").path))
        }
    }

    func testReviewBeforeWriterOrWithoutSuccessfulResponseCannotConsumeReviewSlot() throws {
        let gate = try makeGate()
        XCTAssertThrowsError(try gate.claim(request(review: true)))
        _ = try gate.claim(request())
        XCTAssertThrowsError(try gate.claim(request(review: true)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: gate.file("request-1.json").path))
    }

    func testReviewRequiresExactFullSourceAndEveryCandidateParagraphInOrder() throws {
        let gate = try makeGate()
        _ = try gate.claim(request())
        try gate.record(data: writerResponse(), status: 200, index: 0)
        var variants = [Array(expectedParagraphs().dropFirst()), Array(expectedParagraphs().reversed()), expectedParagraphs() + ["Extra. [1]"]]
        var changed = expectedParagraphs(); changed[1] += " "; variants.append(changed)
        for paragraphs in variants { XCTAssertThrowsError(try gate.claim(request(review: true, paragraphs: paragraphs))) }
        XCTAssertThrowsError(try gate.claim(request(review: true, sourceText: source().text + " ")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: gate.file("request-1.json").path))
        XCTAssertEqual(try gate.claim(request(review: true)).1, 1)
    }

    func testMidparagraphJoinIsByteExactAndNotUnicodeNormalizationEquivalent() throws {
        let gate = try makeGate()
        let prefix = ["The caf\u{00e9} "]
        _ = try gate.claim(request(frozenText: prefix, joins: true))
        try gate.record(data: writerResponse(), status: 200, index: 0)
        let expected = expectedParagraphs(frozenText: prefix, joins: true)
        XCTAssertThrowsError(try gate.claim(request(review: true, paragraphs: expectedParagraphs(frozenText: prefix, joins: false))))
        var normalized = expected; normalized[0] = normalized[0].decomposedStringWithCanonicalMapping
        XCTAssertEqual(normalized, expected, "Swift canonical equality alone is insufficient for the frozen byte contract")
        XCTAssertThrowsError(try gate.claim(request(review: true, paragraphs: normalized)))
        XCTAssertEqual(try gate.claim(request(review: true, paragraphs: expected)).1, 1)
    }

    func testSavedRequestResponseAndStatusTamperingCannotReuseSuccessWitness() throws {
        for name in ["request-0.json", "response-0.json", "status-0.txt", "success-0.json"] {
            let gate = try makeGate(name)
            _ = try gate.claim(request()); try gate.record(data: writerResponse(), status: 200, index: 0)
            let replacement: Data
            switch name {
            case "request-0.json": replacement = try XCTUnwrap(request(sourceText: source().text + " changed").httpBody)
            case "response-0.json": replacement = try writerResponse(texts: ["Changed candidate.", tail[1]])
            case "status-0.txt": replacement = Data("201".utf8)
            default: replacement = Data("{}".utf8)
            }
            try replacement.write(to: gate.file(name))
            XCTAssertThrowsError(try SourceContinuationTrialGate(directory: gate.directory, id: id).claim(request(review: true)))
            XCTAssertFalse(FileManager.default.fileExists(atPath: gate.file("request-1.json").path))
        }
    }

    func testMalformedTruncatedRefusedOrInvalidWriterOutputNeverUnlocksReview() throws {
        let invalid: [Data] = [Data("not JSON".utf8), try writerResponse(finish: "length"), try writerResponse(choices: 2),
            try writerResponse(refusal: "Refused"), try writerResponse(texts: []), try writerResponse(texts: ["Only one"]),
            try writerResponse(texts: [" ", tail[1]]), try writerResponse(citations: ["source2"]),
            try writerResponse(texts: ["Already cited. [1]", tail[1]]), try writerResponse(texts: [String(repeating: "a", count: 4001), tail[1]])]
        for (index, data) in invalid.enumerated() {
            let gate = try makeGate("invalid-\(index)")
            _ = try gate.claim(request())
            XCTAssertThrowsError(try gate.record(data: data, status: 200, index: 0))
            XCTAssertFalse(FileManager.default.fileExists(atPath: gate.file("success-0.json").path))
            XCTAssertThrowsError(try gate.claim(request(review: true)))
            XCTAssertThrowsError(try gate.claim(request()))
        }
    }

    func testRequestByteLimitAppliesToDirectAndStreamBodiesBeforeSlotClaim() throws {
        let gate = try makeGate()
        for stream in [false, true] {
            var oversized = try request()
            let bytes = Data(repeating: 65, count: SourceContinuationTrialGate.requestLimit + 1)
            oversized.httpBody = stream ? nil : bytes
            if stream { oversized.httpBodyStream = InputStream(data: bytes) }
            XCTAssertThrowsError(try gate.claim(oversized))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: gate.file("request-0.json").path))
        var streamed = try request(); let bytes = try XCTUnwrap(streamed.httpBody)
        streamed.httpBody = nil; streamed.httpBodyStream = InputStream(data: bytes)
        let forwarded = try gate.claim(streamed).0
        XCTAssertEqual(forwarded.httpBody, bytes); XCTAssertNil(forwarded.httpBodyStream)
    }

    func testRouteMethodAuthorizationModelSamplingBudgetAndTimeoutCannotChange() throws {
        let gate = try makeGate()
        for extra: [String: Any] in [["model": "gpt-5.6-luna"], ["max_completion_tokens": 2501], ["max_tokens": 2500],
            ["temperature": 0], ["top_p": 1], ["stream": true], ["tools": []], ["response_format": ["type": "text"]]] {
            XCTAssertThrowsError(try gate.claim(request(extra: extra)))
        }
        var wrong = try request(); wrong.url = URL(string: "https://api.openai.com/v1/chat/completions")!
        XCTAssertThrowsError(try gate.claim(wrong))
        wrong = try request(); wrong.httpMethod = "GET"; XCTAssertThrowsError(try gate.claim(wrong))
        wrong = try request(); wrong.timeoutInterval = 61; XCTAssertThrowsError(try gate.claim(wrong))
        wrong = try request(); wrong.setValue("Bearer unrelated-test-value", forHTTPHeaderField: "Authorization")
        XCTAssertThrowsError(try gate.claim(wrong))
        XCTAssertFalse(FileManager.default.fileExists(atPath: gate.file("request-0.json").path))
    }

    func testWriterContextAndParagraphBoundsRejectUnknownOrOversizedFields() throws {
        let gate = try makeGate()
        for extra: [String: Any] in [["unexpected": true], ["title": ""], ["title": String(repeating: "x", count: 501)],
            ["instructions": String(repeating: "x", count: 4001)], ["source1": String(repeating: "x", count: 8001)],
            ["frozenParagraphs": []], ["oldSuffix": []], ["frozenParagraphs": [""]],
            ["minimumTailParagraphs": 0], ["maximumTailParagraphs": 7], ["minimumTailParagraphs": 3, "maximumTailParagraphs": 2]] {
            XCTAssertThrowsError(try gate.claim(request(inputExtra: extra)))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: gate.file("request-0.json").path))
    }

    func testResponseLimitAndExclusiveRecordingPreserveConsumedAttempt() throws {
        let gate = try makeGate()
        _ = try gate.claim(request())
        XCTAssertThrowsError(try gate.record(data: Data(repeating: 65, count: SourceContinuationTrialGate.responseLimit + 1), status: 200, index: 0))
        XCTAssertFalse(FileManager.default.fileExists(atPath: gate.file("response-0.json").path))
        let response = try writerResponse()
        try gate.record(data: response, status: 200, index: 0)
        XCTAssertThrowsError(try gate.record(data: response, status: 200, index: 0))
        XCTAssertThrowsError(try gate.record(data: response, status: 200, index: 2))
        XCTAssertEqual(try Data(contentsOf: gate.file("response-0.json")), response)
        _ = try gate.claim(request(review: true))
        try gate.record(data: Data("review rejected".utf8), status: 429, index: 1)
        XCTAssertThrowsError(try makeGate().claim(request(review: true)))
    }

    func testConcurrentSeparateGateInstancesAdmitExactlyOneWriter() throws {
        let first = try makeGate(), second = try makeGate()
        let writer = try request()
        let results = ContinuationTrialClaimResults()
        DispatchQueue.concurrentPerform(iterations: 16) { index in
            do { _ = try (index.isMultiple(of: 2) ? first : second).claim(writer); results.success() }
            catch { results.failure() }
        }
        XCTAssertEqual(results.successes, 1); XCTAssertEqual(results.failures, 15)
        XCTAssertEqual(try Data(contentsOf: first.file("request-0.json")), writer.httpBody)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.file("request-1.json").path))
    }

    func testActualLiveWrapperThroughOfflineGateUsesTwoBoundRequestsAndRejectsThird() async throws {
        let gate = try makeGate()
        let writer = try writerResponse()
        let review = SourceReviewResponse(units: expectedParagraphs().indices.map {
            .init(index: $0, assessment: .supported, quotes: ["River communities kept written records of seasonal journeys and public meetings."])
        })
        let reviewBytes = try wire(String(decoding: JSONEncoder().encode(review), as: UTF8.self))
        var admitted: [Int] = []
        MockURLProtocol.requestHandler = { request in
            let (forwarded, index) = try gate.claim(request)
            admitted.append(index)
            XCTAssertNil(forwarded.value(forHTTPHeaderField: "Authorization"))
            let bytes = index == 0 ? writer : reviewBytes
            try gate.record(data: bytes, status: 200, index: index)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, bytes)
        }
        let service = injectedService()
        let paragraphs = try await service.writeSourceContinuation(writingRequest())
        XCTAssertEqual(paragraphs.map(\.text), tail)
        let actual = try await service.reviewSourcePreview(.init(paragraphs: expectedParagraphs(), source: source()))
        XCTAssertEqual(actual, review)
        do { _ = try await service.reviewSourcePreview(.init(paragraphs: expectedParagraphs(), source: source())); XCTFail("No third admitted request") }
        catch { }
        XCTAssertEqual(admitted, [0, 1])
        let writerJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: gate.file("request-0.json"))) as? [String: Any])
        XCTAssertEqual(Set(writerJSON.keys), ["model", "messages", "max_completion_tokens", "response_format"])
        XCTAssertEqual(writerJSON["model"] as? String, "gpt-6-astra")
        XCTAssertEqual(writerJSON["max_completion_tokens"] as? Int, 2500)
    }

    func testActualLiveWrapperHTTPFailureConsumesWriterWithoutFallback() async throws {
        let gate = try makeGate()
        var admitted = 0
        let data = Data(#"{"error":{"message":"Trial budget rejected","type":"rate_limit_error","code":"rate_limit_exceeded"}}"#.utf8)
        MockURLProtocol.requestHandler = { request in
            let (_, index) = try gate.claim(request); admitted += 1
            try gate.record(data: data, status: 429, index: index)
            return (HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: nil)!, data)
        }
        let service = injectedService()
        for _ in 0..<2 {
            do { _ = try await service.writeSourceContinuation(writingRequest()); XCTFail("No fallback or replay") }
            catch { }
        }
        XCTAssertEqual(admitted, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: gate.file("request-1.json").path))
    }

    func testActualLiveWrapperTruncatedWriterDoesNotAdmitReview() async throws {
        let gate = try makeGate()
        var admitted = 0
        let truncated = try writerResponse(finish: "length")
        MockURLProtocol.requestHandler = { request in
            let (_, index) = try gate.claim(request); admitted += 1
            try gate.record(data: truncated, status: 200, index: index)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, truncated)
        }
        let service = injectedService()
        do { _ = try await service.writeSourceContinuation(writingRequest()); XCTFail() } catch { }
        do { _ = try await service.reviewSourcePreview(.init(paragraphs: expectedParagraphs(), source: source())); XCTFail() } catch { }
        XCTAssertEqual(admitted, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: gate.file("success-0.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: gate.file("request-1.json").path))
    }

    func testTransportConfigurationHasNoCookiesCredentialsCacheOrUnboundedWait() {
        let config = SourceContinuationTrialTransport.configuration()
        XCTAssertNil(config.httpCookieStorage); XCTAssertNil(config.urlCredentialStorage); XCTAssertNil(config.urlCache)
        XCTAssertEqual(config.protocolClasses?.count, 0)
        XCTAssertEqual(config.timeoutIntervalForResource, 95)
        XCTAssertFalse(config.waitsForConnectivity)
    }

    func testTransportRejectsDeclaredAndStreamingResponseOverflowWithoutForwarding() throws {
        let client = ContinuationTrialProtocolClient()
        let request = URLRequest(url: SourceContinuationTrial.endpoint)
        let transport = SourceContinuationTrialTransport(request: request, cachedResponse: nil, client: client)
        let session = MockURLProtocol.makeSession()
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: request) // Never resumed; no forwarding.
        let large = try XCTUnwrap(HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Length": String(SourceContinuationTrialGate.responseLimit + 1)]))
        var disposition: URLSession.ResponseDisposition?
        transport.urlSession(session, dataTask: task, didReceive: large) { disposition = $0 }
        XCTAssertEqual(disposition, .cancel)
        transport.urlSession(session, task: task, didCompleteWithError: nil)
        XCTAssertEqual((client.failure as? URLError)?.code, .dataLengthExceedsMaximum)
        XCTAssertEqual(client.loadedBytes, 0)

        let streamingClient = ContinuationTrialProtocolClient()
        let streaming = SourceContinuationTrialTransport(request: request, cachedResponse: nil, client: streamingClient)
        let streamingSession = MockURLProtocol.makeSession()
        defer { streamingSession.invalidateAndCancel() }
        let streamingTask = streamingSession.dataTask(with: request) // Never resumed.
        let response = try XCTUnwrap(HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil))
        streaming.urlSession(streamingSession, dataTask: streamingTask, didReceive: response) { disposition = $0 }
        XCTAssertEqual(disposition, .allow)
        streaming.urlSession(streamingSession, dataTask: streamingTask,
            didReceive: Data(repeating: 65, count: SourceContinuationTrialGate.responseLimit))
        streaming.urlSession(streamingSession, dataTask: streamingTask, didReceive: Data([66]))
        streaming.urlSession(streamingSession, task: streamingTask, didCompleteWithError: nil)
        XCTAssertEqual((streamingClient.failure as? URLError)?.code, .dataLengthExceedsMaximum)
        XCTAssertEqual(streamingClient.loadedBytes, 0)
        XCTAssertNil(MockURLProtocol.lastRequest)
    }

    func testTransportNeverFollowsAClientRedirect() throws {
        let request = URLRequest(url: SourceContinuationTrial.endpoint)
        let transport = SourceContinuationTrialTransport(request: request, cachedResponse: nil, client: nil)
        let session = MockURLProtocol.makeSession()
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: request) // Never resumed.
        let response = try XCTUnwrap(HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: nil, headerFields: nil))
        var completionCalled = false
        transport.urlSession(session, task: task, willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)) { forwarded in
            completionCalled = true
            XCTAssertNil(forwarded)
        }
        XCTAssertTrue(completionCalled)
        XCTAssertNil(MockURLProtocol.lastRequest)
    }

    private var askRequest: AskRequest { .init(userQuestion: "Not allowed", bookTitle: "River", bookAuthor: "Fixture", consumedContext: "") }
    private func makeGate(_ suffix: String? = nil) throws -> SourceContinuationTrialGate {
        try .init(directory: suffix.map { root.appendingPathComponent($0, isDirectory: true) } ?? root, id: id)
    }
    private func writingRequest() -> SourceContinuationWritingRequest {
        .init(title: "River Archive", instructions: "Explain the saved records plainly", frozenParagraphs: frozen,
              oldSuffix: ["An old replaceable account."], source: source())
    }
    private func injectedService() -> SourceContinuationTrialService {
        .init(live: LiveOpenAIService(apiKeyProvider: { SourceContinuationTrial.proxyLabel }, preferredModel: .defaultGeneration,
            session: MockURLProtocol.makeSession(), endpoint: SourceContinuationTrial.endpoint))
    }
    private func expectedParagraphs(frozenText: [String]? = nil, joins: Bool = false) -> [String] {
        var result = frozenText ?? frozen
        var remaining = tail
        if joins { result[result.count - 1] += remaining.removeFirst() }
        return (result + remaining).map { $0 + " [1]" }
    }
    private func request(review: Bool = false, sourceText: String? = nil, paragraphs: [String]? = nil,
                         frozenText: [String]? = nil, joins: Bool = false,
                         extra: [String: Any] = [:], inputExtra: [String: Any] = [:]) throws -> URLRequest {
        var input: [String: Any] = review ? ["source1": sourceText ?? source().text, "paragraphs": paragraphs ?? expectedParagraphs()]
            : ["title": "River Archive", "instructions": "Explain plainly", "frozenParagraphs": frozenText ?? frozen,
               "oldSuffix": ["An old replaceable account."], "source1": sourceText ?? source().text,
               "joinsSelectedParagraph": joins, "minimumTailParagraphs": 2, "maximumTailParagraphs": 6]
        input.merge(inputExtra) { _, value in value }
        var json: [String: Any] = ["model": "gpt-6-astra", "max_completion_tokens": review ? 3500 : 2500,
            "response_format": ["type": "json_object"], "messages": [["role": "system", "content": "Fixture source contract"],
                ["role": "user", "content": String(decoding: try JSONSerialization.data(withJSONObject: input), as: UTF8.self)]]]
        json.merge(extra) { _, value in value }
        var request = URLRequest(url: SourceContinuationTrial.endpoint)
        request.httpMethod = "POST"; request.timeoutInterval = review ? 90 : 60
        request.setValue("Bearer " + SourceContinuationTrial.proxyLabel, forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: json)
        return request
    }
    private func writerResponse(texts: [String]? = nil, citations: [String] = ["source1"], finish: String = "stop",
                                choices: Int = 1, refusal: String? = nil) throws -> Data {
        let content = try JSONSerialization.data(withJSONObject: ["paragraphs": (texts ?? tail).map { ["text": $0, "citations": citations] as [String: Any] }])
        return try wire(String(decoding: content, as: UTF8.self), finish: finish, choices: choices, refusal: refusal)
    }
    private func wire(_ content: String, finish: String = "stop", choices: Int = 1, refusal: String? = nil) throws -> Data {
        var message: [String: Any] = ["role": "assistant", "content": content]
        if let refusal { message["refusal"] = refusal }
        return try JSONSerialization.data(withJSONObject: ["model": "gpt-6-astra",
            "choices": Array(repeating: ["finish_reason": finish, "message": message] as [String: Any], count: choices)])
    }
    private func source() -> RetrievedResearchSource {
        let sentence = "River communities kept written records of seasonal journeys and public meetings."
        let text = Array(repeating: sentence, count: 18).joined(separator: " ")
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        return .init(requestedTitle: "River Archive", title: "River Archive",
            canonicalURL: URL(string: "https://en.wikipedia.org/wiki/River_Archive")!, pageID: 42, revisionID: 9001,
            revisionURL: URL(string: "https://en.wikipedia.org/w/index.php?oldid=9001")!, revisionTimestamp: timestamp,
            retrievedAt: timestamp, scope: .wikipediaIntroduction, text: text,
            textSHA256: SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined(),
            attribution: "Authored fixture; no source was retrieved.",
            attributionURL: URL(string: "https://en.wikipedia.org/w/index.php?title=River_Archive&action=history")!,
            licenseName: "Fixture CC BY-SA 4.0", licenseURL: URL(string: "https://creativecommons.org/licenses/by-sa/4.0/")!)
    }
}

private final class ContinuationTrialProcessInfo: ProcessInfo, @unchecked Sendable {
    private let args: [String]; private let env: [String: String]
    init(arguments: [String], environment: [String: String]) { args = arguments; env = environment; super.init() }
    override var arguments: [String] { args }
    override var environment: [String: String] { env }
}
private final class ContinuationTrialKeySpy: APIKeyStoring, @unchecked Sendable {
    var reads = 0; var writes = 0
    func loadAPIKey() throws -> String? { reads += 1; return "unused-test-value" }
    func saveAPIKey(_ key: String?) throws { writes += 1 }
}
private final class ContinuationTrialClaimResults: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var successes = 0
    private(set) var failures = 0
    func success() { lock.lock(); defer { lock.unlock() }; successes += 1 }
    func failure() { lock.lock(); defer { lock.unlock() }; failures += 1 }
}
private final class ContinuationTrialProtocolClient: NSObject, URLProtocolClient {
    var failure: Error?
    var loadedBytes = 0
    func urlProtocol(_ protocol: URLProtocol, wasRedirectedTo request: URLRequest, redirectResponse: URLResponse) { XCTFail("Unexpected redirect") }
    func urlProtocol(_ protocol: URLProtocol, cachedResponseIsValid cachedResponse: CachedURLResponse) { XCTFail("Unexpected cache") }
    func urlProtocol(_ protocol: URLProtocol, didReceive response: URLResponse, cacheStoragePolicy policy: URLCache.StoragePolicy) { XCTFail("Overflow must not return a response") }
    func urlProtocol(_ protocol: URLProtocol, didLoad data: Data) { loadedBytes += data.count }
    func urlProtocolDidFinishLoading(_ protocol: URLProtocol) { XCTFail("Overflow must not succeed") }
    func urlProtocol(_ protocol: URLProtocol, didFailWithError error: Error) { failure = error }
    func urlProtocol(_ protocol: URLProtocol, didReceive challenge: URLAuthenticationChallenge) { XCTFail("No credential challenge") }
    func urlProtocol(_ protocol: URLProtocol, didCancel challenge: URLAuthenticationChallenge) {}
}
#endif
