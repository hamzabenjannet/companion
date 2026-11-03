import Foundation
import Observation

/// Debug record of one captured chunk and what happened to it.
struct ChunkRecord: Identifiable, Equatable {
    enum Status: Equatable {
        case queued
        case processing
        case done(String)
        case skipped(String)
        case failed(String)

        /// Final states: the pipeline no longer needs the file.
        var isFinal: Bool {
            switch self {
            case .queued, .processing: return false
            case .done, .skipped, .failed: return true
            }
        }

        var label: String {
            switch self {
            case .queued: return "Queued"
            case .processing: return "Processing"
            case .done: return "Done"
            case .skipped: return "Skipped"
            case .failed: return "Failed"
            }
        }

        var detail: String? {
            switch self {
            case .queued, .processing: return nil
            case .done(let text), .skipped(let text), .failed(let text): return text.isEmpty ? nil : text
            }
        }
    }

    let chunk: MediaChunk
    let fileSize: Int64
    var status: Status

    var id: UUID { chunk.id }
}

/// Keeps the most recent chunks (10 by default) for the debug list. When a
/// chunk falls out of the list, its file is deleted, unless the pipeline is
/// still using it, in which case the file is deleted when processing finishes.
@Observable
final class ChunkLog {
    static let defaultCapacity = 10

    let capacity: Int
    /// Oldest first.
    private(set) var records: [ChunkRecord] = []

    /// Evicted chunks that were still being processed.
    @ObservationIgnored private var evictedInFlight: [UUID: URL] = [:]
    @ObservationIgnored private let fileManager: FileManager

    init(capacity: Int = ChunkLog.defaultCapacity, fileManager: FileManager = .default) {
        self.capacity = max(1, capacity)
        self.fileManager = fileManager
    }

    func add(_ chunk: MediaChunk) {
        let size = (try? fileManager.attributesOfItem(atPath: chunk.url.path)[.size] as? NSNumber)?.int64Value ?? 0
        records.append(ChunkRecord(chunk: chunk, fileSize: size, status: .queued))

        while records.count > capacity {
            let evicted = records.removeFirst()
            if evicted.status.isFinal {
                try? fileManager.removeItem(at: evicted.chunk.url)
            } else {
                evictedInFlight[evicted.id] = evicted.chunk.url
            }
        }
    }

    func update(_ chunk: MediaChunk, status: ChunkRecord.Status) {
        if let index = records.firstIndex(where: { $0.id == chunk.id }) {
            records[index].status = status
        } else if status.isFinal, let url = evictedInFlight.removeValue(forKey: chunk.id) {
            try? fileManager.removeItem(at: url)
        }
    }

    func status(of chunk: MediaChunk) -> ChunkRecord.Status? {
        records.first { $0.id == chunk.id }?.status
    }

    /// Removes finished records and their files; in-flight chunks stay listed.
    func clear() {
        for record in records where record.status.isFinal {
            try? fileManager.removeItem(at: record.chunk.url)
        }
        records.removeAll { $0.status.isFinal }
    }
}
