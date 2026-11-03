import Foundation

/// Builds the instructions and attachments sent to multimodal providers.
nonisolated enum MultimodalPrompt {
    static let noResponseToken = PromptInstructions.noResponseToken

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
               Consecutive audio chunks from the same channel overlap by about one second, so a chunk may start with words already heard at the end of the previous chunk or transcript. Don't transcribe those words twice.
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
    static func preamble(context: [TranscriptLine], previousSuggestions: [String], hasMedia: Bool = true) -> String {
        let transcript = context.isEmpty
            ? "(nothing yet)"
            : context.map { "\($0.speakerLabel): \($0.text)" }.joined(separator: "\n")
        let previous = previousSuggestions.isEmpty
            ? "(none)"
            : previousSuggestions.map { "- \($0)" }.joined(separator: "\n")
        return """
            Transcript so far (most recent last):
            \(transcript)

            Your previous suggestions (do not repeat them):
            \(previous)

            \(hasMedia ? "New media chunks follow." : "No new media.")
            """
    }

    /// Sent after the preamble when the user typed a message instead of speaking.
    static let typedMessageNote = """
        The last "Me (typed)" line was typed by the user directly to you. Answer it in "suggestion" \
        (do not reply \(noResponseToken)) and leave "transcript" empty.
        """

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
