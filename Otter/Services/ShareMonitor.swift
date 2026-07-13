import AppKit
import Combine
import Foundation

private enum MonitorReason {
    case launch
    case manual
    case timer
    case wake
    case networkChanged
    case volumeChanged
    case configurationChanged
    case retry
}

struct ShareRuntimeState: Equatable {
    var status: ShareStatus = .disconnected
    var failureCount: Int = 0
    var nextRetryDate: Date?
    var lastCheckedAt: Date?
    var needsCredentials: Bool = false
    var mountedAt: Date?
    var lastConnectedAt: Date?
}

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

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
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
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}

enum RetryBackoff {
    static let delays: [TimeInterval] = [10, 30, 120, 300]

    static func delay(afterFailures failures: Int) -> TimeInterval {
        delays[min(max(failures - 1, 0), delays.count - 1)]
    }

    static func delayWithJitter(afterFailures failures: Int) -> TimeInterval {
        let baseDelay = delay(afterFailures: failures)
        let maxJitter = min(baseDelay * 0.1, 30.0)
        let jitter = Double.random(in: -maxJitter...maxJitter)
        return max(baseDelay + jitter, 1.0)
    }
}

private enum WakeOnLANRetryPolicy {
    static let packetCooldown: TimeInterval = 60
}

@MainActor
final class ShareMonitor: ObservableObject {
    @Published private var states: [NetworkShare.ID: ShareRuntimeState] = [:]
    @Published private(set) var isChecking = false

    private let settings: SettingsStore
    private let mountService: MountService
    private let wakeOnLANService: WakeOnLANService
    private let networkService: NetworkReachabilityService
    private let notificationService: NotificationService
    private let eventLog: ShareEventLog
    private var cancellables = Set<AnyCancellable>()
    private var workspaceObservers: [NSObjectProtocol] = []
    private var fallbackTimer: Timer?
    private var retryTasks: [NetworkShare.ID: Task<Void, Never>] = [:]
    private var lastWakePacketDates: [NetworkShare.ID: Date] = [:]
    private var activeChecks = Set<NetworkShare.ID>()
    private var pendingChecks: [NetworkShare.ID: (reason: MonitorReason, force: Bool)] = [:]
    private var hasStarted = false
    private var lastEvaluatedShares: [NetworkShare.ID: NetworkShare] = [:]
    private var persistedConnectionTimes: [String: PersistedConnectionTimes] = [:]

    private static let connectionTimesKey = "shareConnectionTimes"

    // Connection timestamps survive relaunches; everything else in the runtime
    // state is re-derived by the first evaluation.
    private struct PersistedConnectionTimes: Codable, Equatable {
        var mountedAt: Date?
        var lastConnectedAt: Date?
    }

    init(
        settings: SettingsStore,
        mountService: MountService,
        wakeOnLANService: WakeOnLANService,
        networkService: NetworkReachabilityService,
        notificationService: NotificationService,
        eventLog: ShareEventLog
    ) {
        self.settings = settings
        self.mountService = mountService
        self.wakeOnLANService = wakeOnLANService
        self.networkService = networkService
        self.notificationService = notificationService
        self.eventLog = eventLog
        persistedConnectionTimes = Self.loadPersistedConnectionTimes()
        syncStates(with: settings.shares)
    }

    var menuBarSystemImage: String {
        let visibleStates = settings.shares.map { status(for: $0) }

        if visibleStates.contains(where: { $0 == .reconnecting }) {
            return "arrow.triangle.2.circlepath"
        }

        if visibleStates.contains(where: \.needsAttention) {
            return "externaldrive.fill.badge.exclamationmark"
        }

        if visibleStates.contains(.connected) {
            return "externaldrive.fill"
        }

        return "externaldrive"
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true

        installWorkspaceObservers()
        installSettingsObservers()
        installNetworkObserver()
        scheduleFallbackTimer()
        scheduleCheck(reason: .launch)
    }

#if DEBUG
    // Supplies fixed runtime states for screenshot demo shares (set by AppModel).
    var demoStateProvider: ((NetworkShare.ID) -> ShareRuntimeState?)?
#endif

    func status(for share: NetworkShare) -> ShareStatus {
#if DEBUG
        if let demoState = demoStateProvider?(share.id) {
            return demoState.status
        }
#endif
        return states[share.id]?.status ?? .disconnected
    }

