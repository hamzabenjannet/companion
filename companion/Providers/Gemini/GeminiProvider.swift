import Foundation

extension ProcessingProvider {
    /// Raw audio and video chunks are sent to the Gemini API.
    nonisolated static let gemini = ProcessingProvider(id: "gemini")
}

/// Registers Google Gemini with the app. See `GeminiClient` for the wire format.
nonisolated struct GeminiProvider: RemoteProviderDefinition {
    let provider = ProcessingProvider.gemini
    let displayName = "Google Gemini"
    let defaultBaseURL = GeminiClient.defaultBaseURL
    let defaultModel = GeminiClient.defaultModel
    let capabilities: ProviderCapabilities = [.audioInput, .videoInput, .jsonMode]
    let storageKeys = ProviderStorageKeys(baseURL: "geminiBaseURL", model: "geminiModel", apiKeyAccount: "gemini")
    let settingsNote: String? = nil

    func makeClient(
        baseURL: String,
        apiKey: String,
        selectedModel: RemoteModel?,
        transport: any HTTPTransport
    ) -> any MultimodalClient {
        GeminiClient(baseURL: baseURL, apiKey: apiKey, transport: transport)
    }
}
