import AVFoundation
import CoreMedia
import ScreenCaptureKit

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
