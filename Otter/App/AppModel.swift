import AppKit
import Combine
import Foundation

struct ShareEditorRequest: Identifiable, Equatable {
    enum Mode: Equatable {
        case add
        case addDetected(MountedShareSuggestion)
        case edit(NetworkShare.ID)
    }

    let id = UUID()
    let mode: Mode
}

enum AppRuntime {
    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}

@MainActor
final class AppModel: ObservableObject {
    static let sharesWindowID = "shares"

    let settings: SettingsStore
    let networkService: NetworkReachabilityService
    let mountService: MountService
    let mountHealthService: MountHealthService
    let vpnConnectionService: SystemVPNConnectionService
    let discoveryService: SMBDiscoveryService
    let shareBrowserService: SMBShareBrowserService
    let keychainShareDiscoveryService: KeychainSMBShareDiscoveryService
    let wakeOnLANService: WakeOnLANService
    let notificationService: NotificationService
    let loginItemService: LoginItemService
    let updaterViewModel: UpdaterViewModel
    let eventLog: ShareEventLog
    let monitor: ShareMonitor
    let connectionDoctor: ConnectionDoctor
    let newShareDetector: NewShareDetectionService
    let deduplicationService: ShareDeduplicationService
    lazy var commandService = OtterCommandService(appModel: self)

    @Published var editorRequest: ShareEditorRequest?
    @Published var shouldOpenSharesWindow = false
    @Published var shouldPresentOnboarding = false
    @Published private(set) var isMenuBarExtraInserted = true

    private var isSharesWindowVisible = false
    private var deferredEditorRequest: ShareEditorRequest?

#if DEBUG
    @Published private(set) var isScreenshotDemoEnabled = false

    func setScreenshotDemo(_ enabled: Bool) {
        isScreenshotDemoEnabled = enabled
        monitor.demoStateProvider = enabled ? { ScreenshotDemo.runtimeState(for: $0) } : nil
    }
#endif

    // Demo accessors return nil outside debug screenshot mode, so views can
    // write `appModel.screenshotDemoShares ?? settings.shares` unconditionally.
    var screenshotDemoShares: [NetworkShare]? {
#if DEBUG
        return isScreenshotDemoEnabled ? ScreenshotDemo.shares : nil
#else
        return nil
#endif
    }

    var screenshotDemoEvents: [ShareEvent]? {
#if DEBUG
        return isScreenshotDemoEnabled ? ScreenshotDemo.events : nil
#else
        return nil
#endif
    }

    func screenshotDemoHasCredentials(for shareID: NetworkShare.ID) -> Bool? {
#if DEBUG
        guard isScreenshotDemoEnabled else { return nil }
        return ScreenshotDemo.hasCredentials(for: shareID)
#else
        return nil
#endif
    }

    func screenshotDemoDropCount(for shareID: NetworkShare.ID) -> Int? {
#if DEBUG
        guard isScreenshotDemoEnabled else { return nil }
        return ScreenshotDemo.dropCount(for: shareID)
#else
        return nil
#endif
    }

    func triggerOpenSharesWindow() {
        shouldOpenSharesWindow = true
    }

    func requestOnboarding() {
        shouldPresentOnboarding = true
    }

    private var hasStarted = false
    private var isOnboardingPresented = false
    private var isPreferencesWindowVisible = false
    private var lastAppliedDockIconVisibility: Bool?
    private var cancellables = Set<AnyCancellable>()

