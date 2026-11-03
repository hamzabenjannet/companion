import Foundation
import Observation

nonisolated struct TranscriptLine: Identifiable, Sendable {
    let id = UUID()
    let date: Date
    let source: CaptureSource
    let text: String
}

nonisolated struct Suggestion: Identifiable, Sendable {
    enum Kind: Sendable {
        case answer
        case error
        case info
    }

    let id = UUID()
    let date: Date
    let kind: Kind
    let text: String
}

/// Where captured chunks are sent.
nonisolated enum ProcessingMode: Sendable {
    /// Whisper transcribes each audio chunk, then Ollama interprets the transcript.
    case local(BackendSettings)
    /// Raw audio/video chunks are batched and sent to a multimodal model, which
    /// returns both the transcript and the suggestion. `minInterval` spaces out
    /// requests (seconds) for rate-limited providers.
    case remote(
        client: any MultimodalClient,
        model: String,
        language: String,
        providerName: String,
        minInterval: TimeInterval = 0
    )
}

/// Runs the continuous loop:
/// capture (mic + system + screen, separately) → chunk → provider → transcript → suggestion.
@Observable
final class MeetingAssistant {
    private(set) var isRunning = false
    private(set) var isTranscribing = false
    private(set) var isThinking = false
    private(set) var transcript: [TranscriptLine] = []
    private(set) var suggestions: [Suggestion] = []
    /// The most recent chunks, for the debug section.
    let chunkLog: ChunkLog

    /// Sentinel the model returns when there is nothing worth saying.
    private static let noResponseToken = MultimodalPrompt.noResponseToken
    /// How many recent transcript lines are sent as context.
    private static let contextLineCount = 30
    /// Upper bound on chunks per remote request (keeps requests under inline-data limits
    /// while still absorbing ~60 s of three channels when requests are spaced out).
    static let maxChunksPerRequest = 24

    /// Pause before a remote batch is sent, so chunks from the different channels
    /// that end at about the same time go out in the same request.
    @ObservationIgnored var batchDelay: Duration = .milliseconds(500)

    @ObservationIgnored private let transport: any HTTPTransport
    @ObservationIgnored private var mode: ProcessingMode = .local(
        BackendSettings(whisperBaseURL: "", ollamaBaseURL: "", ollamaModel: "", language: "")
    )
    @ObservationIgnored private var microphone: MicrophoneCapture?
    @ObservationIgnored private var systemAudio: SystemAudioCapture?
    @ObservationIgnored private var screen: ScreenCapture?
    @ObservationIgnored private var chunkContinuation: AsyncStream<MediaChunk>.Continuation?
    @ObservationIgnored private var intakeTask: Task<Void, Never>?
    @ObservationIgnored private var workerTask: Task<Void, Never>?
    @ObservationIgnored private var interpretationTask: Task<Void, Never>?
    /// Chunks received but not yet processed, oldest first.
    @ObservationIgnored private var pending: [MediaChunk] = []
    /// When the last remote request was sent, for `minInterval` spacing.
    @ObservationIgnored private var lastRemoteRequest: ContinuousClock.Instant?
    /// Number of transcript lines already seen by the model (local mode).
    @ObservationIgnored private var interpretedLineCount = 0

    init(transport: any HTTPTransport = URLSession.shared, chunkLog: ChunkLog = ChunkLog()) {
        self.transport = transport
        self.chunkLog = chunkLog
    }

    // MARK: Lifecycle

    func start(
        mode: ProcessingMode,
        chunkDuration: TimeInterval,
        captureMicrophone: Bool,
        captureSystemAudio: Bool,
        captureScreen: Bool
    ) async {
        guard !isRunning else { return }
        let onChunk = beginPipeline(mode: mode)

        if captureMicrophone {
            do {
                guard await MicrophoneCapture.requestAccess() else { throw CaptureError.microphoneDenied }
                let mic = MicrophoneCapture(
                    chunker: AudioChunker(source: .microphone, chunkDuration: chunkDuration, onChunk: onChunk)
                )
                try mic.start()
                microphone = mic
                post(.info, "Microphone capture started.")
            } catch {
                post(.error, "Microphone: \(error.localizedDescription)")
            }
        }

        if captureSystemAudio {
            do {
                let system = SystemAudioCapture(
                    chunker: AudioChunker(source: .system, chunkDuration: chunkDuration, onChunk: onChunk),
                    onError: captureErrorHandler(prefix: "System audio stopped")
                )
                try await system.start()
                systemAudio = system
                post(.info, "System audio capture started.")
            } catch {
                post(.error, "System audio: \(error.localizedDescription) — \(Self.screenPermissionHint)")
            }
        }

        if captureScreen {
            do {
                let capture = ScreenCapture(
                    chunkDuration: chunkDuration,
                    onChunk: onChunk,
                    onError: captureErrorHandler(prefix: "Screen recording")
                )
                try await capture.start()
                screen = capture
                if case .local = mode {
                    post(.info, "Screen recording started. Local mode can't read video, so screen chunks only appear in the debug list.")
                } else {
                    post(.info, "Screen recording started.")
                }
            } catch {
                post(.error, "Screen recording: \(error.localizedDescription) — \(Self.screenPermissionHint)")
            }
        }

        if microphone == nil && systemAudio == nil && screen == nil {
            await stop()
        }
    }

