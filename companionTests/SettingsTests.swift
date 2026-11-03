import Foundation
import Testing
@testable import companion

@Suite("Keychain store")
struct KeychainStoreTests {
    private let store = KeychainStore(service: "companion.tests.\(UUID().uuidString)")

    @Test func readMissingReturnsNil() {
        #expect(store.read(account: "missing") == nil)
    }

    @Test func writeReadUpdateDelete() throws {
        defer { try? store.delete(account: "gemini") }

        try store.write("first", account: "gemini")
        #expect(store.read(account: "gemini") == "first")

        try store.write("second", account: "gemini")
        #expect(store.read(account: "gemini") == "second")

        try store.delete(account: "gemini")
        #expect(store.read(account: "gemini") == nil)
    }

    @Test func writingEmptyValueDeletes() throws {
        try store.write("value", account: "openrouter")
        try store.write("", account: "openrouter")
        #expect(store.read(account: "openrouter") == nil)
    }

    @Test func deletingMissingItemSucceeds() throws {
        try store.delete(account: "never-written")
    }

    @Test func errorDescription() {
        #expect(KeychainStore.KeychainError.status(-25300).errorDescription?.contains("-25300") == true)
    }
}

@MainActor
@Suite("Provider configuration")
struct ProviderConfigurationTests {
    private let defaults: UserDefaults
    private let keychain = KeychainStore(service: "companion.tests.\(UUID().uuidString)")

    init() throws {
        defaults = try #require(UserDefaults(suiteName: "companion.tests.\(UUID().uuidString)"))
    }

    private func cleanUpKeys() {
        try? keychain.delete(account: ProviderConfiguration.Key.geminiAPIKeyAccount)
        try? keychain.delete(account: ProviderConfiguration.Key.openRouterAPIKeyAccount)
    }

    @Test func defaultsWhenNothingIsStored() {
        let config = ProviderConfiguration(defaults: defaults, keychain: keychain)
        #expect(config.provider == .local)
        #expect(config.geminiBaseURL == "https://generativelanguage.googleapis.com")
        #expect(config.geminiModel == GeminiClient.defaultModel)
        #expect(config.geminiAPIKey.isEmpty)
        #expect(config.openRouterBaseURL == OpenRouterClient.defaultBaseURL)
        #expect(config.openRouterModel == OpenRouterClient.defaultModel)
        #expect(config.isReady)
    }

    @Test func persistsSettingsAndKeys() {
        defer { cleanUpKeys() }
        let config = ProviderConfiguration(defaults: defaults, keychain: keychain)
        config.provider = .gemini
        config.geminiBaseURL = "https://example.com"
        config.geminiModel = "models/gemini-2.5-pro"
        config.geminiAPIKey = "  secret-gemini \n"
        config.openRouterModel = "openai/gpt-audio"
        config.openRouterAPIKey = "secret-or"

        // Keys go to the Keychain (trimmed), never to UserDefaults.
        #expect(keychain.read(account: "gemini") == "secret-gemini")
        #expect(keychain.read(account: "openrouter") == "secret-or")
        #expect(!defaults.dictionaryRepresentation().values.contains { ($0 as? String)?.contains("secret") == true })

        let reloaded = ProviderConfiguration(defaults: defaults, keychain: keychain)
        #expect(reloaded.provider == .gemini)
        #expect(reloaded.geminiBaseURL == "https://example.com")
        #expect(reloaded.geminiModel == "models/gemini-2.5-pro")
        #expect(reloaded.geminiAPIKey == "secret-gemini")
        #expect(reloaded.openRouterModel == "openai/gpt-audio")
        #expect(reloaded.openRouterAPIKey == "secret-or")
    }

    @Test func readinessRequiresKeyAndModel() {
        defer { cleanUpKeys() }
        let config = ProviderConfiguration(defaults: defaults, keychain: keychain)

        config.provider = .gemini
        #expect(!config.isReady)
        config.geminiAPIKey = "k"
        #expect(config.isReady)
        config.geminiModel = ""
        #expect(!config.isReady)

        config.provider = .openRouter
        #expect(!config.isReady)
        config.openRouterAPIKey = "k"
        #expect(config.isReady)
    }

