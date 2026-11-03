import SwiftUI

/// Provider endpoints, keys and models, plus capture and prompt settings.
/// Disabled while recording; changes apply on the next Start.
struct SettingsForm: View {
    let environment: AppEnvironment

    var body: some View {
        @Bindable var settings = environment.settings
        @Bindable var providers = environment.providers

        Form {
            if let remote = providers.settings(for: providers.provider) {
                RemoteProviderFields(settings: remote, providers: providers)
                Stepper(value: $providers.requestInterval, in: 0...60, step: 5) {
                    Text(providers.requestInterval == 0
                         ? "Request interval: as soon as chunks are ready"
                         : "Request interval: at least \(Int(providers.requestInterval)) s")
                }
            } else {
                TextField("Whisper URL", text: $settings.whisperBaseURL)
                TextField("Ollama URL", text: $settings.ollamaBaseURL)
                LocalModelFields(settings: settings, transport: environment.providers.transport)
            }
            TextField("Language (empty = auto)", text: $settings.language, prompt: Text("e.g. en, fr"))
            TextField(
                "System prompt",
                text: $settings.customInstructions,
                prompt: Text("Optional extra instructions, e.g. I'm a backend engineer interviewing for a staff role"),
                axis: .vertical
            )
            .lineLimit(2...5)
            Stepper(value: $settings.chunkSeconds, in: 3...30, step: 1) {
                Text("Chunk length: \(Int(settings.chunkSeconds)) s")
            }
            HStack {
                Button(providers.provider.isRemote ? "Test \(providers.provider.displayName)" : "Test Ollama") {
                    let processor = environment.makeProcessor()
                    Task { await environment.assistant.testConnection(using: processor) }
                }
                .disabled(!providers.isReady)
                Text("Changes apply on next Start. API keys are stored in the Keychain.")
                    .foregroundStyle(.secondary)
            }
            if let error = providers.lastError {
                Text(error)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .disabled(environment.assistant.isRunning)
    }
}

private struct LocalModelFields: View {
    @Bindable var settings: AppSettings
    let transport: any HTTPTransport

    @State private var models: [String] = []
    @State private var isLoading = false
    @State private var error: String?

    var body: some View {
        HStack {
            Picker("Ollama model", selection: $settings.ollamaModel) {
                if !models.contains(settings.ollamaModel) {
                    Text("\(settings.ollamaModel) (current)").tag(settings.ollamaModel)
                }
                ForEach(models, id: \.self) { model in
                    Text(model).tag(model)
                }
            }

            Button {
                Task { await refreshModels() }
            } label: {
                if isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .help("Reload models from Ollama")
            .disabled(isLoading)
        }

        if let error {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
                .textSelection(.enabled)
        }
    }

    private func refreshModels() async {
        isLoading = true
        error = nil
        defer { isLoading = false }

        do {
            models = try await LocalBackendClient.listModels(
                baseURL: settings.ollamaBaseURL,
                transport: transport
            )
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Host, API key, model picker and notes for one remote provider. Works for
/// any `RemoteProviderDefinition`, so new providers need no UI changes.
private struct RemoteProviderFields: View {
    @Bindable var settings: RemoteProviderSettings
    let providers: ProviderConfiguration

    var body: some View {
        let name = settings.definition.displayName
        TextField("\(name) URL", text: $settings.baseURL, prompt: Text(settings.definition.defaultBaseURL))
        SecureField("\(name) API key", text: $settings.apiKey)
            .onSubmit { Task { await providers.refreshModels() } }
        modelPicker
        if let note = settings.definition.settingsNote {
            Text(note)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Model drop-down filled from the provider's model list, with a refresh button.
    private var modelPicker: some View {
        HStack {
            Picker("Model", selection: $settings.model) {
                // Keep the saved model selectable even before the list is loaded.
                if !settings.models.contains(where: { $0.id == settings.model }) {
                    Text(settings.model).tag(settings.model)
                }
                ForEach(settings.models) { model in
                    Text("\(model.displayName) (\(model.id))").tag(model.id)
                }
            }
            Button {
                Task { await providers.refreshModels() }
            } label: {
                if providers.isLoadingModels {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .help("Reload the model list")
            .disabled(providers.isLoadingModels || !settings.isReady)
        }
    }
}
