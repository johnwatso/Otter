import Foundation
import Darwin

/// No shell, credentials, or raw command output enters the report. Every child
/// has a deadline; output goes to an unlinked local file to avoid pipe deadlocks.
struct DiagnosticCommandRunner: Sendable {
    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 8, acceptedExitCodes: Set<Int32> = [0]) async -> String? {
        let worker = Task.detached(priority: .utility) { () -> String? in
            guard !Task.isCancelled else { return nil }
            var template = Array((NSTemporaryDirectory() + "otter-diagnostic-XXXXXX").utf8CString)
            let fd = mkstemp(&template)
            guard fd >= 0 else { return nil }
            template.withUnsafeBufferPointer { _ = unlink($0.baseAddress!) }
            let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return nil }
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning {
                if Task.isCancelled || Date() >= deadline {
                    process.terminate()
                    // A utility stuck in a syscall must not keep a diagnostic alive.
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    process.waitUntilExit()
                    return nil
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            guard !Task.isCancelled, acceptedExitCodes.contains(process.terminationStatus) else { return nil }
            try? output.seek(toOffset: 0)
            return (try? output.read(upToCount: 1_048_576)).flatMap { String(data: $0, encoding: .utf8) }
        }
        return await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
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
