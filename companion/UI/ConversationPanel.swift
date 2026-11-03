import SwiftUI

/// A titled, auto-scrolling column.
struct Panel<Content: View>: View {
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

/// Live transcript, newest line first.
struct TranscriptPanel: View {
    let transcript: [TranscriptLine]

    var body: some View {
        Panel(title: "Transcript") {
            ForEach(transcript.reversed()) { line in
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
            transcript.last?.id
        }
    }
}

/// Model answers and status messages, newest first.
struct AssistantPanel: View {
    let suggestions: [Suggestion]

    var body: some View {
        Panel(title: "Assistant") {
            ForEach(suggestions.reversed()) { suggestion in
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
            suggestions.last?.id
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
