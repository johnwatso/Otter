import Combine
import Foundation

enum ShareEventKind: String, Codable {
    case mounted
    case connectionLost
    case disconnected
    case blockedByRule
    case mountFailed
    case wakePacketSent
    case unresponsiveDetected
    case recoveryAttempted
    case healthCheckFailed
    case credentialsRequired
    case duplicateResolved
}

struct ShareEvent: Identifiable, Codable, Equatable {
    let id: UUID
    let shareID: NetworkShare.ID
    let date: Date
    let kind: ShareEventKind
    let detail: String?
}

struct ShareReliabilitySummary: Equatable {
    let connectionDrops: Int
    let failures: Int
    let healthFailures: Int
    let lastProblemAt: Date?

    var isStable: Bool {
        connectionDrops == 0 && failures == 0 && healthFailures == 0
    }
}

// Persisted, capped log of share status transitions. Feeds the Activity Log
// window and the per-share drop counter in the detail pane.
@MainActor
final class ShareEventLog: ObservableObject {
    // Newest first.
    @Published private(set) var events: [ShareEvent]

    private static let storageKey = "shareEventLog"
    private static let maxEvents = 200
    // Retry loops re-report the same failure; identical consecutive events
    // for a share within this window collapse into the earlier entry.
    private static let coalescingWindow: TimeInterval = 15 * 60
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let stored = try? JSONDecoder().decode([ShareEvent].self, from: data) {
            events = stored
        } else {
            events = []
        }
    }

    func record(_ kind: ShareEventKind, for share: NetworkShare, detail: String? = nil) {
        if let latest = events.first(where: { $0.shareID == share.id }),
           latest.kind == kind,
           latest.detail == detail,
           Date().timeIntervalSince(latest.date) < Self.coalescingWindow {
            return
        }

        events.insert(
            ShareEvent(id: UUID(), shareID: share.id, date: Date(), kind: kind, detail: detail),
            at: 0
        )
        if events.count > Self.maxEvents {
            events.removeLast(events.count - Self.maxEvents)
        }
        save()
    }

    func events(for shareID: NetworkShare.ID?) -> [ShareEvent] {
        guard let shareID else { return events }
        return events.filter { $0.shareID == shareID }
    }

    func connectionDropCount(for shareID: NetworkShare.ID, within interval: TimeInterval = 24 * 60 * 60) -> Int {
        let cutoff = Date().addingTimeInterval(-interval)
        return events
            .filter { $0.shareID == shareID && $0.kind == .connectionLost && $0.date >= cutoff }
            .count
    }

    private static func isProblem(_ kind: ShareEventKind) -> Bool {
        switch kind {
        case .connectionLost, .mountFailed, .unresponsiveDetected, .healthCheckFailed, .credentialsRequired:
            true
        default:
            false
        }
    }

    /// Problems recorded on each of the last `days` days, oldest first and
    /// ending with the day of `date`. A zero means no problem was recorded,
    /// not that the share was proven reachable all day.
    func dailyProblemCounts(
        for shareID: NetworkShare.ID,
        days: Int = 7,
        at date: Date = Date(),
        calendar: Calendar = .current
    ) -> [Int] {
        let today = calendar.startOfDay(for: date)
        return (0..<days).reversed().map { offset in
            guard let start = calendar.date(byAdding: .day, value: -offset, to: today),
                  let end = calendar.date(byAdding: .day, value: 1, to: start)
            else { return 0 }
            return events.filter {
                $0.shareID == shareID && Self.isProblem($0.kind) && $0.date >= start && $0.date < end
            }.count
        }
    }

    func reliabilitySummary(
        for shareID: NetworkShare.ID,
        within interval: TimeInterval = 7 * 24 * 60 * 60,
        at date: Date = Date()
    ) -> ShareReliabilitySummary {
        let cutoff = date.addingTimeInterval(-interval)
        let recent = events.filter { $0.shareID == shareID && $0.date >= cutoff }
        let problems = recent.filter { Self.isProblem($0.kind) }
        return ShareReliabilitySummary(
            connectionDrops: recent.filter { $0.kind == .connectionLost }.count,
            failures: recent.filter { $0.kind == .mountFailed || $0.kind == .credentialsRequired }.count,
            healthFailures: recent.filter { $0.kind == .healthCheckFailed || $0.kind == .unresponsiveDetected }.count,
            lastProblemAt: problems.map(\.date).max()
        )
    }

    func pruneShares(keeping shareIDs: Set<NetworkShare.ID>) {
        let prunedEvents = events.filter { shareIDs.contains($0.shareID) }
        guard prunedEvents.count != events.count else { return }
        events = prunedEvents
        save()
    }

    func clear() {
        events = []
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(events) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}

/// One day's worth of volume response times for a share.
struct DailyLatency: Codable, Equatable {
    var day: Date
    var sampleCount: Int
    var totalMilliseconds: Double
    var slowestMilliseconds: Double

    var averageMilliseconds: Double {
        sampleCount > 0 ? totalMilliseconds / Double(sampleCount) : 0
    }
}

/// Round-trip time to each share's server (a TCP connect, comparable to
/// `ping`), sampled alongside the periodic health check and rolled up per day.
@MainActor
final class ShareLatencyHistory: ObservableObject {
    @Published private(set) var history: [NetworkShare.ID: [DailyLatency]]

    static let retentionDays = 30
    // v1 stored the duration of the health check, which mostly measured
    // launching a child process. Those numbers are not comparable with the
    // round-trip times recorded now, so they are discarded rather than mixed in.
    private static let storageKey = "shareLatencyHistory.v2"
    private static let legacyStorageKey = "shareLatencyHistory"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.removeObject(forKey: Self.legacyStorageKey)
        if let data = defaults.data(forKey: Self.storageKey),
           let stored = try? JSONDecoder().decode([NetworkShare.ID: [DailyLatency]].self, from: data) {
            history = stored
        } else {
            history = [:]
        }
    }

    func record(
        milliseconds: Double,
        for shareID: NetworkShare.ID,
        at date: Date = Date(),
        calendar: Calendar = .current
    ) {
        guard milliseconds.isFinite, milliseconds >= 0 else { return }
        let day = calendar.startOfDay(for: date)
        var days = history[shareID] ?? []

        if let index = days.firstIndex(where: { $0.day == day }) {
            days[index].sampleCount += 1
            days[index].totalMilliseconds += milliseconds
            days[index].slowestMilliseconds = max(days[index].slowestMilliseconds, milliseconds)
        } else {
            days.append(DailyLatency(
                day: day,
                sampleCount: 1,
                totalMilliseconds: milliseconds,
                slowestMilliseconds: milliseconds
            ))
        }

        if let cutoff = calendar.date(byAdding: .day, value: -Self.retentionDays, to: day) {
            days.removeAll { $0.day < cutoff }
        }
        history[shareID] = days
        save()
    }

    /// The last `days` days ending with the day of `date`, oldest first. A day
    /// Otter took no measurement on is `nil`.
    func recent(
        for shareID: NetworkShare.ID,
        days: Int = 7,
        at date: Date = Date(),
        calendar: Calendar = .current
    ) -> [DailyLatency?] {
        let today = calendar.startOfDay(for: date)
        let stored = history[shareID] ?? []
        return (0..<days).reversed().map { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            return stored.first { $0.day == day }
        }
    }

    func pruneShares(keeping shareIDs: Set<NetworkShare.ID>) {
        let pruned = history.filter { shareIDs.contains($0.key) }
        guard pruned.count != history.count else { return }
        history = pruned
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(history) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
