import AppKit
import Combine
import Foundation

enum MonitorReason {
    case launch
    case manual
    case timer
    case wake
    case networkChanged
    case volumeChanged
    case configurationChanged
    case retry

    var resetsRetryBudget: Bool {
        switch self {
        case .wake, .networkChanged, .configurationChanged:
            true
        case .launch, .manual, .timer, .volumeChanged, .retry:
            false
        }
    }
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

private enum WakeOnLANRetryPolicy {
    static let packetCooldown: TimeInterval = 60
}

@MainActor
final class ShareMonitor: ObservableObject {
    @Published private var states: [NetworkShare.ID: ShareRuntimeState] = [:]
    @Published private(set) var isChecking = false

    private let settings: SettingsStore
    private let mountService: any MountServicing
    private let mountHealthService: any MountHealthChecking
    private let wakeOnLANService: any WakeOnLANServicing
    private let networkService: any NetworkReachabilityProviding
    private let notificationService: any ShareNotificationProviding
    private let eventLog: ShareEventLog
    private let defaults: UserDefaults
    private let now: () -> Date
    private var cancellables = Set<AnyCancellable>()
    private var workspaceObservers: [NSObjectProtocol] = []
    private var fallbackTimer: Timer?
    private var retryTasks: [NetworkShare.ID: Task<Void, Never>] = [:]
    private var pauseResumeTask: Task<Void, Never>?
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
        mountService: any MountServicing,
        mountHealthService: any MountHealthChecking = MountHealthService(),
        wakeOnLANService: any WakeOnLANServicing,
        networkService: any NetworkReachabilityProviding,
        notificationService: any ShareNotificationProviding,
        eventLog: ShareEventLog,
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init
    ) {
        self.settings = settings
        self.mountService = mountService
        self.mountHealthService = mountHealthService
        self.wakeOnLANService = wakeOnLANService
        self.networkService = networkService
        self.notificationService = notificationService
        self.eventLog = eventLog
        self.defaults = defaults
        self.now = now
        persistedConnectionTimes = Self.loadPersistedConnectionTimes(from: defaults)
        syncStates(with: settings.shares)
    }

