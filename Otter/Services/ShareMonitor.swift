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
    private let vpnConnectionService: any VPNConnecting
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
    private var unexpectedDisconnectRecoveries = Set<NetworkShare.ID>()
    private var activeChecks = Set<NetworkShare.ID>()
    private var pendingChecks: [NetworkShare.ID: (reason: MonitorReason, force: Bool)] = [:]
    private var hasStarted = false
    // Shares whose current evaluation is one the user asked for, or the single
    // automatic attempt a Connect Once share is entitled to. Modes that stay
    // quiet in the background still report failures from these attempts.
    private var requestedAttempts = Set<NetworkShare.ID>()
    private var lastEvaluatedShares: [NetworkShare.ID: NetworkShare] = [:]
    // Shares Otter is unmounting only to mount again straight away, so the
    // deduplication pass can move a share to another address without reporting
    // a disconnection the user never experienced.
    private var maintenanceRemounts = Set<NetworkShare.ID>()
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
        vpnConnectionService: any VPNConnecting = SystemVPNConnectionService(),
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
        self.vpnConnectionService = vpnConnectionService
        self.networkService = networkService
        self.notificationService = notificationService
        self.eventLog = eventLog
        self.defaults = defaults
        self.now = now
        persistedConnectionTimes = Self.loadPersistedConnectionTimes(from: defaults)
        syncStates(with: settings.shares)
    }

    var menuBarSystemImage: String {
        if settings.isGloballyPaused && settings.shares.contains(where: { $0.connectsAutomatically }) {
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

    // Connects everything now. This is a request, not a reconfiguration: a
    // share's connection mode is the user's choice and mounting on demand
    // never rewrites it.
    func mountAll() async {
        settings.resumeAll(clearSharePauses: true)
        await evaluateAll(reason: .manual, force: true)
    }

    func disconnectAll() async {
        if settings.shares.contains(where: { $0.connectsAutomatically }) {
            await pauseAll(until: nil, disconnect: true)
        } else {
            for share in settings.shares {
                await disconnect(share, pauseAutomaticMounting: false)
            }
        }
    }

    func mount(_ share: NetworkShare) async {
        settings.resumeShare(id: share.id)
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
        let currentShare = settings.share(id: share.id) ?? share
        if pauseAutomaticMounting && currentShare.connectsAutomatically {
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

    /// Unmounts a share and immediately reconnects it, without reporting the
    /// disconnection in between. Pass the share as it is mounted right now: the
    /// unmount matches on its current address, while the reconnection uses
    /// whatever is saved by the time it runs.
    ///
    /// Returns false when the volume could not be unmounted — a busy volume is
    /// left mounted rather than forced.
    @discardableResult
    func remountForMaintenance(_ share: NetworkShare) async -> Bool {
        cancelRetry(for: share.id)
        maintenanceRemounts.insert(share.id)
        defer { maintenanceRemounts.remove(share.id) }

        do {
            try await mountService.unmount(share)
        } catch {
            return false
        }

        let updatedShare = settings.share(id: share.id) ?? share
        await evaluate(updatedShare, reason: .manual, force: true)
        return true
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

        let mode = share.connectionMode
        // Modes that do not maintain the connection still act on the trigger
        // they were configured for: the user pressing Connect, and — for
        // Connect Once — the one automatic attempt it makes at launch.
        let isRequestedAttempt = force || (reason == .launch && mode == .connectOnce)
        // Whether Otter is expected to have this share mounted right now. This
        // separates a persistent mode from one that only acts on a trigger.
        let wantsConnectionNow = force
            || mode.maintainsConnection
            || (reason == .launch && mode.connectsAutomatically)
        // Keep Connected is not location aware, so its saved VPN configuration
        // is preserved but never evaluated.
        let rules = share.activeRules

        activeChecks.insert(share.id)
        isChecking = true
        if isRequestedAttempt {
            requestedAttempts.insert(share.id)
        }
        defer {
            activeChecks.remove(share.id)
            isChecking = !activeChecks.isEmpty
            requestedAttempts.remove(share.id)

            if let pending = pendingChecks.removeValue(forKey: share.id) {
                Task { [weak self] in
                    await self?.evaluateShare(id: share.id, reason: pending.reason, force: pending.force)
                }
            }
        }

        var state = states[share.id] ?? ShareRuntimeState()

        if force || reason.resetsRetryBudget {
            unexpectedDisconnectRecoveries.remove(share.id)
            state.failureCount = 0
            state.nextRetryDate = nil
            state.needsCredentials = false
            cancelRetry(for: share.id)
        }

        let oldShare = lastEvaluatedShares[share.id]
        if let oldShare, oldShare != share {
            unexpectedDisconnectRecoveries.remove(share.id)
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
            unexpectedDisconnectRecoveries.remove(share.id)
            cancelRetry(for: share.id)
            state.status = isMounted ? .connected : .paused(pauseState.resumeAt)
            state.failureCount = 0
            state.nextRetryDate = nil
            state.needsCredentials = false
            saveState(state, for: share)
            return
        }

        var ruleEvaluation = rules.evaluate(
            currentWiFiNetworkName: networkService.currentWiFiNetworkName,
            isVPNConnected: networkService.isVPNConnected,
            activeVPNNames: networkService.activeVPNNames,
            currentIPv4Subnets: networkService.currentIPv4Subnets
        )

        // A VPN-only rule is a fallback path, not a requirement when the
        // server already answers directly. Probe before starting (or waiting
        // for) the saved VPN so Manual, Adaptive and Connect Once use the LAN
        // whenever it is available. Explicit registered-network rules still
        // rely on their saved network identity and are never bypassed by this
        // reachability check.
        var serverWasReachableDirectly = false
        if !ruleEvaluation.allowsConnection,
           wantsConnectionNow,
           rules.hasVPNRule,
           !rules.hasNetworkRule,
           rules.requiredVPNName != nil,
           networkService.isOnline,
           let url = share.url {
            serverWasReachableDirectly = await networkService.canReachServer(for: url)
            if serverWasReachableDirectly {
                ruleEvaluation = ShareRuleEvaluation(
                    allowsConnection: true,
                    blockedStatus: nil,
                    shouldDisconnectMountedShare: false,
                    shouldAttemptMount: true
                )
            }
        }

        // The saved VPN name identifies the required connection path. Otter
        // starts it only when the server is not directly reachable and
        // automatic VPN connection is enabled; otherwise the rule remains
        // blocked until a live tunnel appears. Any live tunnel allows a server
        // check because app-managed VPNs don't always expose their exact
        // profile name to other apps.
        // Manual and Connect Once only bring up a VPN for the attempt they were
        // asked to make, never in the background.
        if !ruleEvaluation.allowsConnection,
           wantsConnectionNow,
           rules.hasVPNRule,
           rules.shouldConnectVPNAutomatically,
           let requiredVPNName = rules.requiredVPNName,
           networkService.isOnline {
            if !force, !RetryBackoff.shouldRetry(afterFailures: state.failureCount) {
                if case .failed = state.status {
                    // Preserve the specific VPN error that exhausted retries.
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

            if !isMounted {
                state.status = .reconnecting
                saveState(state, for: share)
            }

            do {
                try await vpnConnectionService.connect(named: requiredVPNName)

                // A path-change refresh may still be finishing with a snapshot
                // captured during negotiation. Re-read briefly until the newly
                // connected service is visible before moving on to SMB.
                for refreshAttempt in 0..<5 {
                    await networkService.refreshNetworkDetailsNow()
                    ruleEvaluation = rules.evaluate(
                        currentWiFiNetworkName: networkService.currentWiFiNetworkName,
                        isVPNConnected: networkService.isVPNConnected,
                        activeVPNNames: networkService.activeVPNNames,
                        currentIPv4Subnets: networkService.currentIPv4Subnets
                    )
                    if ruleEvaluation.allowsConnection {
                        break
                    }
                    if refreshAttempt < 4 {
                        try? await Task.sleep(nanoseconds: nanoseconds(for: 0.25))
                    }
                }

                guard ruleEvaluation.allowsConnection else {
                    throw SystemVPNConnectionError.disconnected(requiredVPNName)
                }
            } catch {
                if let vpnError = error as? SystemVPNConnectionError,
                   case .notControllable = vpnError {
                    if isMounted && ruleEvaluation.shouldDisconnectMountedShare {
                        do {
                            try await mountService.unmount(share)
                        } catch {
                            updateFailure(
                                "Connect to “\(requiredVPNName)” to access this server. The mounted share also could not be disconnected: \(error.localizedDescription)",
                                for: share.id
                            )
                            return
                        }
                    }

                    cancelRetry(for: share.id)
                    state.status = .waitingForVPN(requiredVPNName)
                    state.failureCount = 0
                    state.nextRetryDate = nil
                    state.needsCredentials = false
                    saveState(state, for: share)
                    return
                }

                var message = error.localizedDescription

                if isMounted && ruleEvaluation.shouldDisconnectMountedShare {
                    do {
                        try await mountService.unmount(share)
                    } catch {
                        message += " The mounted share also could not be disconnected: \(error.localizedDescription)"
                    }
                }

                registerFailure(message, for: share.id)
                return
            }
        }

        if !ruleEvaluation.allowsConnection {
            unexpectedDisconnectRecoveries.remove(share.id)
            cancelRetry(for: share.id)
            // A share Otter isn't trying to connect right now is simply
            // disconnected; only an expected connection is "waiting" for
            // something.
            state.status = wantsConnectionNow ? (ruleEvaluation.blockedStatus ?? .disconnected) : .disconnected
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
                if reason == .timer && (settings.preferences.recoverUnresponsiveMounts || share.healthCheck.isEnabled) {
                    let health = await mountHealthService.checkPolicy(
                        at: mountedURL,
                        policy: share.healthCheck,
                        timeout: 3
                    )
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
                            if mode.maintainsConnection {
                                unexpectedDisconnectRecoveries.insert(share.id)
                            }
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
                    if case let .unavailable(message) = health {
                        eventLog.record(.healthCheckFailed, for: share, detail: message)
                        state.status = .failed("Health check: \(message)")
                        state.lastCheckedAt = now()
                        state.nextRetryDate = nil
                        saveState(state, for: share)
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
            unexpectedDisconnectRecoveries.remove(share.id)
            cancelRetry(for: share.id)
            resolveAndCacheIPAddress(for: share)
            return
        }

        // A volume notification (or the fallback timer if macOS misses that
        // notification) can reveal that a previously connected, managed share
        // vanished while the local network stayed put. Enter a persistent,
        // faster recovery mode so a NAS reboot does not hit the ordinary retry
        // ceiling and remain disconnected until another external event occurs.
        // Connect Once and Manual deliberately let a mount go: losing one is
        // not a fault to recover from.
        let lostExpectedMount = state.status == .connected
            && mode.maintainsConnection
            && (reason == .volumeChanged || reason == .timer)
        if lostExpectedMount {
            unexpectedDisconnectRecoveries.insert(share.id)
            state.failureCount = 0
            state.nextRetryDate = nil
            state.needsCredentials = false
            cancelRetry(for: share.id)
        }

        // A tunnel whose profile cannot be confirmed is useful positive
        // evidence only when the server answers. If it does not, the user may
        // simply be connected to a different client's VPN. Probe quietly
        // unless this share was already connected or the user explicitly
        // requested a connection.
        let directNetworkEvaluation = rules.evaluate(
            currentWiFiNetworkName: networkService.currentWiFiNetworkName,
            isVPNConnected: false,
            activeVPNNames: [],
            currentIPv4Subnets: networkService.currentIPv4Subnets
        )
        let selectedVPNIsConfirmed = !networkService.hasUnidentifiedTunnel
            && (rules.requiredVPNName.map { requiredName in
                networkService.activeVPNNames.contains {
                    $0.localizedCaseInsensitiveCompare(requiredName) == .orderedSame
                }
            } ?? false)
        let isUnconfirmedVPNPath = rules.hasVPNRule
            && networkService.isVPNConnected
            && !directNetworkEvaluation.allowsConnection
            && !selectedVPNIsConfirmed
        let shouldProbeVPNQuietly = isUnconfirmedVPNPath
            && !force
            && state.status != .connected

        if shouldProbeVPNQuietly {
            state.failureCount = 0
            state.nextRetryDate = nil
            state.needsCredentials = false
            cancelRetry(for: share.id)
        }

        let shouldAttemptMount = wantsConnectionNow

        guard shouldAttemptMount else {
            unexpectedDisconnectRecoveries.remove(share.id)
            // A failure from an attempt Otter was asked to make stays on
            // screen until something that could plausibly fix it happens —
            // waking, a network change, or an edit — rather than quietly
            // reverting to "disconnected" on the next timer tick.
            if case .failed = state.status, !reason.resetsRetryBudget {
                // Keep the reported failure.
            } else {
                state.status = .disconnected
            }
            state.nextRetryDate = nil
            saveState(state, for: share)
            cancelRetry(for: share.id)
            return
        }

        guard networkService.isOnline else {
            unexpectedDisconnectRecoveries.remove(share.id)
            state.status = .waitingForNetwork
            saveState(state, for: share)
            return
        }

        guard force || shouldRetryAutomatically(shareID: share.id, afterFailures: state.failureCount) else {
            if case .failed = state.status {
                // Keep the underlying mount/reachability error that exhausted
                // the retry budget instead of replacing it on every timer tick.
            } else {
                if rules.hasVPNRule && networkService.isVPNConnected {
                    state.status = .failed("\(vpnServerUnavailableMessage()) \(retryLimitMessage())")
                } else {
                    state.status = .failed(retryLimitMessage())
                }
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

        if !shouldProbeVPNQuietly {
            state.status = .reconnecting
            saveState(state, for: share)
        }

        var reachable = serverWasReachableDirectly
        if !reachable {
            reachable = await networkService.canReachServer(for: url)
        }
        var fallbackURL: URL? = nil

        if !reachable, networkService.isVPNConnected {
            if let host = url.host(percentEncoded: false), !NetworkShare.isIPAddress(host) {
                for cachedIP in share.orderedCachedIPAddresses {
                    guard !reachable else { break }
                    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
                    components?.host = NetworkShare.urlComponentsHost(forIPAddress: cachedIP)
                    if let resolvedURL = components?.url,
                       await networkService.canReachServer(for: resolvedURL) {
                        reachable = true
                        fallbackURL = resolvedURL
                    }
                }
            }
        }

        guard reachable else {
            if shouldProbeVPNQuietly {
                state.status = .waitingForAccess
                state.failureCount = 0
                state.nextRetryDate = nil
                state.needsCredentials = false
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

                // A one-shot or user-initiated attempt reports what it found
                // and stops there; only the persistent modes keep retrying.
                guard mode.maintainsConnection else {
                    state.failureCount = 0
                    state.needsCredentials = false
                    state.nextRetryDate = nil
                    if wakePacketSent {
                        state.status = .wakePacketSent
                    } else if rules.hasVPNRule && networkService.isVPNConnected {
                        state.status = .failed(vpnServerUnavailableMessage())
                    } else {
                        state.status = .failed(serverUnavailableMessage())
                    }
                    saveState(state, for: share)
                    cancelRetry(for: share.id)
                    return
                }

                state.failureCount += 1
                if shouldRetryAutomatically(shareID: share.id, afterFailures: state.failureCount) {
                    if wakePacketSent {
                        state.status = .wakePacketSent
                    } else if rules.hasVPNRule && networkService.isVPNConnected {
                        state.status = .waitingForServerOnVPN
                    } else {
                        state.status = .waitingForNetwork
                    }
                    state.nextRetryDate = nextRetryDate(afterFailures: state.failureCount, for: share.id)
                } else {
                    let message = rules.hasVPNRule && networkService.isVPNConnected
                        ? "\(vpnServerUnavailableMessage()) \(retryLimitMessage())"
                        : retryLimitMessage()
                    state.status = .failed(message)
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
                unexpectedDisconnectRecoveries.remove(share.id)
                cancelRetry(for: share.id)
                resolveAndCacheIPAddress(for: share)
            } else {
                registerFailure("macOS mounted the share, but Otter could not find the mounted volume.", for: share.id)
            }
        } catch {
            var needsCredentials = false
            if case MountServiceError.authenticationFailed = error {
                needsCredentials = true
                eventLog.record(.credentialsRequired, for: share, detail: "Open the share in Finder to refresh its saved credentials.")
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
        state.lastCheckedAt = now()
        state.needsCredentials = needsCredentials

        // Manual and Connect Once report the failure of the attempt they were
        // asked to make, then stop. Only the persistent modes back off and
        // keep trying.
        let mode = settings.share(id: shareID)?.connectionMode ?? .keepConnected
        guard mode.maintainsConnection else {
            state.status = .failed(message)
            state.nextRetryDate = nil
            unexpectedDisconnectRecoveries.remove(shareID)
            saveState(state, for: shareID)
            cancelRetry(for: shareID)
            return
        }

        state.failureCount += 1
        // Credential failures require user action and should not create an
        // unbounded stream of authentication attempts.
        if needsCredentials {
            unexpectedDisconnectRecoveries.remove(shareID)
        }
        if shouldRetryAutomatically(shareID: shareID, afterFailures: state.failureCount) {
            state.status = .failed(message)
            state.nextRetryDate = nextRetryDate(afterFailures: state.failureCount, for: shareID)
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

    private func serverUnavailableMessage() -> String {
        "The server isn’t responding on the current network."
    }

    private func vpnServerUnavailableMessage() -> String {
        "A VPN is connected, but the server isn’t responding. Check that the correct VPN is active."
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

        // A maintenance remount reports itself once it knows whether it worked,
        // rather than logging a disconnection and a reconnection in between.
        guard !maintenanceRemounts.contains(share.id) else { return }

        recordEvent(for: share, previous: previousStatus, current: updatedState.status)
        notificationService.notifyStatusChange(
            for: share,
            previous: previousStatus,
            current: updatedState.status,
            isRequestedAttempt: requestedAttempts.contains(share.id)
        )
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
        case let .waitingForVPN(name) where previous == .connected:
            eventLog.record(.blockedByRule, for: share, detail: "Waiting for VPN: \(name)")
        case .waitingForAccess where previous == .connected:
            eventLog.record(.connectionLost, for: share, detail: "The server is not available on the current connection.")
        case .waitingForServerOnVPN where previous == .connected:
            eventLog.record(.connectionLost, for: share, detail: vpnServerUnavailableMessage())
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

    private func shouldRetryAutomatically(shareID: NetworkShare.ID, afterFailures failures: Int) -> Bool {
        unexpectedDisconnectRecoveries.contains(shareID)
            || RetryBackoff.shouldRetry(afterFailures: failures)
    }

    private func nextRetryDate(afterFailures failures: Int, for shareID: NetworkShare.ID) -> Date {
        let delay = unexpectedDisconnectRecoveries.contains(shareID)
            ? UnexpectedDisconnectRetryPolicy.delayWithJitter(afterFailures: failures)
            : RetryBackoff.delayWithJitter(afterFailures: failures)
        return now().addingTimeInterval(delay)
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
        unexpectedDisconnectRecoveries.formIntersection(shareIDs)
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
