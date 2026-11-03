import SwiftUI

/// Main window: controls, live indicators, message field, optional settings,
/// then the transcript and assistant panels with the debug section below.
struct ContentView: View {
    let environment: AppEnvironment
    @State private var showSettings = false
    @State private var showDebug = false

    private var assistant: MeetingAssistant { environment.assistant }
    private var providers: ProviderConfiguration { environment.providers }

    var body: some View {
        VStack(spacing: 0) {
            ControlsBar(environment: environment, showSettings: $showSettings, showDebug: $showDebug)
                .padding()

            if !assistant.monitor.channels.isEmpty {
                RecordingIndicators(monitor: assistant.monitor)
                    .padding([.horizontal, .bottom])
            }

            MessageField(environment: environment)
                .padding([.horizontal, .bottom])

            if showSettings {
                SettingsForm(environment: environment)
                    .padding([.horizontal, .bottom])
            }

            Divider()

            VSplitView {
                HSplitView {
                    TranscriptPanel(transcript: assistant.transcript)
                        .frame(minWidth: 300)
                    AssistantPanel(suggestions: assistant.suggestions)
                        .frame(minWidth: 300)
                }
                .frame(minHeight: 200)

                if showDebug {
                    DebugView(chunkLog: assistant.chunkLog, requestLog: environment.requestLog)
                        .frame(minHeight: 160, idealHeight: 220)
                }
            }
        }
        .frame(minWidth: 860, minHeight: 520)
        .task(id: providers.provider) {
            // Load the model drop-down when switching to a configured remote provider.
            if providers.provider.isRemote, providers.isReady, providers.models(for: providers.provider).isEmpty {
                await providers.refreshModels()
            }
        }
    }
}

#Preview {
    ContentView(environment: AppEnvironment())
}
