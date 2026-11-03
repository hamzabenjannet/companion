import AVFoundation
import CoreMedia
import ScreenCaptureKit

/// Where a chunk of media came from. Mic and system audio are kept as separate
/// channels so transcripts can be attributed to "Me" (mic) or "Others" (system output).
nonisolated enum CaptureSource: String, Sendable, CaseIterable {
    case microphone
    case system
    case screen

    var speakerLabel: String {
        switch self {
        case .microphone: return "Me"
        case .system: return "Others"
        case .screen: return "Screen"
        }
    }

    /// Human-readable name of the capture channel, used in the debug list.
    var channelName: String {
        switch self {
        case .microphone: return "Microphone"
        case .system: return "System audio"
        case .screen: return "Screen recording"
        }
    }
}

/// A finished media file (WAV audio or MP4 video) ready to be processed.
nonisolated struct MediaChunk: Identifiable, Sendable, Equatable {
    let id: UUID
    let source: CaptureSource
    let url: URL
    let duration: TimeInterval
    let mimeType: String
    let createdAt: Date
    /// Audio too quiet to be worth processing. Still emitted so the debug list
    /// and indicators show that recording ran without gaps.
    let isSilent: Bool

    init(
        id: UUID = UUID(),
        source: CaptureSource,
        url: URL,
        duration: TimeInterval,
        mimeType: String,
        createdAt: Date = .now,
        isSilent: Bool = false
    ) {
        self.id = id
        self.source = source
        self.url = url
        self.duration = duration
        self.mimeType = mimeType
        self.createdAt = createdAt
        self.isSilent = isSilent
    }

    var isAudio: Bool { mimeType.hasPrefix("audio/") }
    var isVideo: Bool { mimeType.hasPrefix("video/") }

    /// Folder holding every chunk file. Files are deleted by `ChunkLog` once
    /// they fall out of the debug list.
    static var directory: URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("companion-chunks", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func makeFileURL(source: CaptureSource, fileExtension: String) -> URL {
        directory.appendingPathComponent("\(source.rawValue)-\(UUID().uuidString).\(fileExtension)")
    }
}

nonisolated enum CaptureError: LocalizedError {
    case microphoneDenied
    case noInputDevice
    case noDisplay
    case videoWriter(String)

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            return "Microphone access was denied. Enable it in System Settings › Privacy & Security › Microphone."
        case .noInputDevice:
            return "No usable microphone input was found."
        case .noDisplay:
            return "No display available for ScreenCaptureKit."
        case .videoWriter(let reason):
            return "Could not write the screen recording: \(reason)"
        }
    }
}

/// Live state of a capture channel, reported as buffers arrive.
nonisolated struct CaptureMeter: Sendable, Equatable {
    /// RMS level of the latest buffer (0...1).
    var level: Float
    /// How much of the current chunk's new audio is recorded (0...1).
    var progress: Double
}

// MARK: - Chunker

