import Darwin
import Foundation

// Notices that macOS has started an SMB mount that Otter did not make: the user
// chose Go ▸ Connect to Server, opened an smb:// shortcut, or double-clicked a
// saved server. macOS hands every one of those to NetAuthSysAgent, the helper
// that negotiates the connection, so its appearance is the signal. The helper's
// command line and sockets do not reveal which server it is talking to, so the
// detector reports that an attempt began, not where it was headed.
//
// Looking for the helper means listing every process, so the detector only does
// that while `shouldWatch` says an attempt could matter. The rest of the time
// it costs one closure call per tick.
@MainActor
final class MountAttemptDetector {
    typealias HelperSnapshot = @Sendable () -> Set<pid_t>

    /// Called once per attempt, on the main actor.
    var onAttempt: (() -> Void)?

    private let shouldWatch: () -> Bool
    private let snapshotHelpers: HelperSnapshot
    private let interval: TimeInterval
    private let cooldown: TimeInterval
    private let now: () -> Date

    private var timer: Timer?
    private var knownHelpers = Set<pid_t>()
    private var isWatching = false
    private var lastAttemptDate: Date?

    init(
        shouldWatch: @escaping () -> Bool,
        interval: TimeInterval = 1,
        cooldown: TimeInterval = 45,
        now: @escaping () -> Date = Date.init,
        snapshotHelpers: @escaping HelperSnapshot = { MountAttemptDetector.systemHelperSnapshot() }
    ) {
        self.shouldWatch = shouldWatch
        self.interval = interval
        self.cooldown = cooldown
        self.now = now
        self.snapshotHelpers = snapshotHelpers
    }

    func start() {
        guard timer == nil else { return }

        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
        timer.tolerance = interval * 0.3
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isWatching = false
        knownHelpers = []
    }

    /// One poll. Exposed so tests can drive the detector without a timer.
    func tick() {
        guard shouldWatch() else {
            // Forget the helpers seen so far: one that is still running when
            // watching resumes belongs to an attempt that began earlier.
            isWatching = false
            knownHelpers = []
            return
        }

        let helpers = snapshotHelpers()

        guard isWatching else {
            // The first look after being idle only records what is already
            // running, so a mount that was under way before we cared is not
            // mistaken for a new one.
            isWatching = true
            knownHelpers = helpers
            return
        }

        let newHelpers = helpers.subtracting(knownHelpers)
        knownHelpers = helpers
        guard !newHelpers.isEmpty else { return }

        let currentDate = now()
        if let lastAttemptDate, currentDate.timeIntervalSince(lastAttemptDate) < cooldown {
            return
        }

        lastAttemptDate = currentDate
        onAttempt?()
    }

    private nonisolated static let helperPathSuffix = "/NetAuthAgent.app/Contents/MacOS/NetAuthSysAgent"

    nonisolated static func systemHelperSnapshot() -> Set<pid_t> {
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return [] }

        var pids = [pid_t](repeating: 0, count: Int(capacity) + 32)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.stride))
        guard count > 0 else { return [] }

        var helpers = Set<pid_t>()
        var pathBuffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))

        for pid in pids.prefix(Int(count)) where pid > 0 {
            let length = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
            guard length > 0 else { continue }

            if pathBuffer.stringValue.hasSuffix(helperPathSuffix) {
                helpers.insert(pid)
            }
        }

        return helpers
    }
}
