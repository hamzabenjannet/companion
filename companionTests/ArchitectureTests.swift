import Foundation
import Testing
@testable import companion

@Suite("Provider registry")
struct ProviderRegistryTests {
    @Test func everyRemoteProviderIsRegisteredOnce() {
        let ids = ProviderRegistry.remoteProviders.map(\.provider.rawValue)
        #expect(ids == ["gemini", "openRouter"])
        #expect(Set(ids).count == ids.count)
    }

    @Test func storageKeysAreUniqueAndStable() {
        let keys = ProviderRegistry.remoteProviders.map(\.storageKeys)
        #expect(keys.map(\.apiKeyAccount) == ["gemini", "openrouter"])
        let defaultsKeys = keys.flatMap { [$0.baseURL, $0.model] }
        #expect(Set(defaultsKeys).count == defaultsKeys.count)
    }

    @Test func unknownRawValueIsRejected() {
        #expect(ProcessingProvider(rawValue: "unknown") == nil)
        #expect(ProviderRegistry.definition(for: .local) == nil)
    }

    @Test func noProviderClaimsToolCallingYet() {
        #expect(ProviderRegistry.remoteProviders.allSatisfy { !$0.capabilities.contains(.toolCalling) })
    }

    @Test func openRouterJSONModeFollowsSelectedModel() throws {
        let definition = OpenRouterProvider()
        let withJSON = definition.makeClient(
            baseURL: "https://x", apiKey: "k",
            selectedModel: RemoteModel(id: "a", displayName: "A", supportsJSONMode: true),
            transport: MockTransport(json: "{}")
        )
        let withoutModel = definition.makeClient(baseURL: "https://x", apiKey: "k", selectedModel: nil, transport: MockTransport(json: "{}"))
        #expect(try #require(withJSON as? OpenRouterClient).jsonMode)
        #expect(try #require(withoutModel as? OpenRouterClient).jsonMode == false)
    }
}

@MainActor
@Suite("App settings")
struct AppSettingsTests {
    private let defaults: UserDefaults

    init() throws {
        defaults = try #require(UserDefaults(suiteName: "companion.tests.\(UUID().uuidString)"))
    }

    @Test func defaultsWhenNothingIsStored() {
        let settings = AppSettings(defaults: defaults)
        #expect(settings.whisperBaseURL == "http://localhost:42940")
        #expect(settings.ollamaBaseURL == "http://localhost:11434")
        #expect(settings.ollamaModel == "qwen2.5:3b")
        #expect(settings.language.isEmpty)
        #expect(settings.chunkSeconds == 8)
        #expect(settings.captureOptions == CaptureOptions(microphone: true, systemAudio: true, screen: false, chunkDuration: 8))
        #expect(settings.customInstructions.isEmpty)
    }

    @Test func persistsChanges() {
        let settings = AppSettings(defaults: defaults)
        settings.language = "fr"
        settings.chunkSeconds = 5
        settings.captureMicrophone = false
        settings.captureScreen = true
        settings.customInstructions = "Be brief."

        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.language == "fr")
        #expect(reloaded.localBackend.language == "fr")
        #expect(reloaded.captureOptions == CaptureOptions(microphone: false, systemAudio: true, screen: true, chunkDuration: 5))
        #expect(reloaded.customInstructions == "Be brief.")
    }

    @Test func captureOptionsNeedAtLeastOneChannel() {
        #expect(!CaptureOptions(microphone: false, systemAudio: false, screen: false, chunkDuration: 8).hasInput)
        #expect(CaptureOptions(microphone: false, systemAudio: false, screen: true, chunkDuration: 8).hasInput)
    }
}

@MainActor
@Suite("Processor factory")
struct ProcessorFactoryTests {
    private let defaults: UserDefaults
    private let keychain = KeychainStore(service: "companion.tests.\(UUID().uuidString)")

    init() throws {
        defaults = try #require(UserDefaults(suiteName: "companion.tests.\(UUID().uuidString)"))
    }

    @Test func localProviderMakesLocalProcessor() {
        let providers = ProviderConfiguration(defaults: defaults, keychain: keychain, transport: MockTransport(json: "{}"))
        let processor = ProcessorFactory.makeProcessor(
            providers: providers,
            settings: AppSettings(defaults: defaults),
            throttle: RequestThrottle()
        )
        #expect(processor is LocalChunkProcessor)
        #expect(!processor.acceptsVideo)
    }

    @Test func remoteProviderMakesRemoteProcessorAndSetsInterval() {
        let providers = ProviderConfiguration(defaults: defaults, keychain: keychain, transport: MockTransport(json: "{}"))
        providers.provider = .gemini
        providers.requestInterval = 15
        let throttle = RequestThrottle()

        let processor = ProcessorFactory.makeProcessor(providers: providers, settings: AppSettings(defaults: defaults), throttle: throttle)

        #expect(processor is RemoteChunkProcessor)
        #expect(processor.displayName == "Google Gemini")
        #expect(processor.acceptsVideo)
        #expect(throttle.minInterval == 15)
    }
}

@MainActor
@Suite("Tool registry")
struct ToolRegistryTests {
    private struct EchoTool: AssistantTool {
        let definition = ToolDefinition(
            name: "echo",
            description: "Returns its arguments.",
            parametersSchema: #"{"type": "object"}"#
        )

        func invoke(arguments: Data) async throws -> String {
            String(decoding: arguments, as: UTF8.self)
        }
    }

    @Test func registersAndInvokesTools() async throws {
        let registry = ToolRegistry()
        try registry.register(EchoTool())

        #expect(registry.definitions.map(\.name) == ["echo"])
        #expect(try await registry.invoke("echo", arguments: Data(#"{"a":1}"#.utf8)) == #"{"a":1}"#)
    }

    @Test func rejectsDuplicatesAndUnknownTools() async throws {
        let registry = ToolRegistry()
        try registry.register(EchoTool())

        #expect(throws: ToolError.duplicateTool("echo")) { try registry.register(EchoTool()) }
        await #expect(throws: ToolError.unknownTool("missing")) {
            try await registry.invoke("missing", arguments: Data())
        }

        registry.unregister(named: "echo")
        #expect(registry.tools.isEmpty)
    }
}
