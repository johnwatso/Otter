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

// A share that disappears while Otter still expects it to be mounted is a
// different case from a server that was already unavailable. NAS updates and
// reboots commonly take several minutes, so keep probing without exhausting
// the normal automatic retry budget while capping the retry interval at a
// short, server-friendly delay.
enum UnexpectedDisconnectRetryPolicy {
    static let delays: [TimeInterval] = [2, 5, 10, 15, 30]

    static func delay(afterFailures failures: Int) -> TimeInterval {
        delays[min(max(failures - 1, 0), delays.count - 1)]
    }

    static func delayWithJitter(afterFailures failures: Int) -> TimeInterval {
        let baseDelay = delay(afterFailures: failures)
        let maxJitter = min(baseDelay * 0.1, 3.0)
        let jitter = Double.random(in: -maxJitter...maxJitter)
        return max(baseDelay + jitter, 1.0)
    }
}
