import Foundation

/// Batches raw audio and video chunks into one multimodal request; the model
/// returns both the transcript and the suggestion.
final class RemoteChunkProcessor: ChunkProcessor {
    /// Upper bound on chunks per request (keeps requests under inline-data limits
    /// while still absorbing ~60 s of three channels when requests are spaced out).
    static let maxChunksPerRequest = 24

    let displayName: String
    var acceptsVideo: Bool { capabilities.contains(.videoInput) }

    private let client: any MultimodalClient
    private let model: String
    private let language: String
    private let capabilities: ProviderCapabilities
    private let throttle: RequestThrottle
    /// Pause before a batch is sent, so chunks from the different channels that
    /// end at about the same time go out in the same request.
    private let batchDelay: Duration

    init(
        client: any MultimodalClient,
        model: String,
        language: String,
        providerName: String,
        capabilities: ProviderCapabilities = [.audioInput, .videoInput],
        throttle: RequestThrottle = RequestThrottle(),
        batchDelay: Duration = .milliseconds(500)
    ) {
        self.client = client
        self.model = model
        self.language = language
        self.displayName = providerName
        self.capabilities = capabilities
        self.throttle = throttle
        self.batchDelay = batchDelay
    }

    // MARK: ChunkProcessor

    func processNext(from queue: ChunkQueue, context: any PipelineContext) async {
        await throttle.waitForTurn(minimumDelay: batchDelay)
        let batch = queue.take(Self.maxChunksPerRequest)
        guard !batch.isEmpty else { return }
        batch.forEach { context.chunkLog.update($0, status: .processing) }

        context.setThinking(true)
        defer { context.setThinking(false) }

        do {
            let parts = try MultimodalPrompt.parts(
                for: batch,
                context: context.recentTranscript(),
                previousSuggestions: context.recentAnswers()
            )
            let reply = try MultimodalReply.parse(try await generate(parts: parts, context: context))

            let lines = reply.transcript.compactMap { line -> TranscriptLine? in
                let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : TranscriptLine(date: .now, source: line.source, text: text)
            }
            context.appendTranscript(lines)
            context.postAnswerIfUseful(reply.suggestion)

            for chunk in batch {
                let heard = lines.filter { $0.source == chunk.source }.map(\.text).joined(separator: " ")
                let summary = chunk.isAudio
                    ? (heard.isEmpty ? "No speech recognized." : heard)
                    : "Sent to \(displayName)."
                context.chunkLog.update(chunk, status: .done(summary))
            }
        } catch {
            batch.forEach { context.chunkLog.update($0, status: .failed(error.localizedDescription)) }
            context.post(.error, "\(displayName): \(error.localizedDescription)")
        }
    }

    func respond(toTypedMessage line: TranscriptLine, context: any PipelineContext) async {
        await throttle.waitForTurn()

        context.setThinking(true)
        defer { context.setThinking(false) }

        do {
            let parts: [MediaPart] = [
                .text(MultimodalPrompt.preamble(
                    context: context.recentTranscript(),
                    previousSuggestions: context.recentAnswers(),
                    hasMedia: false
                )),
                .text(MultimodalPrompt.typedMessageNote),
            ]
            // No media was sent, so only the suggestion matters.
            let reply = try MultimodalReply.parse(try await generate(parts: parts, context: context))
            context.postAnswerIfUseful(reply.suggestion)
        } catch {
            context.post(.error, "\(displayName): \(error.localizedDescription)")
        }
    }

    func testConnection(context: any PipelineContext) async {
        do {
            let answer = try await client.generate(
                model: model,
                systemPrompt: "You are a connectivity check.",
                parts: [.text(PromptInstructions.connectivityCheck)]
            )
            context.post(.info, "\(displayName) OK (\(model)): \(answer)")
        } catch {
            context.post(.error, "\(displayName): \(error.localizedDescription)")
        }
    }

    func waitUntilIdle() async {}

    // MARK: Helpers

    private func generate(parts: [MediaPart], context: any PipelineContext) async throws -> String {
        try await client.generate(
            model: model,
            systemPrompt: PromptInstructions.appending(
                context.customInstructions,
                to: MultimodalPrompt.systemPrompt(language: language)
            ),
            parts: parts
        )
    }
}
