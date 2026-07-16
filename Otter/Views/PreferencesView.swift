import AppKit
import SwiftUI
import UniformTypeIdentifiers

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

private enum ShareManagementSelection: Hashable {
    case share(NetworkShare.ID)
    case server(NetworkShareServerGroup.ID)
}

struct ShareManagementView: View {
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var monitor: ShareMonitor
    @EnvironmentObject private var loginItemService: LoginItemService
    @State private var selection: ShareManagementSelection?
    @State private var didRegisterWindowAppearance = false
    @State private var isShowingActivityLog = false
    @State private var isShowingConnectionDoctor = false
    @State private var isShowingOnboarding = false
    @Namespace private var selectionHighlightNamespace
    @State private var rowFrames: [NetworkShare.ID: CGRect] = [:]

    fileprivate static let dragCoordinateSpace = "shareSelectorDrag"

    private var shares: [NetworkShare] {
        appModel.screenshotDemoShares ?? settings.shares
    }

    private var shareGroups: [NetworkShareServerGroup] {
        NetworkShareServerGroup.make(from: shares)
    }

    private var selectionValidationSignature: [String] {
        shareGroups.map { group in
            "\(group.id)|\(group.shares.map { $0.id.uuidString }.joined(separator: ","))"
        }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 250)
        } detail: {
            detail
        }
        .toolbar {
            ToolbarItemGroup {
                if !selectedShares.isEmpty {
                    if areAllSelectedSharesConnected {
                        Button(action: showSelectedSharesInFinder) {
                            Label(
                                selectedServerGroup == nil ? "Show in Finder" : "Show All in Finder",
                                systemImage: "finder"
                            )
                        }
                        .help(selectedServerGroup == nil ? "Show in Finder" : "Show all shares in Finder")
                    } else {
                        Button {
                            Task { await mountSelectedShares() }
                        } label: {
                            Label(
                                selectedServerGroup == nil ? "Mount Now" : "Mount All",
                                systemImage: "arrow.triangle.2.circlepath"
                            )
                        }
                        .help(selectedServerGroup == nil ? "Mount Now" : "Mount all shares on this server")
                    }
                }

                Button {
                    Task { await disconnectSelectedShares() }
                } label: {
                    Label(
                        selectedServerGroup == nil ? "Disconnect & Pause" : "Disconnect & Pause All",
                        systemImage: "eject"
                    )
                }
                .disabled(!canDisconnectSelectedShares)
                .help(selectedServerGroup == nil
                    ? "Disconnect and pause automatic mounting"
                    : "Disconnect and pause every share on this server")

                if let selectedShare {
                    SharePauseMenu(share: selectedShare)
                } else if let selectedServerGroup {
                    ShareGroupPauseMenu(shares: selectedServerGroup.shares)
                }

                if let selectedShare {
                    Button {
                        appModel.requestEditShare(selectedShare)
                    } label: {
                        Label("Settings…", systemImage: "gearshape")
                    }
                    .disabled(settings.isManagedShare(id: selectedShare.id))
                    .help("Share Settings")
                }

                Button {
                    isShowingActivityLog = true
                } label: {
                    Label("Activity Log", systemImage: "clock.arrow.circlepath")
                }
                .help("Activity Log")

                Button {
                    isShowingConnectionDoctor = true
                } label: {
                    Label("Connection Doctor", systemImage: "stethoscope")
                }
                .disabled(selectedShare == nil)
                .help("Run Connection Doctor")
            }
        }
        .sheet(isPresented: $isShowingActivityLog) {
            ActivityLogView(
                initialShareFilter: selectedShare?.id,
                includedShareIDs: selectedServerGroup.map { Set($0.shares.map(\.id)) },
                includedSharesLabel: selectedServerGroup?.serverName
            )
        }
        .sheet(isPresented: $isShowingConnectionDoctor) {
            if let selectedShare {
                ConnectionDoctorView(share: selectedShare)
            }
        }
        .sheet(isPresented: $isShowingOnboarding) {
            OnboardingView {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    appModel.requestNewShare()
                }
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

                selection = .share(savedShare.id)
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
                selection = defaultSelection
            }

            loginItemService.refresh()

            if !settings.preferences.hasCompletedOnboarding {
                Task { @MainActor in
                    await Task.yield()
                    isShowingOnboarding = true
                }
            }
        }
        .onChange(of: appModel.screenshotDemoShares != nil) {
            selection = defaultSelection
        }
        .onChange(of: selectionValidationSignature) {
            validateSelection()
        }
        .onDisappear {
            if didRegisterWindowAppearance {
                didRegisterWindowAppearance = false
                appModel.preferencesWindowDidDisappear()
            }
        }
    }

    // Custom rows instead of List(selection:) so the selection is a sliding
    // material pill (ported from SwiftMiner) rather than the accent-color bar.
    private var sidebar: some View {
        ZStack {
            SidebarMaterialBackground()

            VStack(spacing: 0) {
                sidebarRows

                Divider()

                HStack(spacing: 2) {
                    Button {
                        appModel.requestNewShare()
                    } label: {
                        Image(systemName: "plus")
                            .frame(width: 24, height: 22)
                    }
                    .buttonStyle(.borderless)
                    .help("Add Share")
                    .accessibilityLabel("Add Share")

                    Button {
                        removeSelectedShare()
                    } label: {
                        Image(systemName: "minus")
                            .frame(width: 24, height: 22)
                    }
                    .buttonStyle(.borderless)
                    .disabled(!canRemoveSelectedShare)
                    .help("Remove Share")
                    .accessibilityLabel("Remove Share")

                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
        }
    }

    private var sidebarRows: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                Text("Shares")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 2)

                ForEach(shareGroups) { group in
                    if group.isGrouped {
                        ServerListHeader(
                            group: group,
                            isSelected: selection == .server(group.id),
                            selectionHighlightNamespace: selectionHighlightNamespace
                        ) {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                selection = .server(group.id)
                            }
                        }

                        ForEach(group.shares) { share in
                            ShareListRow(
                                share: share,
                                isSelected: selection == .share(share.id),
                                selectionHighlightNamespace: selectionHighlightNamespace
                            ) {
                                withAnimation(.easeInOut(duration: 0.18)) {
                                    selection = .share(share.id)
                                }
                            }
                            .padding(.leading, 14)
                        }
                    } else if let share = group.shares.first {
                        ShareListRow(
                            share: share,
                            isSelected: selection == .share(share.id),
                            selectionHighlightNamespace: selectionHighlightNamespace
                        ) {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                selection = .share(share.id)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 10)
            .coordinateSpace(name: Self.dragCoordinateSpace)
            .onPreferenceChange(ShareRowFramesKey.self) { rowFrames = $0 }
            .gesture(selectionDragGesture)
        }
    }

    private var selectionDragGesture: some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named(Self.dragCoordinateSpace))
            .onChanged { value in
                updateSelection(forDragLocation: value.location)
            }
    }

    private func updateSelection(forDragLocation point: CGPoint) {
        guard let target = shares.first(where: { rowFrames[$0.id]?.contains(point) ?? false }),
              selection != .share(target.id)
        else { return }

        withAnimation(.easeInOut(duration: 0.18)) {
            selection = .share(target.id)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if shares.isEmpty {
            ContentUnavailableView {
                Label("No Network Shares", systemImage: "externaldrive.badge.plus")
            } description: {
                Text("Add a network share to keep it automatically mounted.")
            } actions: {
                Button {
                    appModel.requestNewShare()
                } label: {
                    Label("Add Share...", systemImage: "plus")
                }
                .tahoePrimaryActionButton()
            }
        } else if let selectedServerGroup {
            ServerDetailView(group: selectedServerGroup)
        } else if let selectedShare {
            ShareDetailView(share: selectedShare)
        } else {
            EmptyShareDetailView()
        }
    }

    private var selectedShare: NetworkShare? {
        guard case let .share(id) = selection else { return nil }
        return shares.first { $0.id == id }
    }

    private var selectedServerGroup: NetworkShareServerGroup? {
        guard case let .server(id) = selection else { return nil }
        return shareGroups.first { $0.id == id && $0.isGrouped }
    }

    private var selectedShares: [NetworkShare] {
        if let selectedShare {
            return [selectedShare]
        }
        return selectedServerGroup?.shares ?? []
    }

    private var areAllSelectedSharesConnected: Bool {
        !selectedShares.isEmpty && selectedShares.allSatisfy { monitor.status(for: $0) == .connected }
    }

    private var canDisconnectSelectedShares: Bool {
        selectedShares.contains { monitor.status(for: $0) == .connected }
    }

    private var canRemoveSelectedShare: Bool {
        guard let selectedShare else { return false }
        return settings.share(id: selectedShare.id) != nil
            && !settings.isManagedShare(id: selectedShare.id)
    }

    private func removeSelectedShare() {
        guard let selectedShare,
              let selectedIndex = settings.shares.firstIndex(where: { $0.id == selectedShare.id })
        else { return }

        settings.removeShare(id: selectedShare.id)
        guard !settings.shares.isEmpty else {
            selection = nil
            return
        }

        selection = .share(settings.shares[min(selectedIndex, settings.shares.count - 1)].id)
    }

    private func share(for request: ShareEditorRequest) -> NetworkShare? {
        if case let .edit(id) = request.mode {
            return settings.share(id: id)
        }

        return nil
    }

    private func selectShare(for request: ShareEditorRequest) {
        if case let .edit(id) = request.mode {
            selection = .share(id)
        }
    }

    private var defaultSelection: ShareManagementSelection? {
        guard let firstGroup = shareGroups.first else { return nil }
        if firstGroup.isGrouped {
            return .server(firstGroup.id)
        }
        return firstGroup.shares.first.map { .share($0.id) }
    }

    private func validateSelection() {
        let isValid: Bool
        switch selection {
        case let .share(id):
            isValid = shares.contains { $0.id == id }
        case let .server(id):
            isValid = shareGroups.contains { $0.id == id && $0.isGrouped }
        case nil:
            isValid = false
        }

        if !isValid {
            selection = defaultSelection
        }
    }

    private func mountSelectedShares() async {
        for share in selectedShares {
            await monitor.mount(share)
        }
    }

    private func disconnectSelectedShares() async {
        for share in selectedShares {
            await monitor.pause(
                share,
                until: nil,
                disconnect: monitor.status(for: share) == .connected
            )
        }
    }

    private func showSelectedSharesInFinder() {
        let mountedURLs = selectedShares
            .filter { monitor.status(for: $0) == .connected }
            .map { URL(fileURLWithPath: $0.mountPath) }
        guard !mountedURLs.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(mountedURLs)
    }
}

