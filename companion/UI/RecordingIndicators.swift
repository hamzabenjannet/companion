import SwiftUI

/// One live row per recording channel: a blinking dot, the audio level (or a
/// frame pulse for the screen), progress through the current chunk, and chunk counts.
struct RecordingIndicators: View {
    let monitor: CaptureMonitor

    var body: some View {
        HStack(spacing: 20) {
            ForEach(CaptureSource.allCases, id: \.self) { source in
                if let channel = monitor.channels[source] {
                    ChannelIndicator(source: source, channel: channel, chunkDuration: monitor.chunkDuration)
                }
            }
            Spacer()
        }
    }
}

struct ChannelIndicator: View {
    let source: CaptureSource
    let channel: CaptureMonitor.Channel
    let chunkDuration: TimeInterval

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Ticks so the dot blinks and the screen's wall-clock progress advances.
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            let progress = progress(at: context.date)
            HStack(spacing: 6) {
                Circle()
                    .fill(.red)
                    .frame(width: 8, height: 8)
                    .opacity(isBlinkOff(at: context.date) ? 0.3 : 1)
                Image(systemName: source.systemImage)
                    .foregroundStyle(source.tint)
                    .frame(width: 18)
                activity(at: context.date)
                ProgressView(value: progress)
                    .tint(source.tint)
                    .frame(width: 70)
                    .help("Current \(Int(chunkDuration)) s chunk")
                Text(countsText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(source.channelName) recording")
            .accessibilityValue("Chunk \(Int(progress * 100)) percent, \(countsText)")
        }
    }

    /// Audio: level meter. Screen: lights up when a new frame arrived recently.
    @ViewBuilder
    private func activity(at date: Date) -> some View {
        let fill: Double = if source == .screen {
            channel.lastFrameAt.map { date.timeIntervalSince($0) < 1.5 } == true ? 1 : 0.1
        } else {
            Self.normalizedLevel(channel.level)
        }
        ZStack(alignment: .leading) {
            Capsule().fill(.quaternary)
            Capsule()
                .fill(source.tint)
                .frame(width: 40 * fill)
        }
        .frame(width: 40, height: 6)
        .animation(.linear(duration: 0.1), value: fill)
    }

    private func progress(at date: Date) -> Double {
        guard source == .screen else { return channel.progress }
        // Screen frames only arrive on change, so measure the chunk by wall clock.
        return min(1, max(0, date.timeIntervalSince(channel.chunkStartedAt) / max(1, chunkDuration)))
    }

    private func isBlinkOff(at date: Date) -> Bool {
        !reduceMotion && Int(date.timeIntervalSinceReferenceDate * 2) % 2 == 1
    }

    private var countsText: String {
        channel.silentCount > 0
            ? "\(channel.sentCount) sent · \(channel.silentCount) silent"
            : "\(channel.sentCount) sent"
    }

    /// Maps RMS to 0...1 on a -50…0 dB scale so speech is clearly visible.
    static func normalizedLevel(_ rms: Float) -> Double {
        guard rms > 0 else { return 0 }
        let decibels = 20 * log10(Double(rms))
        return min(1, max(0, (decibels + 50) / 50))
    }
}
