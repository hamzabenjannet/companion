import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import companion

@Suite("Screen capture")
struct ScreenCaptureTests {
    @Test func outputSizeScalesDownAndStaysEven() {
        let size = ScreenCapture.outputSize(displayWidth: 3024, displayHeight: 1964, maxWidth: 1280)
        #expect(size.width == 1280)
        #expect(size.height == 830)
        #expect(size.width % 2 == 0 && size.height % 2 == 0)
    }

    @Test func outputSizeDoesNotUpscale() {
        let size = ScreenCapture.outputSize(displayWidth: 1001, displayHeight: 601, maxWidth: 1280)
        #expect(size.width == 1000)
        #expect(size.height == 600)
    }

    @Test func outputSizeHandlesInvalidDisplay() {
        let size = ScreenCapture.outputSize(displayWidth: 0, displayHeight: 0, maxWidth: 1280)
        #expect(size.width == 2 && size.height == 2)
    }
}

@Suite("Video chunk writer")
struct VideoChunkWriterTests {
    private func makeFrame(at seconds: Double, size: Int = 64) throws -> CMSampleBuffer {
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, size, size, kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
        let image = try #require(pixelBuffer)

        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: image, formatDescriptionOut: &format)

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 600),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: nil,
            imageBuffer: image,
            formatDescription: try #require(format),
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        return try #require(sampleBuffer)
    }

    @Test func rotatesFilesEveryChunkDuration() async throws {
        let chunks = Collector<MediaChunk>()
        let errors = Collector<String>()
        let writer = VideoChunkWriter(
            chunkDuration: 1,
            width: 64,
            height: 64,
            onChunk: chunks.append,
            onError: { errors.append($0.localizedDescription) }
        )

        for time in stride(from: 0.0, through: 2.5, by: 0.5) {
            writer.append(try makeFrame(at: time))
            try await Task.sleep(for: .milliseconds(30))
        }
        writer.flush()

        #expect(errors.values.isEmpty)
        let written = chunks.values.sorted { $0.createdAt < $1.createdAt }
        #expect(written.count == 3)
        for chunk in written {
            #expect(chunk.source == .screen)
            #expect(chunk.mimeType == "video/mp4")
            #expect(chunk.duration >= 1)
            let tracks = try await AVURLAsset(url: chunk.url).loadTracks(withMediaType: .video)
            #expect(tracks.count == 1)
            try FileManager.default.removeItem(at: chunk.url)
        }
    }

    @Test func flushWithoutFramesWritesNothing() {
        let chunks = Collector<MediaChunk>()
        let writer = VideoChunkWriter(chunkDuration: 1, width: 64, height: 64, onChunk: chunks.append)
        writer.flush()
        #expect(chunks.values.isEmpty)
    }
}
