import XCTest
@testable import LivingReader

/// Requests use a URLProtocol stub: no provider account, key or real network is used.
@MainActor
final class AISharingConsentTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!
    private var consent: AISharingConsentStore!

    override func setUpWithError() throws {
        suite = "AISharingConsentTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        consent = AISharingConsentStore(defaults: defaults)
        MockURLProtocol.reset()
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        MockURLProtocol.reset()
    }

    func testNewInstallAndUnrecognizedDisclosureFailClosedEvenWithSavedKey() throws {
        let keyStore = InMemoryAPIKeyStore(key: "local-test-key")
        XCTAssertFalse(consent.isAllowed)
        XCTAssertNotNil(try keyStore.loadAPIKey())
        defaults.set(AISharingConsentStore.currentDisclosureVersion + 1, forKey: AISharingConsentStore.defaultsKey)
        XCTAssertFalse(consent.isAllowed)
        consent.allowCurrentDisclosure()
        XCTAssertTrue(AISharingConsentStore(defaults: defaults).isAllowed, "Permission survives a relaunch")
        consent.revoke()
        XCTAssertFalse(AISharingConsentStore(defaults: defaults).isAllowed)
        XCTAssertNotNil(try keyStore.loadAPIKey(), "Revoking data sharing is independent of deleting a credential")
    }

    func testExistingAskServiceChecksOptInAndRevocationForEachRequest() async throws {
        let store = consent!
        let service = AIServiceResolver.makeDefault(
            sharingPermission: { store.isAllowed },
            keyStore: InMemoryAPIKeyStore(key: "local-test-key"),
            session: MockURLProtocol.makeSession(),
            processInfo: MockProcessInfo(arguments: [])
        )
        try stubChatContent("A test answer")
        await assertPermissionDenied { _ = try await service.ask(self.askRequest) }
        XCTAssertNil(MockURLProtocol.lastRequest)

        consent.allowCurrentDisclosure()
        let answer = try await service.ask(askRequest)
        XCTAssertEqual(answer.answer, "A test answer")
        XCTAssertNotNil(MockURLProtocol.lastRequest)

        consent.revoke()
        MockURLProtocol.lastRequest = nil
        await assertPermissionDenied { _ = try await service.ask(self.askRequest) }
        XCTAssertNil(MockURLProtocol.lastRequest, "A previously constructed service must not retain permission")
    }

    func testModelFallbackRechecksPermissionBeforeSendingAnotherRequest() async throws {
        let store = consent!
        store.allowCurrentDisclosure()
        let service = LiveOpenAIService(sharingPermission: { store.isAllowed }, apiKey: "local-test-key",
            preferredModel: .gpt41, session: MockURLProtocol.makeSession())
        var requests = 0
        MockURLProtocol.requestHandler = { request in
            requests += 1
            store.revoke()
            return (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
        }
        await assertPermissionDenied { _ = try await service.ask(self.askRequest) }
        XCTAssertEqual(requests, 1, "A fallback must not send more data after revocation")
    }

    func testExistingDefinitionClientChecksOptInAndRevocation() async throws {
        let store = consent!
        let client = DefineLiveClient(sharingPermission: { store.isAllowed }, apiKey: "local-test-key",
            preferredModel: .gpt41, session: MockURLProtocol.makeSession())
        let request = DefineWordRequest(term: "trust", sentenceContext: "A test passage", surroundingContext: nil,
            chapterTitle: "A chapter", bookTitle: "A book")
        try stubChatContent(#"{"term":"trust","senses":[{"number":"1","gloss":"A test definition."}]}"#)
        await assertPermissionDenied { _ = try await client.fetchRichDefinition(request) }
        XCTAssertNil(MockURLProtocol.lastRequest)
        store.allowCurrentDisclosure()
        let definition = try await client.fetchRichDefinition(request)
        XCTAssertEqual(definition.senses.first?.gloss, "A test definition.")
        store.revoke()
        MockURLProtocol.lastRequest = nil
        await assertPermissionDenied { _ = try await client.fetchRichDefinition(request) }
        XCTAssertNil(MockURLProtocol.lastRequest)
    }

    func testDefinitionEnrichmentKeepsOfflineResultWhenSharingIsOff() async throws {
        let baseline = DefineService.define(term: "sovereignty", processInfo: MockProcessInfo(arguments: []))
        let store = consent!
        let result = await DefineService.enrich(sharingPermission: { store.isAllowed },
            request: DefineWordRequest(term: "sovereignty", sentenceContext: nil, surroundingContext: nil,
                chapterTitle: nil, bookTitle: nil), baseline: baseline,
            keyStore: InMemoryAPIKeyStore(key: "local-test-key"), session: MockURLProtocol.makeSession(),
            processInfo: MockProcessInfo(arguments: []))
        XCTAssertEqual(result.rich, baseline.rich)
        XCTAssertEqual(result.source, baseline.source)
        XCTAssertNil(MockURLProtocol.lastRequest)
    }

    func testExistingNarrationClientChecksOptInAndRevocation() async throws {
        let store = consent!
        let client = OpenAISpeechClient(sharingPermission: { store.isAllowed }, apiKeyProvider: { "local-test-key" },
            session: MockURLProtocol.makeSession())
        let request = SpeechSynthesisRequest(text: "A test narration.", voice: .marin)
        MockURLProtocol.requestHandler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Self.fakeMP3())
        }
        await assertPermissionDenied { _ = try await client.synthesize(request) }
        XCTAssertNil(MockURLProtocol.lastRequest)
        store.allowCurrentDisclosure()
        let data = try await client.synthesize(request)
        XCTAssertTrue(ListenAudioValidator.looksLikeMP3(data))
        store.revoke()
        MockURLProtocol.lastRequest = nil
        await assertPermissionDenied { _ = try await client.synthesize(request) }
        XCTAssertNil(MockURLProtocol.lastRequest)
    }

    func testSavedAudioRemainsPlayableAfterRevocation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ConsentAudio-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = FileListenAudioCache(rootDirectory: root)
        let document = ListenDocument(bookId: UUID(), chapterId: UUID(), chapterTitle: "A chapter", revisionId: UUID(),
            voice: .marin, plan: .current, chunks: ListenChunker.chunks(for: "A saved narration."))
        let expected = try cache.store(Self.fakeMP3(), for: document.cacheKey, chunkIndex: 0)
        let store = consent!
        store.allowCurrentDisclosure()
        let client = OpenAISpeechClient(sharingPermission: { store.isAllowed }, apiKeyProvider: { "local-test-key" },
            session: MockURLProtocol.makeSession())
        let provider = ListenAudioProvider(cache: cache, speech: client)
        store.revoke()
        let url = try await provider.audioURL(for: document, chunkIndex: 0)
        XCTAssertEqual(url, expected)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNil(MockURLProtocol.lastRequest)
    }

    nonisolated private static func fakeMP3() -> Data {
        var data = Data([0xFF, 0xFB, 0x90, 0x00])
        data.append(Data(repeating: 0x42, count: 796))
        return data
    }

    private var askRequest: AskRequest {
        AskRequest(userQuestion: "Explain this", bookTitle: "A book", bookAuthor: "An author", consumedContext: "A test passage")
    }

    private func assertPermissionDenied(_ action: () async throws -> Void,
                                        file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await action()
            XCTFail("Expected sharing permission to block the request", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? AIServiceError, .underlying(AISharingConsentStore.permissionRequiredMessage), file: file, line: line)
        }
    }

    private func stubChatContent(_ content: String) throws {
        let data = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]]])
        MockURLProtocol.requestHandler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
        }
    }
}
