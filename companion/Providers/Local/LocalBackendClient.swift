import Foundation

/// Endpoints and model settings, editable from the UI.
nonisolated struct LocalBackendSettings: Sendable {
    var whisperBaseURL: String
    var ollamaBaseURL: String
    var ollamaModel: String
    /// Empty string lets Whisper auto-detect the language.
    var language: String
}

nonisolated struct ChatMessage: Codable, Sendable {
    let role: String
    let content: String
}

nonisolated enum LocalBackendClient {
    private struct WhisperResponse: Decodable {
        let text: String
    }

    private struct OllamaModelsResponse: Decodable {
        let models: [OllamaModel]
    }

    private struct OllamaModel: Decodable {
        let name: String
    }

    private struct OllamaRequest: Encodable {
        let model: String
        let stream: Bool
        let messages: [ChatMessage]
        let keep_alive: String
    }

    private struct OllamaResponse: Decodable {
        let message: ChatMessage
    }

    // MARK: Whisper

    /// Uploads a WAV file to the whisper-asr-webservice `/asr` endpoint.
    static func transcribe(
        wavURL: URL,
        settings: LocalBackendSettings,
        transport: any HTTPTransport = URLSession.shared
    ) async throws -> String {
        guard var components = URLComponents(string: settings.whisperBaseURL) else {
            throw APIError.invalidURL(settings.whisperBaseURL)
        }
        components.path = "/asr"
        components.queryItems = [
            URLQueryItem(name: "encode", value: "true"),
            URLQueryItem(name: "task", value: "transcribe"),
            URLQueryItem(name: "output", value: "json"),
        ]
        let language = settings.language.trimmingCharacters(in: .whitespaces)
        if !language.isEmpty {
            components.queryItems?.append(URLQueryItem(name: "language", value: language))
        }
        guard let url = components.url else { throw APIError.invalidURL(settings.whisperBaseURL) }

        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data(
            "Content-Disposition: form-data; name=\"audio_file\"; filename=\"\(wavURL.lastPathComponent)\"\r\n".utf8
        ))
        body.append(Data("Content-Type: audio/wav\r\n\r\n".utf8))
        body.append(try Data(contentsOf: wavURL))
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        request.httpBody = body

        let (data, response) = try await transport.send(request)
        try checkHTTP(response, data: data)

        return try JSONDecoder().decode(WhisperResponse.self, from: data)
            .text
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Ollama

    static func listModels(
        baseURL: String,
        transport: any HTTPTransport = URLSession.shared
    ) async throws -> [String] {
        guard let url = URL(string: baseURL)?.appendingPathComponent("api/tags") else {
            throw APIError.invalidURL(baseURL)
        }

        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await transport.send(request)
        try checkHTTP(response, data: data)

        return try JSONDecoder().decode(OllamaModelsResponse.self, from: data)
            .models
            .map(\.name)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    static func chat(
        messages: [ChatMessage],
        settings: LocalBackendSettings,
        transport: any HTTPTransport = URLSession.shared
    ) async throws -> String {
        guard let url = URL(string: settings.ollamaBaseURL)?.appendingPathComponent("api/chat") else {
            throw APIError.invalidURL(settings.ollamaBaseURL)
        }

        var request = URLRequest(url: url, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            OllamaRequest(
                model: settings.ollamaModel,
                stream: false,
                messages: messages,
                keep_alive: "30m"
            )
        )

        let (data, response) = try await transport.send(request)
        try checkHTTP(response, data: data)

        return try JSONDecoder().decode(OllamaResponse.self, from: data)
            .message
            .content
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func checkHTTP(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.http(
                status: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? "<non-text response>"
            )
        }
    }
}
