import SwiftUI

/// Start/Stop, provider picker, capture toggles, status badges and toolbar buttons.
struct ControlsBar: View {
    let environment: AppEnvironment
    @Binding var showSettings: Bool
    @Binding var showDebug: Bool

    var body: some View {
        @Bindable var settings = environment.settings
        @Bindable var providers = environment.providers
        let assistant = environment.assistant

        HStack(spacing: 12) {
            Button {
                Task {
                    if assistant.isRunning {
                        await assistant.stop()
                    } else {
                        await assistant.start(
                            processor: environment.makeProcessor(),
                            options: settings.captureOptions
                        )
                    }
                }
            } label: {
                Label(
                    assistant.isRunning ? "Stop" : "Start",
                    systemImage: assistant.isRunning ? "stop.circle.fill" : "record.circle"
                )
            }
            .controlSize(.large)
            .tint(assistant.isRunning ? .red : .accentColor)
            .buttonStyle(.borderedProminent)
            .disabled(!assistant.isRunning && (!settings.captureOptions.hasInput || !providers.isReady))

            Picker("Mode", selection: $providers.provider) {
                ForEach(ProcessingProvider.allCases) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .disabled(assistant.isRunning)
            .help("Where captured audio and video are processed")

            Toggle("Microphone", isOn: $settings.captureMicrophone)
            Toggle("System audio", isOn: $settings.captureSystemAudio)
            Toggle("Screen", isOn: $settings.captureScreen)
                .help("Record the screen in short video chunks (used by remote providers)")

            Spacer()

            if assistant.isTranscribing {
                StatusBadge(text: "Transcribing", systemImage: "waveform")
            }
            if assistant.isThinking {
                StatusBadge(text: "Thinking", systemImage: "brain")
            }

            Button("Clear") { assistant.clear() }
            Button {
                showDebug.toggle()
            } label: {
                Image(systemName: "ladybug")
            }
            .help("Show recent chunks and API requests")
            Button {
                showSettings.toggle()
            } label: {
                Image(systemName: "gearshape")
            }
            .help("Settings")
        }
        .toggleStyle(.checkbox)
    }
}
