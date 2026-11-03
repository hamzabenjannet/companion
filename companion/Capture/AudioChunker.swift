import AVFoundation

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
