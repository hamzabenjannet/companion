import Foundation

/// Identifies where captured media is processed: the built-in local backend
/// (Whisper + Ollama) or one of the remote providers in `ProviderRegistry`.
///
/// The raw value is persisted in `UserDefaults`, so keep existing values stable.
nonisolated struct ProcessingProvider: RawRepresentable, Hashable, Identifiable, Sendable {
    let rawValue: String

    /// Whisper for speech-to-text, then Ollama for suggestions. Screen chunks are not used.
    static let local = ProcessingProvider(id: "local")

    /// Creates an identifier for a provider definition. Use this only when declaring
    /// a new provider; decode stored values with `init?(rawValue:)`.
    init(id: String) {
        rawValue = id
    }

    /// Returns nil for values that no registered provider uses.
    init?(rawValue: String) {
        guard Self.allCases.contains(where: { $0.rawValue == rawValue }) else { return nil }
        self.rawValue = rawValue
    }

    var id: String { rawValue }

    var isRemote: Bool { self != .local }

    var displayName: String {
        guard isRemote else { return "Local (Whisper + Ollama)" }
        return ProviderRegistry.definition(for: self)?.displayName ?? rawValue
    }

    /// Local first, then every registered remote provider in registry order.
    static var allCases: [ProcessingProvider] {
        [.local] + ProviderRegistry.remoteProviders.map(\.provider)
    }
}
