import Foundation
import Testing
@testable import companion

@Suite("Processing provider")
struct ProcessingProviderTests {
    @Test func remoteFlag() {
        #expect(!ProcessingProvider.local.isRemote)
        #expect(ProcessingProvider.gemini.isRemote)
        #expect(ProcessingProvider.openRouter.isRemote)
    }

    @Test func namesAndIDs() {
        #expect(ProcessingProvider.allCases.count == 3)
        #expect(ProcessingProvider.gemini.displayName == "Google Gemini")
        #expect(ProcessingProvider.local.id == "local")
        #expect(ProcessingProvider(rawValue: "openRouter") == .openRouter)
    }
}

@Suite("Multimodal reply")
struct MultimodalReplyTests {
    @Test func parsesPlainJSON() throws {
        let reply = try MultimodalReply.parse(#"{"transcript": [{"speaker": "Me", "text": "Hi"}], "suggestion": "Say hello"}"#)
        #expect(reply == MultimodalReply(transcript: [.init(speaker: "Me", text: "Hi")], suggestion: "Say hello"))
    }

    @Test func parsesFencedJSON() throws {
        let reply = try MultimodalReply.parse("""
            Here you go:
            ```json
            {"transcript": [], "suggestion": "NO_RESPONSE"}
            ```
            """)
        #expect(reply.transcript.isEmpty)
        #expect(reply.suggestion == "NO_RESPONSE")
    }

    @Test func missingFieldsDefaultToEmpty() throws {
        let reply = try MultimodalReply.parse("{}")
        #expect(reply.transcript.isEmpty)
        #expect(reply.suggestion.isEmpty)
    }

    @Test(arguments: ["no json here", "{ not json }", "} {"])
    func rejectsInvalidText(_ text: String) {
        #expect(throws: APIError.invalidReply(text)) {
            _ = try MultimodalReply.parse(text)
        }
    }

    @Test func speakerMapsToSource() {
        #expect(MultimodalReply.Line(speaker: "Me", text: "").source == .microphone)
        #expect(MultimodalReply.Line(speaker: " me ", text: "").source == .microphone)
        #expect(MultimodalReply.Line(speaker: "Others", text: "").source == .system)
        #expect(MultimodalReply.Line(speaker: "Alice", text: "").source == .system)
        #expect(MultimodalReply.Line(speaker: "Screen", text: "").source == .screen)
    }
}

@Suite("Multimodal prompt")
struct MultimodalPromptTests {
    @Test func systemPromptDescribesChannelsAndFormat() {
        let prompt = MultimodalPrompt.systemPrompt(language: "")
        #expect(prompt.contains("\"Me\" audio"))
        #expect(prompt.contains("\"Others\" audio"))
        #expect(prompt.contains("\"Screen\" video"))
        #expect(prompt.contains(MultimodalPrompt.noResponseToken))
        #expect(prompt.contains(#""transcript""#))
        #expect(!prompt.contains("language code"))
    }

    @Test func systemPromptIncludesLanguageHint() {
        #expect(MultimodalPrompt.systemPrompt(language: " fr ").contains(#"language code "fr""#))
    }

    @Test func preambleWithoutHistory() {
        let text = MultimodalPrompt.preamble(context: [], previousSuggestions: [])
        #expect(text.contains("(nothing yet)"))
        #expect(text.contains("(none)"))
    }

    @Test func preambleWithHistory() {
        let text = MultimodalPrompt.preamble(
            context: [
                TranscriptLine(date: .now, source: .microphone, text: "Hello"),
                TranscriptLine(date: .now, source: .system, text: "Hi there"),
            ],
            previousSuggestions: ["Ask about budget"]
        )
        #expect(text.contains("Me: Hello\nOthers: Hi there"))
        #expect(text.contains("- Ask about budget"))
    }

    @Test func labelDescribesChunk() {
        let chunk = MediaChunk(source: .screen, url: URL(fileURLWithPath: "/tmp/a.mp4"), duration: 7.6, mimeType: "video/mp4")
        let label = MultimodalPrompt.label(for: chunk)
        #expect(label.hasPrefix("[Screen — Screen recording video, 8 s"))
    }

    @Test func partsInterleaveLabelsAndMedia() throws {
        let audio = try TestFiles.makeChunk(source: .microphone, bytes: Data([9, 9]))
        let video = try TestFiles.makeChunk(source: .screen, bytes: Data([7]))
        defer {
            try? FileManager.default.removeItem(at: audio.url)
            try? FileManager.default.removeItem(at: video.url)
        }

        let parts = try MultimodalPrompt.parts(for: [audio, video], context: [], previousSuggestions: [])

        #expect(parts.count == 5)
        #expect(parts[2] == .media(mimeType: "audio/wav", data: Data([9, 9])))
        #expect(parts[4] == .media(mimeType: "video/mp4", data: Data([7])))
        guard case .text(let label) = parts[1] else {
            Issue.record("Expected a label")
            return
        }
        #expect(label.contains("Me — Microphone audio"))
    }

    @Test func partsFailForMissingFile() {
        let chunk = MediaChunk(source: .system, url: URL(fileURLWithPath: "/nonexistent/x.wav"), duration: 1, mimeType: "audio/wav")
        #expect(throws: (any Error).self) {
            _ = try MultimodalPrompt.parts(for: [chunk], context: [], previousSuggestions: [])
        }
    }
}
