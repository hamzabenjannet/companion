import SwiftUI

/// Sends typed text to the selected provider, whether or not recording is on.
struct MessageField: View {
    let environment: AppEnvironment
    @State private var text = ""
    @State private var isSending = false

    private var canSend: Bool {
        !isSending && environment.providers.isReady && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack {
            TextField("Type a message to the assistant…", text: $text)
                .textFieldStyle(.roundedBorder)
                .onSubmit(send)
            Button("Send", systemImage: "paperplane.fill", action: send)
                .disabled(!canSend)
        }
    }

    private func send() {
        guard canSend else { return }
        let message = text
        text = ""
        isSending = true
        Task {
            await environment.assistant.send(text: message, using: environment.makeProcessor())
            isSending = false
        }
    }
}
