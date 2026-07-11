import AppKit
import SwiftUI

struct PreferencesView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var selectedTab: PreferencesTab = .general
    @State private var didRegisterWindowAppearance = false

    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralPreferencesView()
                .tabItem {
                    PreferencesTabItem(tab: .general)
                }
                .tag(PreferencesTab.general)

            UpdatesPreferencesView()
                .tabItem {
                    PreferencesTabItem(tab: .updates)
                }
                .tag(PreferencesTab.updates)
        }
        .padding(.top, -2)
        .frame(width: 520)
        .onAppear {
            if !didRegisterWindowAppearance {
                didRegisterWindowAppearance = true
                appModel.preferencesWindowDidAppear()
            }
        }
        .onDisappear {
            if didRegisterWindowAppearance {
                didRegisterWindowAppearance = false
                appModel.preferencesWindowDidDisappear()
            }
        }
    }
}

struct ShareManagementView: View {
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var loginItemService: LoginItemService
    @State private var selection: NetworkShare.ID?
    @State private var didRegisterWindowAppearance = false

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 250)
        } detail: {
            detail
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    appModel.requestNewShare()
                } label: {
                    Label("Add Share", systemImage: "plus")
                }

                Button {
                    if let selectedShare {
                        appModel.requestEditShare(selectedShare)
                    }
                } label: {
                    Label("Edit Share", systemImage: "pencil")
                }
                .disabled(selectedShare == nil)

                Button {
                    if let selectedShare {
                        settings.removeShare(id: selectedShare.id)
                        selection = settings.shares.first?.id
                    }
                } label: {
                    Label("Remove Share", systemImage: "trash")
                }
                .disabled(selectedShare == nil)
            }
        }
        .sheet(item: $appModel.editorRequest) { request in
            let editingShare = share(for: request)

            ShareEditorView(share: editingShare) { savedShare in
                if settings.share(id: savedShare.id) == nil {
                    settings.addShare(savedShare)
                } else {
                    settings.updateShare(savedShare)
                }

                selection = savedShare.id
                appModel.editorRequest = nil
            } onCancel: {
                appModel.editorRequest = nil
            }
            .id(request.id)
            .onAppear {
                selectShare(for: request)
            }
        }
        .onAppear {
            if !didRegisterWindowAppearance {
                didRegisterWindowAppearance = true
                appModel.preferencesWindowDidAppear()
            }

            if selection == nil {
                selection = settings.shares.first?.id
            }

            loginItemService.refresh()
        }
        .onDisappear {
            if didRegisterWindowAppearance {
                didRegisterWindowAppearance = false
                appModel.preferencesWindowDidDisappear()
            }
        }
    }

    private var sidebar: some View {
        List(selection: $selection) {
            Section("Shares") {
                ForEach(settings.shares) { share in
                    ShareListRow(share: share, isSelected: selection == share.id)
                        .tag(share.id)
                }
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let selectedShare {
            ShareDetailView(share: selectedShare)
        } else {
            EmptyShareDetailView()
        }
    }

    private var selectedShare: NetworkShare? {
        guard let selection else { return nil }
        return settings.share(id: selection)
    }

    private func share(for request: ShareEditorRequest) -> NetworkShare? {
        if case let .edit(id) = request.mode {
            return settings.share(id: id)
        }

        return nil
    }

    private func selectShare(for request: ShareEditorRequest) {
        if case let .edit(id) = request.mode {
            selection = id
        }
    }
}

private enum PreferencesTab: String, CaseIterable, Hashable, Identifiable {
    case general
    case updates

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general:
            "General"
        case .updates:
            "Updates"
        }
    }

    var systemImage: String {
        switch self {
        case .general:
            "gearshape"
        case .updates:
            "arrow.clockwise.circle"
        }
    }
}

// Custom tab-item label with precise optical centering and tight spacing,
// matching the SwiftMiner settings style. On macOS the system extracts the
// Image and Text from .tabItem to build the segmented control; explicit
// sizing here ensures every icon sits consistently.
private struct PreferencesTabItem: View {
    let tab: PreferencesTab