    var menuBarSystemImage: String {
        if settings.isGloballyPaused {
            return "pause.circle.fill"
        }

        let visibleStates = settings.shares.map { status(for: $0) }

        if visibleStates.contains(where: { $0 == .reconnecting }) {
            return "arrow.triangle.2.circlepath"
        }

        if visibleStates.contains(where: \.needsAttention) {
            return "externaldrive.fill.badge.exclamationmark"
        }

        if visibleStates.contains(.connected) {
            return "externaldrive.connected.to.line.below.fill"
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
        settings.clearExpiredPauses(at: now())
        schedulePauseResume()
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
        settings.resumeAll(clearSharePauses: true)
        settings.setAllKeepMounted(true)
        await evaluateAll(reason: .manual, force: true)
    }

    func disconnectAll() async {
        await pauseAll(until: nil, disconnect: true)
    }

    func mount(_ share: NetworkShare) async {
        settings.resumeShare(id: share.id)
        settings.updateShare(id: share.id) { $0.keepMounted = true }
        let updatedShare = settings.share(id: share.id) ?? share
        await evaluate(updatedShare, reason: .manual, force: true)
    }

    // Retry a connection without changing the share's long-term keep-mounted
    // preference. Repair flows can explicitly clear a per-share pause while a
    // notification retry simply restarts the current connection attempt.
    func retry(_ share: NetworkShare, resumeAutomaticMounting: Bool = false) async {
        if resumeAutomaticMounting {
            settings.resumeShare(id: share.id)
        }
        let updatedShare = settings.share(id: share.id) ?? share
        await evaluate(updatedShare, reason: .manual, force: true)
    }

    func disconnect(_ share: NetworkShare, pauseAutomaticMounting: Bool = true) async {
        if pauseAutomaticMounting {
            settings.pauseShare(id: share.id, until: nil)
        }

        cancelRetry(for: share.id)

        do {
            try await mountService.unmount(share)
            let currentShare = settings.share(id: share.id) ?? share
            if let pauseState = settings.effectivePauseState(for: currentShare, at: now()) {
                updateStatus(.paused(pauseState.resumeAt), for: share.id)
            } else {
                updateStatus(.disconnected, for: share.id)
            }
        } catch {
            updateFailure(error.localizedDescription, for: share.id)
        }
    }

    func pauseAll(until resumeAt: Date?, disconnect: Bool = false) async {
        settings.pauseAll(until: resumeAt)
        schedulePauseResume()

        if disconnect {
            for share in settings.shares {
                await self.disconnect(share, pauseAutomaticMounting: false)
            }
        } else {
            await evaluateAll(reason: .configurationChanged)
        }
    }

    func resumeAll() async {
        settings.resumeAll(clearSharePauses: true)
        schedulePauseResume()
        await evaluateAll(reason: .configurationChanged)
    }

    func pause(_ share: NetworkShare, until resumeAt: Date?, disconnect: Bool = false) async {
        settings.pauseShare(id: share.id, until: resumeAt)
        schedulePauseResume()

        if disconnect {
            await self.disconnect(share, pauseAutomaticMounting: false)
        } else if let updatedShare = settings.share(id: share.id) {
            await evaluate(updatedShare, reason: .configurationChanged)
        }
    }

    func resume(_ share: NetworkShare) async {
        settings.resumeShare(id: share.id)
        schedulePauseResume()
        if let updatedShare = settings.share(id: share.id) {
            await evaluate(updatedShare, reason: .configurationChanged)
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
            state.lastCheckedAt = now()
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
                    self?.schedulePauseResume()
                    self?.scheduleCheck(reason: .configurationChanged)
                }
            }
            .store(in: &cancellables)

        settings.$preferences
            .map(\.pauseState)
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.schedulePauseResume()
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

    private func schedulePauseResume() {
        pauseResumeTask?.cancel()
        pauseResumeTask = nil

        let currentDate = now()
        settings.clearExpiredPauses(at: currentDate)
        guard let resumeDate = settings.nextPauseResumeDate(after: currentDate) else { return }

        pauseResumeTask = Task { [weak self] in
            guard let self else { return }
            let delay = max(0, resumeDate.timeIntervalSince(self.now()))
            try? await Task.sleep(nanoseconds: nanoseconds(for: delay))
            guard !Task.isCancelled else { return }
            self.settings.clearExpiredPauses(at: self.now())
            self.schedulePauseResume()
            await self.evaluateAll(reason: .configurationChanged)
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

    func evaluate(_ share: NetworkShare, reason: MonitorReason, force: Bool = false) async {
        // A check for this share is already running; remember the request and
        // re-run once it finishes so events arriving mid-check aren't lost.
        guard !activeChecks.contains(share.id) else {
            let pendingForce = (pendingChecks[share.id]?.force ?? false) || force
            let pendingReason: MonitorReason
            if pendingChecks[share.id]?.reason.resetsRetryBudget == true && !reason.resetsRetryBudget {
                pendingReason = pendingChecks[share.id]?.reason ?? reason
            } else {
                pendingReason = reason
            }
            pendingChecks[share.id] = (pendingReason, pendingForce)
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

        if force || reason.resetsRetryBudget {
            state.failureCount = 0
            state.nextRetryDate = nil
            state.needsCredentials = false
            cancelRetry(for: share.id)
        }

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

        state.lastCheckedAt = now()
        await networkService.refreshNetworkDetailsIfStale()

        let mountedURL = await mountService.mountedURL(for: share)
        let isMounted = mountedURL != nil

        if !force, let pauseState = settings.effectivePauseState(for: share, at: now()) {
            cancelRetry(for: share.id)
            state.status = isMounted ? .connected : .paused(pauseState.resumeAt)
            state.failureCount = 0
            state.nextRetryDate = nil
            state.needsCredentials = false
            saveState(state, for: share)
            return
        }

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
                if settings.preferences.recoverUnresponsiveMounts, reason == .timer {
                    let health = await mountHealthService.checkMount(at: mountedURL, timeout: 3)
                    if health == .unresponsive {
                        eventLog.record(
                            .unresponsiveDetected,
                            for: share,
                            detail: "The mounted volume stopped responding."
                        )

                        if await mountHealthService.unmountForRecovery(at: mountedURL, timeout: 10) {
                            eventLog.record(
                                .recoveryAttempted,
                                for: share,
                                detail: "Safely unmounted the unresponsive volume."
                            )
                            state.status = .reconnecting
                            state.failureCount = 0
                            state.nextRetryDate = nil
                            saveState(state, for: share)
                            scheduleCheck(reason: .manual, delay: 1)
                        } else {
                            registerFailure(
                                "The mounted volume is not responding and could not be safely unmounted. Otter did not force it.",
                                for: share.id
                            )
                        }
                        return
                    }
                }

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


        guard force || RetryBackoff.shouldRetry(afterFailures: state.failureCount) else {
            if case .failed = state.status {
                // Keep the underlying mount/reachability error that exhausted
                // the retry budget instead of replacing it on every timer tick.
            } else {
                state.status = .failed(retryLimitMessage())
            }
            state.nextRetryDate = nil
            saveState(state, for: share)
            cancelRetry(for: share.id)
            return
        }

        if !force, let nextRetryDate = state.nextRetryDate, nextRetryDate > now() {
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
                state.failureCount += 1
                if RetryBackoff.shouldRetry(afterFailures: state.failureCount) {
                    state.status = wakePacketSent ? .wakePacketSent : .waitingForNetwork
                    state.nextRetryDate = nextRetryDate(afterFailures: state.failureCount)
                } else {
                    state.status = .failed(retryLimitMessage())
                    state.nextRetryDate = nil
                }
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

        let now = now()
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
        state.failureCount += 1
        state.lastCheckedAt = now()
        state.needsCredentials = needsCredentials
        if RetryBackoff.shouldRetry(afterFailures: state.failureCount) {
            state.status = .failed(message)
            state.nextRetryDate = nextRetryDate(afterFailures: state.failureCount)
        } else {
            state.status = .failed("\(message) \(retryLimitMessage())")
            state.nextRetryDate = nil
        }
        saveState(state, for: shareID)
        scheduleRetry(for: shareID, at: state.nextRetryDate)
    }

    private func retryLimitMessage() -> String {
        "Automatic reconnect paused after \(RetryBackoff.maxAutomaticAttempts) attempts. It will resume after the Mac wakes, the network or settings change, or you mount manually."
    }

    private func updateFailure(_ message: String, for shareID: NetworkShare.ID) {
        var state = states[shareID] ?? ShareRuntimeState()
        state.status = .failed(message)
        state.lastCheckedAt = now()
        saveState(state, for: shareID)
    }

    private func updateStatus(_ status: ShareStatus, for shareID: NetworkShare.ID) {
        var state = states[shareID] ?? ShareRuntimeState()
        state.status = status
        state.lastCheckedAt = now()
        saveState(state, for: shareID)
    }

    private func saveState(_ state: ShareRuntimeState, for share: NetworkShare) {
        var updatedState = state
        let previousState = states[share.id]
        let previousStatus = previousState?.status ?? .disconnected

        if case .connected = updatedState.status {
            if previousState?.mountedAt == nil {
                updatedState.mountedAt = now()
            } else {
                updatedState.mountedAt = previousState?.mountedAt
            }
            updatedState.lastConnectedAt = now()
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
        case .paused where previous == .connected:
            eventLog.record(.disconnected, for: share, detail: "Automatic mounting paused.")
        case let .waitingForAllowedNetwork(requirement) where previous == .connected:
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
        defaults.set(data, forKey: Self.connectionTimesKey)
    }

    private static func loadPersistedConnectionTimes(from defaults: UserDefaults) -> [String: PersistedConnectionTimes] {
        guard let data = defaults.data(forKey: connectionTimesKey),
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
        now().addingTimeInterval(RetryBackoff.delayWithJitter(afterFailures: failures))
    }

    private func scheduleRetry(for shareID: NetworkShare.ID, at date: Date?) {
        cancelRetry(for: shareID)
        guard let date else { return }

        let delay = max(date.timeIntervalSinceNow, 0)
        retryTasks[shareID] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds(for: delay))
            guard !Task.isCancelled else { return }
            await self?.runScheduledRetry(for: shareID)
        }
    }

    private func runScheduledRetry(for shareID: NetworkShare.ID) async {
        // Remove the completed task before evaluating. If the evaluation
        // schedules another attempt, it should not cancel the task currently
        // executing this method.
        retryTasks[shareID] = nil
        await evaluateShare(id: shareID, reason: .retry)
    }

    private func cancelRetry(for shareID: NetworkShare.ID) {
        retryTasks[shareID]?.cancel()
        retryTasks[shareID] = nil
    }

    private func resolveAndCacheIPAddress(for share: NetworkShare) {
        guard let host = share.host, !NetworkShare.isIPAddress(host) else { return }
        guard !networkService.isVPNConnected else { return }

        Task { @MainActor [weak self] in
            let resolvedAddresses = await NetworkShare.resolveIPAddresses(for: host)
            self?.settings.recordResolvedIPAddresses(resolvedAddresses, for: share.id)
        }
    }

    private func syncStates(with shares: [NetworkShare]) {
        let shareIDs = Set(shares.map(\.id))

        for shareID in Array(retryTasks.keys) where !shareIDs.contains(shareID) {
            cancelRetry(for: shareID)
        }

        states = states.filter { shareIDs.contains($0.key) }
        lastWakePacketDates = lastWakePacketDates.filter { shareIDs.contains($0.key) }
        pendingChecks = pendingChecks.filter { shareIDs.contains($0.key) }
        lastEvaluatedShares = lastEvaluatedShares.filter { shareIDs.contains($0.key) }

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
