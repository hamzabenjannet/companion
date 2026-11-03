import Foundation

/// Sends HTTP requests. `URLSession` conforms; tests inject a stub.
nonisolated protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: HTTPTransport {
    nonisolated func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await data(for: request)
    }
}

nonisolated enum APIError: LocalizedError, Equatable {
    case invalidURL(String)
    case http(status: Int, body: String)
    case missingAPIKey
    case emptyResponse(String)
    case invalidReply(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let url):
            return "Invalid URL: \(url)"
        case .http(let status, let body):
            return "HTTP \(status): \(body.prefix(300))"
        case .missingAPIKey:
            return "No API key configured."
        case .emptyResponse(let reason):
            return "The model returned no content (\(reason))."
        case .invalidReply(let reply):
            return "Could not read the model reply: \(reply.prefix(300))"
        }
    }
}
