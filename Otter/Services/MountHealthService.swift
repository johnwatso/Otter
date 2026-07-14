import Foundation

// Network volumes can remain registered with macOS while every filesystem
// access to them blocks. Probe in a disposable child process so a stalled SMB
// syscall cannot block Otter's process or Swift concurrency executor.
final class MountHealthService: @unchecked Sendable {
    func checkMount(at url: URL, timeout: TimeInterval = 3) async -> MountHealthResult {
        let result = await TimedProcess.run(
            executable: URL(fileURLWithPath: "/usr/bin/stat"),
            arguments: ["-f", "%d", url.path],
            timeout: timeout
        )

        if result.timedOut {
            return .unresponsive
        }
        if let launchError = result.launchError {
            return .unavailable(launchError)
        }
        return result.terminationStatus == 0
            ? .healthy
            : .unavailable("The mounted volume could not be read.")
    }

    func unmountForRecovery(at url: URL, timeout: TimeInterval = 10) async -> Bool {
        let standardizedPath = url.standardizedFileURL.path
        guard standardizedPath.hasPrefix("/Volumes/") else { return false }

        // Deliberately avoid a forced unmount. If macOS reports that the volume
        // is busy, Otter leaves it alone rather than risking active file writes.
        let result = await TimedProcess.run(
            executable: URL(fileURLWithPath: "/usr/sbin/diskutil"),
            arguments: ["unmount", standardizedPath],
            timeout: timeout
        )
        return !result.timedOut && result.launchError == nil && result.terminationStatus == 0
    }
}

private struct TimedProcessResult: Sendable {
    let terminationStatus: Int32?
    let timedOut: Bool
    let launchError: String?
}

private enum TimedProcess {
    static func run(executable: URL, arguments: [String], timeout: TimeInterval) async -> TimedProcessResult {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice

            let gate = ProcessCompletionGate(continuation: continuation)
            process.terminationHandler = { process in
                gate.finish(
                    TimedProcessResult(
                        terminationStatus: process.terminationStatus,
                        timedOut: false,
                        launchError: nil
                    )
                )
            }

            do {
                try process.run()
            } catch {
                gate.finish(
                    TimedProcessResult(
                        terminationStatus: nil,
                        timedOut: false,
                        launchError: error.localizedDescription
                    )
                )
                return
            }

            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + max(timeout, 0.1)) {
                guard process.isRunning else { return }
                gate.finish(
                    TimedProcessResult(
                        terminationStatus: nil,
                        timedOut: true,
                        launchError: nil
                    )
                )
                process.terminate()
            }
        }
    }
}

private final class ProcessCompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<TimedProcessResult, Never>?

    init(continuation: CheckedContinuation<TimedProcessResult, Never>) {
        self.continuation = continuation
    }

    func finish(_ result: TimedProcessResult) {
        lock.lock()
        let pendingContinuation = continuation
        continuation = nil
        lock.unlock()
        pendingContinuation?.resume(returning: result)
    }
}
