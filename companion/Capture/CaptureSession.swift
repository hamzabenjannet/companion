import Foundation

/// Which channels to record and how long each chunk is.
nonisolated struct CaptureOptions: Equatable, Sendable {
    var microphone: Bool
    var systemAudio: Bool
    var screen: Bool
    var chunkDuration: TimeInterval

    var hasInput: Bool { microphone || systemAudio || screen }
}

/// Status messages from the capture layer, shown in the Assistant panel.
nonisolated enum CaptureEvent: Equatable, Sendable {
    case info(String)
    case error(String)
}

/// Starts and stops the microphone, system audio and screen captures, and wires
/// their chunks and live meters to the pipeline and the indicators.
final class CaptureSession {
    private var microphone: MicrophoneCapture?
    private var systemAudio: SystemAudioCapture?
    private var screen: ScreenCapture?

    private static let screenPermissionHint =
        "grant access in System Settings › Privacy & Security › Screen & System Audio Recording, then relaunch."

    var isCapturing: Bool {
        microphone != nil || systemAudio != nil || screen != nil
    }

    /// Starts every requested channel. A channel that fails to start is
    /// reported and skipped; the others keep running.
    func start(
        options: CaptureOptions,
        monitor: CaptureMonitor,
        usesVideo: Bool,
        onChunk: @escaping @Sendable (MediaChunk) -> Void,
        report: @escaping @MainActor @Sendable (CaptureEvent) -> Void
    ) async {
        monitor.begin(chunkDuration: options.chunkDuration)
        // Capture threads report live state; hop to the main actor to update the indicators.
        func onMeter(_ source: CaptureSource) -> @Sendable (CaptureMeter) -> Void {
            { meter in Task { @MainActor in monitor.update(meter, for: source) } }
        }
        func onError(_ prefix: String) -> @Sendable (Error) -> Void {
            { error in Task { @MainActor in report(.error("\(prefix): \(error.localizedDescription)")) } }
        }

        if options.microphone {
            do {
                guard await MicrophoneCapture.requestAccess() else { throw CaptureError.microphoneDenied }
                let mic = MicrophoneCapture(
                    chunker: AudioChunker(
                        source: .microphone,
                        chunkDuration: options.chunkDuration,
                        onChunk: onChunk,
                        onMeter: onMeter(.microphone)
                    )
                )
                try mic.start()
                microphone = mic
                monitor.activate(.microphone)
                report(.info("Microphone capture started."))
            } catch {
                report(.error("Microphone: \(error.localizedDescription)"))
            }
        }

        if options.systemAudio {
            do {
                let system = SystemAudioCapture(
                    chunker: AudioChunker(
                        source: .system,
                        chunkDuration: options.chunkDuration,
                        onChunk: onChunk,
                        onMeter: onMeter(.system)
                    ),
                    onError: onError("System audio stopped")
                )
                try await system.start()
                systemAudio = system
                monitor.activate(.system)
                report(.info("System audio capture started."))
            } catch {
                report(.error("System audio: \(error.localizedDescription) — \(Self.screenPermissionHint)"))
            }
        }

        if options.screen {
            do {
                let capture = ScreenCapture(
                    chunkDuration: options.chunkDuration,
                    onChunk: onChunk,
                    onError: onError("Screen recording"),
                    onFrame: { Task { @MainActor in monitor.recordFrame(for: .screen) } }
                )
                try await capture.start()
                screen = capture
                monitor.activate(.screen)
                report(.info(usesVideo
                    ? "Screen recording started."
                    : "Screen recording started. Local mode can't read video, so screen chunks only appear in the debug list."))
            } catch {
                report(.error("Screen recording: \(error.localizedDescription) — \(Self.screenPermissionHint)"))
            }
        }
    }

    /// Stops every channel. Each capture flushes its last partial chunk first.
    func stop(monitor: CaptureMonitor) async {
        microphone?.stop()
        microphone = nil
        await systemAudio?.stop()
        systemAudio = nil
        await screen?.stop()
        screen = nil
        monitor.reset()
    }
}
