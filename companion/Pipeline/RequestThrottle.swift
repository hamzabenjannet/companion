import Foundation

/// Spaces out requests to a rate-limited provider. One instance is shared by
/// every remote processor, so the spacing holds across Start/Stop and typed messages.
final class RequestThrottle {
    /// Minimum seconds between two requests; 0 disables spacing.
    var minInterval: TimeInterval
    private var lastRequest: ContinuousClock.Instant?

    init(minInterval: TimeInterval = 0) {
        self.minInterval = minInterval
    }

    /// Waits for `minimumDelay` or until the interval has passed, whichever is
    /// longer, then records the request.
    func waitForTurn(minimumDelay: Duration = .zero) async {
        let wait = max(minimumDelay, Self.remainingInterval(since: lastRequest, minInterval: minInterval))
        if wait > .zero {
            try? await Task.sleep(for: wait)
        }
        lastRequest = .now
    }

    /// Time left before the next request may be sent.
    nonisolated static func remainingInterval(
        since last: ContinuousClock.Instant?,
        minInterval: TimeInterval,
        now: ContinuousClock.Instant = .now
    ) -> Duration {
        guard let last, minInterval > 0 else { return .zero }
        let remaining = last + .seconds(minInterval) - now
        return max(remaining, .zero)
    }
}
