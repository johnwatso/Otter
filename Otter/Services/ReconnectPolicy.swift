import Foundation

enum RetryBackoff {
    static let delays: [TimeInterval] = [10, 30, 120, 300]
    static let maxAutomaticAttempts = 6

    static func delay(afterFailures failures: Int) -> TimeInterval {
        delays[min(max(failures - 1, 0), delays.count - 1)]
    }

    static func delayWithJitter(afterFailures failures: Int) -> TimeInterval {
        let baseDelay = delay(afterFailures: failures)
        let maxJitter = min(baseDelay * 0.1, 30.0)
        let jitter = Double.random(in: -maxJitter...maxJitter)
        return max(baseDelay + jitter, 1.0)
    }

    static func shouldRetry(afterFailures failures: Int) -> Bool {
        failures < maxAutomaticAttempts
    }
}
