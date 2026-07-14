import Combine
import Foundation

enum ShareEventKind: String, Codable {
    case mounted
    case connectionLost
    case disconnected
    case blockedByRule
    case mountFailed
    case wakePacketSent
}

struct ShareEvent: Identifiable, Codable, Equatable {
    let id: UUID
    let shareID: NetworkShare.ID
    let date: Date
    let kind: ShareEventKind
    let detail: String?
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
