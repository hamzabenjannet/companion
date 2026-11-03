import Foundation

/// Shared conversation state that processors read and update.
/// `MeetingAssistant` is the production implementation.
protocol PipelineContext: AnyObject {
    var transcript: [TranscriptLine] { get }
    var suggestions: [Suggestion] { get }
    var chunkLog: ChunkLog { get }
    /// Extra instructions from the user, appended to every system prompt.
    var customInstructions: String { get }

    func appendTranscript(_ lines: [TranscriptLine])
    func post(_ kind: Suggestion.Kind, _ text: String)
    func setTranscribing(_ isTranscribing: Bool)
    func setThinking(_ isThinking: Bool)
}

extension PipelineContext {
    /// How many recent transcript lines are sent as context.
    static var contextLineCount: Int { 30 }

    func recentTranscript() -> [TranscriptLine] {
        Array(transcript.suffix(Self.contextLineCount))
    }

    /// The last few answers, so the model avoids repeating itself.
    func recentAnswers() -> [String] {
        suggestions.filter { $0.kind == .answer }.suffix(3).map(\.text)
    }

    /// Posts a model reply unless it is empty or the "nothing to add" sentinel.
    func postAnswerIfUseful(_ reply: String) {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty && !text.contains(PromptInstructions.noResponseToken) {
            post(.answer, text)
        }
    }
}

/// Chunks received but not yet processed, oldest first.
final class ChunkQueue {
    private(set) var chunks: [MediaChunk] = []

    var isEmpty: Bool { chunks.isEmpty }

    func append(_ chunk: MediaChunk) {
        chunks.append(chunk)
    }

    /// Removes and returns up to `maxCount` chunks from the front.
    func take(_ maxCount: Int) -> [MediaChunk] {
        let batch = Array(chunks.prefix(maxCount))
        chunks.removeFirst(batch.count)
        return batch
    }
}

/// Turns captured chunks and typed messages into transcript lines and suggestions.
///
/// Each backend (local Whisper + Ollama, remote multimodal models) has its own
/// implementation; `MeetingAssistant` only talks to this protocol.
protocol ChunkProcessor: AnyObject {
    /// Name used in status and error messages, e.g. "Google Gemini".
    var displayName: String { get }
    /// Whether screen (video) chunks are used. When false they only appear in the debug list.
    var acceptsVideo: Bool { get }

    /// Takes one or more chunks from the front of `queue` and processes them.
    func processNext(from queue: ChunkQueue, context: any PipelineContext) async
    /// Answers a typed message. The line is already in `context.transcript`.
    func respond(toTypedMessage line: TranscriptLine, context: any PipelineContext) async
    /// Sends a small request to check that the backend is reachable, and posts the result.
    func testConnection(context: any PipelineContext) async
    /// Waits for background work this processor started (for example, a pending model request).
    func waitUntilIdle() async
}