    func runtimeState(for share: NetworkShare) -> ShareRuntimeState {
#if DEBUG
        if let demoState = demoStateProvider?(share.id) {
            return demoState
        }
#endif
        return states[share.id] ?? ShareRuntimeState()
    }

    func mountAll() async {
        settings.setAllKeepMounted(true)
        await evaluateAll(reason: .manual, force: true)
    }

    func disconnectAll() async {
        settings.setAllKeepMounted(false)

        for share in settings.shares {
            await disconnect(share, disableKeepMounted: false)
        }
    }

    func mount(_ share: NetworkShare) async {
        settings.updateShare(id: share.id) { $0.keepMounted = true }
        let updatedShare = settings.share(id: share.id) ?? share
        await evaluate(updatedShare, reason: .manual, force: true)
    }

    func disconnect(_ share: NetworkShare, disableKeepMounted: Bool = true) async {
        if disableKeepMounted {
            settings.updateShare(id: share.id) { $0.keepMounted = false }
        }

        cancelRetry(for: share.id)

        do {
            try await mountService.unmount(share)
            updateStatus(.disconnected, for: share.id)
        } catch {
            updateFailure(error.localizedDescription, for: share.id)
        }
    }

    func wake(_ share: NetworkShare) async {
        guard share.wakeOnLAN.isEnabled else {
            updateFailure("Wake-on-LAN is not enabled for this share.", for: share.id)
            return
        }

        do {
            _ = try await sendWakePacketIfDue(for: share, ignoringCooldown: true)

            var state = states[share.id] ?? ShareRuntimeState()
            state.status = .wakePacketSent
            state.lastCheckedAt = Date()
            state.nextRetryDate = nil
            state.needsCredentials = false
            saveState(state, for: share)
        } catch {
            updateFailure(error.localizedDescription, for: share.id)
        }
    }

