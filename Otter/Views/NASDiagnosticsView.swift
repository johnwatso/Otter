import Combine
import Foundation

/// Owns the deeper network, SMB, latency, and performance measurements shown
/// inside the unified Diagnose sheet.
@MainActor
final class NASDiagnosticsViewModel: ObservableObject {
    @Published var result: NASDiagnosticResult?
    @Published var status = "Ready to check this connection"
    @Published var running = false
    @Published var testing = false
    @Published var progress = 0.0
    @Published var performanceStatus = "Not tested"
    @Published var error: String?
    @Published var comparison: DiagnosticComparison?
    @Published var comparing = false
    @Published var restorationRequired = false
    @Published var restoring = false
    @Published var reconnecting = false
    private var task: Task<Void, Never>?

    var isBusy: Bool { running || testing || comparing || restoring || reconnecting }
    var blocksDismissal: Bool { testing || comparing || restoring || reconnecting }

    @discardableResult
    func run(
        share: NetworkShare,
        service: MountService,
        performanceBytes: Int64?
    ) -> Task<Void, Never>? {
        guard !running, !testing, !comparing, !restoring else { return nil }
        running = true
        result = nil
        comparison = nil
        error = nil
        status = "Checking connection…"
        performanceStatus = "Not tested"
        task = Task {
            await NASDiagnosticsService().run(share: share, mountService: service) { result, status in
                self.result = result
                self.status = status
            }
            if Task.isCancelled { status = "Diagnostics cancelled — partial results" }
            running = false
            if !Task.isCancelled,
               result?.mount.mountPath != nil,
               let performanceBytes {
                await measurePerformance(bytes: performanceBytes)
            }
            task = nil
        }
        return task
    }

    private func measurePerformance(bytes: Int64) async {
        guard let mount = result?.mount, mount.mountPath != nil else { return }
        testing = true
        progress = 0
        error = nil
        result?.performance = nil
        performanceStatus = "Preparing temporary file…"
        do {
            let performance = try await SharePerformanceTester().test(mount: mount, bytes: bytes) { [weak self] value, label in
                self?.progress = value
                self?.performanceStatus = label
            }
            result?.performance = performance
            performanceStatus = "Speed test complete"
        } catch is CancellationError {
            performanceStatus = "Speed test cancelled"
        } catch {
            self.error = error.localizedDescription
            performanceStatus = "Speed test could not finish"
        }
        testing = false
    }

    func compare(
        kind: DiagnosticComparisonKind,
        share: NetworkShare,
        service: MountService,
        monitor: ShareMonitor
    ) {
        guard !running,
              !testing,
              !comparing,
              !restoring,
              !restorationRequired,
              let before = result
        else { return }

        let target = kind == .ipAddress
            ? before.mount.resolvedIP.flatMap {
                NASDiagnosticsService.temporaryIPURL(share: share, address: $0)
            }
            : nil
        comparing = true
        comparison = nil
        error = nil
        task = Task {
            let outcome = await DiagnosticComparisonService.run(
                before: before,
                kind: kind,
                targetURL: target,
                reconnect: { url in
                    await monitor.remountForMaintenance(share, diagnosticURL: url)
                },
                collect: {
                    var collected: NASDiagnosticResult?
                    await NASDiagnosticsService().run(share: share, mountService: service) { value, label in
                        collected = value
                        self.status = label
                    }
                    try Task.checkCancellation()
                    guard let collected else { throw CancellationError() }
                    return collected
                },
                benchmark: { mount, size in
                    self.testing = true
                    self.progress = 0
                    defer { self.testing = false }
                    return try await SharePerformanceTester().test(mount: mount, bytes: size) { value, label in
                        self.progress = value
                        self.performanceStatus = label
                    }
                },
                status: { self.status = $0 }
            )
            comparison = outcome.comparison
            result = outcome.current ?? (outcome.error == nil ? before : nil)
            error = outcome.error
            restorationRequired = outcome.restorationRequired
            status = outcome.error == nil ? "Comparison complete" : "Comparison stopped"
            comparing = false
            task = nil
        }
    }

    func restore(share: NetworkShare, service: MountService, monitor: ShareMonitor) {
        guard !running, !testing, !comparing, !restoring else { return }
        restoring = true
        status = "Restoring the configured connection…"
        error = nil
        task = Task {
            let reconnected = await monitor.remountForMaintenance(share)
            if reconnected {
                await NASDiagnosticsService().run(share: share, mountService: service) { value, label in
                    self.result = value
                    self.status = label
                }
            }
            let restored = reconnected
                && result?.isComplete == true
                && result?.mount.mountPath != nil
                && result?.mount.connectedUsing == "Hostname"
            restorationRequired = !restored
            comparison?.originalConnectionRestored = restored
            if !restored {
                error = "The configured hostname connection could not be verified. Close files on the share and retry restoration. Your saved server address is unchanged."
            }
            restoring = false
            task = nil
        }
    }

    func cancel() {
        guard !restoring else { return }
        task?.cancel()
        if testing {
            performanceStatus = "Cancelling — waiting for current I/O and cleanup…"
        }
    }
}