private struct ServerListHeader: View {
    let group: NetworkShareServerGroup
    let isSelected: Bool
    let selectionHighlightNamespace: Namespace.ID
    let action: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "server.rack")
                .font(.body)
                .foregroundStyle(isSelected ? .primary : .secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 1) {
                Text(group.serverName)
                    .font(.body)
                    .fontWeight(.semibold)
                    .lineLimit(1)

                Text("\(group.shares.count) shares")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.top, 7)
        .padding(.bottom, 3)
        .background {
            if isSelected {
                SidebarSelectionHighlight()
                    .matchedGeometryEffect(id: "sidebarSelectionHighlight", in: selectionHighlightNamespace)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { action() }
        .accessibilityElement(children: .combine)
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
    @State private var configurationMessage: String?
    @State private var supportPackageMessage: String?

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
                        .tahoeSecondaryActionButton()
                    }
                }
            } header: {
                Text("Notifications")
            }

            Section {
                Stepper(value: fallbackIntervalBinding, in: 15...3600, step: 15) {
                    Text("Fallback check: \(fallbackIntervalLabel(settings.preferences.fallbackCheckInterval))")
                }
                .disabled(settings.hasManagedMonitoringSettings)
                SettingsSecondaryText("Also checks after wake, network, and volume changes.")

                Toggle("Recover unresponsive mounted volumes", isOn: Binding(
                    get: { settings.preferences.recoverUnresponsiveMounts },
                    set: { enabled in
                        settings.updatePreferences { $0.recoverUnresponsiveMounts = enabled }
                    }
                ))
                .disabled(settings.hasManagedMonitoringSettings)
                SettingsSecondaryText("Uses a time-limited helper probe and only attempts a normal unmount. Otter never force-unmounts a busy volume.")

                if settings.hasManagedMonitoringSettings {
                    Label("These monitoring settings are managed by your organization.", systemImage: "checkmark.shield")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Monitoring")
            }

            Section {
                HStack {
                    Button {
                        exportConfiguration()
                    } label: {
                        Label("Export Configuration…", systemImage: "square.and.arrow.up")
                    }
                    .tahoeSecondaryActionButton()

                    Button {
                        importConfiguration()
                    } label: {
                        Label("Import Configuration…", systemImage: "square.and.arrow.down")
                    }
                    .tahoeSecondaryActionButton()
                }

                SettingsSecondaryText("Includes shares, network rules, Wake-on-LAN, and monitoring settings. Keychain credentials are never exported.")

                if let configurationMessage {
                    Text(configurationMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Configuration")
            }

            Section {
                Button {
                    exportSupportPackage()
                } label: {
                    Label("Export Support Package\u{2026}", systemImage: "lifepreserver")
                }
                .tahoeSecondaryActionButton()

                SettingsSecondaryText("Creates a redacted diagnostic file. Server, share, network, VPN, account, and password details are not included.")

                if let supportPackageMessage {
                    Text(supportPackageMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Support")
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
                    .tahoeSecondaryActionButton()
                }

                LabeledContent("Active VPN", value: activeVPNLabel)

                if networkService.isVPNNameUnavailable {
                    Label("An unidentified tunnel is active. It does not satisfy VPN share rules.", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if networkService.knownVPNNames.isEmpty {
                    Label("No VPNs found", systemImage: "lock.slash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    LabeledContent("VPNs in System Settings") {
                        VStack(alignment: .trailing, spacing: 4) {
                            ForEach(networkService.knownVPNNames, id: \.self) { vpnName in
                                HStack(spacing: 5) {
                                    Text(vpnName)
                                    if !networkService.canControlVPN(named: vpnName) {
                                        Text("Manual")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }

                Button {
                    networkService.refreshNetworkDetails()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .tahoeSecondaryActionButton()
            } header: {
                Text("Network")
            }

#if DEBUG
            Section {
                Toggle("Show demo shares", isOn: Binding(
                    get: { appModel.isScreenshotDemoEnabled },
                    set: { appModel.setScreenshotDemo($0) }
                ))
                SettingsSecondaryText("Replaces the share list with five fake shares in assorted states for product screenshots. Real configuration is untouched. Debug builds only.")
            } header: {
                Text("Developer")
            }
#endif
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

    private var configurationFileType: UTType {
        UTType(filenameExtension: "otterconfig", conformingTo: .json) ?? .json
    }

    private var supportPackageFileType: UTType {
        UTType(filenameExtension: "ottersupport", conformingTo: .json) ?? .json
    }

    private func exportSupportPackage() {
        let panel = NSSavePanel()
        panel.title = "Export Otter Support Package"
        panel.nameFieldStringValue = "Otter Support.ottersupport"
        panel.allowedContentTypes = [supportPackageFileType]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let package = SupportPackageService.make(
                settings: settings,
                eventLog: appModel.eventLog,
                monitor: appModel.monitor,
                networkService: networkService,
                notificationService: notificationService,
                loginItemService: loginItemService
            )
            try SupportPackageService.encode(package).write(to: url, options: .atomic)
            supportPackageMessage = "Support package exported with identifying details removed."
        } catch {
            supportPackageMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    private func exportConfiguration() {
        let panel = NSSavePanel()
        panel.title = "Export Otter Configuration"
        panel.nameFieldStringValue = "Otter Configuration.otterconfig"
        panel.allowedContentTypes = [configurationFileType]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let data = try ConfigurationTransferService.encode(settings.configurationArchive())
            try data.write(to: url, options: .atomic)
            configurationMessage = "Configuration exported. Credentials were not included."
        } catch {
            configurationMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    private func importConfiguration() {
        let panel = NSOpenPanel()
        panel.title = "Import Otter Configuration"
        panel.allowedContentTypes = [configurationFileType, .json]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let archive = try ConfigurationTransferService.decode(Data(contentsOf: url))
            let alert = NSAlert()
            alert.messageText = "Import \(archive.shares.count) Share\(archive.shares.count == 1 ? "" : "s")?"
            alert.informativeText = "Merge updates matching SMB addresses and keeps other shares. Replace removes the current share list first. Keychain credentials are not changed."
            alert.addButton(withTitle: "Merge")
            alert.addButton(withTitle: "Replace")
            alert.addButton(withTitle: "Cancel")

            let response = alert.runModal()
            let strategy: ConfigurationImportStrategy
            switch response {
            case .alertFirstButtonReturn:
                strategy = .merge
            case .alertSecondButtonReturn:
                strategy = .replace
            default:
                return
            }

            let result = settings.importConfiguration(archive, strategy: strategy)
            configurationMessage = "Imported: \(result.added) added, \(result.updated) updated, \(result.removed) removed."
        } catch {
            configurationMessage = "Import failed: \(error.localizedDescription)"
        }
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
                .tahoeSecondaryActionButton()
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
            Button {
                appModel.requestNewShare()
            } label: {
                Label("Add Share...", systemImage: "plus")
            }
            .tahoePrimaryActionButton()
        }
    }
}

private struct ShareListRow: View {
    @EnvironmentObject private var monitor: ShareMonitor
    let share: NetworkShare
    let isSelected: Bool
    let selectionHighlightNamespace: Namespace.ID
    let action: () -> Void

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
                    .fontWeight(isSelected ? .semibold : .medium)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Image(systemName: status.circleSymbol)
                        .font(.caption2)
                        .foregroundStyle(status.color)
                    Text(status.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background {
            if isSelected {
                SidebarSelectionHighlight()
                    .matchedGeometryEffect(id: "sidebarSelectionHighlight", in: selectionHighlightNamespace)
            }
        }
        .background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: ShareRowFramesKey.self,
                    value: [share.id: geo.frame(in: .named(ShareManagementView.dragCoordinateSpace))]
                )
            }
        )
        .contentShape(Rectangle())
        .onTapGesture { action() }
    }

}

// Flat, column-like sidebar material (Apple Music style), ported from
// SwiftMiner. Gives the selection pill enough backdrop contrast to read.
private struct SidebarMaterialBackground: View {
    var body: some View {
        VisualEffectMaterialView(material: .sidebar)
            .overlay {
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.10),
                        Color.clear
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
            .overlay(alignment: .trailing) {
                Rectangle()
                    .fill(Color.black.opacity(0.10))
                    .frame(width: 1)
            }
            .clipShape(Rectangle())
            .ignoresSafeArea()
    }
}

private struct VisualEffectMaterialView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode = .withinWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.state = .active
        view.material = material
        view.blendingMode = blendingMode
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = .active
    }
}

// Frosted material selection pill, ported from SwiftMiner's sidebar.
private struct SidebarSelectionHighlight: View {
    @Environment(\.controlActiveState) private var controlActiveState

    private var highlightMaterial: Material {
        controlActiveState == .active ? .ultraThinMaterial : .bar
    }

    private var strokeOpacity: Double {
        controlActiveState == .active ? 0.16 : 0.10
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 11, style: .continuous)
            .fill(highlightMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(.white.opacity(strokeOpacity), lineWidth: 1)
            )
    }
}

private struct ShareRowFramesKey: PreferenceKey {
    static var defaultValue: [NetworkShare.ID: CGRect] { [:] }
    static func reduce(value: inout [NetworkShare.ID: CGRect], nextValue: () -> [NetworkShare.ID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
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
