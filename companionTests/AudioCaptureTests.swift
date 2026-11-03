import AVFoundation
import Foundation
import Testing
@testable import companion

@Suite("Capture sources and chunks")
struct CaptureSourceTests {
    @Test func speakerLabels() {
        #expect(CaptureSource.microphone.speakerLabel == "Me")
        #expect(CaptureSource.system.speakerLabel == "Others")
        #expect(CaptureSource.screen.speakerLabel == "Screen")
    }

    @Test func channelNames() {
        #expect(CaptureSource.microphone.channelName == "Microphone")
        #expect(CaptureSource.system.channelName == "System audio")
        #expect(CaptureSource.screen.channelName == "Screen recording")
    }

    @Test func mediaKindFromMimeType() {
        let url = URL(fileURLWithPath: "/tmp/x")
        let audio = MediaChunk(source: .microphone, url: url, duration: 1, mimeType: "audio/wav")
        let video = MediaChunk(source: .screen, url: url, duration: 1, mimeType: "video/mp4")
        #expect(audio.isAudio && !audio.isVideo)
        #expect(video.isVideo && !video.isAudio)
    }

    @Test func fileURLsLiveInChunkDirectory() {
        let url = MediaChunk.makeFileURL(source: .screen, fileExtension: "mp4")
        #expect(url.deletingLastPathComponent().standardizedFileURL == MediaChunk.directory.standardizedFileURL)
        #expect(url.lastPathComponent.hasPrefix("screen-"))
        #expect(url.pathExtension == "mp4")
        #expect(FileManager.default.fileExists(atPath: MediaChunk.directory.path))
    }

    @Test func captureErrorsHaveMessages() {
        #expect(CaptureError.microphoneDenied.errorDescription?.contains("Microphone") == true)
        #expect(CaptureError.noInputDevice.errorDescription != nil)
        #expect(CaptureError.noDisplay.errorDescription != nil)
        #expect(CaptureError.videoWriter("boom").errorDescription?.contains("boom") == true)
    }
}

@Suite("AudioChunker")
struct AudioChunkerTests {
    /// Mono Float32 buffer containing a sine wave (or silence when amplitude is 0).
    private func makeBuffer(seconds: Double, sampleRate: Double = 48_000, amplitude: Float = 0.5) throws -> AVAudioPCMBuffer {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let channel = try #require(buffer.floatChannelData)[0]
        for index in 0..<Int(frames) {
            channel[index] = amplitude * sin(2 * .pi * 440 * Float(index) / Float(sampleRate))
        }
        return buffer
    }

    @Test func rmsOfEmptyIsZero() {
        #expect(AudioChunker.rms([]) == 0)
    }

    @Test func rmsOfConstantSignal() {
        #expect(abs(AudioChunker.rms([0.5, -0.5, 0.5, -0.5]) - 0.5) < 0.0001)
    }

    @Test func wavHeaderIsValid() {
        let data = AudioChunker.wavData(from: [0, 0.5, -0.5, 1, -1, 2], sampleRate: 16_000)
        #expect(data.count == 44 + 6 * 2)
        #expect(String(data: data[0..<4], encoding: .ascii) == "RIFF")
        #expect(String(data: data[8..<12], encoding: .ascii) == "WAVE")
        #expect(String(data: data[36..<40], encoding: .ascii) == "data")

        func uint32(at offset: Int) -> UInt32 {
            data[offset..<offset + 4].enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
        }
        #expect(uint32(at: 4) == UInt32(36 + 12))   // RIFF size
        #expect(uint32(at: 24) == 16_000)           // sample rate
        #expect(uint32(at: 40) == 12)               // data size

        // Samples are clamped to [-1, 1] before conversion.
        let lastSample = Int16(littleEndian: data[54..<56].withUnsafeBytes { $0.loadUnaligned(as: Int16.self) })
        #expect(lastSample == Int16.max)
    }

