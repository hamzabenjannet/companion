import SwiftUI

/// Debug section with two tabs: recorded chunks and API requests.
struct DebugView: View {
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
