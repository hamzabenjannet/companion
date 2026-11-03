import Foundation

/// Composition root: creates the app's long-lived objects once and wires them
/// together. Views receive what they need from here instead of building it.
final class AppEnvironment {
    let settings: AppSettings
    let providers: ProviderConfiguration
    let assistant: MeetingAssistant
    let requestLog: RequestLog
    let tools: ToolRegistry
    private let throttle = RequestThrottle()

    init(defaults: UserDefaults = .standard, keychain: KeychainStore = KeychainStore()) {
        // Every API call goes through one logging transport so the debug section can show it.
        let requestLog = RequestLog()
        let transport = LoggingTransport(base: URLSession.shared, log: requestLog)

        self.requestLog = requestLog
        settings = AppSettings(defaults: defaults)
        providers = ProviderConfiguration(defaults: defaults, keychain: keychain, transport: transport)
        assistant = MeetingAssistant()
        tools = ToolRegistry()
    }

    /// A processor for the current provider and settings. Call it when the user
    /// starts recording, sends a message, or tests the connection.
    func makeProcessor() -> any ChunkProcessor {
        assistant.customInstructions = settings.customInstructions
        return ProcessorFactory.makeProcessor(providers: providers, settings: settings, throttle: throttle)
    }
}
