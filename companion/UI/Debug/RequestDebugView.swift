import SwiftUI

/// Lists recent HTTP calls to Whisper, Ollama and remote models; the selected
/// one shows its request and response side by side.
struct RequestDebugView: View {
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
struct ExchangeSide: View {
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
