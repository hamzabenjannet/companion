import Foundation

/// One line of the live transcript.
nonisolated struct TranscriptLine: Identifiable, Sendable {
    let id = UUID()
    let date: Date
    let source: CaptureSource
    let text: String
    /// Typed into the text box rather than heard.
    var isTyped = false

    var speakerLabel: String {
        isTyped ? "\(source.speakerLabel) (typed)" : source.speakerLabel
    }
}

/// One entry in the Assistant panel: a model answer or a status message.
nonisolated struct Suggestion: Identifiable, Sendable {
    enum Kind: Sendable {
        case answer
        case error
        case info
    }

    let id = UUID()
    let date: Date
    let kind: Kind
    let text: String
}
