import Foundation
import Darwin

/// No shell, credentials, or raw command output enters the report. Every child
/// has a deadline; output goes to an unlinked local file to avoid pipe deadlocks.
struct DiagnosticCommandRunner: Sendable {
    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 8, acceptedExitCodes: Set<Int32> = [0]) async -> String? {
        let execution = DiagnosticCommandExecution()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                execution.start(
                    executable: executable,
                    arguments: arguments,
                    timeout: timeout,
                    acceptedExitCodes: acceptedExitCodes,
                    continuation: continuation
                )
            }
        }, onCancel: {
            execution.cancel()
        })
    }
}

/// Owns one short-lived diagnostic child process. The caller's continuation is
/// resumed by a deadline or cancellation without waiting for the child to be
/// reaped; `Process.waitUntilExit()` can itself block indefinitely on a busy
/// runner. The termination handler retains the output file until cleanup.
private final class DiagnosticCommandExecution: @unchecked Sendable {
    private static let timeoutQueue = DispatchQueue(
        label: "io.github.johnwatso.Otter.diagnostic-command-timeout",
        qos: .userInitiated
    )

    private let lock = NSLock()
    private var process: Process?
    private var output: FileHandle?
    private var continuation: CheckedContinuation<String?, Never>?
    private var timeoutTimer: DispatchSourceTimer?
    private var cancelled = false
    private var responded = false

    func start(
        executable: String,
        arguments: [String],
        timeout: TimeInterval,
        acceptedExitCodes: Set<Int32>,
        continuation: CheckedContinuation<String?, Never>
    ) {
        lock.lock()
        if cancelled {
            lock.unlock()
            continuation.resume(returning: nil)
            return
        }
        self.continuation = continuation
        lock.unlock()

        // Start and arm the watchdog before returning to the cooperative task
        // executor. Queuing this on a low-priority worker can delay even a
        // 100 ms deadline for minutes under an overloaded test runner.
        launch(executable: executable, arguments: arguments, timeout: timeout, acceptedExitCodes: acceptedExitCodes)
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let runningProcess = process
        let continuation = takeContinuationLocked()
        lock.unlock()

        continuation?.resume(returning: nil)
        stop(runningProcess)
    }

    private func launch(executable: String, arguments: [String], timeout: TimeInterval, acceptedExitCodes: Set<Int32>) {
        var template = Array((NSTemporaryDirectory() + "otter-diagnostic-XXXXXX").utf8CString)
        let fd = mkstemp(&template)
        guard fd >= 0 else {
            respondWithLaunchFailure()
            return
        }
        template.withUnsafeBufferPointer { _ = unlink($0.baseAddress!) }

        let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak process] _ in
            guard let process else { return }
            self.didTerminate(process: process, acceptedExitCodes: acceptedExitCodes)
        }

        lock.lock()
        guard !cancelled, !responded else {
            lock.unlock()
            try? output.close()
            return
        }
        self.process = process
        self.output = output
        do {
            try process.run()
        } catch {
            self.process = nil
            self.output = nil
            let continuation = takeContinuationLocked()
            lock.unlock()
            try? output.close()
            continuation?.resume(returning: nil)
            return
        }

        let timeoutTimer = DispatchSource.makeTimerSource(queue: Self.timeoutQueue)
        timeoutTimer.schedule(deadline: .now() + max(timeout, 0))
        timeoutTimer.setEventHandler { [weak self, weak process] in
            guard let self, let process else { return }
            self.timedOut(process: process)
        }
        self.timeoutTimer = timeoutTimer
        lock.unlock()
        timeoutTimer.resume()
    }

    private func timedOut(process: Process) {
        lock.lock()
        guard self.process === process else {
            lock.unlock()
            return
        }
        let continuation = takeContinuationLocked()
        lock.unlock()

        continuation?.resume(returning: nil)
        stop(process)
    }

    private func didTerminate(process: Process, acceptedExitCodes: Set<Int32>) {
        lock.lock()
        guard self.process === process else {
            lock.unlock()
            return
        }
        self.process = nil
        timeoutTimer?.cancel()
        timeoutTimer = nil
        let output = self.output
        self.output = nil
        let shouldReadOutput = !responded && !cancelled && acceptedExitCodes.contains(process.terminationStatus)
        let continuation = takeContinuationLocked()
        lock.unlock()

        defer { try? output?.close() }
        guard shouldReadOutput else {
            continuation?.resume(returning: nil)
            return
        }
        try? output?.seek(toOffset: 0)
        let text = output.flatMap { handle -> String? in
            guard let data = try? handle.read(upToCount: 1_048_576) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        continuation?.resume(returning: text)
    }

    private func respondWithLaunchFailure() {
        lock.lock()
        let continuation = takeContinuationLocked()
        lock.unlock()
        continuation?.resume(returning: nil)
    }

    private func takeContinuationLocked() -> CheckedContinuation<String?, Never>? {
        guard !responded else { return nil }
        responded = true
        timeoutTimer?.cancel()
        timeoutTimer = nil
        defer { continuation = nil }
        return continuation
    }

    private func stop(_ process: Process?) {
        guard let process, process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.2) {
            guard process.isRunning else { return }
            _ = kill(pid, SIGKILL)
        }
    }
}

/// Small defensive helpers shared by parsers. Unsupported formats stay unknown.
enum DiagnosticParsing {
    static func capture(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<match.numberOfRanges).map { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
        }
    }
    static func bool(_ value: Any?) -> Bool? {
        guard let value else { return nil }
        switch String(describing: value).lowercased() {
        case "true", "yes", "1", "enabled": return true
        case "false", "no", "0", "disabled": return false
        default: return nil
        }
    }
    static func dictionaries(_ value: Any) -> [[String: Any]] {
        if let dict = value as? [String: Any] { return [dict] + dict.values.flatMap(dictionaries) }
        if let array = value as? [Any] { return array.flatMap(dictionaries) }
        return []
    }
}
