import Foundation
import Observation

/// One HTTP request/response pair, prepared for display: API keys are masked
/// and media payloads are replaced by short placeholders.
nonisolated struct HTTPExchange: Identifiable, Equatable, Sendable {
    let id: UUID
    let startedAt: Date
    let service: String
    let method: String
    let url: String
    let requestHeaders: [(name: String, value: String)]
    let requestBody: String
    var status: Int?
    var duration: TimeInterval?
    var responseHeaders: [(name: String, value: String)] = []
    var responseBody: String?
    var error: String?

    var isFinished: Bool { status != nil || error != nil }

    /// Path plus query, e.g. `/v1beta/models/gemini-2.5-flash:generateContent`.
    var endpoint: String {
        guard let components = URLComponents(string: url) else { return url }
        return components.percentEncodedPath + (components.percentEncodedQuery.map { "?\($0)" } ?? "")
    }

    static func == (lhs: HTTPExchange, rhs: HTTPExchange) -> Bool {
        lhs.id == rhs.id && lhs.status == rhs.status && lhs.error == rhs.error
            && lhs.responseBody == rhs.responseBody && lhs.duration == rhs.duration
    }
}

/// Keeps the most recent HTTP exchanges (20 by default) for the debug section.
@Observable
final class RequestLog {
    static let defaultCapacity = 20

    let capacity: Int
    /// Oldest first.
    private(set) var exchanges: [HTTPExchange] = []

    init(capacity: Int = RequestLog.defaultCapacity) {
        self.capacity = max(1, capacity)
    }

    func begin(_ exchange: HTTPExchange) {
        exchanges.append(exchange)
        if exchanges.count > capacity {
            exchanges.removeFirst(exchanges.count - capacity)
        }
    }

    func finish(
        _ id: UUID,
        status: Int?,
        headers: [(name: String, value: String)],
        body: String?,
        error: String?,
        duration: TimeInterval
    ) {
        guard let index = exchanges.firstIndex(where: { $0.id == id }) else { return }
        exchanges[index].status = status
        exchanges[index].responseHeaders = headers
        exchanges[index].responseBody = body
        exchanges[index].error = error
        exchanges[index].duration = duration
    }

    func clear() {
        exchanges.removeAll()
    }
}
