import Foundation
import Observation

/// Runs the continuous loop:
/// capture (mic + system + screen, separately) → chunk queue → `ChunkProcessor` → transcript and suggestions.
///
/// The assistant owns the conversation state and the queue. Capturing is
/// delegated to `CaptureSession` and model calls to a `ChunkProcessor`.
@Observable
final class MeetingAssistant: PipelineContext {
    private(set) var isRunning = false
    private(set) var isTranscribing = false
    private(set) var isThinking = false
    private(set) var transcript: [TranscriptLine] = []
    private(set) var suggestions: [Suggestion] = []
    /// The most recent chunks, for the debug section.
    let chunkLog: ChunkLog
    /// Live per-channel state, for the recording indicators.
    let monitor = CaptureMonitor()
    /// Extra instructions from the user, appended to the built-in system prompt.
    @ObservationIgnored var customInstructions = ""

    /// The processor of the running session, or the one used for the last typed message.
    @ObservationIgnored private var processor: (any ChunkProcessor)?
    @ObservationIgnored private let capture = CaptureSession()
    @ObservationIgnored private let queue = ChunkQueue()
    @ObservationIgnored private var chunkContinuation: AsyncStream<MediaChunk>.Continuation?
    @ObservationIgnored private var intakeTask: Task<Void, Never>?
    @ObservationIgnored private var workerTask: Task<Void, Never>?

    init(chunkLog: ChunkLog = ChunkLog()) {
        self.chunkLog = chunkLog
    }

    // MARK: Lifecycle

    func start(processor: any ChunkProcessor, options: CaptureOptions) async {
        guard !isRunning else { return }
        let onChunk = beginPipeline(processor: processor)

        await capture.start(
            options: options,
            monitor: monitor,
            usesVideo: processor.acceptsVideo,
            onChunk: onChunk,
            report: { [weak self] event in
                switch event {
                case .info(let text): self?.post(.info, text)
                case .error(let text): self?.post(.error, text)
                }
            }
        )

        if !capture.isCapturing {
            await stop()
        }
    }

    /// Sets up the chunk queue and returns the callback captures use to submit
    /// chunks. `start` calls this; tests use it to feed chunks directly.
    func beginPipeline(processor: any ChunkProcessor) -> @Sendable (MediaChunk) -> Void {
        self.processor = processor
        isRunning = true

        // Chunks from every source go through one ordered queue.
        let (stream, continuation) = AsyncStream.makeStream(of: MediaChunk.self)
        chunkContinuation = continuation
        intakeTask = Task { [weak self] in
            for await chunk in stream {
                self?.receive(chunk)
            }
        }
        return { continuation.yield($0) }
    }

    func stop() async {
        guard isRunning else { return }

        // Stopping flushes the last partial chunk into the queue before it closes.
        await capture.stop(monitor: monitor)
        chunkContinuation?.finish()
        chunkContinuation = nil
        isRunning = false
        post(.info, "Stopped. Remaining chunks are still being processed.")
    }

    /// Waits until every queued chunk and model request has finished. Call after `stop()`.
    func waitUntilIdle() async {
        await intakeTask?.value
        while let workerTask {
            await workerTask.value
        }
        await processor?.waitUntilIdle()
    }

    func clear() {
        transcript.removeAll()
        suggestions.removeAll()
    }

    // MARK: Typed messages and checks

    /// Sends a typed message, with or without recording. While recording, the
    /// running session's processor answers; otherwise `processor` does.
    /// The message joins the transcript as "Me (typed)" so later requests see it too.
    func send(text: String, using processor: any ChunkProcessor) async {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let active = isRunning ? (self.processor ?? processor) : processor
        self.processor = active
        let line = TranscriptLine(date: .now, source: .microphone, text: text, isTyped: true)
        transcript.append(line)
        await active.respond(toTypedMessage: line, context: self)
    }

    /// Checks that the processor's backend answers, and posts the result.
    func testConnection(using processor: any ChunkProcessor) async {
        await processor.testConnection(context: self)
    }

    // MARK: Queue

    private func receive(_ chunk: MediaChunk) {
        chunkLog.add(chunk)
        monitor.record(chunk)
        // Silent audio is kept in the debug list (to show there was no gap) but not processed.
        guard !chunk.isSilent else {
            chunkLog.update(chunk, status: .skipped("Silent"))
            return
        }
        queue.append(chunk)
        scheduleWorker()
    }

    /// Runs one worker at a time; chunks that arrive while it is busy are
    /// picked up by the same loop.
    private func scheduleWorker() {
        guard workerTask == nil, let processor else { return }

        workerTask = Task { [weak self] in
            while let self, !self.queue.isEmpty {
                await processor.processNext(from: self.queue, context: self)
            }
            self?.workerTask = nil
        }
    }

    // MARK: PipelineContext

    func appendTranscript(_ lines: [TranscriptLine]) {
        transcript.append(contentsOf: lines)
    }

    func post(_ kind: Suggestion.Kind, _ text: String) {
        suggestions.append(Suggestion(date: .now, kind: kind, text: text))
    }

    func setTranscribing(_ isTranscribing: Bool) {
        self.isTranscribing = isTranscribing
    }

    func setThinking(_ isThinking: Bool) {
        self.isThinking = isThinking
    }
}
