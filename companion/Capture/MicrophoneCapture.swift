import AVFoundation

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