    init(isRunningTests: Bool = AppRuntime.isRunningTests) {
        let defaults: UserDefaults
        if isRunningTests {
            defaults = UserDefaults(suiteName: "OtterTests.Runtime.\(UUID().uuidString)")!
        } else {
            defaults = .standard
        }

        let credentialStore = KeychainCredentialStore()
        let settings = SettingsStore(defaults: defaults, credentialStore: credentialStore)
        let networkService = NetworkReachabilityService()
        let mountService = MountService(credentialStore: credentialStore)
        let mountHealthService = MountHealthService()
        let vpnConnectionService = SystemVPNConnectionService()
        let wakeOnLANService = WakeOnLANService()
        let notificationService = NotificationService(settings: settings)
        let eventLog = ShareEventLog(defaults: defaults)
        let monitor = ShareMonitor(
            settings: settings,
            mountService: mountService,
            mountHealthService: mountHealthService,
            wakeOnLANService: wakeOnLANService,
            vpnConnectionService: vpnConnectionService,
            networkService: networkService,
            notificationService: notificationService,
            eventLog: eventLog,
            defaults: defaults
        )

        self.settings = settings
        self.networkService = networkService
        self.mountService = mountService
        self.mountHealthService = mountHealthService
        self.vpnConnectionService = vpnConnectionService
        self.discoveryService = SMBDiscoveryService()
        self.shareBrowserService = SMBShareBrowserService()
        self.keychainShareDiscoveryService = KeychainSMBShareDiscoveryService()
        self.wakeOnLANService = wakeOnLANService
        self.notificationService = notificationService
        self.loginItemService = LoginItemService()
        // An in-place update relaunches Otter, so hold it back while a share
        // check is in flight rather than interrupting a mount or unmount.
        self.updaterViewModel = UpdaterViewModel(
            startingUpdater: !isRunningTests,
            settings: settings,
            isSafeToInstallNow: { [weak monitor] in
                guard let monitor else { return true }
                return !monitor.isChecking
            }
        )
        self.eventLog = eventLog
        self.monitor = monitor
        self.connectionDoctor = ConnectionDoctor(
            settings: settings,
            mountService: mountService,
            mountHealthService: mountHealthService,
            networkService: networkService,
            monitor: monitor
        )
        self.newShareDetector = NewShareDetectionService(
            settings: settings,
            notificationService: notificationService,
            defaults: defaults
        )
        let discoveryService = self.discoveryService
        self.deduplicationService = ShareDeduplicationService(
            settings: settings,
            monitor: monitor,
            eventLog: eventLog,
            credentialStore: credentialStore,
            // Bonjour knows the exact name Finder lists a server under. It is
            // only browsing while a share editor is open, so deduplication
            // falls back to the stripped name when nothing is advertised.
            advertisedServerNames: { discoveryService.servers.map(\.name) }
        )
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        notificationService.actionHandler = { [weak self] action, shareID in
            self?.handleNotificationAction(action, shareID: shareID)
        }
        notificationService.detectedShareActionHandler = { [weak self] action, mountPath in
            self?.handleDetectedShareAction(action, mountPath: mountPath)
        }
        OtterIntentBridge.configure(with: self)
        loginItemService.refresh()
        notificationService.start()
        networkService.start()
        monitor.start()
        newShareDetector.start()
        deduplicationService.start()
        commandService.start()
        observePreferences()
        refreshDockIconVisibility()
    }

