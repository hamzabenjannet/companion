import Foundation
import Testing
@testable import companion

@MainActor
@Suite("Meeting assistant pipeline")
struct MeetingAssistantTests {
    private let localSettings = LocalBackendSettings(
        whisperBaseURL: "http://whisper.test",
        ollamaBaseURL: "http://ollama.test",
        ollamaModel: "qwen2.5:3b",
        language: ""
    )

    private func remote(_ client: MockMultimodalClient, batchDelay: Duration = .milliseconds(500)) -> RemoteChunkProcessor {
        RemoteChunkProcessor(
            client: client,
            model: "models/gemini-2.5-flash",
            language: "en",
            providerName: "Google Gemini",
            batchDelay: batchDelay
        )
    }

    private func local(_ transport: MockTransport) -> LocalChunkProcessor {
        LocalChunkProcessor(settings: localSettings, transport: transport)
    }

    /// Feeds chunks into a fresh pipeline, stops it and waits for all work to finish.
    private func run(_ assistant: MeetingAssistant, processor: any ChunkProcessor, chunks: [MediaChunk]) async {
        let submit = assistant.beginPipeline(processor: processor)
        #expect(assistant.isRunning)
        chunks.forEach(submit)
        await assistant.stop()
        await assistant.waitUntilIdle()
        #expect(!assistant.isRunning)
    }

    private func answers(_ assistant: MeetingAssistant) -> [String] {
        assistant.suggestions.filter { $0.kind == .answer }.map(\.text)
    }

    private func errors(_ assistant: MeetingAssistant) -> [String] {
        assistant.suggestions.filter { $0.kind == .error }.map(\.text)
    }

    // MARK: Remote

    @Test func remoteBatchProducesTranscriptAndSuggestion() async throws {
        let client = MockMultimodalClient { _ in
            #"{"transcript": [{"speaker": "Others", "text": "What is our Q3 revenue?"}, {"speaker": "Me", "text": "Let me check."}], "suggestion": "Q3 revenue was 1.2M."}"#
        }
        let assistant = MeetingAssistant()
        let batchDelay: Duration = .milliseconds(200)
        let mic = try TestFiles.makeChunk(source: .microphone)
        let system = try TestFiles.makeChunk(source: .system)
        let screen = try TestFiles.makeChunk(source: .screen)
        defer { assistant.chunkLog.clear() }

        await run(assistant, processor: remote(client, batchDelay: batchDelay), chunks: [mic, system, screen])

        // All three chunks travel in one request: preamble + (label, media) × 3.
        #expect(client.calls.count == 1)
        let call = try #require(client.calls.first)
        #expect(call.model == "models/gemini-2.5-flash")
        #expect(call.parts.count == 7)
        #expect(call.systemPrompt.contains(#"language code "en""#))

        #expect(assistant.transcript.map(\.source) == [.system, .microphone])
        #expect(assistant.transcript.map(\.text) == ["What is our Q3 revenue?", "Let me check."])
        #expect(answers(assistant) == ["Q3 revenue was 1.2M."])

        #expect(assistant.chunkLog.status(of: mic) == .done("Let me check."))
        #expect(assistant.chunkLog.status(of: system) == .done("What is our Q3 revenue?"))
        #expect(assistant.chunkLog.status(of: screen) == .done("Sent to Google Gemini."))
        #expect(!assistant.isThinking)
    }