    /// Sets up the chunk queue and returns the callback captures use to submit
    /// chunks. `start` calls this; tests use it to feed chunks directly.
    func beginPipeline(mode: ProcessingMode) -> @Sendable (MediaChunk) -> Void {
        self.mode = mode
        isRunning = true
        lastRemoteRequest = nil

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
        microphone?.stop()
        microphone = nil
        await systemAudio?.stop()
        systemAudio = nil
        await screen?.stop()
        screen = nil

        chunkContinuation?.finish()
        chunkContinuation = nil
        isRunning = false
        post(.info, "Stopped. Remaining chunks are still being processed.")
    }

    /// Waits until every queued chunk and model request has finished. Call after `stop()`.
    func waitUntilIdle() async {
        await intakeTask?.value
        while true {
            if let workerTask {
                await workerTask.value
            } else if let interpretationTask {
                await interpretationTask.value
            } else {
                return
            }
        }
    }

    func clear() {
        transcript.removeAll()
        suggestions.removeAll()
        interpretedLineCount = 0
    }

    /// Sends a fixed question through Ollama to verify the backend without audio.
    func testOllama(settings: BackendSettings) async {
        do {
            let answer = try await APIClient.chat(
                messages: [ChatMessage(role: "user", content: "Reply with one short sentence: are you online?")],
                settings: settings,
                transport: transport
            )
            post(.info, "Ollama OK: \(answer)")
        } catch {
            post(.error, "Ollama: \(error.localizedDescription)")
        }
    }

    /// Sends a text-only prompt to a remote provider to verify the key and model.
    func testRemote(client: any MultimodalClient, model: String, providerName: String) async {
        do {
            let answer = try await client.generate(
                model: model,
                systemPrompt: "You are a connectivity check.",
                parts: [.text("Reply with one short sentence: are you online?")]
            )
            post(.info, "\(providerName) OK (\(model)): \(answer)")
        } catch {
            post(.error, "\(providerName): \(error.localizedDescription)")
        }
    }

    // MARK: Pipeline

    private func receive(_ chunk: MediaChunk) {
        chunkLog.add(chunk)
        pending.append(chunk)
        scheduleWorker()
    }

    /// Runs one worker at a time; chunks that arrive while it is busy are
    /// picked up by the same loop.
    private func scheduleWorker() {
        guard workerTask == nil else { return }

        workerTask = Task { [weak self] in
            while let self, !self.pending.isEmpty {
                await self.processPending()
            }
            self?.workerTask = nil
        }
    }

    private func processPending() async {
        switch mode {
        case .local(let settings):
            let chunk = pending.removeFirst()
            await transcribeLocally(chunk, settings: settings)
        case .remote(let client, let model, let language, let providerName, let minInterval):
            let wait = max(batchDelay, Self.remainingInterval(since: lastRemoteRequest, minInterval: minInterval))
            if wait > .zero {
                try? await Task.sleep(for: wait)
            }
            let batch = Array(pending.prefix(Self.maxChunksPerRequest))
            pending.removeFirst(batch.count)
            lastRemoteRequest = .now
            await processRemotely(batch, client: client, model: model, language: language, providerName: providerName)
        }
    }

    /// Time left before the next remote request may be sent.
    static func remainingInterval(
        since last: ContinuousClock.Instant?,
        minInterval: TimeInterval,
        now: ContinuousClock.Instant = .now
    ) -> Duration {
        guard let last, minInterval > 0 else { return .zero }
        let remaining = last + .seconds(minInterval) - now
        return max(remaining, .zero)
    }

    // MARK: Local (Whisper + Ollama)

    private func transcribeLocally(_ chunk: MediaChunk, settings: BackendSettings) async {
        guard chunk.isAudio else {
            chunkLog.update(chunk, status: .skipped("Video isn't used in local mode."))
            return
        }

        chunkLog.update(chunk, status: .processing)
        isTranscribing = true
        defer { isTranscribing = false }

        do {
            let text = try await APIClient.transcribe(wavURL: chunk.url, settings: settings, transport: transport)
            guard !text.isEmpty else {
                chunkLog.update(chunk, status: .skipped("No speech recognized."))
                return
            }
            chunkLog.update(chunk, status: .done(text))
            transcript.append(TranscriptLine(date: .now, source: chunk.source, text: text))
            scheduleInterpretation(settings: settings)
        } catch {
            chunkLog.update(chunk, status: .failed(error.localizedDescription))
            post(.error, "Whisper (\(chunk.source.speakerLabel)): \(error.localizedDescription)")
        }
    }

