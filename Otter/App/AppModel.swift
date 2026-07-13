import AppKit
import Combine
import Foundation

struct ShareEditorRequest: Identifiable, Equatable {
    enum Mode: Equatable {
        case add
        case edit(NetworkShare.ID)
    }

    let id = UUID()
    let mode: Mode
}

@MainActor
final class AppModel: ObservableObject {
    static let preferencesWindowID = "preferences"
    static let sharesWindowID = "shares"

    let settings: SettingsStore
    let networkService: NetworkReachabilityService
    let mountService: MountService
    let wakeOnLANService: WakeOnLANService
    let notificationService: NotificationService
    let loginItemService: LoginItemService
    let updaterViewModel = UpdaterViewModel()
    let eventLog: ShareEventLog
    let monitor: ShareMonitor

    @Published var editorRequest: ShareEditorRequest?
    @Published var shouldOpenSharesWindow = false

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

    private var hasStarted = false
    private var preferencesWindowOpenCount = 0
    private var lastAppliedDockIconVisibility: Bool?
    private var cancellables = Set<AnyCancellable>()

    init() {
        let settings = SettingsStore()
        let networkService = NetworkReachabilityService()
        let mountService = MountService()
        let wakeOnLANService = WakeOnLANService()
        let notificationService = NotificationService(settings: settings)
        let eventLog = ShareEventLog()

        self.settings = settings
        self.networkService = networkService
        self.mountService = mountService
        self.wakeOnLANService = wakeOnLANService
        self.notificationService = notificationService
        self.loginItemService = LoginItemService()
        self.eventLog = eventLog
        self.monitor = ShareMonitor(
            settings: settings,
            mountService: mountService,
            wakeOnLANService: wakeOnLANService,
            networkService: networkService,
            notificationService: notificationService,
            eventLog: eventLog
        )
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        loginItemService.refresh()
        notificationService.start()
        networkService.start()
        monitor.start()
        observePreferences()
        refreshDockIconVisibility()
    }

    func requestNewShare() {
        editorRequest = ShareEditorRequest(mode: .add)
    }

    func requestEditShare(_ share: NetworkShare) {
        editorRequest = ShareEditorRequest(mode: .edit(share.id))
    }

    func preferencesWindowDidAppear() {
        preferencesWindowOpenCount += 1
        refreshDockIconVisibility(activateIfShowing: true)
    }

    func preferencesWindowDidDisappear() {
        preferencesWindowOpenCount = max(0, preferencesWindowOpenCount - 1)
        refreshDockIconVisibility()
    }

    func refreshDockIconVisibility(activateIfShowing: Bool = false) {
        let shouldShowDockIcon: Bool
        switch settings.preferences.appPresenceMode {
        case .menuBarOnly:
            shouldShowDockIcon = false
        case .dockWhilePreferencesOpen:
            shouldShowDockIcon = preferencesWindowOpenCount > 0
        case .alwaysShowDockIcon:
            shouldShowDockIcon = true
        }

        guard lastAppliedDockIconVisibility != shouldShowDockIcon else { return }
        lastAppliedDockIconVisibility = shouldShowDockIcon

        Task { @MainActor in
            _ = NSApp.setActivationPolicy(shouldShowDockIcon ? .regular : .accessory)
            if shouldShowDockIcon && activateIfShowing {
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    private func observePreferences() {
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
            keepMounted: false,
            mountAtLaunch: false,
            autoConnectWhenReachable: true
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
                vpnRuleEnabled: true
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
            state.status = .waitingForAllowedNetwork("the registered network or VPN")
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
            event(.blockedByRule, timeMachineID, minutesAgo: 11 * 60, detail: "the registered network or VPN"),
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
