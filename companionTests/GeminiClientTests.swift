import Foundation
import Testing
@testable import companion

@Suite("Gemini client")
struct GeminiClientTests {
    private func client(_ transport: MockTransport = MockTransport(json: "{}"), key: String = "test-key") -> GeminiClient {
        GeminiClient(baseURL: GeminiClient.defaultBaseURL, apiKey: key, transport: transport)
    }

    // MARK: Requests

    @Test func normalizesModelNames() {
        #expect(GeminiClient.normalizedModel("gemini-2.5-flash") == "models/gemini-2.5-flash")
        #expect(GeminiClient.normalizedModel(" models/gemini-2.5-pro ") == "models/gemini-2.5-pro")
    }

    @Test func listModelsRequestUsesHeaderKey() throws {
        let request = try client().makeListModelsRequest(pageToken: "abc")

        #expect(request.url?.host == "generativelanguage.googleapis.com")
        #expect(request.url?.path == "/v1beta/models")
        #expect(request.queryItems["pageToken"] == "abc")
        #expect(request.queryItems["pageSize"] == "1000")
        #expect(request.queryItems["key"] == nil)
        #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == "test-key")
    }

    @Test func listModelsRequestWithoutTokenOmitsIt() throws {
        let request = try client().makeListModelsRequest(pageToken: nil)
        #expect(request.queryItems["pageToken"] == nil)
    }

    @Test func baseURLWithTrailingSlashOrPathIsJoined() throws {
        let request = try GeminiClient(baseURL: "https://proxy.example.com/gemini/", apiKey: "k")
            .makeListModelsRequest(pageToken: nil)
        #expect(request.url?.path == "/gemini/v1beta/models")
    }