    @Test func requestIntervalDefaultsToZeroAndPersists() {
        let config = ProviderConfiguration(defaults: defaults, keychain: keychain)
        #expect(config.requestInterval == 0)

        config.requestInterval = 30

        #expect(ProviderConfiguration(defaults: defaults, keychain: keychain).requestInterval == 30)
    }

    @Test func openRouterJSONModeFollowsSelectedModel() async throws {
        defer { cleanUpKeys() }
        let transport = MockTransport(json: """
            {"data": [
              {"id": "a/json", "name": "A", "supported_parameters": ["response_format"]},
              {"id": "b/plain", "name": "B", "supported_parameters": ["temperature"]}
            ]}
            """)
        let config = ProviderConfiguration(defaults: defaults, keychain: keychain, transport: transport)
        config.provider = .openRouter
        config.openRouterAPIKey = "k"
        await config.refreshModels()

        config.openRouterModel = "a/json"
        #expect(try #require(config.client(for: .openRouter) as? OpenRouterClient).jsonMode)

        config.openRouterModel = "b/plain"
        #expect(try #require(config.client(for: .openRouter) as? OpenRouterClient).jsonMode == false)
    }

    @Test func clientsAndSelectedModels() {
        let config = ProviderConfiguration(defaults: defaults, keychain: keychain)
        #expect(config.client(for: .local) == nil)
        #expect(config.client(for: .gemini) is GeminiClient)
        #expect(config.client(for: .openRouter) is OpenRouterClient)
        #expect(config.selectedModel(for: .local).isEmpty)
        #expect(config.selectedModel(for: .gemini) == config.geminiModel)
        #expect(config.selectedModel(for: .openRouter) == config.openRouterModel)
        #expect(config.models(for: .local).isEmpty)
    }

    @Test func refreshModelsSortsAndKeepsSelection() async {
        defer { cleanUpKeys() }
        let transport = MockTransport(json: """
            {"models": [
              {"name": "models/gemini-2.5-pro", "displayName": "Gemini 2.5 Pro", "supportedGenerationMethods": ["generateContent"]},
              {"name": "models/gemini-2.5-flash", "displayName": "Gemini 2.5 Flash", "supportedGenerationMethods": ["generateContent"]}
            ]}
            """)
        let config = ProviderConfiguration(defaults: defaults, keychain: keychain, transport: transport)
        config.provider = .gemini
        config.geminiAPIKey = "k"
        config.geminiModel = "models/gemini-2.5-pro"

        await config.refreshModels()

        #expect(config.models(for: .gemini).map(\.displayName) == ["Gemini 2.5 Flash", "Gemini 2.5 Pro"])
        #expect(config.geminiModel == "models/gemini-2.5-pro")
        #expect(config.lastError == nil)
        #expect(!config.isLoadingModels)
    }

    @Test func refreshModelsReplacesUnavailableSelection() async {
        defer { cleanUpKeys() }
        let transport = MockTransport(json: #"{"data": [{"id": "z/model", "name": "Z"}, {"id": "a/model", "name": "A"}]}"#)
        let config = ProviderConfiguration(defaults: defaults, keychain: keychain, transport: transport)
        config.provider = .openRouter
        config.openRouterAPIKey = "k"
        config.openRouterModel = "removed/model"

        await config.refreshModels()

        #expect(config.openRouterModels.map(\.id) == ["a/model", "z/model"])
        #expect(config.openRouterModel == "a/model")
    }

    @Test func refreshModelsReportsErrors() async {
        let config = ProviderConfiguration(defaults: defaults, keychain: keychain, transport: MockTransport(json: "{}"))
        config.provider = .gemini

        await config.refreshModels()

        #expect(config.lastError == APIError.missingAPIKey.errorDescription)
        #expect(config.geminiModels.isEmpty)
    }

    @Test func refreshModelsDoesNothingForLocal() async {
        let transport = MockTransport(json: "{}")
        let config = ProviderConfiguration(defaults: defaults, keychain: keychain, transport: transport)

        await config.refreshModels()

        #expect(transport.requests.isEmpty)
        #expect(config.lastError == nil)
    }
}
