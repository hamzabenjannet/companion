import SwiftUI

extension CaptureSource {
    var tint: Color {
        switch self {
        case .microphone: return .blue
        case .system: return .orange
        case .screen: return .purple
        }
    }

    var systemImage: String {
        switch self {
        case .microphone: return "mic"
        case .system: return "speaker.wave.2"
        case .screen: return "display"
        }
    }
}
