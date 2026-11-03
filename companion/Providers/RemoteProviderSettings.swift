import Foundation
import Observation

/// Endpoint, model, API key and model list of one remote provider.
///
/// Endpoints and model names are stored in `UserDefaults`; the API key in the Keychain.
@Observable
final class RemoteProviderSettings {
    let definition: any RemoteProviderDefinition

    var baseURL: String {
        didSet { defaults.set(baseURL, forKey: definition.storageKeys.baseURL) }
    }
    var model: String {
        didSet { defaults.set(model, forKey: definition.storageKeys.model) }
    }
    var apiKey: String {
        didSet { saveAPIKey() }
    }
    /// Models fetched from the provider, for the drop-down.
    var models: [RemoteModel] = []

    /// True when the provider has everything it needs to send a request.
    var isReady: Bool {
        !apiKey.isEmpty && !model.isEmpty && !baseURL.isEmpty
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let keychain: KeychainStore
    /// Reports Keychain failures to the owner, which shows them in the settings form.
    @ObservationIgnored var onError: (String) -> Void = { _ in }

    init(definition: any RemoteProviderDefinition, defaults: UserDefaults, keychain: KeychainStore) {
        self.definition = definition
        self.defaults = defaults
        self.keychain = keychain
        let keys = definition.storageKeys
        baseURL = defaults.string(forKey: keys.baseURL) ?? definition.defaultBaseURL
        model = defaults.string(forKey: keys.model) ?? definition.defaultModel
        apiKey = keychain.read(account: keys.apiKeyAccount) ?? ""
    }

    func makeClient(transport: any HTTPTransport) -> any MultimodalClient {
        definition.makeClient(
            baseURL: baseURL,
            apiKey: apiKey,
            selectedModel: models.first { $0.id == model },
            transport: transport
        )
    }

    /// Replaces the model list and keeps the current selection if it is still
    /// offered (otherwise picks the first model).
    func update(models newModels: [RemoteModel]) {
        models = newModels
        if !newModels.contains(where: { $0.id == model }), let first = newModels.first {
            model = first.id
        }
    }

    private func saveAPIKey() {
        do {
            try keychain.write(
                apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
                account: definition.storageKeys.apiKeyAccount
            )
        } catch {
            onError(error.localizedDescription)
        }
    }
}
