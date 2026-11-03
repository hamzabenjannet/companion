import Foundation

/// A model offered by a remote provider, shown in the model drop-down.
nonisolated struct RemoteModel: Identifiable, Hashable, Sendable {
    /// Identifier sent back to the API (e.g. `models/gemini-2.5-flash`).
    let id: String
    let displayName: String
    /// The provider reports that this model honours a JSON `response_format`.
    var supportsJSONMode: Bool = false
}

/// One piece of a multimodal prompt.
nonisolated enum MediaPart: Equatable, Sendable {
    case text(String)
    case media(mimeType: String, data: Data)
}

/// A provider that accepts text, audio and video in one request.
nonisolated protocol MultimodalClient: Sendable {
    func listModels() async throws -> [RemoteModel]
    /// Returns the model's raw text reply.
    func generate(model: String, systemPrompt: String, parts: [MediaPart]) async throws -> String
}
