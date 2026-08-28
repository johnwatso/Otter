import AppKit
import SwiftUI

struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var networkService: NetworkReachabilityService
    @EnvironmentObject private var discovery: SMBDiscoveryService
    @EnvironmentObject private var loginItemService: LoginItemService
    @EnvironmentObject private var notificationService: NotificationService

    let onAddManually: () -> Void

    @State private var step = 0
    @State private var mountedShares: [MountedShareSuggestion] = []
    @State private var isRefreshingMountedShares = false
    @State private var savedSMBShares: [SavedSMBShare] = []
    @State private var isRefreshingSavedSMBShares = false
    @State private var importedPaths = Set<String>()
    @State private var shareBrowserMessage: String?
    @State private var browsingServerID: DiscoveredSMBServer.ID?
    @State private var browsingSavedShareID: SavedSMBShare.ID?
    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case 0:
                    welcomePage
                case 1:
                    permissionsPage
                case 2:
                    presencePage
                case 3:
                    findSharesPage
                default:
                    finishPage
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack {
                if step == 0 {
                    Button("Skip Setup") {
                        finish()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                } else {
                    Button {
                        step -= 1
                    } label: {
                        Label("Back", systemImage: "chevron.left")
                    }
                    .onboardingSecondaryActionButton()
                }

                Spacer()

                if step < 4 {
                    Button {
                        switch step {
                        case 0:
                            step = 1
                        case 1:
                            step = 2
                        case 2:
                            step = 3
                            beginDiscovery()
                        default:
                            refreshMountedShares(
                                advanceToFinish: true
                            )
                        }
                    } label: {
                        Text(step == 0 ? "Get Started" : "Continue")
                    }
                    .onboardingPrimaryActionButton()
                    .keyboardShortcut(.defaultAction)
                    .disabled(step == 3 && isRefreshingMountedShares)
                } else {
                    Button {
                        finish()
                    } label: {
                        Text(settings.shares.isEmpty ? "Finish Without a Share" : "Finish")
                    }
                    .onboardingPrimaryActionButton()
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 620, height: 620)
        .onAppear {
            appModel.onboardingDidBegin()
        }
        .onDisappear {
            discovery.stop()
            appModel.onboardingDidEnd()
        }
    }

    private var welcomePage: some View {
        VStack(spacing: 18) {
            AdaptiveOtterIcon()
                .frame(width: 94, height: 94)

            VStack(spacing: 8) {
                Text("Welcome to Otter")
                    .font(.largeTitle.bold())
                Text("Keep your SMB shares connected after sleep, network changes, VPN reconnects, and server restarts.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 470)
            }

            HStack(spacing: 24) {
                onboardingFeature("bolt.heart", "Quietly monitors")
                onboardingFeature("key.fill", "Uses Keychain")
                onboardingFeature("lock.shield", "Respects network rules")
            }
            .padding(.top, 8)
        }
        .padding(36)
    }

    private var presencePage: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Where should Otter live?")
                    .font(.title2.bold())
                Text("Choose how you want to reach Otter after setup. You can change this later in Preferences.")
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 10) {
                ForEach(AppPresenceMode.allCases) { mode in
                    presenceChoice(mode)
                }
            }

            Label("Otter stays visible in both the Dock and menu bar until onboarding is finished.", systemImage: "info.circle")
                .font(.callout)
                .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(34)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var permissionsPage: some View {
        VStack {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Permissions")
                        .font(.largeTitle.bold())
                    Text("Choose the optional macOS access Otter can use while it sets up your shares.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 18) {
                    OnboardingPermissionRow(
                        symbol: "network",
                        tint: .cyan,
                        title: "Local Network",
                        detail: localNetworkPermissionDetail,
                        isOn: discovery.localNetworkAuthorizationStatus.isAllowed,
                        onEnable: enableLocalNetworkAccess
                    )

                    OnboardingPermissionRow(
                        symbol: "bell.badge.fill",
                        tint: .blue,
                        title: "Notifications",
                        detail: notificationsPermissionDetail,
                        isOn: notificationsPermissionIsEnabled,
                        onEnable: enableNotificationAccess
                    )

                    OnboardingPermissionRow(
                        symbol: "location.fill",
                        tint: .purple,
                        title: "Location",
                        detail: locationPermissionDetail,
                        isOn: networkService.locationAuthorizationStatus == .authorizedAlways,
                        onEnable: enableLocationAccess
                    )
                }

                Text("Otter checks these macOS permissions when this page opens. You can change them later in System Settings.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(32)
            .frame(maxWidth: 540, alignment: .leading)
            .background(.background, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .strokeBorder(.separator.opacity(0.22), lineWidth: 1)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            discovery.checkLocalNetworkAuthorization()
            networkService.refreshLocationAuthorizationStatus()
            Task { await notificationService.refreshAuthorizationStatus() }
        }
    }

    private var findSharesPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Add your shares")
                    .font(.title2.bold())
                Text("Import a share already mounted in Finder, or open a nearby SMB server and connect once so macOS can save its credentials.")
                    .foregroundStyle(.secondary)
            }

            GroupBox("Mounted SMB shares") {
                VStack(spacing: 8) {
                    if isRefreshingMountedShares {
                        ProgressView("Looking for mounted shares…")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if mountedShares.isEmpty {
                        Text("No mounted SMB shares found.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ForEach(mountedShares) { suggestion in
                            HStack {
                                Label(suggestion.displayName, systemImage: "externaldrive.fill")
                                Spacer()
                                if importedPaths.contains(suggestion.mountPath)
                                    || settings.isDuplicateShare(urlString: suggestion.urlString) {
                                    Label("Added", systemImage: "checkmark")
                                        .foregroundStyle(.green)
                                } else {
                                    Button("Add") {
                                        importSuggestion(suggestion)
                                    }
                                }
                            }
                        }
                    }

                    HStack {
                        Button {
                            refreshMountedShares()
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        .tahoeCompactActionButton()

                        Button {
                            settings.completeOnboarding()
                            dismiss()
                            onAddManually()
                        } label: {
                            Label("Enter Address Manually", systemImage: "keyboard")
                        }
                        .tahoeCompactActionButton()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            GroupBox("Saved SMB connections") {
                VStack(spacing: 8) {
                    if isRefreshingSavedSMBShares {
                        ProgressView("Checking Keychain…")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if savedSMBShares.isEmpty {
                        Text("No saved SMB connections found in Keychain.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ForEach(savedSMBShares) { savedShare in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Label(savedShare.displayName, systemImage: "key.fill")
                                    Text(savedShare.detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button {
                                    browseShares(using: savedShare)
                                } label: {
                                    if browsingSavedShareID == savedShare.id {
                                        ProgressView()
                                            .controlSize(.small)
                                    } else {
                                        Text(savedShare.hasSharePath ? "Mount" : "Browse Shares…")
                                    }
                                }
                                .disabled(browsingServerID != nil || browsingSavedShareID != nil)
                            }
                        }
                    }

                    Button {
                        refreshSavedSMBShares()
                    } label: {
                        Label("Refresh Saved Connections", systemImage: "key.viewfinder")
                    }
                    .tahoeCompactActionButton()
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Text("Otter reads only saved server and share addresses. It checks reachability only after you choose one; passwords and usernames stay in Keychain.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            GroupBox("Nearby SMB servers") {
                VStack(spacing: 8) {
                    if discovery.servers.isEmpty {
                        HStack {
                            if discovery.state == .searching {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Searching the local network…")
                            } else {
                                Text(discoveryMessage)
                            }
                            Spacer()
                        }
                        .foregroundStyle(.secondary)
                    } else {
                        ForEach(discovery.servers) { server in
                            HStack {
                                Label(server.name, systemImage: "server.rack")
                                Spacer()
                                Button {
                                    browseShares(on: server)
                                } label: {
                                    if browsingServerID == server.id {
                                        ProgressView()
                                            .controlSize(.small)
                                    } else {
                                        Text("Browse Shares\u{2026}")
                                    }
                                }
                                .disabled(browsingServerID != nil || browsingSavedShareID != nil)
                            }
                        }
                    }

                    if let shareBrowserMessage {
                        Label(shareBrowserMessage, systemImage: "info.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text("macOS will show the server's shares and handle sign-in. Save the password to Keychain when prompted.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(24)
    }

    private var finishPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Keep Otter ready")
                    .font(.title2.bold())
                Text("These defaults make reconnection automatic while keeping alerts under your control.")
                    .foregroundStyle(.secondary)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 14) {
                    Toggle("Start Otter at login", isOn: Binding(
                        get: { loginItemService.isEnabled },
                        set: { loginItemService.setEnabled($0) }
                    ))

                    Toggle("Notify me about connection changes and problems", isOn: Binding(
                        get: { settings.preferences.notificationsEnabled },
                        set: { enabled in
                            settings.updatePreferences { $0.notificationsEnabled = enabled }
                            if enabled {
                                Task { await notificationService.requestAuthorization() }
                            }
                        }
                    ))
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if settings.shares.isEmpty {
                Label("No shares were added. Go Back to add one, or finish and add one later.", systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            } else {
                Label("\(settings.shares.count) share\(settings.shares.count == 1 ? "" : "s") ready for Otter to monitor.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }

            Spacer()
        }
        .padding(34)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            loginItemService.refresh()
        }
    }

    private var discoveryMessage: String {
        if case let .failed(message) = discovery.state {
            return "Discovery unavailable: \(message)"
        }
        return "No SMB servers found yet."
    }

    private func onboardingFeature(_ symbol: String, _ title: String) -> some View {
        VStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.blue)
            Text(title)
                .font(.caption.weight(.medium))
        }
        .frame(width: 120)
    }

    private func beginDiscovery() {
        discovery.start()
        refreshMountedShares()
        refreshSavedSMBShares()
    }

    private func refreshMountedShares(
        advanceToFinish: Bool = false
    ) {
        guard !isRefreshingMountedShares else { return }
        isRefreshingMountedShares = true
        Task {
            let suggestions = await Task.detached(priority: .userInitiated) {
                MountedShareSuggestion.discover()
            }.value
            mountedShares = suggestions

            isRefreshingMountedShares = false
            if advanceToFinish {
                step = 4
            }
        }
    }

    private func refreshSavedSMBShares() {
        guard !isRefreshingSavedSMBShares else { return }
        isRefreshingSavedSMBShares = true
        let keychainDiscovery = appModel.keychainShareDiscoveryService
        Task {
            savedSMBShares = await Task.detached(priority: .userInitiated) {
                keychainDiscovery.savedShares()
            }.value
            isRefreshingSavedSMBShares = false
        }
    }

    private func browseShares(on server: DiscoveredSMBServer) {
        guard browsingServerID == nil, browsingSavedShareID == nil else { return }
        browsingServerID = server.id
        shareBrowserMessage = nil

        Task {
            do {
                let suggestions = try await appModel.shareBrowserService.browse(server)
                guard !suggestions.isEmpty else {
                    shareBrowserMessage = "No share was selected."
                    browsingServerID = nil
                    return
                }

                let existing = Set(mountedShares)
                mountedShares = existing.union(suggestions).sorted {
                    $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
                }
                let previousCount = settings.shares.count
                suggestions.forEach(importSuggestion)
                let addedCount = settings.shares.count - previousCount
                shareBrowserMessage = addedCount > 0
                    ? "Added \(addedCount) share\(addedCount == 1 ? "" : "s")."
                    : "The selected share was already added."
            } catch {
                shareBrowserMessage = "Couldn't browse this server: \(error.localizedDescription)"
            }
            browsingServerID = nil
        }
    }

    private func browseShares(using savedShare: SavedSMBShare) {
        guard browsingServerID == nil, browsingSavedShareID == nil else { return }
        browsingSavedShareID = savedShare.id
        shareBrowserMessage = nil

        Task {
            do {
                guard let url = savedShare.connectionURL else {
                    shareBrowserMessage = "This saved connection has an invalid network address."
                    browsingSavedShareID = nil
                    return
                }
                guard await networkService.canReachServer(for: url, timeout: 2) else {
                    shareBrowserMessage = "\(savedShare.displayName) is not reachable on the current network, so Otter didn't try to mount it."
                    browsingSavedShareID = nil
                    return
                }
                let suggestions = try await appModel.shareBrowserService.browse(savedShare)
                guard !suggestions.isEmpty else {
                    shareBrowserMessage = "No share was selected."
                    browsingSavedShareID = nil
                    return
                }

                let existing = Set(mountedShares)
                mountedShares = existing.union(suggestions).sorted {
                    $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
                }
                let previousCount = settings.shares.count
                suggestions.forEach(importSuggestion)
                let addedCount = settings.shares.count - previousCount
                shareBrowserMessage = addedCount > 0
                    ? "Added \(addedCount) share\(addedCount == 1 ? "" : "s") from Keychain."
                    : "The selected share was already added."
            } catch {
                shareBrowserMessage = "Couldn't connect using this saved connection: \(error.localizedDescription)"
            }
            browsingSavedShareID = nil
        }
    }

    private func importSuggestion(_ suggestion: MountedShareSuggestion) {
        guard !settings.isDuplicateShare(urlString: suggestion.urlString) else { return }
        settings.addShare(NetworkShare(
            displayName: suggestion.displayName,
            urlString: suggestion.urlString,
            mountPath: suggestion.mountPath
        ))
        importedPaths.insert(suggestion.mountPath)
    }

    private func enableLocalNetworkAccess() {
        if discovery.localNetworkAuthorizationStatus == .denied {
            openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")
        } else {
            discovery.checkLocalNetworkAuthorization()
        }
    }

    private func enableNotificationAccess() {
        Task { await notificationService.requestAuthorization() }
    }

    private func enableLocationAccess() {
        if networkService.canRequestLocationAuthorization {
            networkService.requestLocationAuthorization()
        } else if networkService.locationAuthorizationStatus != .authorizedAlways {
            openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")
        }
    }

    private var notificationsPermissionIsEnabled: Bool {
        switch notificationService.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            true
        case .notDetermined, .denied:
            false
        @unknown default:
            false
        }
    }

    private func openSystemSettings(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    private var localNetworkPermissionDetail: String {
        switch discovery.localNetworkAuthorizationStatus {
        case .checking:
            "Checking macOS permission…"
        case .allowed:
            "Otter can find nearby SMB servers and communicate with local shares."
        case .denied:
            "Disabled in System Settings. Enable Otter under Privacy & Security > Local Network."
        case .unknown:
            "MacOS has not confirmed whether Otter can access your local network yet."
        }
    }

    private var notificationsPermissionDetail: String {
        switch notificationService.authorizationStatus {
        case .authorized:
            "Otter can alert you about connection changes and problems."
        case .notDetermined:
            "MacOS has not asked for notification permission yet."
        case .denied:
            "Disabled in System Settings."
        case .provisional:
            "Otter can deliver notifications quietly."
        case .ephemeral:
            "Otter has temporary notification access."
        @unknown default:
            "MacOS has not confirmed notification access."
        }
    }

    private var locationPermissionDetail: String {
        switch networkService.locationAuthorizationStatus {
        case .authorizedAlways:
            "Otter can show the Wi-Fi name when you create a network rule for a share."
        case .notDetermined:
            "MacOS has not asked for location permission yet."
        case .denied, .restricted:
            "Disabled in System Settings."
        case .authorizedWhenInUse:
            "Otter has limited location access. Allow it in System Settings to use Wi-Fi network rules."
        @unknown default:
            "MacOS has not confirmed location access."
        }
    }

    private func finish() {
        settings.completeOnboarding()
        dismiss()
    }

    private func presenceChoice(_ mode: AppPresenceMode) -> some View {
        let isSelected = settings.preferences.appPresenceMode == mode

        return AppPresenceChoice(mode: mode, isSelected: isSelected) {
            settings.updatePreferences { $0.appPresenceMode = mode }
        }
    }
}

private extension View {
    @ViewBuilder
    func onboardingPrimaryActionButton() -> some View {
        if #available(macOS 26.0, *) {
            self
                .font(.body.weight(.semibold))
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.roundedRectangle(radius: 11))
                .controlSize(.large)
                .frame(minWidth: 132)
        } else {
            self
                .font(.body.weight(.semibold))
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.roundedRectangle(radius: 11))
                .controlSize(.large)
                .frame(minWidth: 132)
        }
    }

    @ViewBuilder
    func onboardingSecondaryActionButton() -> some View {
        if #available(macOS 26.0, *) {
            self
                .font(.body.weight(.medium))
                .buttonStyle(.glass)
                .buttonBorderShape(.roundedRectangle(radius: 11))
                .controlSize(.large)
        } else {
            self
                .font(.body.weight(.medium))
                .buttonStyle(.bordered)
                .buttonBorderShape(.roundedRectangle(radius: 11))
                .controlSize(.large)
        }
    }
}

private struct OnboardingPermissionRow: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String
    let isOn: Bool
    let onEnable: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(tint)
                .frame(width: 58, height: 58)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Toggle(title, isOn: Binding(
                get: { isOn },
                set: { enabled in
                    if enabled {
                        onEnable()
                    }
                }
            ))
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityLabel(title)
                .accessibilityHint(detail)
        }
    }
}

private struct AppPresenceChoice: View {
    let mode: AppPresenceMode
    let isSelected: Bool
    let action: () -> Void

    private var secondaryColor: Color {
        Color(nsColor: .secondaryLabelColor)
    }

    private var tertiaryColor: Color {
        Color(nsColor: .tertiaryLabelColor)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: mode.systemImage)
                    .font(.title2)
                    .foregroundStyle(isSelected ? Color.accentColor : secondaryColor)
                    .frame(width: 32)

                VStack(alignment: .leading, spacing: 3) {
                    Text(mode.title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(mode.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }

                Spacer()

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : tertiaryColor)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(choiceBackground)
            .overlay(choiceBorder)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(mode.title)
        .accessibilityHint(mode.detail)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
    }

    private var choiceBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(isSelected ? Color.accentColor.opacity(0.10) : secondaryColor.opacity(0.06))
    }

    private var choiceBorder: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(isSelected ? Color.accentColor.opacity(0.65) : secondaryColor.opacity(0.12))
    }
}

struct AdaptiveOtterIcon: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Image(nsImage: Self.image(for: colorScheme) ?? NSApplication.shared.applicationIconImage)
            .resizable()
            .scaledToFit()
            .id(colorScheme)
    }

    static func image(for colorScheme: ColorScheme, bundle: Bundle = .main) -> NSImage? {
        let resourceName = colorScheme == .dark ? "otter-icon-dark" : "otter-icon-light"
        guard let url = bundle.url(forResource: resourceName, withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }
}