    private func handleNotificationAction(_ action: ShareNotificationAction, shareID: NetworkShare.ID) {
        guard let share = settings.share(id: shareID) else { return }

        switch action {
        case .retry:
            Task { await monitor.retry(share) }
        case .openInFinder:
            if monitor.status(for: share) == .connected {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: share.mountPath)])
            } else if let url = share.url {
                NSWorkspace.shared.open(url)
            }
        case .pause:
            Task { await monitor.pause(share, until: nil) }
        case .showShare:
            triggerOpenSharesWindow()
        }
    }

    private func handleDetectedShareAction(_ action: DetectedShareNotificationAction, mountPath: String) {
        guard let suggestion = newShareDetector.pendingSuggestion(withMountPath: mountPath) else { return }

        switch action {
        case .manage:
            manageDetectedShare(suggestion)
        case .review:
            reviewDetectedShare(suggestion)
        case .ignore:
            newShareDetector.ignore(suggestion)
        }
    }

    // Accepts the offer: Otter adds the share and keeps it mounted from now on.
    func manageDetectedShare(_ suggestion: MountedShareSuggestion) {
        guard newShareDetector.manage(suggestion) != nil else { return }
        triggerOpenSharesWindow()
    }

    // Opens the new-share editor prefilled from the detected volume. The offer
    // stays until the share is saved or ignored, so cancelling loses nothing.
    func reviewDetectedShare(_ suggestion: MountedShareSuggestion) {
        newShareDetector.acknowledgeNotification(for: suggestion)

        let request = ShareEditorRequest(mode: .addDetected(suggestion))
        if isSharesWindowVisible {
            editorRequest = request
        } else {
            // The editor is a sheet over the shares window, so it can't present
            // until that window's content exists. The request waits for the
            // window to report that it appeared.
            deferredEditorRequest = request
        }

        triggerOpenSharesWindow()
    }

    func requestNewShare() {
        editorRequest = ShareEditorRequest(mode: .add)
    }

    func requestEditShare(_ share: NetworkShare) {
        guard !settings.isManagedShare(id: share.id) else { return }
        editorRequest = ShareEditorRequest(mode: .edit(share.id))
    }

    func sharesWindowDidAppear() {
        isSharesWindowVisible = true
        refreshDockIconVisibility(activateIfShowing: true)

        guard let request = deferredEditorRequest else { return }
        deferredEditorRequest = nil

        // One turn of the main actor lets SwiftUI finish presenting the window
        // before the sheet attaches to it.
        Task { @MainActor in
            await Task.yield()
            editorRequest = request
        }
    }

    func sharesWindowDidDisappear() {
        isSharesWindowVisible = false
        refreshDockIconVisibility()
    }

    func preferencesWindowDidAppear() {
        isPreferencesWindowVisible = true
        refreshDockIconVisibility(activateIfShowing: true)
    }

    func preferencesWindowDidDisappear() {
        isPreferencesWindowVisible = false
        refreshDockIconVisibility()
    }

    func onboardingDidBegin() {
        isOnboardingPresented = true
        newShareDetector.isSuppressed = true
        refreshDockIconVisibility(activateIfShowing: true)
    }

    func onboardingDidEnd() {
        isOnboardingPresented = false
        newShareDetector.isSuppressed = editorRequest != nil
        refreshDockIconVisibility()
    }

    // Shared by Preferences → Support and the Help menu so both produce the
    // same redacted package from the same live services.
    func exportSupportPackage() async -> Result<URL?, Error> {
        await SupportDiagnosticsExporter.presentSavePanel(
            settings: settings,
            eventLog: eventLog,
            monitor: monitor,
            networkService: networkService,
            notificationService: notificationService,
            loginItemService: loginItemService
        )
    }

    func refreshDockIconVisibility(activateIfShowing: Bool = false) {
        let mode = settings.preferences.appPresenceMode
        let shouldShowMenuBarIcon = mode.shouldShowMenuBarIcon(duringOnboarding: isOnboardingPresented)
        if isMenuBarExtraInserted != shouldShowMenuBarIcon {
            isMenuBarExtraInserted = shouldShowMenuBarIcon
        }

        let shouldShowDockIcon = mode.shouldShowDockIcon(
            duringOnboarding: isOnboardingPresented,
            duringShareEditing: editorRequest != nil,
            duringPreferencesOpen: isPreferencesWindowVisible,
            duringSharesWindowOpen: isSharesWindowVisible
        )

        // Only the policy switch is expensive enough to guard. Activation is a
        // separate concern: in Dock + Menu Bar mode the policy is already
        // .regular, so guarding both together meant opening a window never
        // brought Otter forward and the menu bar kept showing the other app.
        let policyChanged = lastAppliedDockIconVisibility != shouldShowDockIcon
        lastAppliedDockIconVisibility = shouldShowDockIcon
        let shouldActivate = shouldShowDockIcon && activateIfShowing

        guard policyChanged || shouldActivate else { return }

        Task { @MainActor in
            if policyChanged {
                _ = NSApp.setActivationPolicy(shouldShowDockIcon ? .regular : .accessory)
            }

            if shouldActivate {
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    private func observePreferences() {
        // The editor's Finder picker mounts the very share being added, so
        // detection stays quiet while an editor or onboarding is on screen.
        $editorRequest
            .sink { [weak self] request in
                guard let self else { return }
                self.newShareDetector.isSuppressed = request != nil || self.isOnboardingPresented
                self.refreshDockIconVisibility(activateIfShowing: request != nil)
            }
            .store(in: &cancellables)

        settings.$preferences
            .map(\.appPresenceMode)
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.refreshDockIconVisibility(activateIfShowing: true)
                }
            }
            .store(in: &cancellables)
    }
}

#if DEBUG
// Fixed fake shares in assorted states for product screenshots. Enabled from
// Preferences → Developer; reads only — real configuration is never touched
// and the monitor never mounts these.
enum ScreenshotDemo {
    private static let mediaID = UUID()
    private static let backupsID = UUID()
    private static let projectsID = UUID()
    private static let timeMachineID = UUID()
    private static let archiveID = UUID()

