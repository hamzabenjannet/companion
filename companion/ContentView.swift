import AppKit
import SwiftUI

struct ContentView: View {
    @State private var assistant = MeetingAssistant()
    @State private var providers = ProviderConfiguration()
    @State private var showSettings = false
    @State private var showDebug = false

    @AppStorage("whisperBaseURL") private var whisperBaseURL = "http://localhost:42940"
    @AppStorage("ollamaBaseURL") private var ollamaBaseURL = "http://localhost:11434"
    @AppStorage("ollamaModel") private var ollamaModel = "qwen2.5:3b"
    @AppStorage("language") private var language = ""
    @AppStorage("chunkSeconds") private var chunkSeconds = 8.0
    @AppStorage("captureMicrophone") private var captureMicrophone = true
    @AppStorage("captureSystemAudio") private var captureSystemAudio = true
    @AppStorage("captureScreen") private var captureScreen = false

    private var settings: BackendSettings {
        BackendSettings(
            whisperBaseURL: whisperBaseURL,
            ollamaBaseURL: ollamaBaseURL,
            ollamaModel: ollamaModel,
            language: language
        )
    }

    /// Where chunks go, based on the selected provider.
    private var processingMode: ProcessingMode {
        let provider = providers.provider
        guard let client = providers.client(for: provider) else { return .local(settings) }
        return .remote(
            client: client,
            model: providers.selectedModel(for: provider),
            language: language,
            providerName: provider.displayName,
            minInterval: providers.requestInterval
        )
    }

