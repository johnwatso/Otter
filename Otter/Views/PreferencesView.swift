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
                    Label(PreferencesTab.general.title, systemImage: PreferencesTab.general.systemImage)
                }
                .tag(PreferencesTab.general)

            UpdatesPreferencesView()
                .tabItem {
                    Label(PreferencesTab.updates.title, systemImage: PreferencesTab.updates.systemImage)
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
                    ShareListRow(share: share)
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
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }

                if let error = loginItemService.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
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
                        .font(.caption2)
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
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if networkService.knownVPNNames.isEmpty {
                    Label("No VPNs found", systemImage: "lock.slash")
                        .font(.caption2)
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
    @EnvironmentObject private var updateService: UpdateService

    var body: some View {
        Form {
            Section {
                LabeledContent("Version", value: versionText)
                LabeledContent("Build", value: buildText)
            } header: {
                Text("Installed Version")
            }

            Section {
                LabeledContent("Status", value: updateStatusText)

                if let lastCheckedAt = updateService.lastCheckedAt {
                    LabeledContent("Last checked", value: lastCheckedAt, format: .dateTime.hour().minute())
                }

                HStack {
                    Button {
                        Task { await updateService.checkForUpdates() }
                    } label: {
                        Label("Check for Updates", systemImage: "arrow.clockwise")
                    }
                    .disabled(updateService.isChecking)

                    if updateService.updateAvailable {
                        Button {
                            NSWorkspace.shared.open(updateService.releaseURL)
                        } label: {
                            Label("Download", systemImage: "arrow.down.circle")
                        }
                    }
                }

                SettingsSecondaryText("Otter checks GitHub Releases and opens the download page in your browser.")
            } header: {
                Text("Updates")
            }
        }
        .compactPreferencesForm()
    }

    private var updateStatusText: String {
        if updateService.isChecking {
            return "Checking..."
        }

        if updateService.updateAvailable, let latestVersion = updateService.latestVersion {
            return "\(latestVersion) available"
        }

        if let error = updateService.lastCheckError {
            return error
        }

        if updateService.lastCheckedAt != nil {
            return "Up to date"
        }

        return "Not checked yet"
    }

    private var versionText: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
    }

    private var buildText: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
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

    var body: some View {
        let status = monitor.status(for: share)

        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(share.displayName)
                    .lineLimit(1)
                Text(status.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: status.systemImage)
                .foregroundStyle(status.color)
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

            if currentShare.rules.hasWiFiNetworkRule || currentShare.rules.hasVPNRule {
                Section("Rules") {
                    if let requiredWiFiNetworkName = currentShare.rules.requiredWiFiNetworkName {
                        LabeledContent("Wi-Fi network", value: requiredWiFiNetworkName)
                        LabeledContent("Wi-Fi action", value: currentShare.rules.wifiNetworkAction.title)
                    }

                    if currentShare.rules.hasVPNRule {
                        LabeledContent("VPN", value: currentShare.rules.vpnRuleTitle)
                        LabeledContent("VPN action", value: currentShare.rules.vpnAction.title)
                    }

                    LabeledContent("Current Wi-Fi", value: networkService.currentWiFiNetworkName ?? "Unavailable")
                    LabeledContent("Current VPN", value: currentVPNLabel)
                }
            }

            Section {
                HStack {
                    Button {
                        Task { await monitor.mount(currentShare) }
                    } label: {
                        Label("Mount Now", systemImage: "arrow.triangle.2.circlepath")
                    }

                    Button {
                        Task { await monitor.disconnect(currentShare) }
                    } label: {
                        Label("Disconnect", systemImage: "eject")
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
            .font(.caption2)
            .foregroundStyle(tint)
            .padding(.vertical, 0)
    }
}

private extension View {
    func compactPreferencesForm() -> some View {
        self
            .formStyle(.grouped)
            .controlSize(.small)
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
            .padding(.top, 6)
    }
}