    @Test func emitsFixedLengthChunksAndResamples() throws {
        let collector = Collector<MediaChunk>()
        let chunker = AudioChunker(source: .microphone, chunkDuration: 1, overlapDuration: 0, onChunk: collector.append)

        chunker.append(try makeBuffer(seconds: 2.5))

        let chunks = collector.values
        #expect(chunks.count == 2)
        for chunk in chunks {
            #expect(chunk.source == .microphone)
            #expect(chunk.mimeType == "audio/wav")
            #expect(chunk.duration == 1)
            let data = try Data(contentsOf: chunk.url)
            #expect(data.count == 44 + 16_000 * 2)
            try FileManager.default.removeItem(at: chunk.url)
        }

        // The remaining ~0.5 s is shorter than the one-second minimum and is dropped.
        chunker.flush()
        #expect(collector.values.count == 2)
    }

    @Test func flushEmitsRemainderLongerThanOneSecond() throws {
        let collector = Collector<MediaChunk>()
        let chunker = AudioChunker(source: .system, chunkDuration: 5, onChunk: collector.append)

        chunker.append(try makeBuffer(seconds: 1.5))
        #expect(collector.values.isEmpty)

        chunker.flush()
        let chunk = try #require(collector.values.first)
        #expect(chunk.source == .system)
        #expect(chunk.duration > 1 && chunk.duration <= 1.5)
        try FileManager.default.removeItem(at: chunk.url)
    }

    @Test func marksSilentChunks() throws {
        let collector = Collector<MediaChunk>()
        let chunker = AudioChunker(source: .microphone, chunkDuration: 1, overlapDuration: 0, onChunk: collector.append)

        chunker.append(try makeBuffer(seconds: 2.2, amplitude: 0))
        chunker.flush()

        // Silent chunks are still emitted back to back, just flagged.
        #expect(collector.values.count == 2)
        let allSilent = collector.values.allSatisfy { $0.isSilent }
        #expect(allSilent)
        try collector.values.forEach { try FileManager.default.removeItem(at: $0.url) }
    }

    @Test func soundChunksAreNotSilent() throws {
        let collector = Collector<MediaChunk>()
        let chunker = AudioChunker(source: .microphone, chunkDuration: 1, overlapDuration: 0, onChunk: collector.append)

        chunker.append(try makeBuffer(seconds: 1.2))

        let chunk = try #require(collector.values.first)
        #expect(!chunk.isSilent)
        try FileManager.default.removeItem(at: chunk.url)
    }

    @Test func chunksOverlapPreviousChunk() throws {
        let collector = Collector<MediaChunk>()
        let chunker = AudioChunker(source: .system, chunkDuration: 4, overlapDuration: 1, onChunk: collector.append)

        // 4 s, then every 3 s of new audio: chunks cover 0–4, 3–7, 6–10.
        chunker.append(try makeBuffer(seconds: 10.2))
        #expect(collector.values.count == 3)

        // Overlap: the last second of chunk 1 equals the first second of chunk 2.
        let first = try Data(contentsOf: collector.values[0].url)
        let second = try Data(contentsOf: collector.values[1].url)
        let oneSecond = 16_000 * 2
        #expect(first.suffix(oneSecond) == second.dropFirst(44).prefix(oneSecond))

        // Only 0.2 s of new audio remains, below the one-second minimum.
        chunker.flush()
        #expect(collector.values.count == 3)
        try collector.values.forEach { try FileManager.default.removeItem(at: $0.url) }
    }

    @Test func overlapIsCappedAtHalfAChunk() throws {
        let collector = Collector<MediaChunk>()
        let chunker = AudioChunker(source: .microphone, chunkDuration: 2, overlapDuration: 5, onChunk: collector.append)

        // Overlap is capped at 1 s: chunks cover 0–2, 1–3.
        chunker.append(try makeBuffer(seconds: 3.1))
        #expect(collector.values.count == 2)
        try collector.values.forEach { try FileManager.default.removeItem(at: $0.url) }
    }

    @Test func reportsLevelAndProgress() throws {
        let meters = Collector<CaptureMeter>()
        let chunker = AudioChunker(
            source: .microphone,
            chunkDuration: 4,
            overlapDuration: 0,
            onChunk: { _ in },
            onMeter: meters.append
        )

        chunker.append(try makeBuffer(seconds: 1))
        let meter = try #require(meters.values.last)
        #expect(meter.level > 0.3)
        #expect(abs(meter.progress - 0.25) < 0.02)
    }
}
