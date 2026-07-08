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
    let notificationService: NotificationService
    let loginItemService: LoginItemService
    let updateService = UpdateService()
    let monitor: ShareMonitor

    @Published var editorRequest: ShareEditorRequest?

    private var hasStarted = false
    private var preferencesWindowOpenCount = 0
    private var lastAppliedDockIconVisibility: Bool?
    private var cancellables = Set<AnyCancellable>()

    init() {
        let settings = SettingsStore()
        let networkService = NetworkReachabilityService()
        let mountService = MountService()
        let notificationService = NotificationService(settings: settings)

        self.settings = settings
        self.networkService = networkService
        self.mountService = mountService
        self.notificationService = notificationService
        self.loginItemService = LoginItemService()
        self.monitor = ShareMonitor(
            settings: settings,
            mountService: mountService,
            networkService: networkService,
            notificationService: notificationService
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

        Task {
            await updateService.checkForUpdates()
        }
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
