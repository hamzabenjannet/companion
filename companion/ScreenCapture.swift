import AVFoundation
import CoreMedia
import ScreenCaptureKit

// MARK: - Video chunk writer

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

// MARK: - Screen capture

/// Records the main display (excluding this app's own windows) at a low frame
/// rate and resolution, and cuts it into MP4 chunks.
nonisolated final class ScreenCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let chunkDuration: TimeInterval
    private let framesPerSecond: Int
    private let maxWidth: Int
    private let onChunk: @Sendable (MediaChunk) -> Void
    private let onError: @Sendable (Error) -> Void
    private let sampleQueue = DispatchQueue(label: "companion.screen")
    private var stream: SCStream?
    private var writer: VideoChunkWriter?

    init(
        chunkDuration: TimeInterval,
        framesPerSecond: Int = 1,
        maxWidth: Int = 1280,
        onChunk: @escaping @Sendable (MediaChunk) -> Void,
        onError: @escaping @Sendable (Error) -> Void
    ) {
        self.chunkDuration = chunkDuration
        self.framesPerSecond = framesPerSecond
        self.maxWidth = maxWidth
        self.onChunk = onChunk
        self.onError = onError
    }

    /// Scales a display size down to `maxWidth`, keeping the aspect ratio and
    /// rounding to even numbers (required by H.264).
    static func outputSize(displayWidth: Int, displayHeight: Int, maxWidth: Int) -> (width: Int, height: Int) {
        guard displayWidth > 0, displayHeight > 0 else { return (2, 2) }
        let scale = min(1, Double(maxWidth) / Double(displayWidth))
        func even(_ value: Double) -> Int { max(2, Int(value.rounded()) & ~1) }
        return (even(Double(displayWidth) * scale), even(Double(displayHeight) * scale))
    }

    /// Triggers the Screen & System Audio Recording permission prompt on first use.
    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw CaptureError.noDisplay }

        let ownApps = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])

        let size = Self.outputSize(displayWidth: display.width, displayHeight: display.height, maxWidth: maxWidth)
        let config = SCStreamConfiguration()
        config.width = size.width
        config.height = size.height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, framesPerSecond)))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = true
        config.capturesAudio = false

        writer = VideoChunkWriter(
            chunkDuration: chunkDuration,
            width: size.width,
            height: size.height,
            onChunk: onChunk,
            onError: onError
        )

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil
        // Let the capture queue drain before finishing the last file.
        let writer = writer
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sampleQueue.async {
                writer?.flush()
                continuation.resume()
            }
        }
        self.writer = nil
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen, sampleBuffer.isValid, Self.isCompleteFrame(sampleBuffer) else { return }
        writer?.append(sampleBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError(error)
    }

    /// ScreenCaptureKit also sends idle/blank status buffers without pixels; skip those.
    private static func isCompleteFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
            let rawStatus = attachments.first?[.status] as? Int,
            let status = SCFrameStatus(rawValue: rawStatus)
        else { return false }
        return status == .complete
    }
}
