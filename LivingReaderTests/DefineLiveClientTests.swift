import XCTest
@testable import LivingReader

/// URLProtocol responses are local fixtures; no provider key or network is used.
@MainActor
final class DefineLiveClientTests: XCTestCase {
    override func setUpWithError() throws { MockURLProtocol.reset() }
    override func tearDownWithError() throws { MockURLProtocol.reset() }

    func testEveryModelUsesCompatibleParametersAndPreservesDefinitionContext() async throws {
        for model in OpenAIModelOption.allCases {
            var calls = 0
            MockURLProtocol.requestHandler = { request in
                calls += 1
                let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                XCTAssertEqual(body["model"] as? String, model.rawValue)
                XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/chat/completions")
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(request.timeoutInterval, 25)
                XCTAssertEqual(body["response_format"] as? [String: String], ["type": "json_object"])
                switch model {
                case .gpt6Astra, .gpt56Luna:
                    XCTAssertEqual(Set(body.keys), ["model", "messages", "max_completion_tokens", "response_format"])
                    XCTAssertEqual(body["max_completion_tokens"] as? Int, 1200)
                    XCTAssertNil(body["temperature"])
                    XCTAssertNil(body["max_tokens"])
                case .gpt41Mini, .gpt41, .gpt4oMini, .gpt4o:
                    XCTAssertEqual(Set(body.keys), ["model", "messages", "temperature", "max_tokens", "response_format"])
                    XCTAssertEqual(body["temperature"] as? Double, 0.3)
                    XCTAssertEqual(body["max_tokens"] as? Int, 1200)
                    XCTAssertNil(body["max_completion_tokens"])
                }
                let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
                XCTAssertEqual(messages.map { $0["role"] }, ["system", "user"])
                let user = try XCTUnwrap(messages.last?["content"])
                XCTAssertTrue(user.contains("A test sentence."))
                XCTAssertTrue(user.contains("A test context."))
                XCTAssertTrue(user.contains("A chapter"))
                XCTAssertTrue(user.contains("A book"))
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, try Self.definitionResponse())
            }
            let client = DefineLiveClient(sharingPermission: { true }, apiKey: "test-provider-key", preferredModel: model,
                session: MockURLProtocol.makeSession())
            let result = try await client.fetchRichDefinition(definitionRequest)
            XCTAssertEqual(result.senses.first?.gloss, "A test definition.")
            XCTAssertEqual(calls, 1, "A valid response must not cause a model fallback")
        }
    }

    func testUnavailableLunaFallbackSwitchesToLegacyRequestParameters() async throws {
        var models: [String] = []
        MockURLProtocol.requestHandler = { request in
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            models.append(try XCTUnwrap(body["model"] as? String))
            if models.count == 1 {
                XCTAssertEqual(body["max_completion_tokens"] as? Int, 1200)
                XCTAssertNil(body["temperature"])
                XCTAssertNil(body["max_tokens"])
                return (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
            }
            XCTAssertEqual(body["max_tokens"] as? Int, 1200)
            XCTAssertEqual(body["temperature"] as? Double, 0.3)
            XCTAssertNil(body["max_completion_tokens"])
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, try Self.definitionResponse())
        }
        let client = DefineLiveClient(sharingPermission: { true }, apiKey: "test-provider-key", preferredModel: .gpt56Luna,
            session: MockURLProtocol.makeSession())
        let result = try await client.fetchRichDefinition(definitionRequest)
        XCTAssertEqual(models, ["gpt-5.6-luna", "gpt-4.1-mini"])
        XCTAssertEqual(result.senses.first?.gloss, "A test definition.")
    }

    private var definitionRequest: DefineWordRequest {
        DefineWordRequest(term: "trust", sentenceContext: "A test sentence.", surroundingContext: "A test context.",
            chapterTitle: "A chapter", bookTitle: "A book")
    }

    private static func definitionResponse() throws -> Data {
        let content = #"{"term":"trust","senses":[{"number":"1","gloss":"A test definition."}]}"#
        return try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]]])
    }
}
