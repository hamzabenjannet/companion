import AppKit
import SwiftUI

struct ContentView: View {
    @State private var assistant: MeetingAssistant
    @State private var providers: ProviderConfiguration
    @State private var requestLog: RequestLog
    @State private var showSettings = false
    @State private var showDebug = false
    @State private var messageText = ""
    @State private var isSending = false

    @AppStorage("whisperBaseURL") private var whisperBaseURL = "http://localhost:42940"
    @AppStorage("ollamaBaseURL") private var ollamaBaseURL = "http://localhost:11434"
    @AppStorage("ollamaModel") private var ollamaModel = "qwen2.5:3b"
    @AppStorage("language") private var language = ""
    @AppStorage("chunkSeconds") private var chunkSeconds = 8.0
    @AppStorage("captureMicrophone") private var captureMicrophone = true
    @AppStorage("captureSystemAudio") private var captureSystemAudio = true
    @AppStorage("captureScreen") private var captureScreen = false
    /// Extra instructions appended to the built-in system prompt (empty = none).
    @AppStorage("customInstructions") private var customInstructions = ""

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

    init() {
        // Every API call goes through one logging transport so the debug section can show it.
        let log = RequestLog()
        let transport = LoggingTransport(base: URLSession.shared, log: log)
        _requestLog = State(initialValue: log)
        _assistant = State(initialValue: MeetingAssistant(transport: transport))
        _providers = State(initialValue: ProviderConfiguration(transport: transport))
    }

    private var hasInput: Bool {
        captureMicrophone || captureSystemAudio || captureScreen
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
                .padding()

            if !assistant.monitor.channels.isEmpty {
                RecordingIndicators(monitor: assistant.monitor)
                    .padding([.horizontal, .bottom])
            }

            messageField
                .padding([.horizontal, .bottom])

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
                    DebugView(chunkLog: assistant.chunkLog, requestLog: requestLog)
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
                        assistant.customInstructions = customInstructions
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

    /// Sends typed text to the selected provider, whether or not recording is on.
    private var messageField: some View {
        HStack {
            TextField("Type a message to the assistant…", text: $messageText)
                .textFieldStyle(.roundedBorder)
                .onSubmit(sendMessage)
            Button("Send", systemImage: "paperplane.fill", action: sendMessage)
                .disabled(!canSendMessage)
        }
    }

    private var canSendMessage: Bool {
        !isSending && providers.isReady && !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func sendMessage() {
        guard canSendMessage else { return }
        let text = messageText
        messageText = ""
        isSending = true
        assistant.customInstructions = customInstructions
        Task {
            await assistant.send(text: text, mode: processingMode)
            isSending = false
        }
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
            TextField(
                "System prompt",
                text: $customInstructions,
                prompt: Text("Optional extra instructions, e.g. I'm a backend engineer interviewing for a staff role"),
                axis: .vertical
            )
            .lineLimit(2...5)
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
            ForEach(assistant.transcript.reversed()) { line in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(line.speakerLabel) · \(line.date.formatted(date: .omitted, time: .standard))")
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
            ForEach(assistant.suggestions.reversed()) { suggestion in
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
                    // Newest entries are listed first, so keep the top in view.
                    withAnimation { proxy.scrollTo(newID, anchor: .top) }
                }
            }
        }
    }
}

/// Debug section with two tabs: recorded chunks and API requests.
private struct DebugView: View {
    enum Tab: Hashable {
        case chunks
        case requests
    }

    let chunkLog: ChunkLog
    let requestLog: RequestLog
    @State private var tab = Tab.chunks

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("Debug", selection: $tab) {
                Text("Chunks").tag(Tab.chunks)
                Text("Requests").tag(Tab.requests)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding([.horizontal, .top])

            switch tab {
            case .chunks: ChunkDebugView(log: chunkLog)
            case .requests: RequestDebugView(log: requestLog)
            }
        }
    }
}

