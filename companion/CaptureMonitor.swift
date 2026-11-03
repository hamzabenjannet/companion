import Foundation
import Observation

/// Live state of every running capture channel, for the recording indicators.
/// Kept separate from `MeetingAssistant` so frequent level updates only
/// refresh the indicator row.
@Observable
final class CaptureMonitor {
    struct Channel: Equatable {
        /// Latest audio level (0...1); unused for the screen.
        var level: Float = 0
        /// How much of the current audio chunk is recorded (0...1).
        var progress: Double = 0
        /// When the current chunk started. The screen uses it for progress,
        /// because frames only arrive when something changes.
        var chunkStartedAt: Date = .now
        /// When the last screen frame arrived.
        var lastFrameAt: Date?
        /// Chunks with content, handed to the pipeline.
        var sentCount = 0
        /// Near-silent audio chunks that were recorded but not sent.
        var silentCount = 0
    }

    /// Only channels that are currently recording, keyed by source.
    private(set) var channels: [CaptureSource: Channel] = [:]
    private(set) var chunkDuration: TimeInterval = 8

    func begin(chunkDuration: TimeInterval) {
        self.chunkDuration = chunkDuration
        channels.removeAll()
    }

    func activate(_ source: CaptureSource) {
        channels[source] = Channel()
    }

    func reset() {
        channels.removeAll()
    }

    /// Updates are ignored for channels that aren't running (e.g. late updates after stop).
    func update(_ meter: CaptureMeter, for source: CaptureSource) {
        guard channels[source] != nil else { return }
        channels[source]?.level = meter.level
        channels[source]?.progress = meter.progress
    }

    func recordFrame(for source: CaptureSource, at date: Date = .now) {
        guard channels[source] != nil else { return }
        channels[source]?.lastFrameAt = date
    }

    func record(_ chunk: MediaChunk, at date: Date = .now) {
        guard channels[chunk.source] != nil else { return }
        if chunk.isSilent {
            channels[chunk.source]?.silentCount += 1
        } else {
            channels[chunk.source]?.sentCount += 1
        }
        channels[chunk.source]?.chunkStartedAt = date
    }
}
