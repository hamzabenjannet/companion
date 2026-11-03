import Foundation
import Testing
@testable import companion

@Suite("OpenRouter client")
struct OpenRouterClientTests {
    private func client(_ transport: MockTransport = MockTransport(json: "{}"), key: String = "or-key") -> OpenRouterClient {
        OpenRouterClient(baseURL: OpenRouterClient.defaultBaseURL, apiKey: key, transport: transport)
    }

    @Test func listModelsRequestUsesBearerToken() throws {
        let request = try client().makeListModelsRequest()
        #expect(request.url?.absoluteString == "https://openrouter.ai/api/v1/models")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer or-key")
    }

    @Test func missingKeyIsRejected() {
        #expect(throws: APIError.missingAPIKey) {
            _ = try client(key: "").makeListModelsRequest()
        }
    }

    @Test func invalidBaseURLIsRejected() {
        #expect(throws: APIError.invalidURL("not a url")) {
            _ = try OpenRouterClient(baseURL: "not a url", apiKey: "k").makeListModelsRequest()
        }
    }

    @Test func contentPartsMapEachMediaType() throws {
        let text = OpenRouterClient.contentPart(.text("hi"))
        #expect(text["type"] as? String == "text")
        #expect(text["text"] as? String == "hi")

        let audio = OpenRouterClient.contentPart(.media(mimeType: "audio/wav", data: Data([1])))
        #expect(audio["type"] as? String == "input_audio")
        let input = try #require(audio["input_audio"] as? [String: String])
        #expect(input == ["data": "AQ==", "format": "wav"])

        let video = OpenRouterClient.contentPart(.media(mimeType: "video/mp4", data: Data([1])))
        #expect(video["type"] as? String == "video_url")
        #expect((video["video_url"] as? [String: String])?["url"] == "data:video/mp4;base64,AQ==")

        let image = OpenRouterClient.contentPart(.media(mimeType: "image/jpeg", data: Data([1])))
        #expect(image["type"] as? String == "image_url")
        #expect((image["image_url"] as? [String: String])?["url"] == "data:image/jpeg;base64,AQ==")
    }

    @Test func generateRequestBody() throws {
        let request = try client().makeGenerateRequest(
            model: "google/gemini-2.5-flash",
            systemPrompt: "SYSTEM",
            parts: [.text("hello")]
        )

        #expect(request.url?.absoluteString == "https://openrouter.ai/api/v1/chat/completions")
        #expect(request.httpMethod == "POST")
        let body = try #require(request.jsonBody)
        #expect(body["model"] as? String == "google/gemini-2.5-flash")
        // JSON mode is off unless the model supports it.
        #expect(body["response_format"] == nil)
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.count == 2)
        #expect(messages[0]["role"] as? String == "system")
        #expect(messages[0]["content"] as? String == "SYSTEM")
        #expect(messages[1]["role"] as? String == "user")
        #expect((messages[1]["content"] as? [[String: Any]])?.count == 1)
    }

    @Test func jsonModeAddsResponseFormat() throws {
        var client = client()
        client.jsonMode = true
        let body = try #require(try client.makeGenerateRequest(model: "m", systemPrompt: "s", parts: []).jsonBody)
        #expect((body["response_format"] as? [String: String])?["type"] == "json_object")
    }

    @Test func defaultModelIsFreeOmniModel() {
        #expect(OpenRouterClient.defaultModel == "nvidia/nemotron-3-nano-omni-30b-a3b-reasoning:free")
    }

    @Test func parseModelsReadsJSONModeSupport() throws {
        // Shape taken from the live /models entry for the Nemotron omni model.
        let json = """
            {"data": [
              {"id": "nvidia/nemotron-3-nano-omni-30b-a3b-reasoning:free", "name": "NVIDIA: Nemotron 3 Nano Omni (free)",
               "architecture": {"input_modalities": ["text", "audio", "image", "video"]},
               "supported_parameters": ["include_reasoning", "max_tokens", "reasoning", "temperature"]},
              {"id": "openai/gpt-audio", "name": "GPT Audio",
               "architecture": {"input_modalities": ["text", "audio"]},
               "supported_parameters": ["response_format", "temperature"]}
            ]}
            """
        let models = try OpenRouterClient.parseModels(Data(json.utf8))
        #expect(models.map(\.supportsJSONMode) == [false, true])
        #expect(models.first?.displayName == "NVIDIA: Nemotron 3 Nano Omni (free)")
    }

    @Test func parseGenerateResponseIgnoresReasoningField() throws {
        let json = #"{"choices": [{"finish_reason": "stop", "message": {"role": "assistant", "content": "{\"suggestion\": \"Canberra\"}", "reasoning": "We need to answer {quickly}."}}]}"#
        #expect(try OpenRouterClient.parseGenerateResponse(Data(json.utf8)) == #"{"suggestion": "Canberra"}"#)
    }

    @Test func paymentRequiredIsSurfaced() async {
        let body = #"{"error": {"message": "This request requires at least $0.50 in balance for audio", "code": 402}}"#
        let transport = MockTransport(status: 402, json: body)
        await #expect(throws: APIError.http(status: 402, body: body)) {
            _ = try await client(transport).generate(model: "m", systemPrompt: "s", parts: [.media(mimeType: "audio/wav", data: Data([1]))])
        }
    }

    @Test func parseModelsKeepsAudioCapableModels() throws {
        let json = """
            {"data": [
              {"id": "google/gemini-2.5-flash", "name": "Gemini 2.5 Flash",
               "architecture": {"input_modalities": ["text", "image", "audio", "video"]}},
              {"id": "meta/llama", "name": "Llama", "architecture": {"input_modalities": ["text"]}},
              {"id": "unknown/model"}
            ]}
            """
        let models = try OpenRouterClient.parseModels(Data(json.utf8))
        #expect(models == [
            RemoteModel(id: "google/gemini-2.5-flash", displayName: "Gemini 2.5 Flash"),
            RemoteModel(id: "unknown/model", displayName: "unknown/model"),
        ])
    }

    @Test func parseGenerateResponse() throws {
        let json = #"{"choices": [{"message": {"role": "assistant", "content": " {\"suggestion\": \"x\"} "}}]}"#
        #expect(try OpenRouterClient.parseGenerateResponse(Data(json.utf8)) == #"{"suggestion": "x"}"#)
    }

    @Test func parseGenerateResponseErrors() {
        #expect(throws: APIError.emptyResponse("no choices")) {
            _ = try OpenRouterClient.parseGenerateResponse(Data("{}".utf8))
        }
        #expect(throws: APIError.emptyResponse("length")) {
            _ = try OpenRouterClient.parseGenerateResponse(
                Data(#"{"choices": [{"message": {"content": null}, "finish_reason": "length"}]}"#.utf8)
            )
        }
    }

    @Test func listAndGenerateThroughTransport() async throws {
        let transport = MockTransport { request in
            if request.url?.path.hasSuffix("/models") == true {
                return (200, Data(#"{"data": [{"id": "a/b", "name": "AB"}]}"#.utf8))
            }
            return (200, Data(#"{"choices": [{"message": {"content": "pong"}}]}"#.utf8))
        }
        let client = client(transport)

        #expect(try await client.listModels() == [RemoteModel(id: "a/b", displayName: "AB")])
        #expect(try await client.generate(model: "a/b", systemPrompt: "s", parts: [.text("ping")]) == "pong")
    }

    @Test func generateSurfacesHTTPErrors() async {
        let transport = MockTransport(status: 401, json: #"{"error": "unauthorized"}"#)
        await #expect(throws: APIError.self) {
            _ = try await client(transport).generate(model: "a/b", systemPrompt: "s", parts: [])
        }
    }
}
