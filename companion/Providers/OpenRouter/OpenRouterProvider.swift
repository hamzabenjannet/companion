import Foundation

extension ProcessingProvider {
    /// Raw audio and video chunks are sent to an OpenRouter model.
    nonisolated static let openRouter = ProcessingProvider(id: "openRouter")
}

/// Registers OpenRouter with the app. See `OpenRouterClient` for the wire format.
nonisolated struct OpenRouterProvider: RemoteProviderDefinition {
    let provider = ProcessingProvider.openRouter
    let displayName = "OpenRouter"
    let defaultBaseURL = OpenRouterClient.defaultBaseURL
    let defaultModel = OpenRouterClient.defaultModel
    let capabilities: ProviderCapabilities = [.audioInput, .videoInput, .jsonMode]
    let storageKeys = ProviderStorageKeys(
        baseURL: "openRouterBaseURL",
        model: "openRouterModel",
        apiKeyAccount: "openrouter"
    )
    let settingsNote: String? = """
        Audio input needs at least $0.50 of OpenRouter credit, even on :free models. \
        Free models are limited to 20 requests/min and 50/day; use the request interval below to stay under them.
        """

    func makeClient(
        baseURL: String,
        apiKey: String,
        selectedModel: RemoteModel?,
        transport: any HTTPTransport
    ) -> any MultimodalClient {
        var client = OpenRouterClient(baseURL: baseURL, apiKey: apiKey, transport: transport)
        // Only models that list `response_format` accept JSON mode.
        client.jsonMode = selectedModel?.supportsJSONMode ?? false
        return client
    }
}
