import Foundation

/// Google Gemini API (Generative Language API) over REST.
///
/// - Model list: `GET {host}/v1beta/models`
/// - Generation: `POST {host}/v1beta/{model}:generateContent` with audio/video as inline data.
nonisolated struct GeminiClient: MultimodalClient {
    static let defaultBaseURL = "https://generativelanguage.googleapis.com"
    /// `gemini-2.5-flash` is still listed but returns 404 for new API keys.
    static let defaultModel = "models/gemini-3.8-flash"

    let baseURL: String
    let apiKey: String
    var transport: any HTTPTransport = URLSession.shared

    // MARK: Wire types

    struct ModelList: Decodable {
        struct Model: Decodable {
            let name: String
            let displayName: String?
            let supportedGenerationMethods: [String]?
        }

        let models: [Model]?
        let nextPageToken: String?
    }

    struct GenerateRequest: Encodable {
        let systemInstruction: Content?
        let contents: [Content]
        let generationConfig: GenerationConfig
    }

    struct Content: Codable {
        let role: String?
        let parts: [Part]
    }

    struct Part: Codable {
        var text: String?
        var inlineData: InlineData?
        /// True for "thinking" summaries, which are not part of the answer.
        var thought: Bool?
    }

    struct InlineData: Codable {
        let mimeType: String
        let data: String
    }

    struct GenerationConfig: Encodable {
        let responseMimeType: String
        let temperature: Double
    }

    struct GenerateResponse: Decodable {
        struct Candidate: Decodable {
            let content: Content?
            let finishReason: String?
        }

        struct PromptFeedback: Decodable {
            let blockReason: String?
        }

        let candidates: [Candidate]?
        let promptFeedback: PromptFeedback?
    }

    // MARK: Requests

    /// Ensures the model id has the `models/` prefix the REST paths expect.
    static func normalizedModel(_ model: String) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("models/") ? trimmed : "models/\(trimmed)"
    }

    private func url(path: String, query: [URLQueryItem] = []) throws -> URL {
        let base = baseURL.trimmingCharacters(in: .whitespaces)
        guard var components = URLComponents(string: base), components.host != nil else {
            throw APIError.invalidURL(baseURL)
        }
        let prefix = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.path = prefix + path
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw APIError.invalidURL(baseURL) }
        return url
    }

    private func authorized(_ request: inout URLRequest) throws {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw APIError.missingAPIKey }
        // Sent as a header rather than `?key=` so it never ends up in logged URLs.
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
    }

    func makeListModelsRequest(pageToken: String?) throws -> URLRequest {
        var query = [URLQueryItem(name: "pageSize", value: "1000")]
        if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
        var request = URLRequest(url: try url(path: "/v1beta/models", query: query), timeoutInterval: 30)
        try authorized(&request)
        return request
    }

    func makeGenerateRequest(model: String, systemPrompt: String, parts: [MediaPart]) throws -> URLRequest {
        let path = "/v1beta/\(Self.normalizedModel(model)):generateContent"
        var request = URLRequest(url: try url(path: path), timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        try authorized(&request)

        let body = GenerateRequest(
            systemInstruction: Content(role: nil, parts: [Part(text: systemPrompt)]),
            contents: [Content(role: "user", parts: parts.map(Self.part))],
            generationConfig: GenerationConfig(responseMimeType: "application/json", temperature: 0.4)
        )
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    static func part(_ part: MediaPart) -> Part {
        switch part {
        case .text(let text):
            return Part(text: text)
        case .media(let mimeType, let data):
            return Part(inlineData: InlineData(mimeType: mimeType, data: data.base64EncodedString()))
        }
    }

    // MARK: Responses

    /// Keeps only models that can be used with `generateContent`.
    static func parseModels(_ data: Data) throws -> (models: [RemoteModel], nextPageToken: String?) {
        let list = try JSONDecoder().decode(ModelList.self, from: data)
        let models = (list.models ?? [])
            .filter { $0.supportedGenerationMethods?.contains("generateContent") ?? false }
            .map { RemoteModel(id: $0.name, displayName: $0.displayName ?? $0.name) }
        let token = list.nextPageToken.flatMap { $0.isEmpty ? nil : $0 }
        return (models, token)
    }

    /// Joins the text parts of the first candidate, skipping thinking parts.
    static func parseGenerateResponse(_ data: Data) throws -> String {
        let response = try JSONDecoder().decode(GenerateResponse.self, from: data)
        if let reason = response.promptFeedback?.blockReason {
            throw APIError.emptyResponse("blocked: \(reason)")
        }
        guard let candidate = response.candidates?.first else {
            throw APIError.emptyResponse("no candidates")
        }
        let text = (candidate.content?.parts ?? [])
            .filter { $0.thought != true }
            .compactMap(\.text)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw APIError.emptyResponse(candidate.finishReason ?? "empty text")
        }
        return text
    }

    // MARK: MultimodalClient

    func listModels() async throws -> [RemoteModel] {
        var all: [RemoteModel] = []
        var token: String?
        // Follow `nextPageToken`, with a hard cap in case the server keeps returning one.
        for _ in 0..<20 {
            let (data, response) = try await transport.send(try makeListModelsRequest(pageToken: token))
            try LocalBackendClient.checkHTTP(response, data: data)
            let page = try Self.parseModels(data)
            all.append(contentsOf: page.models)
            guard let next = page.nextPageToken else { break }
            token = next
        }
        return all
    }

    func generate(model: String, systemPrompt: String, parts: [MediaPart]) async throws -> String {
        let request = try makeGenerateRequest(model: model, systemPrompt: systemPrompt, parts: parts)
        let (data, response) = try await transport.send(request)
        try LocalBackendClient.checkHTTP(response, data: data)
        return try Self.parseGenerateResponse(data)
    }
}