    /// Runs at most one Ollama request at a time. Lines that arrive while the
    /// model is busy are picked up in the next pass instead of queuing requests.
    private func scheduleInterpretation(settings: BackendSettings) {
        guard interpretationTask == nil else { return }

        interpretationTask = Task { [weak self] in
            while let self, self.interpretedLineCount < self.transcript.count {
                await self.interpretNewLines(settings: settings)
            }
            self?.interpretationTask = nil
        }
    }

    private func interpretNewLines(settings: BackendSettings) async {
        let newLines = transcript.count - interpretedLineCount
        interpretedLineCount = transcript.count

        let context = transcript.suffix(Self.contextLineCount)
            .map { "\($0.source.speakerLabel): \($0.text)" }
            .joined(separator: "\n")
        let recentSuggestions = recentAnswers()
            .map { "- \($0)" }
            .joined(separator: "\n")

        let messages = [
            ChatMessage(role: "system", content: Self.systemPrompt),
            ChatMessage(role: "user", content: """
                Live meeting transcript (most recent last; the last \(newLines) line(s) are new):
                \(context)

                Your previous suggestions (do not repeat them):
                \(recentSuggestions.isEmpty ? "(none)" : recentSuggestions)
                """),
        ]

        isThinking = true
        defer { isThinking = false }

        do {
            let reply = try await APIClient.chat(messages: messages, settings: settings, transport: transport)
            postAnswerIfUseful(reply)
        } catch {
            post(.error, "Ollama: \(error.localizedDescription)")
        }
    }

    // MARK: Remote (multimodal)

    private func processRemotely(
        _ batch: [MediaChunk],
        client: any MultimodalClient,
        model: String,
        language: String,
        providerName: String
    ) async {
        guard !batch.isEmpty else { return }
        batch.forEach { chunkLog.update($0, status: .processing) }

        isThinking = true
        defer { isThinking = false }

        do {
            let parts = try MultimodalPrompt.parts(
                for: batch,
                context: Array(transcript.suffix(Self.contextLineCount)),
                previousSuggestions: recentAnswers()
            )
            let raw = try await client.generate(
                model: model,
                systemPrompt: MultimodalPrompt.systemPrompt(language: language),
                parts: parts
            )
            let reply = try MultimodalReply.parse(raw)

            let lines = reply.transcript.compactMap { line -> TranscriptLine? in
                let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : TranscriptLine(date: .now, source: line.source, text: text)
            }
            transcript.append(contentsOf: lines)
            postAnswerIfUseful(reply.suggestion)

            for chunk in batch {
                let heard = lines.filter { $0.source == chunk.source }.map(\.text).joined(separator: " ")
                let summary = chunk.isAudio
                    ? (heard.isEmpty ? "No speech recognized." : heard)
                    : "Sent to \(providerName)."
                chunkLog.update(chunk, status: .done(summary))
            }
        } catch {
            batch.forEach { chunkLog.update($0, status: .failed(error.localizedDescription)) }
            post(.error, "\(providerName): \(error.localizedDescription)")
        }
    }

    // MARK: Helpers

    private func recentAnswers() -> [String] {
        suggestions.filter { $0.kind == .answer }.suffix(3).map(\.text)
    }

    private func postAnswerIfUseful(_ reply: String) {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty && !text.contains(Self.noResponseToken) {
            post(.answer, text)
        }
    }

    private func post(_ kind: Suggestion.Kind, _ text: String) {
        suggestions.append(Suggestion(date: .now, kind: kind, text: text))
    }

    private func captureErrorHandler(prefix: String) -> @Sendable (Error) -> Void {
        { [weak self] error in
            // Unwrap into an immutable reference before handing it to the task;
            // the weak capture itself is a mutable `var` and can't cross into it.
            guard let self else { return }
            Task { @MainActor in
                self.post(.error, "\(prefix): \(error.localizedDescription)")
            }
        }
    }

    private static let screenPermissionHint =
        "grant access in System Settings › Privacy & Security › Screen & System Audio Recording, then relaunch."

    private static let systemPrompt = """
        You are a discreet real-time meeting companion for the user ("Me").
        The transcript comes from automatic speech recognition and may contain errors or cut-off sentences.
        "Others" are the remote participants; "Me" is the user.

        Focus on the newest lines:
        - If someone asks a question (especially "Others" asking "Me"), give the user a concise, accurate answer they can say.
        - If a factual claim, decision or topic would benefit from a quick fact, opinion or follow-up question, give one short, useful insight.
        - Keep replies under 80 words. Use bullet points when listing. Reply in the language of the conversation.
        - If there is nothing useful to add, or the new lines are just small talk or incomplete, reply with exactly: NO_RESPONSE
        """
}
