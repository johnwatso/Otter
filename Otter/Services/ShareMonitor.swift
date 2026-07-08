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
}

private struct ShareRuleEvaluation {
    var allowsConnection: Bool
    var blockedStatus: ShareStatus?
    var shouldDisconnectMountedShare: Bool
    var shouldAttemptMount: Bool
}

private struct ShareRuleCondition {
    var action: ShareRuleAction
    var matches: Bool
    var requirement: String
}

@MainActor
final class ShareMonitor: ObservableObject {
    @Published private var states: [NetworkShare.ID: ShareRuntimeState] = [:]
    @Published private(set) var isChecking = false

    private let settings: SettingsStore
    private let mountService: MountService
    private let networkService: NetworkReachabilityService
    private let notificationService: NotificationService
    private var cancellables = Set<AnyCancellable>()
    private var workspaceObservers: [NSObjectProtocol] = []
    private var fallbackTimer: Timer?
    private var retryTasks: [NetworkShare.ID: Task<Void, Never>] = [:]
    private var activeChecks = Set<NetworkShare.ID>()
    private var pendingChecks: [NetworkShare.ID: (reason: MonitorReason, force: Bool)] = [:]
    private var hasStarted = false

    init(
        settings: SettingsStore,
        mountService: MountService,
        networkService: NetworkReachabilityService,
        notificationService: NotificationService
    ) {
        self.settings = settings
        self.mountService = mountService
        self.networkService = networkService
        self.notificationService = notificationService
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

    func status(for share: NetworkShare) -> ShareStatus {
        states[share.id]?.status ?? .disconnected
    }

    func runtimeState(for share: NetworkShare) -> ShareRuntimeState {
        states[share.id] ?? ShareRuntimeState()
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
        state.lastCheckedAt = Date()
        networkService.refreshNetworkDetailsIfStale()

        let mountedURL = await mountService.mountedURL(for: share)
        let isMounted = mountedURL != nil
        let ruleEvaluation = evaluateRules(for: share)
        if !ruleEvaluation.allowsConnection {
            cancelRetry(for: share.id)
            state.status = ruleEvaluation.blockedStatus ?? .disconnected
            state.failureCount = 0
            state.nextRetryDate = nil
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
            saveState(state, for: share)
            cancelRetry(for: share.id)
            return
        }

        let shouldAttemptMount = force
            || share.keepMounted
            || (reason == .launch && share.mountAtLaunch)
            || ruleEvaluation.shouldAttemptMount
        guard shouldAttemptMount else {
            state.status = .disconnected
            state.nextRetryDate = nil
            saveState(state, for: share)
            cancelRetry(for: share.id)
            return
        }

        guard networkService.isOnline else {
            state.status = .waitingForNetwork
            saveState(state, for: share)
            return
        }

        let now = Date()
        if !force, let nextRetryDate = state.nextRetryDate, nextRetryDate > now {
            saveState(state, for: share)
            return
        }

        state.status = .reconnecting
        saveState(state, for: share)

        guard let url = share.url else {
            registerFailure("The network address is invalid.", for: share.id)
            return
        }

        let reachable = await networkService.canReachServer(for: url)
        guard reachable else {
            state = states[share.id] ?? state
            state.status = .waitingForNetwork
            state.nextRetryDate = nextRetryDate(afterFailures: max(state.failureCount, 1))
            saveState(state, for: share)
            scheduleRetry(for: share.id, at: state.nextRetryDate)
            return
        }

        do {
            if let mountedURL = try await mountService.mount(share) {
                syncMountPathIfNeeded(mountedURL, for: share)
                state.status = .connected
                state.failureCount = 0
                state.nextRetryDate = nil
                saveState(state, for: share)
                cancelRetry(for: share.id)
            } else {
                registerFailure("macOS mounted the share, but Otter could not find the mounted volume.", for: share.id)
            }
        } catch {
            registerFailure(error.localizedDescription, for: share.id)
        }
    }

    private func syncMountPathIfNeeded(_ mountedURL: URL, for share: NetworkShare) {
        let mountedPath = mountedURL.standardizedFileURL.resolvingSymlinksInPath().path

        guard normalizedPath(share.mountPath) != normalizedPath(mountedPath) else { return }

        settings.updateShare(id: share.id) { updatedShare in
            updatedShare.mountPath = mountedPath
        }
    }

    private func evaluateRules(for share: NetworkShare) -> ShareRuleEvaluation {
        let conditions = ruleConditions(for: share)

        guard !conditions.isEmpty else {
            return ShareRuleEvaluation(
                allowsConnection: true,
                blockedStatus: nil,
                shouldDisconnectMountedShare: false,
                shouldAttemptMount: false
            )
        }

        var shouldAttemptMount = false

        for condition in conditions {
            switch condition.action {
            case .connect:
                guard condition.matches else {
                    return ShareRuleEvaluation(
                        allowsConnection: false,
                        blockedStatus: .waitingForAllowedNetwork(condition.requirement),
                        shouldDisconnectMountedShare: true,
                        shouldAttemptMount: false
                    )
                }

                shouldAttemptMount = true
            case .disconnect:
                if condition.matches {
                    return ShareRuleEvaluation(
                        allowsConnection: false,
                        blockedStatus: .pausedByRule(condition.requirement),
                        shouldDisconnectMountedShare: true,
                        shouldAttemptMount: false
                    )
                }
            }
        }

        return ShareRuleEvaluation(
            allowsConnection: true,
            blockedStatus: nil,
            shouldDisconnectMountedShare: false,
            shouldAttemptMount: shouldAttemptMount
        )
    }

    private func ruleConditions(for share: NetworkShare) -> [ShareRuleCondition] {
        var conditions: [ShareRuleCondition] = []

        if let requiredNetworkName = share.rules.requiredWiFiNetworkName {
            let currentNetworkName = networkService.currentWiFiNetworkName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let matches = currentNetworkName?.localizedCaseInsensitiveCompare(requiredNetworkName) == .orderedSame

            conditions.append(ShareRuleCondition(
                action: share.rules.wifiNetworkAction,
                matches: matches,
                requirement: "Wi-Fi \(requiredNetworkName)"
            ))
        }

        if share.rules.hasVPNRule {
            let requiredVPNName = share.rules.requiredVPNName
            let matches = vpnMatches(requiredVPNName)
            let requirement = requiredVPNName.map { "VPN \($0)" } ?? "a VPN"

            conditions.append(ShareRuleCondition(
                action: share.rules.vpnAction,
                matches: matches,
                requirement: requirement
            ))
        }

        return conditions
    }

    private func vpnMatches(_ requiredVPNName: String?) -> Bool {
        guard let requiredVPNName else {
            return networkService.isVPNConnected
        }

        if networkService.activeVPNNames.contains(where: { activeVPNName in
            activeVPNName.localizedCaseInsensitiveCompare(requiredVPNName) == .orderedSame
        }) {
            return true
        }

        return networkService.isVPNConnected && networkService.activeVPNNames.isEmpty
    }

    private func registerFailure(_ message: String, for shareID: NetworkShare.ID) {
        var state = states[shareID] ?? ShareRuntimeState()
        state.status = .failed(message)
        state.failureCount += 1
        state.lastCheckedAt = Date()
        state.nextRetryDate = nextRetryDate(afterFailures: state.failureCount)
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
        let previousStatus = states[share.id]?.status ?? .disconnected
        states[share.id] = state
        notificationService.notifyStatusChange(for: share, previous: previousStatus, current: state.status)
    }

    private func saveState(_ state: ShareRuntimeState, for shareID: NetworkShare.ID) {
        if let share = settings.share(id: shareID) {
            saveState(state, for: share)
        } else {
            states[shareID] = state
        }
    }

    private func nextRetryDate(afterFailures failures: Int) -> Date {
        Date().addingTimeInterval(backoffDelay(afterFailures: failures))
    }

    private func backoffDelay(afterFailures failures: Int) -> TimeInterval {
        let delays: [TimeInterval] = [10, 30, 120, 300]
        return delays[min(max(failures - 1, 0), delays.count - 1)]
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

    private func syncStates(with shares: [NetworkShare]) {
        let shareIDs = Set(shares.map(\.id))
        states = states.filter { shareIDs.contains($0.key) }

        for share in shares where states[share.id] == nil {
            states[share.id] = ShareRuntimeState()
        }
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