    static let shares: [NetworkShare] = [
        NetworkShare(
            id: mediaID,
            displayName: "Media",
            urlString: "smb://homenas.local/Media",
            mountPath: "/Volumes/Media",
            wakeOnLAN: WakeOnLANConfiguration(isEnabled: true, macAddress: "A4:83:E7:2C:19:5B"),
            rules: ShareRules(wifiNetworkName: "Homebase", registeredSubnets: ["192.168.1.0/24"]),
            cachedIPAddress: "192.168.1.20"
        ),
        NetworkShare(
            id: backupsID,
            displayName: "Backups",
            urlString: "smb://homenas.local/Backups",
            mountPath: "/Volumes/Backups",
            connectionMode: .adaptive
        ),
        NetworkShare(
            id: projectsID,
            displayName: "Projects",
            urlString: "smb://studio-server.local/Projects",
            mountPath: "/Volumes/Projects"
        ),
        NetworkShare(
            id: timeMachineID,
            displayName: "Time Machine",
            urlString: "smb://homenas.local/TimeMachine",
            mountPath: "/Volumes/TimeMachine",
            rules: ShareRules(
                wifiNetworkName: "Homebase",
                registeredSubnets: ["192.168.1.0/24"],
                vpnRuleEnabled: true,
                vpnName: "Work VPN"
            )
        ),
        NetworkShare(
            id: archiveID,
            displayName: "Archive",
            urlString: "smb://archive-nas.local/Archive",
            mountPath: "/Volumes/Archive"
        ),
    ]

    static func runtimeState(for shareID: NetworkShare.ID) -> ShareRuntimeState? {
        let now = Date()

        switch shareID {
        case mediaID:
            var state = ShareRuntimeState()
            state.status = .connected
            state.mountedAt = now.addingTimeInterval(-2 * 3600 - 47 * 60)
            state.lastConnectedAt = now.addingTimeInterval(-90)
            return state
        case backupsID:
            var state = ShareRuntimeState()
            state.status = .connected
            state.mountedAt = now.addingTimeInterval(-25 * 60)
            state.lastConnectedAt = now.addingTimeInterval(-120)
            return state
        case projectsID:
            var state = ShareRuntimeState()
            state.status = .reconnecting
            state.failureCount = 2
            state.lastConnectedAt = now.addingTimeInterval(-12 * 60)
            return state
        case timeMachineID:
            var state = ShareRuntimeState()
            state.status = .waitingForAllowedNetwork("the registered network or VPN Work VPN")
            state.lastConnectedAt = now.addingTimeInterval(-11 * 3600)
            return state
        case archiveID:
            var state = ShareRuntimeState()
            state.status = .failed("Authentication failed. Connect once in Finder and save the password to Keychain.")
            state.failureCount = 4
            state.needsCredentials = true
            state.lastConnectedAt = now.addingTimeInterval(-3 * 24 * 3600)
            return state
        default:
            return nil
        }
    }

    static let events: [ShareEvent] = {
        let now = Date()

        func event(_ kind: ShareEventKind, _ shareID: NetworkShare.ID, minutesAgo: Double, detail: String? = nil) -> ShareEvent {
            ShareEvent(
                id: UUID(),
                shareID: shareID,
                date: now.addingTimeInterval(-minutesAgo * 60),
                kind: kind,
                detail: detail
            )
        }

        return [
            event(.connectionLost, projectsID, minutesAgo: 12),
            event(.mounted, backupsID, minutesAgo: 25),
            event(.mounted, projectsID, minutesAgo: 58),
            event(.connectionLost, projectsID, minutesAgo: 65),
            event(.mounted, mediaID, minutesAgo: 167),
            event(.mountFailed, archiveID, minutesAgo: 180, detail: "Authentication failed. Connect once in Finder and save the password to Keychain."),
            event(.blockedByRule, timeMachineID, minutesAgo: 11 * 60, detail: "the registered network or VPN Work VPN"),
            event(.wakePacketSent, mediaID, minutesAgo: 11.5 * 60),
            event(.connectionLost, projectsID, minutesAgo: 18 * 60),
            event(.disconnected, backupsID, minutesAgo: 26 * 60),
        ]
    }()

    static func hasCredentials(for shareID: NetworkShare.ID) -> Bool {
        shareID != archiveID
    }

    static func dropCount(for shareID: NetworkShare.ID, within interval: TimeInterval = 24 * 60 * 60) -> Int {
        let cutoff = Date().addingTimeInterval(-interval)
        return events
            .filter { $0.shareID == shareID && $0.kind == .connectionLost && $0.date >= cutoff }
            .count
    }
}
#endif
