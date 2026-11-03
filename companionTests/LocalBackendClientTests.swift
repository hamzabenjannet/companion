import Foundation
import Testing
@testable import companion

@Suite("Whisper and Ollama client")
struct LocalBackendClientTests {
    private let settings = LocalBackendSettings(
        whisperBaseURL: "http://localhost:42940",
        ollamaBaseURL: "http://localhost:11434",
        ollamaModel: "qwen2.5:3b",
        language: "fr"
    )

    @Test func transcribeBuildsMultipartRequest() async throws {
        let transport = MockTransport(json: #"{"text": "  bonjour  "}"#)
        let chunk = try TestFiles.makeChunk(source: .microphone, bytes: Data("RIFFDATA".utf8))
        defer { try? FileManager.default.removeItem(at: chunk.url) }

        let text = try await LocalBackendClient.transcribe(wavURL: chunk.url, settings: settings, transport: transport)

        #expect(text == "bonjour")
        let request = try #require(transport.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/asr")
        #expect(request.queryItems["language"] == "fr")
        #expect(request.queryItems["output"] == "json")
        #expect(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true)
        let body = String(decoding: try #require(request.httpBody), as: UTF8.self)
        #expect(body.contains(#"name="audio_file"; filename="\#(chunk.url.lastPathComponent)""#))
        #expect(body.contains("RIFFDATA"))
    }

    @Test func transcribeOmitsEmptyLanguage() async throws {
        var settings = settings
        settings.language = "  "
        let transport = MockTransport(json: #"{"text": ""}"#)
        let chunk = try TestFiles.makeChunk(source: .system)
        defer { try? FileManager.default.removeItem(at: chunk.url) }

        _ = try await LocalBackendClient.transcribe(wavURL: chunk.url, settings: settings, transport: transport)

        #expect(transport.requests.first?.queryItems["language"] == nil)
    }

    @Test func transcribeRejectsInvalidURL() async throws {
        var settings = settings
        settings.whisperBaseURL = "http://exa mple.com:bad"
        let chunk = try TestFiles.makeChunk(source: .system)
        defer { try? FileManager.default.removeItem(at: chunk.url) }

        await #expect(throws: APIError.self) {
            _ = try await LocalBackendClient.transcribe(wavURL: chunk.url, settings: settings, transport: MockTransport(json: "{}"))
        }
    }

    @Test func chatSendsModelAndMessages() async throws {
        let transport = MockTransport(json: #"{"message": {"role": "assistant", "content": " Hi! \n"}}"#)

        let reply = try await LocalBackendClient.chat(
            messages: [ChatMessage(role: "user", content: "Hello")],
            settings: settings,
            transport: transport
        )

        #expect(reply == "Hi!")
        let request = try #require(transport.requests.first)
        #expect(request.url?.absoluteString == "http://localhost:11434/api/chat")
        let body = try #require(request.jsonBody)
        #expect(body["model"] as? String == "qwen2.5:3b")
        #expect(body["stream"] as? Bool == false)
        let messages = try #require(body["messages"] as? [[String: String]])
        #expect(messages == [["role": "user", "content": "Hello"]])
    }

    @Test func httpErrorsAreReported() async throws {
        let transport = MockTransport(status: 500, json: "model not found")

        await #expect(throws: APIError.http(status: 500, body: "model not found")) {
            _ = try await LocalBackendClient.chat(messages: [], settings: settings, transport: transport)
        }
    }

    @Test func checkHTTPAcceptsSuccessAndNonHTTPResponses() throws {
        let url = URL(string: "https://example.com")!
        try LocalBackendClient.checkHTTP(HTTPURLResponse(url: url, statusCode: 204, httpVersion: nil, headerFields: nil)!, data: Data())
        try LocalBackendClient.checkHTTP(URLResponse(url: url, mimeType: nil, expectedContentLength: 0, textEncodingName: nil), data: Data())
    }

    @Test func errorDescriptions() {
        #expect(APIError.invalidURL("x").errorDescription == "Invalid URL: x")
        #expect(APIError.http(status: 404, body: "nope").errorDescription == "HTTP 404: nope")
        #expect(APIError.missingAPIKey.errorDescription == "No API key configured.")
        #expect(APIError.emptyResponse("SAFETY").errorDescription?.contains("SAFETY") == true)
        #expect(APIError.invalidReply("garbage").errorDescription?.contains("garbage") == true)
    }
}
