import Foundation
import Testing
@testable import companion

@MainActor
@Suite("Capture monitor")
struct CaptureMonitorTests {
    private func chunk(_ source: CaptureSource, silent: Bool = false) -> MediaChunk {
        MediaChunk(source: source, url: URL(fileURLWithPath: "/tmp/x"), duration: 8, mimeType: "audio/wav", isSilent: silent)
    }

    @Test func ignoresInactiveChannels() {
        let monitor = CaptureMonitor()
        monitor.begin(chunkDuration: 5)
        monitor.update(CaptureMeter(level: 0.5, progress: 0.5), for: .microphone)
        monitor.record(chunk(.microphone))
        monitor.recordFrame(for: .screen)
        #expect(monitor.channels.isEmpty)
        #expect(monitor.chunkDuration == 5)
    }

    @Test func tracksMetersAndCounts() {
        let monitor = CaptureMonitor()
        monitor.begin(chunkDuration: 8)
        monitor.activate(.microphone)
        monitor.activate(.screen)

        monitor.update(CaptureMeter(level: 0.2, progress: 0.4), for: .microphone)
        monitor.record(chunk(.microphone))
        monitor.record(chunk(.microphone, silent: true))
        let frameDate = Date(timeIntervalSinceReferenceDate: 100)
        monitor.recordFrame(for: .screen, at: frameDate)
        let chunkDate = Date(timeIntervalSinceReferenceDate: 200)
        monitor.record(chunk(.screen), at: chunkDate)

        let mic = monitor.channels[.microphone]
        #expect(mic?.level == 0.2)
        #expect(mic?.progress == 0.4)
        #expect(mic?.sentCount == 1)
        #expect(mic?.silentCount == 1)

        let screen = monitor.channels[.screen]
        #expect(screen?.lastFrameAt == frameDate)
        #expect(screen?.chunkStartedAt == chunkDate)
        #expect(screen?.sentCount == 1)

        monitor.reset()
        #expect(monitor.channels.isEmpty)
    }
}
