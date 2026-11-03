import Foundation
import Observation

/// Which provider processes captured media, plus the settings of every remote
/// provider in `ProviderRegistry`.
@Observable
final class ProviderConfiguration {
    enum Key {
        static let provider = "processingProvider"
        static let requestInterval = "remoteRequestInterval"
    }

    var provider: ProcessingProvider {
        didSet { defaults.set(provider.rawValue, forKey: Key.provider) }
    }

    /// Minimum seconds between two remote requests. Chunks captured in the
    /// meantime are batched into the next request. Useful for rate-limited free tiers.
    var requestInterval: Double {
        didSet { defaults.set(requestInterval, forKey: Key.requestInterval) }
    }

    private(set) var isLoadingModels = false
    private(set) var lastError: String?

    /// One entry per registered remote provider.
    @ObservationIgnored private let remoteSettings: [ProcessingProvider: RemoteProviderSettings]
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored let transport: any HTTPTransport

    init(
        defaults: UserDefaults = .standard,
        keychain: KeychainStore = KeychainStore(),
        transport: any HTTPTransport = URLSession.shared
    ) {
        self.defaults = defaults
        self.transport = transport
        provider = defaults.string(forKey: Key.provider).flatMap(ProcessingProvider.init(rawValue:)) ?? .local
        requestInterval = defaults.object(forKey: Key.requestInterval) as? Double ?? 0
        remoteSettings = Dictionary(uniqueKeysWithValues: ProviderRegistry.remoteProviders.map {
            ($0.provider, RemoteProviderSettings(definition: $0, defaults: defaults, keychain: keychain))
        })
        for settings in remoteSettings.values {
            settings.onError = { [weak self] in self?.lastError = $0 }
        }
    }

    // MARK: Per provider

    /// Settings of a remote provider, or nil for `.local`.
    func settings(for provider: ProcessingProvider) -> RemoteProviderSettings? {
        remoteSettings[provider]
    }

    /// Client for the given remote provider, or nil for `.local`.
    func client(for provider: ProcessingProvider) -> (any MultimodalClient)? {
        settings(for: provider)?.makeClient(transport: transport)
    }

    func selectedModel(for provider: ProcessingProvider) -> String {
        settings(for: provider)?.model ?? ""
    }

    func models(for provider: ProcessingProvider) -> [RemoteModel] {
        settings(for: provider)?.models ?? []
    }

    /// True when the selected provider has everything it needs to start.
    var isReady: Bool {
        settings(for: provider)?.isReady ?? true
    }

    // MARK: Model list

    /// Fetches the model list for the selected provider and keeps the current
    /// selection if it is still offered (otherwise picks the first model).
    func refreshModels() async {
        guard let settings = settings(for: provider) else { return }

        isLoadingModels = true
        lastError = nil
        defer { isLoadingModels = false }

        do {
            let models = try await settings.makeClient(transport: transport).listModels()
                .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
            settings.update(models: models)
        } catch {
            lastError = error.localizedDescription
        }
    }
}