    private func installWorkspaceObservers() {
        let notificationCenter = NSWorkspace.shared.notificationCenter
        let events: [(Notification.Name, MonitorReason)] = [
            (NSWorkspace.didWakeNotification, .wake),
            (NSWorkspace.didMountNotification, .volumeChanged),
            (NSWorkspace.didUnmountNotification, .volumeChanged)
        ]

        workspaceObservers = events.map { name, reason in
            notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.scheduleCheck(reason: reason)
                }
            }
        }
    }

    private func installSettingsObservers() {
        settings.$shares
            .dropFirst()
            .sink { [weak self] shares in
                Task { @MainActor in
                    self?.syncStates(with: shares)
                    self?.scheduleCheck(reason: .configurationChanged)
                }
            }
            .store(in: &cancellables)

        settings.$preferences
            .map(\.fallbackCheckInterval)
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.scheduleFallbackTimer()
                }
            }
            .store(in: &cancellables)
    }

    private func installNetworkObserver() {
        networkService.onPathChange = { [weak self] in
            Task { @MainActor in
                self?.scheduleCheck(reason: .networkChanged)
            }
        }
    }

    private func scheduleFallbackTimer() {
        fallbackTimer?.invalidate()

        let interval = settings.preferences.fallbackCheckInterval
        fallbackTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.scheduleCheck(reason: .timer)
            }
        }
        fallbackTimer?.tolerance = interval * 0.2
    }

    private func scheduleCheck(reason: MonitorReason, delay: TimeInterval = 0) {
        Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: nanoseconds(for: delay))
            }

            guard !Task.isCancelled else { return }
            await self?.evaluateAll(reason: reason)
        }
    }

    private func evaluateAll(reason: MonitorReason, force: Bool = false) async {
        syncStates(with: settings.shares)

        for share in settings.shares {
            await evaluate(share, reason: reason, force: force)
        }
    }

    private func evaluateShare(id: NetworkShare.ID, reason: MonitorReason, force: Bool = false) async {
        guard let share = settings.share(id: id) else { return }
        await evaluate(share, reason: reason, force: force)
    }

    private func evaluate(_ share: NetworkShare, reason: MonitorReason, force: Bool = false) async {
        // A check for this share is already running; remember the request and
        // re-run once it finishes so events arriving mid-check aren't lost.
        guard !activeChecks.contains(share.id) else {
            let pendingForce = (pendingChecks[share.id]?.force ?? false) || force
            pendingChecks[share.id] = (reason, pendingForce)
            return
        }

        activeChecks.insert(share.id)
        isChecking = true
        defer {
            activeChecks.remove(share.id)
            isChecking = !activeChecks.isEmpty

            if let pending = pendingChecks.removeValue(forKey: share.id) {
                Task { [weak self] in
                    await self?.evaluateShare(id: share.id, reason: pending.reason, force: pending.force)
                }
            }
        }

        var state = states[share.id] ?? ShareRuntimeState()

        let oldShare = lastEvaluatedShares[share.id]
        if let oldShare, oldShare != share {
            state.failureCount = 0
            state.nextRetryDate = nil
            state.needsCredentials = false
            if case .failed = state.status {
                state.status = .disconnected
            }
            states[share.id] = state
        }
        lastEvaluatedShares[share.id] = share

        state.lastCheckedAt = Date()
        await networkService.refreshNetworkDetailsIfStale()

        let mountedURL = await mountService.mountedURL(for: share)
        let isMounted = mountedURL != nil
        let ruleEvaluation = share.rules.evaluate(
            currentWiFiNetworkName: networkService.currentWiFiNetworkName,
            isVPNConnected: networkService.isVPNConnected,
            activeVPNNames: networkService.activeVPNNames,
            currentIPv4Subnets: networkService.currentIPv4Subnets
        )
        if !ruleEvaluation.allowsConnection {
            cancelRetry(for: share.id)
            state.status = ruleEvaluation.blockedStatus ?? .disconnected
            state.failureCount = 0
            state.nextRetryDate = nil
            state.needsCredentials = false
            saveState(state, for: share)

            if isMounted && ruleEvaluation.shouldDisconnectMountedShare {
                do {
                    try await mountService.unmount(share)
                    updateStatus(state.status, for: share.id)
                } catch {
                    updateFailure(error.localizedDescription, for: share.id)
                }
            }

            return
        }

        if isMounted {
            if let mountedURL {
                syncMountPathIfNeeded(mountedURL, for: share)
            }

            state.status = .connected
            state.failureCount = 0
            state.nextRetryDate = nil
            state.needsCredentials = false
            saveState(state, for: share)
            cancelRetry(for: share.id)
            resolveAndCacheIPAddress(for: share)
            return
        }

        let shouldAttemptMount = force
            || share.keepMounted
            || (reason == .launch && share.mountAtLaunch)
            || ruleEvaluation.shouldAttemptMount

        // Opportunistic shares mount whenever their server answers, but an
        // unreachable server is a normal condition for them, not an error.
        let isOpportunistic = !shouldAttemptMount && share.autoConnectWhenReachable

        guard shouldAttemptMount || isOpportunistic else {
            state.status = .disconnected
            state.nextRetryDate = nil
            saveState(state, for: share)
            cancelRetry(for: share.id)
            return
        }

        guard networkService.isOnline else {
            state.status = isOpportunistic ? .disconnected : .waitingForNetwork
            saveState(state, for: share)
            return
        }

        let now = Date()
        if !force, let nextRetryDate = state.nextRetryDate, nextRetryDate > now {
            saveState(state, for: share)
            return
        }

        guard let url = share.url else {
            registerFailure("The network address is invalid.", for: share.id)
            return
        }

        if !isOpportunistic {
            state.status = .reconnecting
            saveState(state, for: share)
        }

        var reachable = await networkService.canReachServer(for: url)
        var fallbackURL: URL? = nil

        if !reachable, networkService.isVPNConnected, let cachedIP = share.cachedIPAddress {
            if let host = url.host(percentEncoded: false), !NetworkShare.isIPAddress(host) {
                var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
                components?.host = cachedIP
                if let resolvedURL = components?.url {
                    let ipReachable = await networkService.canReachServer(for: resolvedURL)
                    if ipReachable {
                        reachable = true
                        fallbackURL = resolvedURL
                    }
                }
            }
        }

        guard reachable else {
            if isOpportunistic {
                state.status = .disconnected
                state.nextRetryDate = nil
                saveState(state, for: share)
                cancelRetry(for: share.id)
            } else {
                let wakePacketSent: Bool
                do {
                    wakePacketSent = try await sendWakePacketIfDue(for: share)
                } catch {
                    registerFailure(error.localizedDescription, for: share.id)
                    return
                }

                state = states[share.id] ?? state
                state.status = wakePacketSent ? .wakePacketSent : .waitingForNetwork
                state.nextRetryDate = nextRetryDate(afterFailures: max(state.failureCount, 1))
                saveState(state, for: share)
                scheduleRetry(for: share.id, at: state.nextRetryDate)
            }
            return
        }

        do {
            if let mountedURL = try await mountService.mount(share, urlOverride: fallbackURL) {
                syncMountPathIfNeeded(mountedURL, for: share)
                state.status = .connected
                state.failureCount = 0
                state.nextRetryDate = nil
                saveState(state, for: share)
                cancelRetry(for: share.id)
                resolveAndCacheIPAddress(for: share)
            } else {
                registerFailure("macOS mounted the share, but Otter could not find the mounted volume.", for: share.id)
            }
        } catch {
            var needsCredentials = false
            if case MountServiceError.authenticationFailed = error {
                needsCredentials = true
            }

            registerFailure(error.localizedDescription, for: share.id, needsCredentials: needsCredentials)
        }
    }

    @discardableResult
    private func sendWakePacketIfDue(
        for share: NetworkShare,
        ignoringCooldown: Bool = false
    ) async throws -> Bool {
        guard share.wakeOnLAN.isEnabled else { return false }

        let now = Date()
        if !ignoringCooldown,
           let lastWakePacketDate = lastWakePacketDates[share.id],
           now.timeIntervalSince(lastWakePacketDate) < WakeOnLANRetryPolicy.packetCooldown {
            return false
        }

        try await wakeOnLANService.sendWakePacket(using: share.wakeOnLAN)
        lastWakePacketDates[share.id] = now
        return true
    }

    private func syncMountPathIfNeeded(_ mountedURL: URL, for share: NetworkShare) {
        let mountedPath = mountedURL.standardizedFileURL.resolvingSymlinksInPath().path

        guard normalizedPath(share.mountPath) != normalizedPath(mountedPath) else { return }

        settings.updateShare(id: share.id) { updatedShare in
            updatedShare.mountPath = mountedPath
        }
    }

    private func registerFailure(_ message: String, for shareID: NetworkShare.ID, needsCredentials: Bool = false) {
        var state = states[shareID] ?? ShareRuntimeState()
        state.status = .failed(message)
        state.failureCount += 1
        state.lastCheckedAt = Date()
        state.nextRetryDate = nextRetryDate(afterFailures: state.failureCount)
        state.needsCredentials = needsCredentials
        saveState(state, for: shareID)
        scheduleRetry(for: shareID, at: state.nextRetryDate)
    }

    private func updateFailure(_ message: String, for shareID: NetworkShare.ID) {
        var state = states[shareID] ?? ShareRuntimeState()
        state.status = .failed(message)
        state.lastCheckedAt = Date()
        saveState(state, for: shareID)
    }

    private func updateStatus(_ status: ShareStatus, for shareID: NetworkShare.ID) {
        var state = states[shareID] ?? ShareRuntimeState()
        state.status = status
        state.lastCheckedAt = Date()
        saveState(state, for: shareID)
    }

    private func saveState(_ state: ShareRuntimeState, for share: NetworkShare) {
        var updatedState = state
        let previousState = states[share.id]
        let previousStatus = previousState?.status ?? .disconnected

        if case .connected = updatedState.status {
            if previousState?.mountedAt == nil {
                updatedState.mountedAt = Date()
            } else {
                updatedState.mountedAt = previousState?.mountedAt
            }
            updatedState.lastConnectedAt = Date()
        } else {
            updatedState.mountedAt = nil
            updatedState.lastConnectedAt = previousState?.lastConnectedAt
        }

        states[share.id] = updatedState
        persistConnectionTimes(for: share.id, state: updatedState)
        recordEvent(for: share, previous: previousStatus, current: updatedState.status)
        notificationService.notifyStatusChange(for: share, previous: previousStatus, current: updatedState.status)
    }

    private func recordEvent(for share: NetworkShare, previous: ShareStatus, current: ShareStatus) {
        guard previous != current else { return }

        switch current {
        case .connected:
            eventLog.record(.mounted, for: share)
        case let .failed(message):
            eventLog.record(.mountFailed, for: share, detail: message)
        case .wakePacketSent:
            eventLog.record(.wakePacketSent, for: share)
        case .disconnected where previous == .connected:
            eventLog.record(.disconnected, for: share)
        case let .waitingForAllowedNetwork(requirement) where previous == .connected,
             let .pausedByRule(requirement) where previous == .connected:
            eventLog.record(.blockedByRule, for: share, detail: requirement)
        case .reconnecting where previous == .connected,
             .waitingForNetwork where previous == .connected:
            eventLog.record(.connectionLost, for: share)
        default:
            break
        }
    }

    private func persistConnectionTimes(for shareID: NetworkShare.ID, state: ShareRuntimeState) {
        let key = shareID.uuidString
        let existing = persistedConnectionTimes[key]
        let updated = PersistedConnectionTimes(mountedAt: state.mountedAt, lastConnectedAt: state.lastConnectedAt)
        guard existing != updated else { return }

        // lastConnectedAt refreshes on every check while a share stays
        // connected; skip the defaults write until it has moved meaningfully.
        if let existingDate = existing?.lastConnectedAt,
           let updatedDate = updated.lastConnectedAt,
           existing?.mountedAt == updated.mountedAt,
           updatedDate.timeIntervalSince(existingDate) < 60 {
            return
        }

        persistedConnectionTimes[key] = updated
        savePersistedConnectionTimes()
    }

    private func savePersistedConnectionTimes() {
        guard let data = try? JSONEncoder().encode(persistedConnectionTimes) else { return }
        UserDefaults.standard.set(data, forKey: Self.connectionTimesKey)
    }

    private static func loadPersistedConnectionTimes() -> [String: PersistedConnectionTimes] {
        guard let data = UserDefaults.standard.data(forKey: connectionTimesKey),
              let times = try? JSONDecoder().decode([String: PersistedConnectionTimes].self, from: data)
        else { return [:] }

        return times
    }

    private func saveState(_ state: ShareRuntimeState, for shareID: NetworkShare.ID) {
        if let share = settings.share(id: shareID) {
            saveState(state, for: share)
        } else {
            states[shareID] = state
        }
    }

    private func nextRetryDate(afterFailures failures: Int) -> Date {
        Date().addingTimeInterval(RetryBackoff.delayWithJitter(afterFailures: failures))
    }

    private func scheduleRetry(for shareID: NetworkShare.ID, at date: Date?) {
        cancelRetry(for: shareID)
        guard let date else { return }

        let delay = max(date.timeIntervalSinceNow, 0)
        retryTasks[shareID] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds(for: delay))
            guard !Task.isCancelled else { return }
            await self?.evaluateShare(id: shareID, reason: .retry)
        }
    }

    private func cancelRetry(for shareID: NetworkShare.ID) {
        retryTasks[shareID]?.cancel()
        retryTasks[shareID] = nil
    }

    private func resolveAndCacheIPAddress(for share: NetworkShare) {
        guard let host = share.host, !NetworkShare.isIPAddress(host) else { return }
        guard !networkService.isVPNConnected else { return }

        Task { @MainActor [weak self] in
            if let resolvedIP = await NetworkShare.resolveIPAddress(for: host) {
                if share.cachedIPAddress != resolvedIP {
                    self?.settings.updateShare(id: share.id) { updatedShare in
                        updatedShare.cachedIPAddress = resolvedIP
                    }
                }
            }
        }
    }

    private func syncStates(with shares: [NetworkShare]) {
        let shareIDs = Set(shares.map(\.id))
        states = states.filter { shareIDs.contains($0.key) }
        lastWakePacketDates = lastWakePacketDates.filter { shareIDs.contains($0.key) }

        for share in shares where states[share.id] == nil {
            var state = ShareRuntimeState()
            if let times = persistedConnectionTimes[share.id.uuidString] {
                state.mountedAt = times.mountedAt
                state.lastConnectedAt = times.lastConnectedAt
            }
            states[share.id] = state
        }

        let validKeys = Set(shareIDs.map(\.uuidString))
        let prunedTimes = persistedConnectionTimes.filter { validKeys.contains($0.key) }
        if prunedTimes.count != persistedConnectionTimes.count {
            persistedConnectionTimes = prunedTimes
            savePersistedConnectionTimes()
        }

        eventLog.pruneShares(keeping: shareIDs)
    }
}

private func nanoseconds(for interval: TimeInterval) -> UInt64 {
    UInt64(max(interval, 0) * 1_000_000_000)
}

private func normalizedPath(_ path: String) -> String {
    URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        .standardizedFileURL
        .resolvingSymlinksInPath()
        .path
}
