import Foundation

/// Builds the `ChunkProcessor` for the provider the user selected.
enum ProcessorFactory {
    static func makeProcessor(
        providers: ProviderConfiguration,
        settings: AppSettings,
        throttle: RequestThrottle
    ) -> any ChunkProcessor {
        let provider = providers.provider
        guard let remote = providers.settings(for: provider) else {
            return LocalChunkProcessor(settings: settings.localBackend, transport: providers.transport)
        }

        throttle.minInterval = providers.requestInterval
        return RemoteChunkProcessor(
            client: remote.makeClient(transport: providers.transport),
            model: remote.model,
            language: settings.language,
            providerName: remote.definition.displayName,
            capabilities: remote.definition.capabilities,
            throttle: throttle
        )
    }
}
