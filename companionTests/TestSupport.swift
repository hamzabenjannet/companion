import Foundation
@testable import companion

/// Thread-safe collector for values delivered from capture/audio threads.
final class Collector<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []

    func append(_ value: Value) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }

    var values: [Value] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

/// Stub HTTP transport: records every request and answers with `handler`.
final class MockTransport: HTTPTransport, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (status: Int, body: Data)

    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    private let handler: Handler

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    /// Always answers with the same status and JSON body.
    convenience init(status: Int = 200, json: String) {
        self.init { _ in (status, Data(json.utf8)) }
    }

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        lock.withLock { recorded.append(request) }

        let (status, body) = try handler(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        return (body, response)
    }
}

/// Scriptable multimodal client.
final class MockMultimodalClient: MultimodalClient, @unchecked Sendable {
    struct Call {
        let model: String
        let systemPrompt: String
        let parts: [MediaPart]
    }

    private let lock = NSLock()
    private var recorded: [Call] = []
    private let models: [RemoteModel]
    private let reply: @Sendable (Int) throws -> String

    /// `reply` receives the zero-based call index.
    init(models: [RemoteModel] = [], reply: @escaping @Sendable (Int) throws -> String = { _ in "{}" }) {
        self.models = models
        self.reply = reply
    }

    var calls: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func listModels() async throws -> [RemoteModel] {
        models
    }

    func generate(model: String, systemPrompt: String, parts: [MediaPart]) async throws -> String {
        let index = lock.withLock {
            let index = recorded.count
            recorded.append(Call(model: model, systemPrompt: systemPrompt, parts: parts))
            return index
        }
        return try reply(index)
    }
}

struct TestError: LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }
}

enum TestFiles {
    /// Writes a small file into the chunk directory and returns a chunk pointing at it.
    static func makeChunk(
        source: CaptureSource,
        mimeType: String? = nil,
        duration: TimeInterval = 8,
        bytes: Data = Data([1, 2, 3, 4])
    ) throws -> MediaChunk {
        let type = mimeType ?? (source == .screen ? "video/mp4" : "audio/wav")
        let url = MediaChunk.makeFileURL(source: source, fileExtension: source == .screen ? "mp4" : "wav")
        try bytes.write(to: url)
        return MediaChunk(source: source, url: url, duration: duration, mimeType: type)
    }

    static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }
}

extension URLRequest {
    /// The JSON body decoded into a dictionary.
    var jsonBody: [String: Any]? {
        guard let httpBody else { return nil }
        return (try? JSONSerialization.jsonObject(with: httpBody)) as? [String: Any]
    }

    var queryItems: [String: String] {
        guard let url, let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return [:] }
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
    }
}
