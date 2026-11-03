import AVFoundation
import CoreMedia
import ScreenCaptureKit

/// Where a chunk of media came from. Mic and system audio are kept as separate
/// channels so transcripts can be attributed to "Me" (mic) or "Others" (system output).
nonisolated enum CaptureSource: String, Sendable, CaseIterable {
    case microphone
    case system
    case screen

    var speakerLabel: String {
        switch self {
        case .microphone: return "Me"
        case .system: return "Others"
        case .screen: return "Screen"
        }
    }

    /// Human-readable name of the capture channel, used in the debug list.
    var channelName: String {
        switch self {
        case .microphone: return "Microphone"
        case .system: return "System audio"
        case .screen: return "Screen recording"
        }
    }
}

/// A finished media file (WAV audio or MP4 video) ready to be processed.
nonisolated struct MediaChunk: Identifiable, Sendable, Equatable {
    let id: UUID
    let source: CaptureSource
    let url: URL
    let duration: TimeInterval
    let mimeType: String
    let createdAt: Date
    /// Audio too quiet to be worth processing. Still emitted so the debug list
    /// and indicators show that recording ran without gaps.
    let isSilent: Bool

    init(
        id: UUID = UUID(),
        source: CaptureSource,
        url: URL,
        duration: TimeInterval,
        mimeType: String,
        createdAt: Date = .now,
        isSilent: Bool = false
    ) {
        self.id = id
        self.source = source
        self.url = url
        self.duration = duration
        self.mimeType = mimeType
        self.createdAt = createdAt
        self.isSilent = isSilent
    }

    var isAudio: Bool { mimeType.hasPrefix("audio/") }
    var isVideo: Bool { mimeType.hasPrefix("video/") }

    /// Folder holding every chunk file. Files are deleted by `ChunkLog` once
    /// they fall out of the debug list.
    static var directory: URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("companion-chunks", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func makeFileURL(source: CaptureSource, fileExtension: String) -> URL {
        directory.appendingPathComponent("\(source.rawValue)-\(UUID().uuidString).\(fileExtension)")
    }
}

nonisolated enum CaptureError: LocalizedError {
    case microphoneDenied
    case noInputDevice
    case noDisplay
    case videoWriter(String)

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            return "Microphone access was denied. Enable it in System Settings › Privacy & Security › Microphone."
        case .noInputDevice:
            return "No usable microphone input was found."
        case .noDisplay:
            return "No display available for ScreenCaptureKit."
        case .videoWriter(let reason):
            return "Could not write the screen recording: \(reason)"
        }
    }
}

/// Live state of a capture channel, reported as buffers arrive.
nonisolated struct CaptureMeter: Sendable, Equatable {
    /// RMS level of the latest buffer (0...1).
    var level: Float
    /// How much of the current chunk's new audio is recorded (0...1).
    var progress: Double
}
