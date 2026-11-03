import Foundation

/// What a provider's client implementation supports. The pipeline and UI check
/// these flags instead of switching on specific providers.
nonisolated struct ProviderCapabilities: OptionSet, Sendable {
    let rawValue: Int

    /// Accepts raw audio chunks.
    static let audioInput = ProviderCapabilities(rawValue: 1 << 0)
    /// Accepts video chunks (screen recordings).
    static let videoInput = ProviderCapabilities(rawValue: 1 << 1)
    /// Can be asked for a JSON-only reply.
    static let jsonMode = ProviderCapabilities(rawValue: 1 << 2)
    /// The client can send tool definitions and return tool calls (see `Tools/`).
    /// No client implements this yet; see `roadmap.md`.
    static let toolCalling = ProviderCapabilities(rawValue: 1 << 3)
}

/// Keys under which a provider's settings are persisted. Keep them stable so
/// saved settings survive upgrades.
nonisolated struct ProviderStorageKeys: Sendable {
    /// `UserDefaults` key for the endpoint.
    let baseURL: String
    /// `UserDefaults` key for the selected model.
    let model: String
    /// Keychain account for the API key.
    let apiKeyAccount: String
}

/// Everything the app needs to know about one remote multimodal provider.
///
/// To add a provider: implement `MultimodalClient`, add a type conforming to
/// this protocol, and append it to `ProviderRegistry.remoteProviders`.
/// The settings form, mode picker and pipeline pick it up from there.
nonisolated protocol RemoteProviderDefinition: Sendable {
    var provider: ProcessingProvider { get }
    var displayName: String { get }
    var defaultBaseURL: String { get }
    var defaultModel: String { get }
    var capabilities: ProviderCapabilities { get }
    var storageKeys: ProviderStorageKeys { get }
    /// Shown under the provider's settings (pricing, rate limits); nil for none.
    var settingsNote: String? { get }

    /// Builds a client for the current settings. `selectedModel` is the entry from
    /// the provider's model list, when it has been loaded.
    func makeClient(
        baseURL: String,
        apiKey: String,
        selectedModel: RemoteModel?,
        transport: any HTTPTransport
    ) -> any MultimodalClient
}

/// The list of remote providers the app offers, in menu order.
nonisolated enum ProviderRegistry {
    static let remoteProviders: [any RemoteProviderDefinition] = [
        GeminiProvider(),
        OpenRouterProvider(),
    ]

    static func definition(for provider: ProcessingProvider) -> (any RemoteProviderDefinition)? {
        remoteProviders.first { $0.provider == provider }
    }
}
