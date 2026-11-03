import Foundation

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