    var body: some View {
        VStack(spacing: 1) {
            Image(systemName: tab.systemImage)
                .font(.system(size: 12, weight: .medium))
                .imageScale(.small)
                .symbolRenderingMode(.hierarchical)
                .frame(height: 14, alignment: .center)
            Text(tab.title)
                .font(.system(size: 10, weight: .medium))
        }
    }
}

private struct GeneralPreferencesView: View {
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var networkService: NetworkReachabilityService
    @EnvironmentObject private var notificationService: NotificationService
    @EnvironmentObject private var loginItemService: LoginItemService

    var body: some View {
        Form {
            Section {
                Picker("App Presence", selection: appPresenceBinding) {
                    ForEach(AppPresenceMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                SettingsSecondaryText(settings.preferences.appPresenceMode.detail)

                Toggle("Start at login", isOn: Binding(
                    get: { loginItemService.isEnabled },
                    set: { loginItemService.setEnabled($0) }
                ))
                .onAppear {
                    loginItemService.refresh()
                }

                if loginItemService.requiresApproval {
                    Label("Approve Otter in System Settings to finish enabling login launch.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                if let error = loginItemService.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Application")
            }

            Section {
                Toggle("Notifications", isOn: notificationsEnabledBinding)
                SettingsSecondaryText("Uses temporary banners by default.")

                if settings.preferences.notificationsEnabled {
                    Toggle("Connection changes", isOn: notificationPreferenceBinding(\.notifyConnectionChanges))
                    Toggle("Problems", isOn: notificationPreferenceBinding(\.notifyProblems))
                    Toggle("Play sound", isOn: notificationPreferenceBinding(\.notificationSoundsEnabled))

                    LabeledContent("Permission", value: notificationService.authorizationStatusTitle)

                    if notificationService.canAskForAuthorization {
                        Button {
                            Task { await notificationService.requestAuthorization() }
                        } label: {
                            Label("Allow Notifications", systemImage: "bell.badge")
                        }
                    }
                }
            } header: {
                Text("Notifications")
            }

            Section {
                Stepper(value: fallbackIntervalBinding, in: 15...3600, step: 15) {
                    Text("Fallback check: \(fallbackIntervalLabel(settings.preferences.fallbackCheckInterval))")
                }
                SettingsSecondaryText("Also checks after wake, network, and volume changes.")
            } header: {
                Text("Monitoring")
            }

            Section {
                LabeledContent("Current Wi-Fi", value: networkService.currentWiFiNetworkName ?? "Unavailable")

                if networkService.wifiNameRequiresLocationPermission {
                    Label("macOS requires Location Services access to show the Wi-Fi network name.", systemImage: "location.slash")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button {
                        if networkService.canRequestLocationAuthorization {
                            networkService.requestLocationAuthorization()
                        } else {
                            openLocationPrivacySettings()
                        }
                    } label: {
                        Label(
                            networkService.canRequestLocationAuthorization ? "Allow Location Access" : "Open Location Settings",
                            systemImage: "location"
                        )
                    }
                }

                LabeledContent("Active VPN", value: activeVPNLabel)

                if networkService.isVPNNameUnavailable {
                    Label("VPN profile name is unavailable to Otter.", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if networkService.knownVPNNames.isEmpty {
                    Label("No VPNs found", systemImage: "lock.slash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    LabeledContent("Known VPNs") {
                        VStack(alignment: .trailing, spacing: 4) {
                            ForEach(networkService.knownVPNNames, id: \.self) { vpnName in
                                Text(vpnName)
                            }
                        }
                    }
                }

                Button {
                    networkService.refreshNetworkDetails()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            } header: {
                Text("Network")
            }
        }
        .compactPreferencesForm()
        .onAppear {
            networkService.refreshNetworkDetails()
            Task { await notificationService.refreshAuthorizationStatus() }
        }
    }

    private var appPresenceBinding: Binding<AppPresenceMode> {
        Binding {
            settings.preferences.appPresenceMode
        } set: { mode in
            settings.updatePreferences { preferences in
                preferences.appPresenceMode = mode
            }
            appModel.refreshDockIconVisibility(activateIfShowing: true)
        }
    }

    private var fallbackIntervalBinding: Binding<Double> {
        Binding {
            settings.preferences.fallbackCheckInterval
        } set: { newValue in
            settings.updatePreferences { preferences in
                preferences.fallbackCheckInterval = newValue
            }
        }
    }

    private var notificationsEnabledBinding: Binding<Bool> {
        Binding {
            settings.preferences.notificationsEnabled
        } set: { enabled in
            settings.updatePreferences { preferences in
                preferences.notificationsEnabled = enabled
            }

            if enabled {
                Task { await notificationService.requestAuthorization() }
            }
        }
    }

    private func notificationPreferenceBinding(_ keyPath: WritableKeyPath<AppPreferences, Bool>) -> Binding<Bool> {
        Binding {
            settings.preferences[keyPath: keyPath]
        } set: { newValue in
            settings.updatePreferences { preferences in
                preferences[keyPath: keyPath] = newValue
            }
        }
    }

    private func fallbackIntervalLabel(_ value: TimeInterval) -> String {
        let seconds = Int(value)
        if seconds % 60 == 0 {
            let minutes = seconds / 60
            return "\(minutes) minute\(minutes == 1 ? "" : "s")"
        }

        return "\(seconds) seconds"
    }

    private var activeVPNLabel: String {
        networkService.currentVPNDisplayName
    }

    private func openLocationPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") else { return }
        NSWorkspace.shared.open(url)
    }
}

private struct UpdatesPreferencesView: View {
    @EnvironmentObject private var updaterViewModel: UpdaterViewModel

    var body: some View {
        Form {
            Section {
                LabeledContent("Version", value: updaterViewModel.currentVersion)
                LabeledContent("Build", value: updaterViewModel.currentBuild)
            } header: {
                Text("Installed Version")
            }

            Section {
                Toggle("Check for updates automatically", isOn: automaticChecksBinding)

                if let lastUpdateCheckDate = updaterViewModel.lastUpdateCheckDate {
                    LabeledContent("Last checked", value: lastUpdateCheckDate, format: .dateTime.day().month().hour().minute())
                }

                Button {
                    updaterViewModel.checkForUpdates()
                } label: {
                    Label("Check for Updates...", systemImage: "arrow.clockwise")
                }
                .disabled(!updaterViewModel.canCheckForUpdates)

                SettingsSecondaryText("Updates are delivered by Sparkle and installed in place.")
            } header: {
                Text("Updates")
            }
        }
        .compactPreferencesForm()
    }

    private var automaticChecksBinding: Binding<Bool> {
        Binding {
            updaterViewModel.automaticallyChecksForUpdates
        } set: { enabled in
            updaterViewModel.automaticallyChecksForUpdates = enabled
        }
    }
}

private struct EmptyShareDetailView: View {
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        Form {
            Section {
                VStack(spacing: 14) {
                    Image(systemName: "externaldrive")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("No share selected")
                        .font(.title3)
                        .fontWeight(.medium)
                    Button {
                        appModel.requestNewShare()
                    } label: {
                        Label("Add Share", systemImage: "plus")
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
            }
        }
        .formStyle(.grouped)
        .padding(24)
    }
}

private struct ShareListRow: View {
    @EnvironmentObject private var monitor: ShareMonitor
    let share: NetworkShare
    let isSelected: Bool

    var body: some View {
        let status = monitor.status(for: share)

        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(share.displayName)
                    .lineLimit(1)
                Text(status.label)
                    .font(.caption)
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
        } icon: {
            Image(systemName: status.systemImage)
                .foregroundStyle(isSelected ? .primary : status.color)
        }
    }
}

private struct ShareDetailView: View {
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var monitor: ShareMonitor
    @EnvironmentObject private var networkService: NetworkReachabilityService
    let share: NetworkShare

    var body: some View {
        let status = monitor.status(for: currentShare)
        let runtimeState = monitor.runtimeState(for: currentShare)

        Form {
            Section {
                LabeledContent("Status") {
                    Label(status.label, systemImage: status.systemImage)
                        .foregroundStyle(status.color)
                }

                if let detail = status.detail {
                    LabeledContent(status.detailTitle, value: detail)
                }

                if runtimeState.needsCredentials, let url = currentShare.url {
                    LabeledContent("Credentials") {
                        Button {
                            NSWorkspace.shared.open(url)
                        } label: {
                            Label("Connect Once in Finder...", systemImage: "person.badge.key")
                        }
                    }
                }

                if let nextRetryDate = runtimeState.nextRetryDate {
                    LabeledContent("Next retry", value: nextRetryDate, format: .dateTime.hour().minute().second())
                }

                LabeledContent("Address", value: currentShare.urlString)
                LabeledContent("Location", value: currentShare.mountPath)
            }

            Section {
                Toggle("Keep mounted", isOn: binding(\.keepMounted))
                Toggle("Mount at launch", isOn: binding(\.mountAtLaunch))
                Toggle("Connect when server is reachable", isOn: binding(\.autoConnectWhenReachable))
            }

            if currentShare.wakeOnLAN.isEnabled {
                Section("Wake on LAN") {
                    LabeledContent("MAC address", value: currentShare.wakeOnLAN.macAddress)
                    LabeledContent("Broadcast", value: "\(currentShare.wakeOnLAN.broadcastAddress):\(currentShare.wakeOnLAN.port)")
                }
            }

            if currentShare.rules.hasWiFiNetworkRule || currentShare.rules.hasVPNRule {
                Section("Rules") {
                    if let requiredWiFiNetworkName = currentShare.rules.requiredWiFiNetworkName {
                        LabeledContent("Wi-Fi network", value: requiredWiFiNetworkName)
                    }

                    if currentShare.rules.hasVPNRule {
                        LabeledContent("VPN", value: currentShare.rules.vpnRuleTitle)
                    }

                    LabeledContent("Current Wi-Fi", value: networkService.currentWiFiNetworkName ?? "Unavailable")
                    LabeledContent("Current VPN", value: currentVPNLabel)

                    if currentShare.rules.hasVPNRule || (currentShare.host?.hasSuffix(".local") ?? false) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 4) {
                                Image(systemName: "info.circle")
                                Text("Static IP Warning")
                            }
                            .font(.caption)
                            .fontWeight(.medium)
                            Text("Ensure this server has a static IP address, or VPN IP fallback might fail if the IP changes.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            if let fallbackURL = fallbackURLString {
                Section("Advanced") {
                    LabeledContent("Fallback IP", value: fallbackURL)
                }
            }

            Section {
                HStack {
                    if currentShare.wakeOnLAN.isEnabled {
                        Button {
                            Task { await monitor.wake(currentShare) }
                        } label: {
                            Label("Wake Server", systemImage: "power")
                        }
                    }

                    Button {
                        Task { await monitor.mount(currentShare) }
                    } label: {
                        Label("Mount Now", systemImage: "arrow.triangle.2.circlepath")
                    }

                    if !currentShare.autoConnectWhenReachable {
                        Button {
                            Task { await monitor.disconnect(currentShare) }
                        } label: {
                            Label("Disconnect", systemImage: "eject")
                        }
                    }

                    Button {
                        appModel.requestEditShare(currentShare)
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }

                    Spacer()

                    if case .connected = status {
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: currentShare.mountPath)])
                        } label: {
                            Label("Show in Finder", systemImage: "finder")
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding(24)
        .onAppear {
            networkService.refreshNetworkDetails()
        }
    }

    private var currentShare: NetworkShare {
        settings.share(id: share.id) ?? share
    }

    private var currentVPNLabel: String {
        networkService.currentVPNDisplayName
    }

    private var fallbackURLString: String? {
        guard let cachedIP = currentShare.cachedIPAddress,
              let url = currentShare.url,
              let host = url.host(percentEncoded: false),
              !NetworkShare.isIPAddress(host)
        else { return nil }

        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.host = cachedIP
        return components?.string
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<NetworkShare, Value>) -> Binding<Value> {
        Binding {
            currentShare[keyPath: keyPath]
        } set: { value in
            settings.updateShare(id: currentShare.id) { share in
                share[keyPath: keyPath] = value
            }
        }
    }
}

private struct SettingsSecondaryText: View {
    let text: String
    var tint: Color = .secondary

    init(_ text: String, tint: Color = .secondary) {
        self.text = text
        self.tint = tint
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(tint)
            .padding(.vertical, 0)
    }
}

// Form styling shared with the SwiftMiner settings window.
private extension View {
    func compactPreferencesForm() -> some View {
        self
            .formStyle(.grouped)
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
            .padding(.top, 10)
    }
}