    private var hasInput: Bool {
        captureMicrophone || captureSystemAudio || captureScreen
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
                .padding()

            if showSettings {
                settingsForm
                    .padding([.horizontal, .bottom])
            }

            Divider()

            VSplitView {
                HSplitView {
                    transcriptPanel
                        .frame(minWidth: 300)
                    suggestionsPanel
                        .frame(minWidth: 300)
                }
                .frame(minHeight: 200)

                if showDebug {
                    ChunkDebugView(log: assistant.chunkLog)
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

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 12) {
            Button {
                Task {
                    if assistant.isRunning {
                        await assistant.stop()
                    } else {
                        await assistant.start(
                            mode: processingMode,
                            chunkDuration: chunkSeconds,
                            captureMicrophone: captureMicrophone,
                            captureSystemAudio: captureSystemAudio,
                            captureScreen: captureScreen
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
            .disabled(!assistant.isRunning && (!hasInput || !providers.isReady))

            Picker("Mode", selection: $providers.provider) {
                ForEach(ProcessingProvider.allCases) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .disabled(assistant.isRunning)
            .help("Where captured audio and video are processed")

            Toggle("Microphone", isOn: $captureMicrophone)
            Toggle("System audio", isOn: $captureSystemAudio)
            Toggle("Screen", isOn: $captureScreen)
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
            .help("Show the last \(ChunkLog.defaultCapacity) recorded chunks")
            Button {
                showSettings.toggle()
            } label: {
                Image(systemName: "gearshape")
            }
            .help("Settings")
        }
        .toggleStyle(.checkbox)
    }

    private var settingsForm: some View {
        Form {
            switch providers.provider {
            case .local:
                TextField("Whisper URL", text: $whisperBaseURL)
                TextField("Ollama URL", text: $ollamaBaseURL)
                TextField("Ollama model", text: $ollamaModel)
            case .gemini:
                TextField("Gemini host", text: $providers.geminiBaseURL, prompt: Text(GeminiClient.defaultBaseURL))
                SecureField("Gemini API key", text: $providers.geminiAPIKey)
                    .onSubmit { Task { await providers.refreshModels() } }
                modelPicker(selection: $providers.geminiModel)
            case .openRouter:
                TextField("OpenRouter URL", text: $providers.openRouterBaseURL, prompt: Text(OpenRouterClient.defaultBaseURL))
                SecureField("OpenRouter API key", text: $providers.openRouterAPIKey)
                    .onSubmit { Task { await providers.refreshModels() } }
                modelPicker(selection: $providers.openRouterModel)
                Text("Audio input needs at least $0.50 of OpenRouter credit, even on :free models. Free models are limited to 20 requests/min and 50/day; use the request interval below to stay under them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if providers.provider.isRemote {
                Stepper(value: $providers.requestInterval, in: 0...60, step: 5) {
                    Text(providers.requestInterval == 0
                         ? "Request interval: as soon as chunks are ready"
                         : "Request interval: at least \(Int(providers.requestInterval)) s")
                }
            }
            TextField("Language (empty = auto)", text: $language, prompt: Text("e.g. en, fr"))
            Stepper(value: $chunkSeconds, in: 3...30, step: 1) {
                Text("Chunk length: \(Int(chunkSeconds)) s")
            }
            HStack {
                if providers.provider.isRemote {
                    Button("Test \(providers.provider.displayName)") {
                        let provider = providers.provider
                        guard let client = providers.client(for: provider) else { return }
                        Task {
                            await assistant.testRemote(
                                client: client,
                                model: providers.selectedModel(for: provider),
                                providerName: provider.displayName
                            )
                        }
                    }
                    .disabled(!providers.isReady)
                } else {
                    Button("Test Ollama") {
                        Task { await assistant.testOllama(settings: settings) }
                    }
                }
                Text("Changes apply on next Start. API keys are stored in the Keychain.")
                    .foregroundStyle(.secondary)
            }
            if let error = providers.lastError {
                Text(error)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .disabled(assistant.isRunning)
    }

    /// Model drop-down filled from the provider's model list, with a refresh button.
    private func modelPicker(selection: Binding<String>) -> some View {
        let models = providers.models(for: providers.provider)
        return HStack {
            Picker("Model", selection: selection) {
                // Keep the saved model selectable even before the list is loaded.
                if !models.contains(where: { $0.id == selection.wrappedValue }) {
                    Text(selection.wrappedValue).tag(selection.wrappedValue)
                }
                ForEach(models) { model in
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
            .disabled(providers.isLoadingModels || !providers.isReady)
        }
    }

    // MARK: Panels

    private var transcriptPanel: some View {
        Panel(title: "Transcript") {
            ForEach(assistant.transcript) { line in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(line.source.speakerLabel) · \(line.date.formatted(date: .omitted, time: .standard))")
                        .font(.caption.bold())
                        .foregroundStyle(line.source.tint)
                    Text(line.text)
                        .textSelection(.enabled)
                }
                .id(line.id)
            }
        } lastID: {
            assistant.transcript.last?.id
        }
    }

    private var suggestionsPanel: some View {
        Panel(title: "Assistant") {
            ForEach(assistant.suggestions) { suggestion in
                VStack(alignment: .leading, spacing: 2) {
                    Text(suggestion.date.formatted(date: .omitted, time: .standard))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(suggestion.text)
                        .font(suggestion.kind == .answer ? .body : .callout)
                        .foregroundStyle(color(for: suggestion.kind))
                        .textSelection(.enabled)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    suggestion.kind == .answer ? Color.accentColor.opacity(0.1) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8)
                )
                .id(suggestion.id)
            }
        } lastID: {
            assistant.suggestions.last?.id
        }
    }

    private func color(for kind: Suggestion.Kind) -> Color {
        switch kind {
        case .answer: return .primary
        case .error: return .red
        case .info: return .secondary
        }
    }
}

/// A titled, auto-scrolling column.
private struct Panel<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    let lastID: () -> UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.headline)
                .padding([.horizontal, .top])
                .padding(.bottom, 8)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        content
                    }
                    .padding([.horizontal, .bottom])
                }
                .onChange(of: lastID()) { _, newID in
                    guard let newID else { return }
                    withAnimation { proxy.scrollTo(newID, anchor: .bottom) }
                }
            }
        }
    }
}

/// Lists the most recent chunks from every channel with their processing status.
private struct ChunkDebugView: View {
    let log: ChunkLog

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Debug · last \(log.capacity) chunks")
                    .font(.headline)
                Spacer()
                Button("Open Folder") {
                    NSWorkspace.shared.open(MediaChunk.directory)
                }
                Button("Clear") { log.clear() }
            }
            .padding([.horizontal, .top])
            .padding(.bottom, 8)

            if log.records.isEmpty {
                Text("No chunks yet. Press Start to record.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(Array(log.records.reversed())) {
                    TableColumn("Channel") { record in
                        Label(record.chunk.source.channelName, systemImage: record.chunk.source.systemImage)
                            .foregroundStyle(record.chunk.source.tint)
                    }
                    .width(min: 130, ideal: 150)
                    TableColumn("Time") { record in
                        Text(record.chunk.createdAt.formatted(date: .omitted, time: .standard))
                    }
                    .width(min: 70, ideal: 80)
                    TableColumn("Length") { record in
                        Text("\(record.chunk.duration, specifier: "%.1f") s")
                    }
                    .width(min: 50, ideal: 60)
                    TableColumn("Size") { record in
                        Text(record.fileSize.formatted(.byteCount(style: .file)))
                    }
                    .width(min: 60, ideal: 70)
                    TableColumn("Status") { record in
                        Text(record.status.label)
                            .foregroundStyle(statusColor(record.status))
                            .help(record.status.detail ?? "")
                    }
                    .width(min: 70, ideal: 80)
                    TableColumn("Details") { record in
                        Text(record.status.detail ?? "")
                            .lineLimit(1)
                            .help(record.status.detail ?? "")
                    }
                    TableColumn("") { record in
                        Button("Play") { NSWorkspace.shared.open(record.chunk.url) }
                            .buttonStyle(.link)
                            .disabled(!FileManager.default.fileExists(atPath: record.chunk.url.path))
                    }
                    .width(40)
                }
            }
        }
    }

    private func statusColor(_ status: ChunkRecord.Status) -> Color {
        switch status {
        case .queued, .processing: return .secondary
        case .done: return .green
        case .skipped: return .orange
        case .failed: return .red
        }
    }
}

private extension CaptureSource {
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

private struct StatusBadge: View {
    let text: String
    let systemImage: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

#Preview {
    ContentView()
}
