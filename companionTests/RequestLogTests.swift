import Foundation
import Testing
@testable import companion

@Suite("HTTP preview formatting")
struct HTTPPreviewTests {
    private let longBase64 = Data(repeating: 7, count: 3_000).base64EncodedString()

    @Test func identifiesServices() {
        #expect(HTTPPreview.service(for: URL(string: "https://generativelanguage.googleapis.com/v1beta/models")) == "Gemini")
        #expect(HTTPPreview.service(for: URL(string: "https://openrouter.ai/api/v1/chat/completions")) == "OpenRouter")
        #expect(HTTPPreview.service(for: URL(string: "http://localhost:42940/asr?output=json")) == "Whisper")
        #expect(HTTPPreview.service(for: URL(string: "http://localhost:11434/api/chat")) == "Ollama")
        #expect(HTTPPreview.service(for: URL(string: "https://example.com/x")) == "example.com")
        #expect(HTTPPreview.service(for: nil) == "Unknown")
    }

    @Test func masksSecretsInHeadersAndQuery() {
        let headers = HTTPPreview.redactedHeaders([
            "Authorization": "Bearer sk-secret",
            "x-goog-api-key": "AIza-secret",
            "Content-Type": "application/json",
        ])
        #expect(headers.map(\.name) == ["Authorization", "Content-Type", "x-goog-api-key"])
        #expect(headers.map(\.value) == [HTTPPreview.mask, "application/json", HTTPPreview.mask])

        let url = HTTPPreview.redactedURL(URL(string: "https://host/models?key=AIza-secret&pageSize=50"))
        #expect(!url.contains("AIza-secret"))
        #expect(url.contains("pageSize=50"))
    }

    @Test func collapsesGeminiInlineData() throws {
        let json = #"{"contents":[{"parts":[{"text":"Hello"},{"inlineData":{"mimeType":"audio/wav","data":"\#(longBase64)"}}]}]}"#
        let preview = HTTPPreview.body(Data(json.utf8), contentType: "application/json")
        #expect(preview.contains("\"Hello\""))
        #expect(preview.contains("<audio/wav · "))
        #expect(!preview.contains(longBase64))
    }

    @Test func collapsesOpenRouterAudioAndDataURLs() {
        let json = #"""
            {"messages":[{"content":[
              {"type":"input_audio","input_audio":{"format":"wav","data":"\#(longBase64)"}},
              {"type":"video_url","video_url":{"url":"data:video/mp4;base64,\#(longBase64)"}}
            ]}]}
            """#
        let preview = HTTPPreview.body(Data(json.utf8), contentType: "application/json")
        #expect(preview.contains("<audio/wav · "))
        #expect(preview.contains("<video/mp4 · "))
        #expect(!preview.contains(longBase64))
    }

    @Test func keepsShortStrings() {
        let preview = HTTPPreview.body(Data(#"{"text":"abc"}"#.utf8), contentType: "application/json")
        #expect(preview.contains("\"abc\""))
    }

    @Test func collapsesBinaryMultipartParts() {
        var body = Data("--B\r\nContent-Disposition: form-data; name=\"audio_file\"; filename=\"a.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8)
        body.append(Data(repeating: 0, count: 2_048))
        body.append(Data("\r\n--B--\r\n".utf8))

        let preview = HTTPPreview.body(body, contentType: "multipart/form-data; boundary=B")
        #expect(preview.contains("filename=\"a.wav\""))
        #expect(preview.contains("<audio/wav · "))
        #expect(preview.hasPrefix("--B\n"))
        #expect(preview.hasSuffix("--B--"))
    }

    @Test func plainTextAndBinaryBodies() {
        #expect(HTTPPreview.body(Data(), contentType: nil) == "")
        #expect(HTTPPreview.body(Data("not json".utf8), contentType: "text/plain") == "not json")
        #expect(HTTPPreview.body(Data([0xFF, 0xFE, 0x00]), contentType: "audio/wav").hasPrefix("<audio/wav · "))
    }
}

@MainActor
@Suite("Request log")
struct RequestLogTests {
    @Test func keepsOnlyMostRecentExchanges() {
        let log = RequestLog(capacity: 2)
        for index in 0..<3 {
            log.begin(HTTPExchange(
                id: UUID(), startedAt: .now, service: "S\(index)", method: "GET",
                url: "https://x", requestHeaders: [], requestBody: ""
            ))
        }
        #expect(log.exchanges.map(\.service) == ["S1", "S2"])
        log.clear()
        #expect(log.exchanges.isEmpty)
    }

    @Test func loggingTransportRecordsSuccess() async throws {
        let log = RequestLog()
        let transport = LoggingTransport(base: MockTransport(json: #"{"text":"hi"}"#), log: log)
        var request = URLRequest(url: try #require(URL(string: "http://localhost:11434/api/chat")))
        request.httpMethod = "POST"
        request.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
        request.httpBody = Data(#"{"model":"m"}"#.utf8)

        let (data, _) = try await transport.send(request)

        #expect(String(decoding: data, as: UTF8.self) == #"{"text":"hi"}"#)
        let exchange = try #require(log.exchanges.first)
        #expect(exchange.service == "Ollama")
        #expect(exchange.method == "POST")
        #expect(exchange.endpoint == "/api/chat")
        #expect(exchange.status == 200)
        #expect(exchange.isFinished)
        #expect(exchange.requestBody.contains("\"model\""))
        #expect(exchange.responseBody?.contains("\"hi\"") == true)
        #expect(exchange.requestHeaders.first { $0.name == "Authorization" }?.value == HTTPPreview.mask)
    }

    @Test func loggingTransportRecordsFailure() async throws {
        let log = RequestLog()
        let transport = LoggingTransport(base: MockTransport { _ in throw TestError(message: "offline") }, log: log)
        let request = URLRequest(url: try #require(URL(string: "http://localhost:42940/asr")))

        await #expect(throws: TestError.self) { try await transport.send(request) }

        let exchange = try #require(log.exchanges.first)
        #expect(exchange.status == nil)
        #expect(exchange.error == "offline")
        #expect(exchange.isFinished)
    }
}