/// Lists recent HTTP calls to Whisper, Ollama and remote models; the selected
/// one shows its request and response side by side.
private struct RequestDebugView: View {
    let log: RequestLog
    @State private var selection: HTTPExchange.ID?

    private var selected: HTTPExchange? {
        log.exchanges.first { $0.id == selection } ?? log.exchanges.last
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Requests · last \(log.capacity)")
                    .font(.headline)
                Spacer()
                Button("Clear") {
                    log.clear()
                    selection = nil
                }
            }
            .padding([.horizontal, .top])
            .padding(.bottom, 8)

            if log.exchanges.isEmpty {
                Text("No API requests yet. Start recording, send a message, or use a Test button.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    Table(Array(log.exchanges.reversed()), selection: $selection) {
                        TableColumn("Time") { exchange in
                            Text(exchange.startedAt.formatted(date: .omitted, time: .standard))
                        }
                        .width(min: 70, ideal: 80)
                        TableColumn("Service") { exchange in
                            Text(exchange.service)
                        }
                        .width(min: 70, ideal: 80)
                        TableColumn("Method") { exchange in
                            Text(exchange.method)
                                .font(.body.monospaced())
                        }
                        .width(min: 50, ideal: 55)
                        TableColumn("Endpoint") { exchange in
                            Text(exchange.endpoint)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(exchange.url)
                        }
                        TableColumn("Status") { exchange in
                            Text(statusText(exchange))
                                .foregroundStyle(statusColor(exchange))
                        }
                        .width(min: 55, ideal: 65)
                        TableColumn("Time taken") { exchange in
                            Text(exchange.duration.map { String(format: "%.2f s", $0) } ?? "…")
                                .monospacedDigit()
                        }
                        .width(min: 60, ideal: 70)
                    }
                    .frame(minWidth: 380)

                    if let selected {
                        HStack(alignment: .top, spacing: 0) {
                            ExchangeSide(
                                title: "Request",
                                summary: "\(selected.method) \(selected.url)",
                                headers: selected.requestHeaders,
                                content: selected.requestBody
                            )
                            Divider()
                            ExchangeSide(
                                title: "Response",
                                summary: responseSummary(selected),
                                headers: selected.responseHeaders,
                                content: selected.error ?? selected.responseBody ?? ""
                            )
                        }
                        .frame(minWidth: 380)
                    }
                }
            }
        }
    }

    private func statusText(_ exchange: HTTPExchange) -> String {
        if let status = exchange.status { return "\(status)" }
        return exchange.error == nil ? "…" : "Error"
    }

    private func statusColor(_ exchange: HTTPExchange) -> Color {
        guard exchange.isFinished else { return .secondary }
        guard let status = exchange.status else { return .red }
        return (200..<300).contains(status) ? .green : .red
    }

    private func responseSummary(_ exchange: HTTPExchange) -> String {
        guard exchange.isFinished else { return "Waiting for response…" }
        let duration = exchange.duration.map { String(format: " · %.2f s", $0) } ?? ""
        if let status = exchange.status {
            return "HTTP \(status) \(HTTPURLResponse.localizedString(forStatusCode: status))\(duration)"
        }
        return "Failed\(duration)"
    }
}

/// One half of the request/response detail: summary line, headers and body.
private struct ExchangeSide: View {
    let title: String
    let summary: String
    let headers: [(name: String, value: String)]
    let content: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.headline)
                Text(summary)
                    .font(.callout.monospaced())
                if !headers.isEmpty {
                    Text(headers.map { "\($0.name): \($0.value)" }.joined(separator: "\n"))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Divider()
                Text(content.isEmpty ? "(empty body)" : content)
                    .font(.caption.monospaced())
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
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

/// One live row per recording channel: a blinking dot, the audio level (or a
/// frame pulse for the screen), progress through the current chunk, and chunk counts.
private struct RecordingIndicators: View {
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

private struct ChannelIndicator: View {
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
