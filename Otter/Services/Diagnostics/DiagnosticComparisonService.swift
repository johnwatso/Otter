import Foundation

struct DiagnosticComparisonOutcome {
    var comparison: DiagnosticComparison?
    var current: NASDiagnosticResult?
    var error: String?
    var restorationRequired = false
}

/// Owns the full comparison, including restoration even after cancellation or
/// failed measurement. Dependencies allow lifecycle tests without remounting disks.
@MainActor
enum DiagnosticComparisonService {
    static func run(before: NASDiagnosticResult, kind: DiagnosticComparisonKind, targetURL: URL?,
                    reconnect: @escaping @MainActor (URL?) async -> Bool,
                    collect: @escaping @MainActor () async throws -> NASDiagnosticResult,
                    benchmark: @escaping @MainActor (MountDiagnostic, Int) async throws -> PerformanceDiagnostic,
                    status: @escaping @MainActor (String) -> Void) async -> DiagnosticComparisonOutcome {
        var outcome = DiagnosticComparisonOutcome()
        guard before.isComplete, before.mount.mountPath != nil else {
            outcome.error = "Run Diagnostics on the connected share before comparing."
            return outcome
        }
        if kind == .ipAddress, targetURL == nil {
            outcome.error = "A resolved IP address is required."
            return outcome
        }
        var needsRestoration = false
        do {
            try Task.checkCancellation()
            status("Reconnecting for comparison…")
            let reconnected = await reconnect(targetURL)
            needsRestoration = kind == .ipAddress && reconnected
            guard reconnected else { throw ComparisonError.reconnect }
            try Task.checkCancellation()
            var after = try await collect()
            guard after.isComplete, after.mount.mountPath != nil else { throw ComparisonError.incomplete }
            if kind == .ipAddress {
                guard after.mount.connectedUsing == "IP address", after.mount.server == targetURL?.host(percentEncoded: false)?.trimmingCharacters(in: CharacterSet(charactersIn: "[]")) else {
                    throw ComparisonError.unverifiedIP
                }
            }
            if let performance = before.performance {
                try Task.checkCancellation()
                status("Repeating the same performance test…")
                let size = Int(performance.bytes / 1_000_000_000)
                guard (1...5).contains(size), Int64(size) * 1_000_000_000 == performance.bytes else { throw ComparisonError.testSize }
                after.performance = try await benchmark(after.mount, size)
            }
            try Task.checkCancellation()
            outcome.current = after
            outcome.comparison = .init(kind: kind, before: before, after: after)
        } catch is CancellationError {
            outcome.error = "Comparison cancelled."
        } catch {
            outcome.error = error.localizedDescription
        }
        if needsRestoration {
            status("Restoring the configured connection…")
            // Unstructured task deliberately does not inherit cancellation. A
            // cancelled benchmark must still restore the original hostname mount.
            let restored = await Task { @MainActor in
                guard await reconnect(nil) else { return nil as NASDiagnosticResult? }
                return try? await collect()
            }.value
            let succeeded = restored?.isComplete == true && restored?.mount.mountPath != nil && restored?.mount.connectedUsing == "Hostname"
            outcome.comparison?.originalConnectionRestored = succeeded
            outcome.current = succeeded ? restored : nil
            outcome.restorationRequired = !succeeded
            if !succeeded {
                outcome.error = [outcome.error, "The configured connection could not be restored. Use Restore Configured Connection to retry; the saved server address has not changed."].compactMap { $0 }.joined(separator: " ")
            }
        }
        return outcome
    }

    private enum ComparisonError: LocalizedError {
        case reconnect, incomplete, unverifiedIP, testSize
        var errorDescription: String? {
            switch self {
            case .reconnect: return "The share is busy or another connection check is running. The comparison could not reconnect it."
            case .incomplete: return "Diagnostics did not find a connected share after reconnecting. No comparison was completed."
            case .unverifiedIP: return "The direct-IP mount could not be verified. No IP comparison was completed."
            case .testSize: return "The baseline test size cannot be repeated. Run a new performance test before comparing."
            }
        }
    }
}
