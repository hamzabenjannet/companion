import Foundation

/// How captured media is turned into transcript lines and suggestions.
nonisolated enum ProcessingProvider: String, CaseIterable, Identifiable, Sendable {
    /// Whisper for speech-to-text, then Ollama for suggestions. Screen chunks are not used.
    case local
    /// Raw audio and video chunks are sent to the Gemini API.
    case gemini
    /// Raw audio and video chunks are sent to an OpenRouter model.
    case openRouter

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .local: return "Local (Whisper + Ollama)"
        case .gemini: return "Google Gemini"
        case .openRouter: return "OpenRouter"
        }
    }

    var isRemote: Bool { self != .local }
}

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

// MARK: - Reply

/// The structured reply the remote model is asked to produce for each batch.
nonisolated struct MultimodalReply: Decodable, Equatable, Sendable {
    struct Line: Decodable, Equatable, Sendable {
        let speaker: String
        let text: String

        /// Maps the model's speaker label back to a capture channel.
        var source: CaptureSource {
            switch speaker.trimmingCharacters(in: .whitespaces).lowercased() {
            case "me": return .microphone
            case "screen": return .screen
            default: return .system
            }
        }
    }

    let transcript: [Line]
    let suggestion: String

    private enum CodingKeys: String, CodingKey {
        case transcript
        case suggestion
    }

    init(transcript: [Line], suggestion: String) {
        self.transcript = transcript
        self.suggestion = suggestion
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        transcript = try container.decodeIfPresent([Line].self, forKey: .transcript) ?? []
        suggestion = try container.decodeIfPresent(String.self, forKey: .suggestion) ?? ""
    }

    /// Parses the model's text, tolerating Markdown code fences or prose around the JSON object.
    static func parse(_ text: String) throws -> MultimodalReply {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else {
            throw APIError.invalidReply(text)
        }
        let json = Data(text[start...end].utf8)
        do {
            return try JSONDecoder().decode(MultimodalReply.self, from: json)
        } catch {
            throw APIError.invalidReply(text)
        }
    }
}

// MARK: - Prompt

/// Builds the instructions and attachments sent to multimodal providers.
nonisolated enum MultimodalPrompt {
    static let noResponseToken = "NO_RESPONSE"

    static func systemPrompt(language: String) -> String {
        let trimmed = language.trimmingCharacters(in: .whitespaces)
        let languageHint = trimmed.isEmpty
            ? ""
            : "\nThe conversation is expected to be in language code \"\(trimmed)\"."
        return """
            You are a discreet real-time meeting companion for the user ("Me").
            Each request contains the recent transcript plus new raw media chunks, in chronological order:
            - "Me" audio is the user's microphone.
            - "Others" audio is the computer's output (the remote participants).
            - "Screen" video is a low-frame-rate recording of the user's screen (slides, shared documents, chat).

            Tasks:
            1. Transcribe the speech in each new audio chunk verbatim. Label it "Me" or "Others" according to the chunk it came from. Skip silence and noise; never invent speech.
            2. Using the transcript and what is visible on screen, decide whether the user needs help:
               - If someone asks a question (especially "Others" asking "Me"), give a concise, accurate answer the user can say.
               - If a claim, decision, or something on screen would benefit from a quick fact, opinion, or follow-up question, give one short, useful insight.
               - Keep it under 80 words. Use bullet points when listing. Reply in the language of the conversation.
               - If there is nothing useful to add, set "suggestion" to exactly \(noResponseToken).\(languageHint)

            Reply with only a JSON object:
            {"transcript": [{"speaker": "Me" | "Others", "text": "..."}], "suggestion": "..."}
            """
    }

    /// Text that introduces the new media: recent transcript and earlier suggestions.
    static func preamble(context: [TranscriptLine], previousSuggestions: [String]) -> String {
        let transcript = context.isEmpty
            ? "(nothing yet)"
            : context.map { "\($0.source.speakerLabel): \($0.text)" }.joined(separator: "\n")
        let previous = previousSuggestions.isEmpty
            ? "(none)"
            : previousSuggestions.map { "- \($0)" }.joined(separator: "\n")
        return """
            Transcript so far (most recent last):
            \(transcript)

            Your previous suggestions (do not repeat them):
            \(previous)

            New media chunks follow.
            """
    }

    /// Label placed before each attachment so the model knows its channel and timing.
    static func label(for chunk: MediaChunk) -> String {
        let kind = chunk.isVideo ? "video" : "audio"
        let time = chunk.createdAt.formatted(date: .omitted, time: .standard)
        return "[\(chunk.source.speakerLabel) — \(chunk.source.channelName) \(kind), \(Int(chunk.duration.rounded())) s, ended \(time)]"
    }

    /// Full list of parts for a batch: preamble, then a label + payload per chunk.
    static func parts(
        for chunks: [MediaChunk],
        context: [TranscriptLine],
        previousSuggestions: [String]
    ) throws -> [MediaPart] {
        var parts: [MediaPart] = [.text(preamble(context: context, previousSuggestions: previousSuggestions))]
        for chunk in chunks {
            parts.append(.text(label(for: chunk)))
            parts.append(.media(mimeType: chunk.mimeType, data: try Data(contentsOf: chunk.url)))
        }
        return parts
    }
}
