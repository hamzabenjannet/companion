import Foundation

/// Wraps another transport and records every request and response in a `RequestLog`.
nonisolated struct LoggingTransport: HTTPTransport {
    let base: any HTTPTransport
    let log: RequestLog

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let id = UUID()
        let exchange = HTTPExchange(
            id: id,
            startedAt: .now,
            service: HTTPPreview.service(for: request.url),
            method: request.httpMethod ?? "GET",
            url: HTTPPreview.redactedURL(request.url),
            requestHeaders: HTTPPreview.redactedHeaders(request.allHTTPHeaderFields ?? [:]),
            requestBody: HTTPPreview.body(
                request.httpBody ?? Data(),
                contentType: request.value(forHTTPHeaderField: "Content-Type")
            )
        )
        await log.begin(exchange)

        let start = ContinuousClock.now
        do {
            let (data, response) = try await base.send(request)
            let http = response as? HTTPURLResponse
            let headers = (http?.allHeaderFields ?? [:]).reduce(into: [String: String]()) {
                $0["\($1.key)"] = "\($1.value)"
            }
            await log.finish(
                id,
                status: http?.statusCode,
                headers: HTTPPreview.redactedHeaders(headers),
                body: HTTPPreview.body(data, contentType: http?.value(forHTTPHeaderField: "Content-Type")),
                error: nil,
                duration: (ContinuousClock.now - start).seconds
            )
            return (data, response)
        } catch {
            await log.finish(
                id,
                status: nil,
                headers: [],
                body: nil,
                error: error.localizedDescription,
                duration: (ContinuousClock.now - start).seconds
            )
            throw error
        }
    }
}

private extension Duration {
    nonisolated var seconds: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}
