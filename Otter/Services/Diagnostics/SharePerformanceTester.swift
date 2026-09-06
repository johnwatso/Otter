import Foundation
import Darwin

struct SharePerformanceTester {
    enum Failure: LocalizedError {
        case notMounted, insufficientSpace, io, cleanup(String)
        var errorDescription: String? {
            switch self {
            case .notMounted: return "The original network share is no longer mounted. Run Diagnostics again."
            case .insufficientSpace: return "There is not enough available space for this test and a 256 MB reserve. Choose a smaller test size."
            case .io: return "The performance test could not finish. Check the connection and write access."
            case .cleanup(let folder): return "The temporary test could not be fully removed. After reconnecting, remove only Otter’s test folder: \(folder)"
            }
        }
    }

    func test(mount: MountDiagnostic, gigabytes: Int,
              progress: @escaping @MainActor @Sendable (Double, String) -> Void) async throws -> PerformanceDiagnostic {
        let worker = Task.detached(priority: .utility) {
            try await Self.perform(mount: mount, bytes: Int64(min(5, max(1, gigabytes))) * 1_000_000_000, progress: progress)
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    private static func perform(mount: MountDiagnostic, bytes: Int64,
                                progress: @escaping @MainActor @Sendable (Double, String) -> Void) async throws -> PerformanceDiagnostic {
        try Task.checkCancellation()
        guard let path = mount.mountPath, let actual = NASDiagnosticsService.mountedSource(path: path),
              actual.server == mount.server, actual.shareName == mount.shareName, actual.protocolName == mount.protocolName else { throw Failure.notMounted }
        let root = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard root >= 0 else { throw Failure.notMounted }
        defer { close(root) }
        var filesystem = statfs()
        guard fstatfs(root, &filesystem) == 0, filesystem.f_flags & UInt32(MNT_LOCAL) == 0 else { throw Failure.notMounted }
        let pinnedPath = withUnsafePointer(to: &filesystem.f_mntonname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        let pinned = NASDiagnosticsService.diagnostic(for: filesystem, mountPath: pinnedPath)
        guard pinnedPath == path, pinned.server == mount.server, pinned.shareName == mount.shareName,
              pinned.protocolName == mount.protocolName else { throw Failure.notMounted }
        // Pin all creation/removal to directory descriptors. No recursive removal,
        // existing directory reuse, symlink traversal, or user file overwrites.
        guard Double(filesystem.f_bavail) * Double(filesystem.f_bsize) >= Double(bytes) + 256_000_000 else { throw Failure.insufficientSpace }
        return try await measure(in: root, path: path, bytes: bytes, progress: progress)
    }

    /// Separated from network-volume validation so file ownership and cleanup
    /// can be exercised on a small disposable fixture without a NAS.
    static func measure(in root: Int32, path: String, bytes: Int64,
                        progress: @escaping @MainActor @Sendable (Double, String) -> Void) async throws -> PerformanceDiagnostic {
        try Task.checkCancellation()
        let directoryName = ".otter-diagnostics-" + UUID().uuidString
        guard mkdirat(root, directoryName, 0o700) == 0 else { throw Failure.io }
        let directory = openat(root, directoryName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directory >= 0 else {
            if unlinkat(root, directoryName, AT_REMOVEDIR) != 0 { throw Failure.cleanup(path + "/" + directoryName) }
            throw Failure.io
        }
        defer { close(directory) }
        let filename = UUID().uuidString + ".test"
        let file = openat(directory, filename, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard file >= 0 else {
            if unlinkat(root, directoryName, AT_REMOVEDIR) != 0 { throw Failure.cleanup(path + "/" + directoryName) }
            throw Failure.io
        }
        let testStart = DispatchTime.now().uptimeNanoseconds
        var outcome: Result<PerformanceDiagnostic, Error>
        do {
            let bypass = fcntl(file, F_NOCACHE, 1) == 0
            var buffer = [UInt8](repeating: 0, count: 4 * 1024 * 1024)
            // Random data avoids zero-fill/compression shortcuts. Refill each block
            // outside its timed write to avoid repeatedly writing identical data.
            var elapsedWrite = 0.0
            var writeSampler = ThroughputSampler()
            var readSampler = ThroughputSampler()
            var completed: Int64 = 0
            while completed < bytes {
                try Task.checkCancellation()
                buffer.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, $0.count) }
                let count = Int(min(Int64(buffer.count), bytes - completed))
                let start = DispatchTime.now().uptimeNanoseconds
                try buffer.withUnsafeBytes { data in
                    var offset = 0
                    while offset < count {
                        try Task.checkCancellation()
                        let written = Darwin.write(file, data.baseAddress!.advanced(by: offset), count - offset)
                        if written < 0 && errno == EINTR { continue }
                        guard written > 0 else { throw Failure.io }
                        offset += written
                    }
                }
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
                elapsedWrite += elapsed
                writeSampler.record(bytes: Int64(count), duration: elapsed)
                completed += Int64(count)
                await progress(Double(completed) / Double(bytes) / 2, "Writing temporary file…")
            }
            let flushStart = DispatchTime.now().uptimeNanoseconds
            guard fsync(file) == 0 else { throw Failure.io }
            let flushDuration = Double(DispatchTime.now().uptimeNanoseconds - flushStart) / 1e9
            elapsedWrite += flushDuration
            writeSampler.record(bytes: 0, duration: flushDuration)
            writeSampler.flush()
            try Task.checkCancellation()
            guard lseek(file, 0, SEEK_SET) == 0 else { throw Failure.io }
            completed = 0
            var elapsedRead = 0.0
            while completed < bytes {
                try Task.checkCancellation()
                let count = Int(min(Int64(buffer.count), bytes - completed))
                let start = DispatchTime.now().uptimeNanoseconds
                let received = buffer.withUnsafeMutableBytes { Darwin.read(file, $0.baseAddress!, count) }
                if received < 0 && errno == EINTR { continue }
                guard received > 0 else { throw Failure.io }
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
                elapsedRead += elapsed
                readSampler.record(bytes: Int64(received), duration: elapsed)
                completed += Int64(received)
                await progress(0.5 + Double(completed) / Double(bytes) / 2, "Reading temporary file…")
            }
            readSampler.flush()
            outcome = .success(PerformanceDiagnostic(writeMBps: Double(bytes) / 1e6 / max(elapsedWrite, 0.000001),
                                                       readMBps: Double(bytes) / 1e6 / max(elapsedRead, 0.000001), bytes: bytes, cacheBypass: bypass,
                                                       duration: Double(DispatchTime.now().uptimeNanoseconds - testStart) / 1e9,
                                                       writeSamples: writeSampler.samples, readSamples: readSampler.samples))
        } catch { outcome = .failure(error) }
        await progress(1, "Removing temporary file…")
        close(file)
        let fileRemoved = unlinkat(directory, filename, 0) == 0
        let directoryRemoved = unlinkat(root, directoryName, AT_REMOVEDIR) == 0
        guard fileRemoved, directoryRemoved else { throw Failure.cleanup(path + "/" + directoryName) }
        try Task.checkCancellation()
        return try outcome.get()
    }
}
