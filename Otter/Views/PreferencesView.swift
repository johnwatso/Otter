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
                    Label("Settings…", systemImage: "gearshape")
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
        if settings.shares.isEmpty {
            ContentUnavailableView {
                Label("No Network Shares", systemImage: "externaldrive.badge.plus")
            } description: {
                Text("Add a network share to keep it automatically mounted.")
            } actions: {
                Button("Add Share...") {
                    appModel.requestNewShare()
                }
                .buttonStyle(.borderedProminent)
            }
        } else if let selectedShare {
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
        ContentUnavailableView {
            Label("No Share Selected", systemImage: "externaldrive")
        } description: {
            Text("Select a network share from the sidebar or add a new one.")
        } actions: {
            Button("Add Share...") {
                appModel.requestNewShare()
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

private struct ShareListRow: View {
    @EnvironmentObject private var monitor: ShareMonitor
    let share: NetworkShare
    let isSelected: Bool

    var body: some View {
        let status = monitor.status(for: share)

        HStack(spacing: 8) {
            Image(systemName: isSelected ? "externaldrive.fill" : "externaldrive")
                .font(.title3)
                .foregroundStyle(isSelected ? .primary : .secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 1) {
                Text(share.displayName)
                    .font(.body)
                    .fontWeight(.medium)
                    .lineLimit(1)
                
                HStack(spacing: 4) {
                    Image(systemName: statusSymbol(for: status))
                        .font(.caption2)
                        .foregroundStyle(isSelected ? .primary : statusColor(for: status))
                    Text(status.label)
                        .font(.caption)
                        .foregroundStyle(isSelected ? .primary : .secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func statusColor(for status: ShareStatus) -> Color {
        switch status {
        case .connected:
            return .green
        case .reconnecting:
            return .blue
        case .failed:
            return .red
        case .waitingForNetwork, .waitingForAllowedNetwork:
            return .orange
        default:
            return .secondary
        }
    }

    private func statusSymbol(for status: ShareStatus) -> String {
        switch status {
        case .connected:
            return "circle.fill"
        case .reconnecting, .wakePacketSent:
            return "circle.fill"
        default:
            return "circle"
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

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                
                // Status Section
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(statusColor(for: status))
                        
                        Text(status.label)
                            .font(.headline)
                            .foregroundStyle(.primary)
                    }
                    
                    VStack(alignment: .leading, spacing: 1) {
                        if case .connected = status {
                            if let mountedAt = runtimeState.mountedAt {
                                Text("Mounted since \(mountedAt, format: .dateTime.hour().minute())")
                            }
                        } else {
                            if let detail = status.detail {
                                Text(detail)
                            } else {
                                Text("Retrying automatically")
                            }
                        }
                        
                        if let lastConnected = runtimeState.lastConnectedAt {
                            Text(formatLastConnected(lastConnected))
                        }
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 14)
                }
                
                Divider()
                
                // Server / Connection Details Section
                VStack(alignment: .leading, spacing: 10) {
                    Text("Details")
                        .font(.subheadline)
                        .fontWeight(.bold)
                        .foregroundStyle(.secondary)

                    VStack(spacing: 6) {
                        DetailRow(label: "Server", value: currentShare.host ?? "Unknown")
                        DetailRow(label: "Share", value: NetworkShare.inferredShareName(from: currentShare.urlString) ?? currentShare.displayName)
                        DetailRow(label: "Mount location", value: currentShare.mountPath)
                        DetailRow(label: "Protocol", value: "SMB")
                        DetailRow(label: "Keychain credentials", value: hasKeychainCredentials ? "✓ Saved" : "✕ Not found")
                    }
                }
                
                Divider()
                
                // Configuration Section (Read-Only)
                VStack(alignment: .leading, spacing: 10) {
                    Text("Configuration")
                        .font(.subheadline)
                        .fontWeight(.bold)
                        .foregroundStyle(.secondary)
                    
                    VStack(spacing: 6) {
                        ConfigStatusRow(label: "Reconnect automatically", isEnabled: currentShare.keepMounted)
                        ConfigStatusRow(label: "Connect when server becomes available", isEnabled: currentShare.autoConnectWhenReachable)
                        ConfigStatusRow(label: "Mount at login", isEnabled: currentShare.mountAtLaunch)
                        ConfigStatusRow(label: "Wake sleeping server", isEnabled: currentShare.wakeOnLAN.isEnabled)
                    }
                }
                
                Divider()
                
                // Conditions Section (Read-Only)
                VStack(alignment: .leading, spacing: 10) {
                    Text("Conditions")
                        .font(.subheadline)
                        .fontWeight(.bold)
                        .foregroundStyle(.secondary)
                    
                    VStack(spacing: 6) {
                        if currentShare.rules.hasWiFiNetworkRule {
                            if currentShare.rules.hasVPNRule && !currentShare.rules.vpnName.isEmpty {
                                DetailRow(label: "Limit connections", value: "Home network or VPN \(currentShare.rules.vpnName) only")
                            } else {
                                DetailRow(label: "Limit connections", value: "Home network or VPN only")
                            }
                            if let ssid = currentShare.rules.requiredWiFiNetworkName {
                                DetailRow(label: "Home Wi-Fi", value: ssid)
                            }
                        } else {
                            DetailRow(label: "Limit connections", value: "None (any network)")
                        }
                    }
                }
                
                Divider()
                
                // Actions Block
                HStack(spacing: 8) {
                    if case .connected = status {
                        Button(action: {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: currentShare.mountPath)])
                        }) {
                            Label("Show in Finder", systemImage: "finder")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        
                        if !currentShare.autoConnectWhenReachable {
                            Button(action: {
                                Task { await monitor.disconnect(currentShare) }
                            }) {
                                Label("Disconnect", systemImage: "eject")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    } else {
                        Button(action: {
                            Task { await monitor.mount(currentShare) }
                        }) {
                            Label("Mount Now", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                    
                    Button(action: {
                        appModel.requestEditShare(currentShare)
                    }) {
                        Label("Settings…", systemImage: "gearshape")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    
                    Spacer()
                }
                .padding(.top, 2)
            }
            .padding(20)
        }
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear {
            networkService.refreshNetworkDetails()
        }
    }

    private func formatLastConnected(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "Last connected Today at \(date.formatted(.dateTime.hour().minute()))"
        } else if calendar.isDateInYesterday(date) {
            return "Last connected Yesterday at \(date.formatted(.dateTime.hour().minute()))"
        } else {
            return "Last connected on \(date.formatted(.dateTime.month().day().hour().minute()))"
        }
    }

    private var hasKeychainCredentials: Bool {
        guard let url = currentShare.url,
              let host = url.host(percentEncoded: false)
        else { return false }
        
        if NetworkShare.checkKeychainHasCredentials(for: host) {
            return true
        }
        if let cachedIP = currentShare.cachedIPAddress, NetworkShare.checkKeychainHasCredentials(for: cachedIP) {
            return true
        }
        return false
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

    private func statusColor(for status: ShareStatus) -> Color {
        switch status {
        case .connected:
            return .green
        case .reconnecting:
            return .blue
        case .failed:
            return .red
        case .waitingForNetwork, .waitingForAllowedNetwork:
            return .orange
        default:
            return .secondary
        }
    }

    private func statusIcon(for status: ShareStatus) -> String {
        switch status {
        case .connected:
            return "checkmark.circle.fill"
        case .reconnecting:
            return "arrow.triangle.2.circlepath.circle.fill"
        case .failed:
            return "exclamationmark.circle.fill"
        case .waitingForNetwork, .waitingForAllowedNetwork:
            return "wifi.circle.fill"
        default:
            return "circle.fill"
        }
    }
}

private struct DetailRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        }
        .padding(.vertical, 1)
    }
}

private struct ConfigStatusRow: View {
    let label: String
    let isEnabled: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isEnabled ? "checkmark.circle.fill" : "minus.circle")
                .foregroundStyle(isEnabled ? .green : .secondary)
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.primary)
            Spacer()
        }
        .padding(.vertical, 1)
    }
}

private struct ToggleRow: View {
    let label: String
    let description: String
    let isOn: Binding<Bool>

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                Text(description)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .padding(.vertical, 1)
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
