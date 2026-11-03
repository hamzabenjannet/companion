import Foundation

/// OpenRouter's OpenAI-compatible API.
///
/// - Model list: `GET {base}/models` (only models that accept audio input are kept)
/// - Generation: `POST {base}/chat/completions`, with audio as `input_audio` and video as `video_url` data URLs.
nonisolated struct OpenRouterClient: MultimodalClient {
    static let defaultBaseURL = "https://openrouter.ai/api/v1"
    /// Free omni model (text, image, audio, video in). Free-tier limits: 20 requests/min, 50/day.
    static let defaultModel = "nvidia/nemotron-3-nano-omni-30b-a3b-reasoning:free"

    let baseURL: String
    let apiKey: String
    var transport: any HTTPTransport = URLSession.shared
    /// Sends `response_format: json_object`. Only enable for models that list it in
    /// `supported_parameters`; the prompt asks for JSON either way and the parser is lenient.
    var jsonMode = false

    // MARK: Wire types

    struct ModelList: Decodable {
        struct Model: Decodable {
            struct Architecture: Decodable {
                let input_modalities: [String]?
            }

            let id: String
            let name: String?
            let architecture: Architecture?
            let supported_parameters: [String]?
        }

        let data: [Model]
    }

    struct ChatResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                let content: String?
            }

            let message: Message
            let finish_reason: String?
        }

        let choices: [Choice]?
    }

    // MARK: Requests

    private func url(_ path: String) throws -> URL {
        let base = baseURL.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: base), url.host != nil else { throw APIError.invalidURL(baseURL) }
        return url.appendingPathComponent(path)
    }

    private func authorized(_ request: inout URLRequest) throws {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw APIError.missingAPIKey }
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("Companion", forHTTPHeaderField: "X-Title")
    }

    func makeListModelsRequest() throws -> URLRequest {
        var request = URLRequest(url: try url("models"), timeoutInterval: 30)
        try authorized(&request)
        return request
    }

    func makeGenerateRequest(model: String, systemPrompt: String, parts: [MediaPart]) throws -> URLRequest {
        var request = URLRequest(url: try url("chat/completions"), timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        try authorized(&request)

        // The content array mixes types, so it is built as JSON objects.
        var body: [String: Any] = [
            "model": model.trimmingCharacters(in: .whitespaces),
            "temperature": 0.4,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": parts.map(Self.contentPart)],
            ],
        ]
        if jsonMode {
            body["response_format"] = ["type": "json_object"]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    static func contentPart(_ part: MediaPart) -> [String: Any] {
        switch part {
        case .text(let text):
            return ["type": "text", "text": text]
        case .media(let mimeType, let data) where mimeType.hasPrefix("audio/"):
            // OpenRouter expects the bare format name, e.g. "wav".
            let format = String(mimeType.dropFirst("audio/".count))
            return ["type": "input_audio", "input_audio": ["data": data.base64EncodedString(), "format": format]]
        case .media(let mimeType, let data) where mimeType.hasPrefix("video/"):
            return ["type": "video_url", "video_url": ["url": dataURL(mimeType: mimeType, data: data)]]
        case .media(let mimeType, let data):
            return ["type": "image_url", "image_url": ["url": dataURL(mimeType: mimeType, data: data)]]
        }
    }

    private static func dataURL(mimeType: String, data: Data) -> String {
        "data:\(mimeType);base64,\(data.base64EncodedString())"
    }

    // MARK: Responses

    /// Keeps models that accept audio, since every batch contains audio chunks.
    static func parseModels(_ data: Data) throws -> [RemoteModel] {
        try JSONDecoder().decode(ModelList.self, from: data).data
            .filter { $0.architecture?.input_modalities?.contains("audio") ?? true }
            .map {
                RemoteModel(
                    id: $0.id,
                    displayName: $0.name ?? $0.id,
                    supportsJSONMode: $0.supported_parameters?.contains("response_format") ?? false
                )
            }
    }

    static func parseGenerateResponse(_ data: Data) throws -> String {
        let response = try JSONDecoder().decode(ChatResponse.self, from: data)
        guard let choice = response.choices?.first else { throw APIError.emptyResponse("no choices") }
        let text = (choice.message.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw APIError.emptyResponse(choice.finish_reason ?? "empty text") }
        return text
    }

    // MARK: MultimodalClient

    func listModels() async throws -> [RemoteModel] {
        let (data, response) = try await transport.send(try makeListModelsRequest())
        try APIClient.checkHTTP(response, data: data)
        return try Self.parseModels(data)
    }

    func generate(model: String, systemPrompt: String, parts: [MediaPart]) async throws -> String {
        let request = try makeGenerateRequest(model: model, systemPrompt: systemPrompt, parts: parts)
        let (data, response) = try await transport.send(request)
        try APIClient.checkHTTP(response, data: data)
        return try Self.parseGenerateResponse(data)
    }
}
