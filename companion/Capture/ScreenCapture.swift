import AVFoundation
import CoreMedia
import ScreenCaptureKit

/// Records the main display (excluding this app's own windows) at a low frame
/// rate and resolution, and cuts it into MP4 chunks.
nonisolated final class ScreenCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let chunkDuration: TimeInterval
    private let framesPerSecond: Int
    private let maxWidth: Int
    private let onChunk: @Sendable (MediaChunk) -> Void
    private let onError: @Sendable (Error) -> Void
    /// Called for every captured frame (frames only arrive when the screen changes).
    private let onFrame: @Sendable () -> Void
    private let sampleQueue = DispatchQueue(label: "companion.screen")
    private var stream: SCStream?
    private var writer: VideoChunkWriter?

    init(
        chunkDuration: TimeInterval,
        framesPerSecond: Int = 1,
        maxWidth: Int = 1280,
        onChunk: @escaping @Sendable (MediaChunk) -> Void,
        onError: @escaping @Sendable (Error) -> Void,
        onFrame: @escaping @Sendable () -> Void = {}
    ) {
        self.chunkDuration = chunkDuration
        self.framesPerSecond = framesPerSecond
        self.maxWidth = maxWidth
        self.onChunk = onChunk
        self.onError = onError
        self.onFrame = onFrame
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
        onFrame()
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