    @Test func missingKeyIsRejected() {
        #expect(throws: APIError.missingAPIKey) {
            _ = try client(key: "  ").makeListModelsRequest(pageToken: nil)
        }
    }

    @Test func invalidHostIsRejected() {
        #expect(throws: APIError.invalidURL("nohost")) {
            _ = try GeminiClient(baseURL: "nohost", apiKey: "k").makeListModelsRequest(pageToken: nil)
        }
    }

    @Test func generateRequestContainsSystemPromptMediaAndJSONMode() throws {
        let audio = Data([0x52, 0x49, 0x46, 0x46])
        let request = try client().makeGenerateRequest(
            model: "models/gemini-2.5-flash",
            systemPrompt: "SYSTEM",
            parts: [.text("hello"), .media(mimeType: "audio/wav", data: audio)]
        )

        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent")
        #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == "test-key")

        let body = try #require(request.jsonBody)
        let system = try #require(body["systemInstruction"] as? [String: Any])
        #expect((system["parts"] as? [[String: Any]])?.first?["text"] as? String == "SYSTEM")

        let contents = try #require(body["contents"] as? [[String: Any]])
        #expect(contents.first?["role"] as? String == "user")
        let parts = try #require(contents.first?["parts"] as? [[String: Any]])
        #expect(parts.count == 2)
        #expect(parts[0]["text"] as? String == "hello")
        #expect(parts[0]["inlineData"] == nil)
        let inline = try #require(parts[1]["inlineData"] as? [String: String])
        #expect(inline["mimeType"] == "audio/wav")
        #expect(inline["data"] == audio.base64EncodedString())

        let config = try #require(body["generationConfig"] as? [String: Any])
        #expect(config["responseMimeType"] as? String == "application/json")
    }

    @Test func mediaPartConversion() {
        let text = GeminiClient.part(.text("hi"))
        #expect(text.text == "hi" && text.inlineData == nil)
        let video = GeminiClient.part(.media(mimeType: "video/mp4", data: Data([1])))
        #expect(video.text == nil)
        #expect(video.inlineData?.mimeType == "video/mp4")
        #expect(video.inlineData?.data == "AQ==")
    }

    // MARK: Responses

    @Test func parseModelsKeepsGenerateContentModels() throws {
        let json = """
            {
              "models": [
                {"name": "models/gemini-2.5-flash", "displayName": "Gemini 2.5 Flash",
                 "supportedGenerationMethods": ["generateContent", "countTokens"]},
                {"name": "models/gemini-embedding-001", "displayName": "Gemini Embedding 001",
                 "supportedGenerationMethods": ["embedContent"]},
                {"name": "models/aqa", "supportedGenerationMethods": ["generateAnswer"]},
                {"name": "models/no-display", "supportedGenerationMethods": ["generateContent"]}
              ],
              "nextPageToken": "Cgptb2RlbHMvYXFh"
            }
            """
        let page = try GeminiClient.parseModels(Data(json.utf8))

        #expect(page.models == [
            RemoteModel(id: "models/gemini-2.5-flash", displayName: "Gemini 2.5 Flash"),
            RemoteModel(id: "models/no-display", displayName: "models/no-display"),
        ])
        #expect(page.nextPageToken == "Cgptb2RlbHMvYXFh")
    }

    @Test func parseModelsTreatsEmptyTokenAsLastPage() throws {
        let page = try GeminiClient.parseModels(Data(#"{"models": [], "nextPageToken": ""}"#.utf8))
        #expect(page.models.isEmpty)
        #expect(page.nextPageToken == nil)
    }

    @Test func parseGenerateResponseSkipsThoughts() throws {
        let json = """
            {"candidates": [{"content": {"role": "model", "parts": [
                {"text": "thinking...", "thought": true},
                {"text": "{\\"suggestion\\": "},
                {"text": "\\"ok\\"}"}
            ]}, "finishReason": "STOP"}]}
            """
        #expect(try GeminiClient.parseGenerateResponse(Data(json.utf8)) == #"{"suggestion": "ok"}"#)
    }

    @Test func parseGenerateResponseReportsBlockedPrompt() {
        let json = #"{"promptFeedback": {"blockReason": "SAFETY"}}"#
        #expect(throws: APIError.emptyResponse("blocked: SAFETY")) {
            _ = try GeminiClient.parseGenerateResponse(Data(json.utf8))
        }
    }

    @Test func parseGenerateResponseReportsMissingCandidates() {
        #expect(throws: APIError.emptyResponse("no candidates")) {
            _ = try GeminiClient.parseGenerateResponse(Data("{}".utf8))
        }
    }

    @Test func parseGenerateResponseReportsEmptyText() {
        let json = #"{"candidates": [{"content": {"parts": []}, "finishReason": "MAX_TOKENS"}]}"#
        #expect(throws: APIError.emptyResponse("MAX_TOKENS")) {
            _ = try GeminiClient.parseGenerateResponse(Data(json.utf8))
        }
    }

    // MARK: End to end with stub transport

    @Test func listModelsFollowsPagination() async throws {
        let transport = MockTransport { request in
            if request.queryItems["pageToken"] == nil {
                return (200, Data(#"{"models": [{"name": "models/a", "displayName": "A", "supportedGenerationMethods": ["generateContent"]}], "nextPageToken": "p2"}"#.utf8))
            }
            return (200, Data(#"{"models": [{"name": "models/b", "displayName": "B", "supportedGenerationMethods": ["generateContent"]}]}"#.utf8))
        }

        let models = try await client(transport).listModels()

        #expect(models.map(\.id) == ["models/a", "models/b"])
        #expect(transport.requests.count == 2)
        #expect(transport.requests.last?.queryItems["pageToken"] == "p2")
    }

    @Test func listModelsSurfacesHTTPErrors() async {
        let transport = MockTransport(status: 400, json: #"{"error": {"message": "API key not valid"}}"#)
        await #expect(throws: APIError.self) {
            _ = try await client(transport).listModels()
        }
    }

    @Test func generateReturnsModelText() async throws {
        let transport = MockTransport(json: #"{"candidates": [{"content": {"parts": [{"text": "hello"}]}}]}"#)
        let text = try await client(transport).generate(model: "gemini-2.5-flash", systemPrompt: "s", parts: [.text("hi")])
        #expect(text == "hello")
        #expect(transport.requests.first?.url?.path == "/v1beta/models/gemini-2.5-flash:generateContent")
    }
}
