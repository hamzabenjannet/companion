import Foundation
import Observation

/// User preferences that are not tied to a remote provider: capture channels,
/// chunk length, language, the local backend and custom instructions.
///
/// Values live in `UserDefaults` under the same keys the app has always used.
@Observable
final class AppSettings {
    enum Key {
        static let whisperBaseURL = "whisperBaseURL"
        static let ollamaBaseURL = "ollamaBaseURL"
        static let ollamaModel = "ollamaModel"
        static let ollamaSystemPrompt = "ollamaSystemPrompt"
        static let ollamaUserMessageTemplate = "ollamaUserMessageTemplate"
        static let language = "language"
        static let chunkSeconds = "chunkSeconds"
        static let captureMicrophone = "captureMicrophone"
        static let captureSystemAudio = "captureSystemAudio"
        static let captureScreen = "captureScreen"
        static let customInstructions = "customInstructions"
    }

    enum Default {
        static let whisperBaseURL = "http://localhost:42940"
        static let ollamaBaseURL = "http://localhost:11434"
        static let ollamaModel = "qwen2.5:3b"
        static let ollamaSystemPrompt = PromptInstructions.localSystemPrompt
        static let ollamaUserMessageTemplate = PromptInstructions.localUserMessageTemplate
        static let chunkSeconds = 8.0
    }

    var whisperBaseURL: String { didSet { defaults.set(whisperBaseURL, forKey: Key.whisperBaseURL) } }
    var ollamaBaseURL: String { didSet { defaults.set(ollamaBaseURL, forKey: Key.ollamaBaseURL) } }
    var ollamaModel: String { didSet { defaults.set(ollamaModel, forKey: Key.ollamaModel) } }
    var ollamaSystemPrompt: String { didSet { defaults.set(ollamaSystemPrompt, forKey: Key.ollamaSystemPrompt) } }
    var ollamaUserMessageTemplate: String { didSet { defaults.set(ollamaUserMessageTemplate, forKey: Key.ollamaUserMessageTemplate) } }
    /// Language code such as `en` or `fr`; empty lets the model detect it.
    var language: String { didSet { defaults.set(language, forKey: Key.language) } }
    var chunkSeconds: Double { didSet { defaults.set(chunkSeconds, forKey: Key.chunkSeconds) } }
    var captureMicrophone: Bool { didSet { defaults.set(captureMicrophone, forKey: Key.captureMicrophone) } }
    var captureSystemAudio: Bool { didSet { defaults.set(captureSystemAudio, forKey: Key.captureSystemAudio) } }
    var captureScreen: Bool { didSet { defaults.set(captureScreen, forKey: Key.captureScreen) } }
    /// Extra instructions appended to the built-in system prompt (empty = none).
    var customInstructions: String { didSet { defaults.set(customInstructions, forKey: Key.customInstructions) } }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        whisperBaseURL = defaults.string(forKey: Key.whisperBaseURL) ?? Default.whisperBaseURL
        ollamaBaseURL = defaults.string(forKey: Key.ollamaBaseURL) ?? Default.ollamaBaseURL
        ollamaModel = defaults.string(forKey: Key.ollamaModel) ?? Default.ollamaModel
        ollamaSystemPrompt = defaults.string(forKey: Key.ollamaSystemPrompt) ?? Default.ollamaSystemPrompt
        ollamaUserMessageTemplate = defaults.string(forKey: Key.ollamaUserMessageTemplate) ?? Default.ollamaUserMessageTemplate
        language = defaults.string(forKey: Key.language) ?? ""
        chunkSeconds = defaults.object(forKey: Key.chunkSeconds) as? Double ?? Default.chunkSeconds
        captureMicrophone = defaults.object(forKey: Key.captureMicrophone) as? Bool ?? true
        captureSystemAudio = defaults.object(forKey: Key.captureSystemAudio) as? Bool ?? true
        captureScreen = defaults.object(forKey: Key.captureScreen) as? Bool ?? false
        customInstructions = defaults.string(forKey: Key.customInstructions) ?? ""
    }

    var localBackend: LocalBackendSettings {
        LocalBackendSettings(
            whisperBaseURL: whisperBaseURL,
            ollamaBaseURL: ollamaBaseURL,
            ollamaModel: ollamaModel,
            ollamaSystemPrompt: ollamaSystemPrompt,
            ollamaUserMessageTemplate: ollamaUserMessageTemplate,
            language: language
        )
    }

    var captureOptions: CaptureOptions {
        CaptureOptions(
            microphone: captureMicrophone,
            systemAudio: captureSystemAudio,
            screen: captureScreen,
            chunkDuration: chunkSeconds
        )
    }
}
