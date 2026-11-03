import Foundation
import Testing
@testable import companion

@MainActor
@Suite("Chunk debug log")
struct ChunkLogTests {
    @Test func defaultCapacityIsTen() {
        #expect(ChunkLog().capacity == 10)
        #expect(ChunkLog(capacity: 0).capacity == 1)
    }

    @Test func addRecordsFileSizeAndQueuedStatus() throws {
        let log = ChunkLog()
        let chunk = try TestFiles.makeChunk(source: .microphone, bytes: Data(count: 123))
        defer { log.clear() }

        log.add(chunk)

        let record = try #require(log.records.first)
        #expect(record.id == chunk.id)
        #expect(record.fileSize == 123)
        #expect(record.status == .queued)
    }

    @Test func keepsOnlyMostRecentChunksAndDeletesOldFiles() throws {
        let log = ChunkLog(capacity: 3)
        var chunks: [MediaChunk] = []
        for source in [CaptureSource.microphone, .system, .screen, .microphone, .system] {
            let chunk = try TestFiles.makeChunk(source: source)
            chunks.append(chunk)
            log.add(chunk)
            log.update(chunk, status: .done("ok"))
        }
        defer { log.clear() }

        #expect(log.records.map(\.id) == chunks.suffix(3).map(\.id))
        #expect(!TestFiles.exists(chunks[0].url))
        #expect(!TestFiles.exists(chunks[1].url))
        #expect(chunks.suffix(3).allSatisfy { TestFiles.exists($0.url) })
    }

    @Test func evictedInFlightChunkIsDeletedWhenFinished() throws {
        let log = ChunkLog(capacity: 1)
        let first = try TestFiles.makeChunk(source: .microphone)
        let second = try TestFiles.makeChunk(source: .system)
        defer { log.clear() }

        log.add(first)
        log.update(first, status: .processing)
        log.add(second)

        // Still being processed: the file must survive eviction.
        #expect(log.status(of: first) == nil)
        #expect(TestFiles.exists(first.url))

        log.update(first, status: .done("text"))
        #expect(!TestFiles.exists(first.url))
    }

    @Test func updateChangesStatus() throws {
        let log = ChunkLog()
        let chunk = try TestFiles.makeChunk(source: .screen)
        defer { log.clear() }
        log.add(chunk)

        log.update(chunk, status: .failed("HTTP 500"))

        #expect(log.status(of: chunk) == .failed("HTTP 500"))
    }

    @Test func clearRemovesFinishedRecordsOnly() throws {
        let log = ChunkLog()
        let finished = try TestFiles.makeChunk(source: .microphone)
        let inFlight = try TestFiles.makeChunk(source: .system)
        log.add(finished)
        log.add(inFlight)
        log.update(finished, status: .skipped("silence"))
        log.update(inFlight, status: .processing)

        log.clear()

        #expect(log.records.map(\.id) == [inFlight.id])
        #expect(!TestFiles.exists(finished.url))
        #expect(TestFiles.exists(inFlight.url))
        try FileManager.default.removeItem(at: inFlight.url)
    }

    @Test func statusPresentation() {
        typealias Status = ChunkRecord.Status
        #expect(!Status.queued.isFinal && !Status.processing.isFinal)
        #expect(Status.done("").isFinal && Status.skipped("").isFinal && Status.failed("").isFinal)
        #expect(Status.queued.label == "Queued")
        #expect(Status.failed("x").label == "Failed")
        #expect(Status.done("hello").detail == "hello")
        #expect(Status.done("").detail == nil)
        #expect(Status.processing.detail == nil)
    }
}
