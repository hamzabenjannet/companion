import AVFoundation
import CoreMedia

/// Receives screen frames and writes them to short H.264 MP4 files, starting
/// a new file every `chunkDuration` seconds of presentation time.
nonisolated final class VideoChunkWriter: @unchecked Sendable {
    private let chunkDuration: TimeInterval
    private let width: Int
    private let height: Int
    private let bitRate: Int
    private let onChunk: @Sendable (MediaChunk) -> Void
    private let onError: @Sendable (Error) -> Void

    // Guarded by `lock`; frames arrive on the capture queue.
    private let lock = NSLock()
    private var writer: AVAssetWriter?
    private var receiver: AVAssetWriterInput.SampleBufferReceiver?
    private var url: URL?
    private var startTime: CMTime = .invalid
    private var lastTime: CMTime = .invalid
    /// Finishing is asynchronous; `flush()` waits on this group.
    private let pending = DispatchGroup()

    init(
        chunkDuration: TimeInterval,
        width: Int,
        height: Int,
        bitRate: Int = 600_000,
        onChunk: @escaping @Sendable (MediaChunk) -> Void,
        onError: @escaping @Sendable (Error) -> Void = { _ in }
    ) {
        self.chunkDuration = chunkDuration
        self.width = width
        self.height = height
        self.bitRate = bitRate
        self.onChunk = onChunk
        self.onError = onError
    }

    func append(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        defer { lock.unlock() }

        let time = sampleBuffer.presentationTimeStamp
        guard time.isValid else { return }

        if writer != nil, (time - startTime).seconds >= chunkDuration {
            finishCurrentLocked()
        }
        if writer == nil {
            do {
                try startWriterLocked(at: time)
            } catch {
                onError(error)
                return
            }
        }
        guard let receiver else { return }
        // Drops the frame (returns false) when the input isn't ready, as before.
        do {
            if try receiver.appendImmediately(CMReadySampleBuffer(unsafeBuffer: sampleBuffer)) {
                lastTime = time
            }
        } catch {
            onError(error)
        }
    }

    /// Finishes the current file (if any) and waits until it is written. Call on stop.
    func flush() {
        lock.lock()
        finishCurrentLocked()
        lock.unlock()
        pending.wait()
    }

    private func startWriterLocked(at time: CMTime) throws {
        let url = MediaChunk.makeFileURL(source: .screen, fileExtension: "mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bitRate],
        ])
        guard writer.canAdd(input) else { throw CaptureError.videoWriter("cannot add video input") }
        let receiver = writer.inputReceiver(for: input)
        try writer.start()
        writer.startSession(atSourceTime: time)

        self.writer = writer
        self.receiver = receiver
        self.url = url
        startTime = time
        lastTime = .invalid
    }

    private func finishCurrentLocked() {
        guard let writer, let receiver, let url else { return }
        self.writer = nil
        self.receiver = nil
        self.url = nil

        // Nothing was appended: discard the empty file.
        guard lastTime.isValid else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            return
        }

        // Screen frames are only delivered when something changes, so pad the
        // session to cover at least one second after the last frame.
        let end = max(lastTime + CMTime(seconds: 1, preferredTimescale: 600), startTime)
        let duration = (end - startTime).seconds
        receiver.finish()
        writer.endSession(atSourceTime: end)

        pending.enter()
        let onChunk = onChunk
        let onError = onError
        let group = pending
        nonisolated(unsafe) let finishingWriter = writer
        writer.finishWriting {
            if finishingWriter.status == .completed {
                onChunk(MediaChunk(source: .screen, url: url, duration: duration, mimeType: "video/mp4"))
            } else {
                try? FileManager.default.removeItem(at: url)
                onError(CaptureError.videoWriter(finishingWriter.error?.localizedDescription ?? "unknown error"))
            }
            group.leave()
        }
    }
}
