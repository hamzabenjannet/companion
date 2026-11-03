import Foundation

/// Whisper transcribes each audio chunk, then Ollama reads the new transcript
/// lines and suggests an answer. Video chunks are skipped.
final class LocalChunkProcessor: ChunkProcessor {
    let displayName = "Local (Whisper + Ollama)"
    let acceptsVideo = false

    private let settings: LocalBackendSettings
    private let transport: any HTTPTransport
    /// At most one Ollama request runs at a time.
    private var interpretationTask: Task<Void, Never>?
    /// Transcript lines Ollama has already seen. Nil until the first line
    /// arrives, so lines from before this processor existed count as seen.
    private var interpretedLineCount: Int?

    init(settings: LocalBackendSettings, transport: any HTTPTransport) {
        self.settings = settings
        self.transport = transport
    }

    // MARK: ChunkProcessor

    func processNext(from queue: ChunkQueue, context: any PipelineContext) async {
        guard let chunk = queue.take(1).first else { return }
        await transcribe(chunk, context: context)
    }

    func respond(toTypedMessage line: TranscriptLine, context: any PipelineContext) async {
        if interpretedLineCount == nil {
            interpretedLineCount = context.transcript.count - 1
        }
        scheduleInterpretation(context: context)
        await interpretationTask?.value
    }

    func testConnection(context: any PipelineContext) async {
        do {
            let answer = try await LocalBackendClient.chat(
                messages: [ChatMessage(role: "user", content: PromptInstructions.connectivityCheck)],
                settings: settings,
                transport: transport
            )
            context.post(.info, "Ollama OK: \(answer)")
        } catch {
            context.post(.error, "Ollama: \(error.localizedDescription)")
        }
    }

    func waitUntilIdle() async {
        while let interpretationTask {
            await interpretationTask.value
        }
    }

    // MARK: Whisper

    private func transcribe(_ chunk: MediaChunk, context: any PipelineContext) async {
        guard chunk.isAudio else {
            context.chunkLog.update(chunk, status: .skipped("Video isn't used in local mode."))
            return
        }

        context.chunkLog.update(chunk, status: .processing)
        context.setTranscribing(true)
        defer { context.setTranscribing(false) }

        do {
            let text = try await LocalBackendClient.transcribe(wavURL: chunk.url, settings: settings, transport: transport)
            guard !text.isEmpty else {
                context.chunkLog.update(chunk, status: .skipped("No speech recognized."))
                return
            }
            context.chunkLog.update(chunk, status: .done(text))
            if interpretedLineCount == nil {
                interpretedLineCount = context.transcript.count
            }
            context.appendTranscript([TranscriptLine(date: .now, source: chunk.source, text: text)])
            scheduleInterpretation(context: context)
        } catch {
            context.chunkLog.update(chunk, status: .failed(error.localizedDescription))
            context.post(.error, "Whisper (\(chunk.source.speakerLabel)): \(error.localizedDescription)")
        }
    }

    // MARK: Ollama

    /// Lines that arrive while the model is busy are picked up in the next pass
    /// instead of queuing more requests.
    private func scheduleInterpretation(context: any PipelineContext) {
        guard interpretationTask == nil else { return }

        interpretationTask = Task { [weak self] in
            while let self, self.hasNewLines(in: context) {
                await self.interpretNewLines(context: context)
            }
            self?.interpretationTask = nil
        }
    }

    private func hasNewLines(in context: any PipelineContext) -> Bool {
        // The transcript shrinks when the user clears it; start over from there.
        let seen = min(interpretedLineCount ?? 0, context.transcript.count)
        interpretedLineCount = seen
        return seen < context.transcript.count
    }

    private func interpretNewLines(context: any PipelineContext) async {
        let newLines = context.transcript.count - (interpretedLineCount ?? 0)
        interpretedLineCount = context.transcript.count

        let transcript = context.recentTranscript()
            .map { "\($0.speakerLabel): \($0.text)" }
            .joined(separator: "\n")
        let previous = context.recentAnswers()
            .map { "- \($0)" }
            .joined(separator: "\n")

        let messages = [
            ChatMessage(
                role: "system",
                content: PromptInstructions.appending(context.customInstructions, to: PromptInstructions.localSystemPrompt)
            ),
            ChatMessage(role: "user", content: """
                Live meeting transcript (most recent last; the last \(newLines) line(s) are new):
                \(transcript)

                Your previous suggestions (do not repeat them):
                \(previous.isEmpty ? "(none)" : previous)
                """),
        ]

        context.setThinking(true)
        defer { context.setThinking(false) }

        do {
            let reply = try await LocalBackendClient.chat(messages: messages, settings: settings, transport: transport)
            context.postAnswerIfUseful(reply)
        } catch {
            context.post(.error, "Ollama: \(error.localizedDescription)")
        }
    }
}