    @Test func silentChunksAreLoggedButNotSent() async throws {
        let client = MockMultimodalClient { _ in #"{"transcript": [], "suggestion": "NO_RESPONSE"}"# }
        let assistant = MeetingAssistant()
        let batchDelay: Duration = .milliseconds(50)
        let url = MediaChunk.makeFileURL(source: .microphone, fileExtension: "wav")
        try Data([1, 2, 3, 4]).write(to: url)
        let silent = MediaChunk(source: .microphone, url: url, duration: 8, mimeType: "audio/wav", isSilent: true)
        defer { assistant.chunkLog.clear() }

        await run(assistant, processor: remote(client, batchDelay: batchDelay), chunks: [silent])

        #expect(client.calls.isEmpty)
        #expect(assistant.chunkLog.status(of: silent) == .skipped("Silent"))
    }

    @Test func typedMessageGoesToRemoteWithoutRecording() async throws {
        let client = MockMultimodalClient { _ in #"{"transcript": [], "suggestion": "Say 42."}"# }
        let assistant = MeetingAssistant()
        assistant.customInstructions = "I am interviewing for a staff role."

        await assistant.send(text: "  What should I answer?  ", using: remote(client))

        #expect(!assistant.isRunning)
        #expect(assistant.transcript.map(\.text) == ["What should I answer?"])
        #expect(assistant.transcript.first?.speakerLabel == "Me (typed)")
        #expect(answers(assistant) == ["Say 42."])
        #expect(!assistant.isThinking)

        let call = try #require(client.calls.first)
        #expect(call.systemPrompt.hasSuffix("I am interviewing for a staff role."))
        guard case .text(let preamble) = call.parts.first else {
            Issue.record("Expected a text preamble")
            return
        }
        #expect(preamble.contains("Me (typed): What should I answer?"))
        #expect(preamble.contains("No new media."))
        #expect(call.parts.count == 2)
    }

    @Test func emptyTypedMessageIsIgnored() async {
        let client = MockMultimodalClient()
        let assistant = MeetingAssistant()

        await assistant.send(text: "   ", using: remote(client))

        #expect(assistant.transcript.isEmpty)
        #expect(client.calls.isEmpty)
    }

    @Test func customInstructionsAreAppendedOnlyWhenSet() {
        #expect(PromptInstructions.appending("", to: "Base") == "Base")
        #expect(PromptInstructions.appending("  \n ", to: "Base") == "Base")
        let combined = PromptInstructions.appending(" Be brief. ", to: "Base")
        #expect(combined.hasPrefix("Base\n\n"))
        #expect(combined.hasSuffix("Be brief."))
    }

    @Test func remoteNoResponseIsHidden() async throws {
        let client = MockMultimodalClient { _ in #"{"transcript": [{"speaker": "Me", "text": "  "}], "suggestion": "NO_RESPONSE"}"# }
        let assistant = MeetingAssistant()
        let batchDelay: Duration = .zero
        let mic = try TestFiles.makeChunk(source: .microphone)
        defer { assistant.chunkLog.clear() }

        await run(assistant, processor: remote(client, batchDelay: batchDelay), chunks: [mic])

        #expect(answers(assistant).isEmpty)
        #expect(assistant.transcript.isEmpty)
        #expect(assistant.chunkLog.status(of: mic) == .done("No speech recognized."))
    }

    @Test func remoteContextIncludesEarlierTranscriptAndSuggestions() async throws {
        let client = MockMultimodalClient { index in
            #"{"transcript": [{"speaker": "Others", "text": "line \#(index)"}], "suggestion": "tip \#(index)"}"#
        }
        let assistant = MeetingAssistant()
        let batchDelay: Duration = .zero
        let first = try TestFiles.makeChunk(source: .system)
        let second = try TestFiles.makeChunk(source: .system)
        defer { assistant.chunkLog.clear() }

        let submit = assistant.beginPipeline(processor: remote(client, batchDelay: batchDelay))
        submit(first)
        // Wait for the first request before sending the second chunk.
        while client.calls.isEmpty || assistant.isThinking { await Task.yield() }
        submit(second)
        await assistant.stop()
        await assistant.waitUntilIdle()

        #expect(client.calls.count == 2)
        guard case .text(let preamble) = client.calls[1].parts.first else {
            Issue.record("Missing preamble")
            return
        }
        #expect(preamble.contains("Others: line 0"))
        #expect(preamble.contains("- tip 0"))
        #expect(answers(assistant) == ["tip 0", "tip 1"])
    }

    @Test func remoteFailureMarksChunksFailed() async throws {
        let client = MockMultimodalClient { _ in throw TestError(message: "quota exceeded") }
        let assistant = MeetingAssistant()
        let batchDelay: Duration = .zero
        let mic = try TestFiles.makeChunk(source: .microphone)
        defer { assistant.chunkLog.clear() }

        await run(assistant, processor: remote(client, batchDelay: batchDelay), chunks: [mic])

        #expect(assistant.chunkLog.status(of: mic) == .failed("quota exceeded"))
        #expect(errors(assistant) == ["Google Gemini: quota exceeded"])
    }

    @Test func remoteInvalidReplyIsReported() async throws {
        let client = MockMultimodalClient { _ in "sorry, I can't" }
        let assistant = MeetingAssistant()
        let batchDelay: Duration = .zero
        let mic = try TestFiles.makeChunk(source: .microphone)
        defer { assistant.chunkLog.clear() }

        await run(assistant, processor: remote(client, batchDelay: batchDelay), chunks: [mic])

        #expect(errors(assistant).count == 1)
        if case .failed = assistant.chunkLog.status(of: mic) {} else {
            Issue.record("Expected failed status")
        }
    }

    @Test func remainingIntervalMath() {
        let now = ContinuousClock.now
        #expect(RequestThrottle.remainingInterval(since: nil, minInterval: 30, now: now) == .zero)
        #expect(RequestThrottle.remainingInterval(since: now, minInterval: 0, now: now) == .zero)
        #expect(RequestThrottle.remainingInterval(since: now - .seconds(10), minInterval: 30, now: now) == .seconds(20))
        #expect(RequestThrottle.remainingInterval(since: now - .seconds(40), minInterval: 30, now: now) == .zero)
    }

    @Test func remoteRequestsRespectMinimumInterval() async throws {
        let sentAt = Collector<ContinuousClock.Instant>()
        let client = MockMultimodalClient { _ in
            sentAt.append(.now)
            return #"{"transcript": [], "suggestion": ""}"#
        }
        let assistant = MeetingAssistant()
        let batchDelay: Duration = .zero
        let first = try TestFiles.makeChunk(source: .microphone)
        let second = try TestFiles.makeChunk(source: .system)
        let third = try TestFiles.makeChunk(source: .microphone)
        defer { assistant.chunkLog.clear() }

        let submit = assistant.beginPipeline(processor: RemoteChunkProcessor(
            client: client,
            model: "m",
            language: "",
            providerName: "OpenRouter",
            throttle: RequestThrottle(minInterval: 0.4),
            batchDelay: batchDelay
        ))
        submit(first)
        while client.calls.isEmpty || assistant.isThinking { await Task.yield() }
        // Both arrive during the wait and go out together in the second request.
        submit(second)
        submit(third)
        await assistant.stop()
        await assistant.waitUntilIdle()

        let times = sentAt.values
        #expect(times.count == 2)
        #expect(client.calls.last?.parts.count == 5)
        if times.count == 2 {
            #expect(times[1] - times[0] >= .milliseconds(390))
        }
    }

    @Test func remoteBatchesAreCapped() async throws {
        let client = MockMultimodalClient { _ in #"{"transcript": [], "suggestion": ""}"# }
        let assistant = MeetingAssistant(chunkLog: ChunkLog(capacity: 50))
        let batchDelay: Duration = .milliseconds(200)
        let chunks = try (0..<(RemoteChunkProcessor.maxChunksPerRequest + 3)).map { _ in
            try TestFiles.makeChunk(source: .microphone)
        }
        defer { assistant.chunkLog.clear() }

        await run(assistant, processor: remote(client, batchDelay: batchDelay), chunks: chunks)

        #expect(client.calls.count == 2)
        #expect(client.calls[0].parts.count == 1 + 2 * RemoteChunkProcessor.maxChunksPerRequest)
        #expect(client.calls[1].parts.count == 1 + 2 * 3)
    }

    // MARK: Local

    private func localTransport(transcript: String = "Hello team", reply: String = "Ask about the agenda.") -> MockTransport {
        MockTransport { request in
            if request.url?.path == "/asr" {
                let body = try JSONSerialization.data(withJSONObject: ["text": transcript])
                return (200, body)
            }
            let body = try JSONSerialization.data(withJSONObject: ["message": ["role": "assistant", "content": reply]])
            return (200, body)
        }
    }

    @Test func localTranscribesAndInterprets() async throws {
        let transport = localTransport()
        let assistant = MeetingAssistant()
        let mic = try TestFiles.makeChunk(source: .microphone)
        defer { assistant.chunkLog.clear() }

        await run(assistant, processor: local(transport), chunks: [mic])

        #expect(assistant.transcript.map(\.text) == ["Hello team"])
        #expect(assistant.transcript.first?.source == .microphone)
        #expect(answers(assistant) == ["Ask about the agenda."])
        #expect(assistant.chunkLog.status(of: mic) == .done("Hello team"))
        #expect(transport.requests.map { $0.url?.host ?? "" } == ["whisper.test", "ollama.test"])
        #expect(!assistant.isTranscribing)
    }

    @Test func localSkipsScreenChunksAndEmptyTranscripts() async throws {
        let transport = localTransport(transcript: "")
        let assistant = MeetingAssistant()
        let screen = try TestFiles.makeChunk(source: .screen)
        let system = try TestFiles.makeChunk(source: .system)
        defer { assistant.chunkLog.clear() }

        await run(assistant, processor: local(transport), chunks: [screen, system])

        if case .skipped = assistant.chunkLog.status(of: screen) {} else { Issue.record("Screen chunk should be skipped") }
        #expect(assistant.chunkLog.status(of: system) == .skipped("No speech recognized."))
        #expect(transport.requests.count == 1)
        #expect(assistant.transcript.isEmpty)
    }

    @Test func localNoResponseIsHidden() async throws {
        let transport = localTransport(reply: "NO_RESPONSE")
        let assistant = MeetingAssistant()
        let mic = try TestFiles.makeChunk(source: .microphone)
        defer { assistant.chunkLog.clear() }

        await run(assistant, processor: local(transport), chunks: [mic])

        #expect(assistant.transcript.count == 1)
        #expect(answers(assistant).isEmpty)
    }

    @Test func localWhisperErrorIsReported() async throws {
        let transport = MockTransport(status: 503, json: "busy")
        let assistant = MeetingAssistant()
        let mic = try TestFiles.makeChunk(source: .microphone)
        defer { assistant.chunkLog.clear() }

        await run(assistant, processor: local(transport), chunks: [mic])

        #expect(assistant.chunkLog.status(of: mic) == .failed("HTTP 503: busy"))
        #expect(errors(assistant) == ["Whisper (Me): HTTP 503: busy"])
    }

    // MARK: Misc

    @Test func clearResetsTranscriptAndSuggestions() async throws {
        let transport = localTransport()
        let assistant = MeetingAssistant()
        let mic = try TestFiles.makeChunk(source: .microphone)
        defer { assistant.chunkLog.clear() }
        await run(assistant, processor: local(transport), chunks: [mic])

        assistant.clear()

        #expect(assistant.transcript.isEmpty)
        #expect(assistant.suggestions.isEmpty)
        // The debug list is independent from the transcript.
        #expect(assistant.chunkLog.records.count == 1)
    }

    @Test func stopWhenNotRunningDoesNothing() async {
        let assistant = MeetingAssistant()
        await assistant.stop()
        #expect(assistant.suggestions.isEmpty)
    }

    @Test func testRemoteReportsSuccessAndFailure() async {
        let assistant = MeetingAssistant()
        func processor(_ client: MockMultimodalClient) -> RemoteChunkProcessor {
            RemoteChunkProcessor(client: client, model: "m", language: "", providerName: "OpenRouter")
        }
        await assistant.testConnection(using: processor(MockMultimodalClient { _ in "Yes, online." }))
        await assistant.testConnection(using: processor(MockMultimodalClient { _ in throw TestError(message: "bad key") }))

        #expect(assistant.suggestions.map(\.text) == ["OpenRouter OK (m): Yes, online.", "OpenRouter: bad key"])
        #expect(assistant.suggestions.map(\.kind) == [.info, .error])
    }

    @Test func testOllamaReportsSuccessAndFailure() async {
        let ok = MeetingAssistant()
        await ok.testConnection(using: local(localTransport(reply: "Online.")))
        #expect(ok.suggestions.last?.text == "Ollama OK: Online.")

        let failing = MeetingAssistant()
        await failing.testConnection(using: local(MockTransport(status: 404, json: "no model")))
        #expect(failing.suggestions.last?.text == "Ollama: HTTP 404: no model")
    }
}