/// Receives PCM buffers in any format, converts them to 16 kHz mono Float32
/// (what Whisper expects), and emits a WAV file every `chunkDuration` seconds.
/// Chunks are cut back to back from one continuous buffer, and each one also
/// repeats the last `overlapDuration` seconds of the previous chunk, so a word
/// cut at a boundary is heard whole at least once. Chunks that are almost
/// silent are marked `isSilent` so they aren't sent (Whisper hallucinates on silence).
nonisolated final class AudioChunker: @unchecked Sendable {
    static let sampleRate: Double = 16_000
    static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: sampleRate,
        channels: 1,
        interleaved: false
    )!

    private let source: CaptureSource
    private let chunkFrames: Int
    private let overlapFrames: Int
    private let silenceThreshold: Float
    private let onChunk: @Sendable (MediaChunk) -> Void
    private let onMeter: @Sendable (CaptureMeter) -> Void

    // Guarded by `lock`; buffers arrive on audio threads.
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    /// Leading samples of `samples` that were already sent in the previous chunk.
    private var carriedFrames = 0

    init(
        source: CaptureSource,
        chunkDuration: TimeInterval,
        overlapDuration: TimeInterval = 1,
        silenceThreshold: Float = 0.003,
        onChunk: @escaping @Sendable (MediaChunk) -> Void,
        onMeter: @escaping @Sendable (CaptureMeter) -> Void = { _ in }
    ) {
        self.source = source
        self.chunkFrames = max(1, Int(chunkDuration * Self.sampleRate))
        // Keep the overlap at most half a chunk so every chunk is mostly new audio.
        self.overlapFrames = min(max(0, Int(overlapDuration * Self.sampleRate)), chunkFrames / 2)
        self.silenceThreshold = silenceThreshold
        self.onChunk = onChunk
        self.onMeter = onMeter
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        var ready: [[Float]] = []
        var level: Float = 0

        lock.lock()
        if let converted = convert(buffer), let channel = converted.floatChannelData {
            let new = Array(UnsafeBufferPointer(start: channel[0], count: Int(converted.frameLength)))
            samples.append(contentsOf: new)
            level = Self.rms(new)
        }
        while samples.count >= chunkFrames {
            ready.append(Array(samples.prefix(chunkFrames)))
            // Keep the tail so the next chunk starts with the overlap.
            samples.removeFirst(chunkFrames - overlapFrames)
            carriedFrames = overlapFrames
        }
        let progress = Double(samples.count - carriedFrames) / Double(chunkFrames - carriedFrames)
        lock.unlock()

        // Write files outside the lock to keep the audio thread responsive.
        ready.forEach(emit)
        onMeter(CaptureMeter(level: level, progress: min(1, max(0, progress))))
    }

    /// Emits whatever is buffered (if it holds at least one second of new audio). Call on stop.
    func flush() {
        lock.lock()
        let remaining = samples
        let carried = carriedFrames
        samples.removeAll()
        carriedFrames = 0
        converter = nil
        lock.unlock()

        if remaining.count - carried >= Int(Self.sampleRate) {
            emit(remaining)
        }
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let target = Self.targetFormat

        // Rebuild the converter if the input format changed (e.g. device switch).
        if converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
            converter?.downmix = true
        }
        guard let converter else { return nil }

        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1_024
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            return nil
        }

        // Feed the single input buffer once, then report "no data for now" so the
        // converter keeps its resampler state between calls.
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        return status == .error ? nil : output
    }

    private func emit(_ chunk: [Float]) {
        let url = MediaChunk.makeFileURL(source: source, fileExtension: "wav")
        do {
            try Self.wavData(from: chunk, sampleRate: Int(Self.sampleRate)).write(to: url)
            onChunk(MediaChunk(
                source: source,
                url: url,
                duration: Double(chunk.count) / Self.sampleRate,
                mimeType: "audio/wav",
                isSilent: Self.rms(chunk) < silenceThreshold
            ))
        } catch {
            // Dropping one chunk is acceptable for a POC; capture keeps running.
        }
    }

    static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sumOfSquares = samples.reduce(Float(0)) { $0 + $1 * $1 }
        return (sumOfSquares / Float(samples.count)).squareRoot()
    }

    /// Encodes mono Float32 samples as a 16-bit PCM WAV file.
    static func wavData(from samples: [Float], sampleRate: Int) -> Data {
        let pcm: [Int16] = samples.map { Int16(max(-1, min(1, $0)) * Float(Int16.max)) }
        let dataSize = pcm.count * MemoryLayout<Int16>.size

        var data = Data()
        func appendInteger<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }

        data.append(contentsOf: Array("RIFF".utf8))
        appendInteger(UInt32(36 + dataSize))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        appendInteger(UInt32(16))              // fmt chunk size
        appendInteger(UInt16(1))               // PCM
        appendInteger(UInt16(1))               // mono
        appendInteger(UInt32(sampleRate))
        appendInteger(UInt32(sampleRate * 2))  // byte rate
        appendInteger(UInt16(2))               // block align
        appendInteger(UInt16(16))              // bits per sample
        data.append(contentsOf: Array("data".utf8))
        appendInteger(UInt32(dataSize))
        pcm.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }
}

// MARK: - Microphone

/// Captures the default input device with AVAudioEngine.
nonisolated final class MicrophoneCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let chunker: AudioChunker

    init(chunker: AudioChunker) {
        self.chunker = chunker
    }

    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }

    func start() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw CaptureError.noInputDevice
        }

        // The tap delivers Sendable read-only buffers; copy into a mutable
        // AVAudioPCMBuffer because AVAudioConverter needs one as input.
        try input.installAudioTap(onBus: 0, bufferSize: 4_096, format: format) { [chunker] buffer, _ in
            chunker.append(AVAudioPCMBuffer(copying: buffer))
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        chunker.flush()
    }
}

// MARK: - System audio

/// Captures everything the Mac plays (browser meetings, Zoom, Teams, …) via
/// ScreenCaptureKit, excluding this app's own audio.
nonisolated final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let chunker: AudioChunker
    private let onError: @Sendable (Error) -> Void
    private let sampleQueue = DispatchQueue(label: "companion.system-audio")
    private var stream: SCStream?

    init(chunker: AudioChunker, onError: @escaping @Sendable (Error) -> Void) {
        self.chunker = chunker
        self.onError = onError
    }

    /// Triggers the Screen & System Audio Recording permission prompt on first use.
    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        guard let display = content.displays.first else { throw CaptureError.noDisplay }

        let filter = SCContentFilter(display: display, excludingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = Int(AudioChunker.sampleRate)
        config.channelCount = 1
        // Video can't be disabled, so keep it as cheap as possible.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        // A screen output is registered too, otherwise SCK logs dropped-frame errors.
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil
        chunker.flush()
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .audio, sampleBuffer.isValid, let buffer = sampleBuffer.makePCMBuffer() else {
            return
        }
        chunker.append(buffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError(error)
    }
}

private extension CMSampleBuffer {
    /// Copies the audio in this sample buffer into an AVAudioPCMBuffer.
    nonisolated func makePCMBuffer() -> AVAudioPCMBuffer? {
        guard var description = formatDescription?.audioStreamBasicDescription,
              let format = AVAudioFormat(streamDescription: &description) else {
            return nil
        }

        let frameCount = AVAudioFrameCount(numSamples)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return nil
        }
        buffer.frameLength = frameCount

        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            self,
            at: 0,
            frameCount: Int32(frameCount),
            into: buffer.mutableAudioBufferList
        )
        return status == noErr ? buffer : nil
    }
}
