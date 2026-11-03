import Foundation

/// Prompt text shared by every processor.
nonisolated enum PromptInstructions {
    /// Sentinel the model returns when there is nothing worth saying.
    static let noResponseToken = "NO_RESPONSE"

    /// Prompt for the "Test" buttons in Settings.
    static let connectivityCheck = "Reply with one short sentence: are you online?"

    /// Appends the user's instructions to a built-in prompt; empty instructions change nothing.
    static func appending(_ instructions: String, to basePrompt: String) -> String {
        let trimmed = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return basePrompt }
        return """
            \(basePrompt)

            Additional instructions from the user (follow them unless they conflict with the reply format above):
            \(trimmed)
            """
    }

    /// System prompt for the local Ollama model, which only sees the transcript.
    static let localSystemPrompt = """
        You are a discreet real-time meeting companion for the user ("Me").
        The transcript comes from automatic speech recognition and may contain errors or cut-off sentences.
        "Others" are the remote participants; "Me" is the user. "Me (typed)" lines were typed by the user directly to you; always answer those.

        Focus on the newest lines:
        - If someone asks a question (especially "Others" asking "Me"), give the user a concise, accurate answer they can say.
        - If a factual claim, decision or topic would benefit from a quick fact, opinion or follow-up question, give one short, useful insight.
        - Keep replies under 80 words. Use bullet points when listing. Reply in the language of the conversation.
        - If there is nothing useful to add, or the new lines are just small talk or incomplete, reply with exactly: \(noResponseToken)
        """
}
