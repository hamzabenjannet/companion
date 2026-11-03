import Foundation
import Observation

/// User-editable configuration of the processing provider and the remote
/// providers' endpoints, models and API keys.
///
/// Endpoints and model names are stored in `UserDefaults`; API keys in the Keychain.
@Observable
final class ProviderConfiguration {
    enum Key {
        static let provider = "processingProvider"
        static let geminiBaseURL = "geminiBaseURL"
        static let geminiModel = "geminiModel"
        static let openRouterBaseURL = "openRouterBaseURL"
        static let openRouterModel = "openRouterModel"
        static let requestInterval = "remoteRequestInterval"
        static let geminiAPIKeyAccount = "gemini"
        static let openRouterAPIKeyAccount = "openrouter"
    }

    var provider: ProcessingProvider {
        didSet { defaults.set(provider.rawValue, forKey: Key.provider) }
    }

    var geminiBaseURL: String {
        didSet { defaults.set(geminiBaseURL, forKey: Key.geminiBaseURL) }
    }
    var geminiModel: String {
        didSet { defaults.set(geminiModel, forKey: Key.geminiModel) }
    }
    var geminiAPIKey: String {
        didSet { saveKey(geminiAPIKey, account: Key.geminiAPIKeyAccount) }
    }

    var openRouterBaseURL: String {
        didSet { defaults.set(openRouterBaseURL, forKey: Key.openRouterBaseURL) }
    }
    var openRouterModel: String {
        didSet { defaults.set(openRouterModel, forKey: Key.openRouterModel) }
    }
    var openRouterAPIKey: String {
        didSet { saveKey(openRouterAPIKey, account: Key.openRouterAPIKeyAccount) }
    }

    /// Minimum seconds between two remote requests. Chunks captured in the
    /// meantime are batched into the next request. Useful for rate-limited free tiers.
    var requestInterval: Double {
        didSet { defaults.set(requestInterval, forKey: Key.requestInterval) }
    }

    /// Models fetched from each provider, for the drop-down.
    private(set) var geminiModels: [RemoteModel] = []
    private(set) var openRouterModels: [RemoteModel] = []
    private(set) var isLoadingModels = false
    private(set) var lastError: String?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let keychain: KeychainStore
    @ObservationIgnored private let transport: any HTTPTransport

    init(
        defaults: UserDefaults = .standard,
        keychain: KeychainStore = KeychainStore(),
        transport: any HTTPTransport = URLSession.shared
    ) {
        self.defaults = defaults
        self.keychain = keychain
        self.transport = transport

        provider = defaults.string(forKey: Key.provider).flatMap(ProcessingProvider.init(rawValue:)) ?? .local
        geminiBaseURL = defaults.string(forKey: Key.geminiBaseURL) ?? GeminiClient.defaultBaseURL
        geminiModel = defaults.string(forKey: Key.geminiModel) ?? GeminiClient.defaultModel
        geminiAPIKey = keychain.read(account: Key.geminiAPIKeyAccount) ?? ""
        openRouterBaseURL = defaults.string(forKey: Key.openRouterBaseURL) ?? OpenRouterClient.defaultBaseURL
        openRouterModel = defaults.string(forKey: Key.openRouterModel) ?? OpenRouterClient.defaultModel
        openRouterAPIKey = keychain.read(account: Key.openRouterAPIKeyAccount) ?? ""
        requestInterval = defaults.object(forKey: Key.requestInterval) as? Double ?? 0
    }

    // MARK: Current provider

    /// Client for the given remote provider, or nil for `.local`.
    func client(for provider: ProcessingProvider) -> (any MultimodalClient)? {
        switch provider {
        case .local:
            return nil
        case .gemini:
            return GeminiClient(baseURL: geminiBaseURL, apiKey: geminiAPIKey, transport: transport)
        case .openRouter:
            var client = OpenRouterClient(baseURL: openRouterBaseURL, apiKey: openRouterAPIKey, transport: transport)
            client.jsonMode = openRouterModels.first { $0.id == openRouterModel }?.supportsJSONMode ?? false
            return client
        }
    }

    func selectedModel(for provider: ProcessingProvider) -> String {
        switch provider {
        case .local: return ""
        case .gemini: return geminiModel
        case .openRouter: return openRouterModel
        }
    }

    func models(for provider: ProcessingProvider) -> [RemoteModel] {
        switch provider {
        case .local: return []
        case .gemini: return geminiModels
        case .openRouter: return openRouterModels
        }
    }

    /// True when the selected provider has everything it needs to start.
    var isReady: Bool {
        switch provider {
        case .local:
            return true
        case .gemini:
            return !geminiAPIKey.isEmpty && !geminiModel.isEmpty && !geminiBaseURL.isEmpty
        case .openRouter:
            return !openRouterAPIKey.isEmpty && !openRouterModel.isEmpty && !openRouterBaseURL.isEmpty
        }
    }

    // MARK: Model list

    /// Fetches the model list for the selected provider and keeps the current
    /// selection if it is still offered (otherwise picks the first model).
    func refreshModels() async {
        let provider = provider
        guard let client = client(for: provider) else { return }

        isLoadingModels = true
        lastError = nil
        defer { isLoadingModels = false }

        do {
            let models = try await client.listModels()
                .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
            switch provider {
            case .local:
                break
            case .gemini:
                geminiModels = models
                if !models.contains(where: { $0.id == geminiModel }), let first = models.first {
                    geminiModel = first.id
                }
            case .openRouter:
                openRouterModels = models
                if !models.contains(where: { $0.id == openRouterModel }), let first = models.first {
                    openRouterModel = first.id
                }
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func saveKey(_ value: String, account: String) {
        do {
            try keychain.write(value.trimmingCharacters(in: .whitespacesAndNewlines), account: account)
        } catch {
            lastError = error.localizedDescription
        }
    }
}
