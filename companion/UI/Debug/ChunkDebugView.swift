import AppKit
import SwiftUI

/// Lists the most recent chunks from every channel with their processing status.
struct ChunkDebugView: View {
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
