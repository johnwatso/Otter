import AppKit
import SwiftUI

struct ShareEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var networkService: NetworkReachabilityService
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var discovery: SMBDiscoveryService
    @State private var draft: DraftShare
    @State private var validationMessage: String?
    @State private var mountedShareSuggestions: [MountedShareSuggestion] = []
    @State private var readinessReport: ConnectionDiagnosticReport?
    @State private var isTestingSetup = false
    @State private var isVerifyingVPN = false
    @State private var vpnVerification: VPNVerificationResult?
    @State private var provisionalShareID = UUID()
    @State private var browsingServerID: DiscoveredSMBServer.ID?
    @State private var savedSMBShares: [SavedSMBShare] = []
    @State private var isRefreshingSavedSMBShares = false
    @State private var browsingSavedShareID: SavedSMBShare.ID?
    @State private var shareBrowserMessage: String?
    @State private var isDiscoveringWakeOnLANSettings = false
    @State private var wakeOnLANDiscoveryMessage: String?

    private let sourceShare: NetworkShare?
    private let appliesToShareCount: Int?
    let onSave: (NetworkShare) -> Void
    let onCancel: () -> Void

    private var selectedProtocol: NetworkShareProtocol {
        NetworkShareProtocol(urlScheme: URL(string: draft.urlString)?.scheme) ?? .smb
    }

    private var protocolSelection: Binding<NetworkShareProtocol> {
        Binding {
            selectedProtocol
        } set: { selected in
            var value = draft.urlString.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("//") { value = "smb:\(value)" }
            if var components = URLComponents(string: value), components.host != nil {
                components.scheme = selected == .webdav ? "https" : selected.rawValue
                draft.urlString = components.string ?? value
            } else if value.isEmpty {
                draft.urlString = selected.exampleURL
            } else {
                draft.urlString = "\(selected == .webdav ? "https" : selected.rawValue)://\(value)"
            }
        }
    }

    init(
        share: NetworkShare?,
        prefill: MountedShareSuggestion? = nil,
        appliesToShareCount: Int? = nil,
        onSave: @escaping (NetworkShare) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.sourceShare = share
        self.appliesToShareCount = appliesToShareCount

        var initialDraft = DraftShare(share: share)
        if let prefill {
            initialDraft.displayName = prefill.displayName
            initialDraft.urlString = prefill.urlString
            initialDraft.mountPath = prefill.mountPath
        }
        _draft = State(initialValue: initialDraft)

        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(editorTitle)
                    .font(.title2)
                    .fontWeight(.bold)
                if isEditing && appliesToShareCount == nil {
                    Text("— \(draft.displayName)")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 10)

            Form {
                if !isEditing {
                    Section("Available SMB Shares") {
                        if mountedShareSuggestions.isEmpty {
                            Text("No mounted SMB shares found.")
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Mounted in Finder")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)

                            ForEach(mountedShareSuggestions) { suggestion in
                                Button {
                                    apply(suggestion)
                                } label: {
                                    HStack {
                                        Label(suggestion.displayName, systemImage: "externaldrive.fill")
                                        Spacer()
                                        Text(suggestion.mountPath)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                            }
                        }

                        if !discovery.servers.isEmpty || discovery.state == .searching {
                            if !mountedShareSuggestions.isEmpty {
                                Divider()
                            }

                            Text("Nearby servers")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)

                            if discovery.servers.isEmpty {
                                HStack {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("Searching the local network…")
                                        .foregroundStyle(.secondary)
                                }
                            } else {
                                ForEach(discovery.servers) { server in
                                    Button {
                                        browseShares(on: server)
                                    } label: {
                                        HStack {
                                            Label(server.name, systemImage: "server.rack")
                                            Spacer()
                                            if browsingServerID == server.id {
                                                ProgressView()
                                                    .controlSize(.small)
                                            } else {
                                                Text(mountedShareCount(on: server) > 0 ? "Browse Other Shares…" : "Browse Shares…")
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                    }
                                    .disabled(browsingServerID != nil || browsingSavedShareID != nil)
                                }
                            }
                        }

                        HStack {
                            Button {
                                chooseMountedShare()
                            } label: {
                                Label("Choose Mounted Volume…", systemImage: "folder")
                            }
                            .tahoeCompactActionButton()

                            Button {
                                refreshMountedShares()
                                discovery.restart()
                            } label: {
                                Label("Refresh", systemImage: "arrow.clockwise")
                            }
                            .tahoeCompactActionButton()
                        }

                        if let shareBrowserMessage {
                            Text(shareBrowserMessage)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Select a mounted share, or browse a nearby server to add another one. macOS handles sign-in and can save credentials in Keychain.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Section("Saved SMB Connections") {
                        if isRefreshingSavedSMBShares {
                            ProgressView("Checking Keychain…")
                        } else if savedSMBShares.isEmpty {
                            Text("No saved SMB connections found in Keychain.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(savedSMBShares) { savedShare in
                                Button {
                                    browseShares(using: savedShare)
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Label(savedShare.displayName, systemImage: "key.fill")
                                            Text(savedShare.detail)
                                                .font(.footnote)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        if browsingSavedShareID == savedShare.id {
                                            ProgressView()
                                                .controlSize(.small)
                                        } else {
                                            Text(savedShare.hasSharePath ? "Mount" : "Browse Shares…")
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                .disabled(browsingServerID != nil || browsingSavedShareID != nil)
                            }
                        }

                        Button {
                            refreshSavedSMBShares()
                        } label: {
                            Label("Refresh Saved Connections", systemImage: "key.viewfinder")
                        }
                        .tahoeCompactActionButton()

                        Text("Otter checks reachability only after you choose a saved connection. Passwords and usernames stay in Keychain.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if appliesToShareCount == nil {
                    // General Section
                    Section("General") {
                        TextField("Share name", text: $draft.displayName, prompt: Text(inferredDisplayName ?? "OtterNAS"))
                        TextField("Network address", text: $draft.urlString, prompt: Text(selectedProtocol.exampleURL))
                        TextField("Finder mount location", text: $draft.mountPath, prompt: Text(inferredMountPath))
                        Picker("Protocol", selection: protocolSelection) {
                            ForEach(NetworkShareProtocol.allCases, id: \.self) { protocolKind in
                                Text(protocolKind.title).tag(protocolKind)
                            }
                        }

                        if isEditing {
                            Button {
                                chooseMountedShare()
                            } label: {
                                Label("Auto-fill details from Finder...", systemImage: "arrow.down.doc.fill")
                            }
                            .tahoeCompactActionButton()
                            .padding(.vertical, 2)
                        }
                    }
                }

                Section("Connection") {
                    Picker("Connection mode", selection: $draft.automaticConnectionMode) {
                        ForEach(AutomaticConnectionMode.allCases, id: \.self) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)

                    Text(draft.automaticConnectionMode.detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    DisclosureGroup {
                        vpnConfiguration
                    } label: {
                        HStack {
                            Text("Remote access")
                            Spacer()
                            Text(remoteAccessSummary)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Advanced") {
                    if draft.automaticConnectionMode == .manual {
                        Toggle("Mount once when Otter starts", isOn: $draft.mountAtLaunch)
                        Text("Use this for a one-time login mount without ongoing automatic reconnection.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    DisclosureGroup {
                        Toggle("Disconnect outside this network", isOn: networkRestrictionEnabled)

                        if draft.limitsToRegisteredNetwork {
                            registeredNetworkConfiguration
                        }
                    } label: {
                        advancedRowLabel("Network restriction", detail: networkRestrictionSummary)
                    }

                    DisclosureGroup {
                        Toggle("Wake this server before connecting", isOn: $draft.wakeOnLANEnabled)

                        if draft.wakeOnLANEnabled {
                            TextField("MAC address", text: $draft.wakeOnLANMACAddress, prompt: Text("AA:BB:CC:DD:EE:FF"))
                            TextField(
                                "Broadcast address",
                                text: $draft.wakeOnLANBroadcastAddress,
                                prompt: Text(WakeOnLANConfiguration.defaultBroadcastAddress)
                            )
                            Stepper(value: $draft.wakeOnLANPort, in: 1...65_535, step: 1) {
                                Text("Port: \(draft.wakeOnLANPort)")
                            }

                            Button {
                                discoverWakeOnLANSettings()
                            } label: {
                                if isDiscoveringWakeOnLANSettings {
                                    HStack(spacing: 8) {
                                        ProgressView()
                                            .controlSize(.small)
                                        Text("Detecting Settings…")
                                    }
                                } else {
                                    Label("Auto-detect Settings", systemImage: "dot.radiowaves.left.and.right")
                                }
                            }
                            .tahoeSecondaryActionButton()
                            .disabled(isDiscoveringWakeOnLANSettings)

                            Text("Otter fills in the server MAC address and local broadcast address while this share is mounted. It cannot discover these settings over a VPN or after the server sleeps.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)

                            if let wakeOnLANDiscoveryMessage {
                                Text(wakeOnLANDiscoveryMessage)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } label: {
                        advancedRowLabel("Wake-on-LAN", detail: draft.wakeOnLANEnabled ? "On" : "Off")
                    }

                    DisclosureGroup {
                        Toggle("Check mounted volume", isOn: $draft.healthCheck.isEnabled)

                        if draft.healthCheck.isEnabled {
                            Toggle("Require writable volume", isOn: $draft.healthCheck.requiresWritableVolume)
                            TextField("Expected file (optional)", text: $draft.healthCheck.sentinelRelativePath, prompt: Text(".otter-health"))
                        }

                        Text("Checks that the mounted volume responds, and can optionally require write access or a file that should exist on it.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } label: {
                        advancedRowLabel("Health checks", detail: healthCheckSummary)
                    }
                }

                // Credentials and diagnostics are specific to one share.
                if appliesToShareCount == nil {
                    Section("Credentials") {
                        HStack(spacing: 8) {
                            Image(systemName: hasKeychainCredentials ? "checkmark.circle.fill" : "minus.circle")
                                .foregroundStyle(hasKeychainCredentials ? .green : .secondary)
                            Text(hasKeychainCredentials ? "Credentials found in macOS Keychain." : "No credentials found in macOS Keychain.")
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                        }
                        if !hasKeychainCredentials {
                            Text("To mount this share, connect once in Finder and select \"Remember this password in my keychain\".")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Section("Connection Readiness") {
                        Button {
                            testSetup()
                        } label: {
                            if isTestingSetup {
                                HStack(spacing: 8) {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("Testing Setup\u{2026}")
                                }
                            } else {
                                Label("Test Setup", systemImage: "checkmark.circle.badge.questionmark")
                            }
                        }
                        .tahoeSecondaryActionButton()
                        .disabled(isTestingSetup)

                        Text("Checks the network, VPN connection, credentials, SMB service, and mount. macOS may ask you to sign in or choose a share.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        if let readinessReport {
                            ForEach(readinessReport.steps) { step in
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: readinessSymbol(for: step.status))
                                        .foregroundStyle(readinessColor(for: step.status))
                                        .frame(width: 16)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(step.title)
                                            .font(.subheadline.weight(.medium))
                                        Text(step.detail)
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }

                    // Advanced Section
                    if let fallbackURL = fallbackURLString {
                        Section("Advanced") {
                            LabeledContent("Fallback IP", value: fallbackURL)

                            if let host = hostFromURL, !NetworkShare.isIPAddress(host) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Label("VPN IP Fallback", systemImage: "info.circle")
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                    Text("Otter will resolve and cache this server's local IP address when connected locally. If you connect to your VPN later, Otter will use the cached IP address to bypass mDNS limits. Ensure your server has a static IP address, or this fallback may fail if the IP changes.")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.top, 4)
                            }
                        }
                    }
                }

            }
            .formStyle(.grouped)
            .padding(20)

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                if let validationMessage {
                    Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    Button {
                        onCancel()
                        dismiss()
                    } label: {
                        Label("Cancel", systemImage: "xmark")
                    }
                    .tahoeSecondaryActionButton()
                    .keyboardShortcut(.cancelAction)

                    Spacer()

                    Button {
                        save()
                    } label: {
                        Label("Done", systemImage: "checkmark")
                    }
                    .tahoePrimaryActionButton()
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
        }
        .frame(width: 540)
        .onAppear {
            resetDraftIfNeeded()
            networkService.refreshNetworkDetails()
            if !isEditing {
                refreshMountedShares()
                discovery.start()
                refreshSavedSMBShares()
            }
        }
        .onChange(of: networkService.currentWiFiNetworkName) {
            fillDraftFromCurrentNetwork()
        }
        .onChange(of: networkService.currentIPv4Subnets) {
            fillDraftFromCurrentNetwork()
        }
        .onChange(of: draft.wakeOnLANEnabled) { _, enabled in
            guard enabled else {
                wakeOnLANDiscoveryMessage = nil
                return
            }
            discoverWakeOnLANSettings()
        }
        .onDisappear {
            if !isEditing {
                discovery.stop()
            }
        }
    }

    private var editorTitle: String {
        if let appliesToShareCount {
            return "Settings for \(appliesToShareCount) Shares"
        }
        return isEditing ? "Settings" : "New Share"
    }

    private func mountedShareCount(on server: DiscoveredSMBServer) -> Int {
        mountedShareSuggestions.count { $0.matches(server: server) }
    }

    private var hasKeychainCredentials: Bool {
        guard let url = URL(string: draft.urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = url.host(percentEncoded: false)
        else { return false }
        
        if settings.hasCredentials(for: host) {
            return true
        }
        if let cachedIP = draft.cachedIPAddress, settings.hasCredentials(for: cachedIP) {
            return true
        }
        return false
    }

    private var isEditing: Bool {
        sourceShare != nil
    }

    private var hostFromURL: String? {
        URL(string: draft.urlString.trimmingCharacters(in: .whitespacesAndNewlines))?.host(percentEncoded: false)
    }

    private var fallbackURLString: String? {
        guard let cachedIP = draft.cachedIPAddress,
              let url = URL(string: draft.urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = url.host(percentEncoded: false),
              !NetworkShare.isIPAddress(host)
        else { return nil }

        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.host = cachedIP
        return components?.string
    }

    private func resetDraftIfNeeded() {
        guard draft.id != sourceShare?.id else { return }
        draft = DraftShare(share: sourceShare)
        validationMessage = nil
        readinessReport = nil
        vpnVerification = nil
    }

    private var vpnSelection: Binding<VPNNameSelection> {
        Binding {
            if draft.vpnName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .unconfigured
            }

            if let configuredName = configuredSystemVPN(named: draft.vpnName) {
                return .known(configuredName)
            }

            return .custom
        } set: { selection in
            vpnVerification = nil
            readinessReport = nil
            switch selection {
            case .unconfigured:
                draft.vpnName = ""
                draft.usesVPNRule = false
            case let .known(vpnName):
                draft.vpnName = vpnName
                draft.usesVPNRule = true
            case .custom:
                break
            }
        }
    }

    private var networkRestrictionEnabled: Binding<Bool> {
        Binding {
            draft.limitsToRegisteredNetwork
        } set: { isEnabled in
            draft.limitsToRegisteredNetwork = isEnabled
            if isEnabled {
                registerCurrentNetworkIfNeeded()
            } else {
                draft.registeredSubnets = []
                draft.wifiNetworkName = ""
            }
        }
    }

    private var registeredNetworkConfiguration: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Otter disconnects this share when your Mac leaves this Wi-Fi or wired network.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                LabeledContent("Network", value: registeredNetworkSummary)

                if !networkService.currentIPv4Subnets.isEmpty || networkService.currentWiFiNetworkName != nil {
                    Button {
                        registerCurrentNetwork()
                    } label: {
                        Label(
                            draft.registeredSubnets.isEmpty && draft.wifiNetworkName.isEmpty
                                ? "Use Current Network"
                                : "Update",
                            systemImage: "location"
                        )
                    }
                    .tahoeCompactActionButton()
                }
            }

            DisclosureGroup("Network details") {
                LabeledContent(
                    "Wi-Fi",
                    value: draft.wifiNetworkName.isEmpty ? "Not available" : draft.wifiNetworkName
                )
                LabeledContent(
                    "Subnet",
                    value: draft.registeredSubnets.isEmpty ? "Not available" : draft.registeredSubnets.joined(separator: ", ")
                )
                Text("Otter captures both details so the network can still be recognized if either one changes.")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }

            if draft.registeredSubnets.isEmpty && draft.wifiNetworkName.isEmpty && networkService.wifiNameRequiresLocationPermission {
                locationPermissionNotice
            }
        }
        .padding(.leading, 20)
    }

    private var remoteAccessSummary: String {
        let vpnName = draft.vpnName.trimmingCharacters(in: .whitespacesAndNewlines)
        return draft.usesVPNRule && !vpnName.isEmpty ? vpnName : "Local network"
    }

    private var vpnConfiguration: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("VPN", selection: vpnSelection) {
                Text("Choose a VPN…").tag(VPNNameSelection.unconfigured)

                ForEach(networkService.knownVPNNames, id: \.self) { vpnName in
                    Text(networkService.canControlVPN(named: vpnName)
                        ? vpnName
                        : "\(vpnName) — Connect Manually")
                        .tag(VPNNameSelection.known(vpnName))
                }

                if !draft.vpnName.isEmpty,
                   configuredSystemVPN(named: draft.vpnName) == nil {
                    Text("\(draft.vpnName) (not in System Settings)")
                        .tag(VPNNameSelection.custom)
                }
            }
            .pickerStyle(.menu)

            if vpnSelection.wrappedValue == .custom {
                Text("This saved VPN is no longer available. Choose another VPN from System Settings.")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            } else if vpnSelection.wrappedValue == .unconfigured {
                Text("Select a VPN to enable this connection location.")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            } else {
                Text(vpnRuleDescription)
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }

            if vpnSelection.wrappedValue != .unconfigured,
               vpnSelection.wrappedValue != .custom {
                DisclosureGroup("VPN details") {
                    Toggle("Start VPN automatically", isOn: $draft.connectVPNAutomatically)
                    Text(automaticVPNDescription)
                        .font(.footnote)
                        .foregroundStyle(.tertiary)

                    HStack(spacing: 8) {
                        Button {
                            verifyVPN()
                        } label: {
                            if isVerifyingVPN {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Label("Verify Connection", systemImage: "checkmark.shield")
                            }
                        }
                        .tahoeCompactActionButton()
                        .disabled(isVerifyingVPN)

                        if let vpnVerification {
                            Label(
                                vpnVerification.message,
                                systemImage: vpnVerification.isVerified
                                    ? "checkmark.circle.fill"
                                    : "exclamationmark.triangle.fill"
                            )
                            .font(.footnote)
                            .foregroundStyle(vpnVerification.isVerified ? .green : .orange)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .padding(.leading, 20)
    }

    private var registeredNetworkSummary: String {
        let wifiName = draft.wifiNetworkName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !wifiName.isEmpty {
            return wifiName
        }
        if !draft.registeredSubnets.isEmpty {
            return draft.registeredSubnets.joined(separator: ", ")
        }
        return "Identifying current network…"
    }

    private var networkRestrictionSummary: String {
        draft.limitsToRegisteredNetwork ? registeredNetworkSummary : "Off"
    }

    private var healthCheckSummary: String {
        guard draft.healthCheck.isEnabled else { return "Off" }
        return draft.healthCheck.hasCustomChecks ? "Custom" : "Standard"
    }

    private func advancedRowLabel(_ title: String, detail: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(detail)
                .foregroundStyle(.secondary)
        }
    }

    private func configuredSystemVPN(named name: String) -> String? {
        networkService.knownVPNNames.first {
            $0.localizedCaseInsensitiveCompare(name) == .orderedSame
        }
    }

    private var vpnRuleDescription: String {
        let vpnName = draft.vpnName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !vpnName.isEmpty, !networkService.canControlVPN(named: vpnName) {
            return "macOS may require you to connect this VPN from its app."
        }

        return "Otter checks the server after this VPN connects."
    }

    private var automaticVPNDescription: String {
        if draft.connectVPNAutomatically {
            return draft.limitsToRegisteredNetwork
                ? "Away from the registered network, Otter starts this VPN when needed to keep the share connected."
                : "Otter starts this VPN when needed to keep the share connected."
        }

        return "Otter waits for this VPN, then connects the share."
    }

    private var locationPermissionNotice: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("macOS requires Location Services access to read the Wi-Fi network name.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            if networkService.canRequestLocationAuthorization {
                Button {
                    networkService.requestLocationAuthorization()
                } label: {
                    Label("Allow Location Access", systemImage: "location")
                }
                .tahoeCompactActionButton()
            } else {
                Button {
                    openLocationPrivacySettings()
                } label: {
                    Label("Open Location Settings", systemImage: "gearshape")
                }
                .tahoeCompactActionButton()
            }
        }
    }

    private func openLocationPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") else { return }
        NSWorkspace.shared.open(url)
    }

    private func chooseMountedShare() {
        let panel = NSOpenPanel()
        panel.title = "Choose Mounted Share"
        panel.message = "Choose a mounted SMB share."
        panel.prompt = "Choose"
        panel.directoryURL = URL(fileURLWithPath: "/Volumes", isDirectory: true)
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            apply(try MountedShareSuggestion.make(from: url))
            refreshMountedShares()
        } catch {
            validationMessage = error.localizedDescription
        }
    }

    private func refreshMountedShares() {
        // Reading volume resource values can hang for seconds when a network
        // mount is unresponsive, so discovery runs off the main thread.
        Task {
            mountedShareSuggestions = await Task.detached(priority: .userInitiated) {
                MountedShareSuggestion.discover()
            }.value
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

    private func apply(_ suggestion: MountedShareSuggestion) {
        draft.displayName = suggestion.displayName
        draft.urlString = suggestion.urlString
        draft.mountPath = suggestion.mountPath
        validationMessage = nil
    }

    private func browseShares(on server: DiscoveredSMBServer) {
        guard browsingServerID == nil, browsingSavedShareID == nil else { return }
        browsingServerID = server.id
        shareBrowserMessage = nil

        Task {
            do {
                let suggestions = try await appModel.shareBrowserService.browse(server)
                let newlyMountedShares = addNewMountedShares(suggestions)
                if suggestions.isEmpty {
                    shareBrowserMessage = "No share was selected."
                } else if newlyMountedShares.isEmpty {
                    shareBrowserMessage = "That share is already mounted."
                } else {
                    if newlyMountedShares.count == 1, let suggestion = newlyMountedShares.first {
                        apply(suggestion)
                    }
                    shareBrowserMessage = "Selected \(newlyMountedShares.count) new share\(newlyMountedShares.count == 1 ? "" : "s")."
                }
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
                let newlyMountedShares = addNewMountedShares(suggestions)
                if suggestions.isEmpty {
                    shareBrowserMessage = "No share was selected."
                } else if newlyMountedShares.isEmpty {
                    shareBrowserMessage = "That share is already mounted."
                } else {
                    if newlyMountedShares.count == 1, let suggestion = newlyMountedShares.first {
                        apply(suggestion)
                    }
                    shareBrowserMessage = "Selected \(newlyMountedShares.count) new share\(newlyMountedShares.count == 1 ? "" : "s") from Keychain."
                }
            } catch {
                shareBrowserMessage = "Couldn't connect using this saved connection: \(error.localizedDescription)"
            }
            browsingSavedShareID = nil
        }
    }

    private func addNewMountedShares(_ suggestions: [MountedShareSuggestion]) -> [MountedShareSuggestion] {
        var allSuggestions = mountedShareSuggestions
        var newSuggestions: [MountedShareSuggestion] = []

        for suggestion in suggestions where !allSuggestions.contains(where: { $0.isSameShare(as: suggestion) }) {
            allSuggestions.append(suggestion)
            newSuggestions.append(suggestion)
        }

        mountedShareSuggestions = allSuggestions.sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
        return newSuggestions
    }

    private func registerCurrentNetwork() {
        draft.registeredSubnets = networkService.currentIPv4Subnets
        if let currentSSID = networkService.currentWiFiNetworkName {
            draft.wifiNetworkName = currentSSID
        }
    }

    private func discoverWakeOnLANSettings() {
        guard !isDiscoveringWakeOnLANSettings else { return }
        guard let url = networkURLComponents(from: draft.urlString)?.url else {
            wakeOnLANDiscoveryMessage = WakeOnLANConfigurationDiscoveryError.invalidShareURL.localizedDescription
            return
        }

        isDiscoveringWakeOnLANSettings = true
        wakeOnLANDiscoveryMessage = nil
        Task {
            do {
                let configuration = try await WakeOnLANConfigurationDiscoveryService().discover(for: url)
                draft.wakeOnLANMACAddress = configuration.macAddress
                draft.wakeOnLANBroadcastAddress = configuration.broadcastAddress
                draft.wakeOnLANPort = configuration.port
                wakeOnLANDiscoveryMessage = "Found MAC address \(configuration.macAddress)."
            } catch {
                wakeOnLANDiscoveryMessage = error.localizedDescription
            }
            isDiscoveringWakeOnLANSettings = false
        }
    }

    private func registerCurrentNetworkIfNeeded() {
        fillDraftFromCurrentNetwork()

        // Reading the Wi-Fi name needs Location Services, so ask the moment
        // the user enables the condition (no-op unless undetermined). The
        // draft back-fills via onChange once the refreshed details arrive.
        if draft.wifiNetworkName.isEmpty {
            networkService.requestLocationAuthorization()
        }

        Task {
            await networkService.refreshNetworkDetailsNow()
            fillDraftFromCurrentNetwork()
        }
    }

    // Fills whatever the current network can provide into fields the user
    // hasn't set, so the condition configures itself where possible.
    private func fillDraftFromCurrentNetwork() {
        guard draft.limitsToRegisteredNetwork else { return }

        if draft.registeredSubnets.isEmpty {
            draft.registeredSubnets = networkService.currentIPv4Subnets
        }
        if draft.wifiNetworkName.isEmpty, let currentSSID = networkService.currentWiFiNetworkName {
            draft.wifiNetworkName = currentSSID
        }
    }

    private func save() {
        validationMessage = validate()
        guard validationMessage == nil, let share = makeShareFromDraft() else { return }

        onSave(share)
        dismiss()
    }

    private func makeShareFromDraft() -> NetworkShare? {
        guard let normalizedURLString = normalizedNetworkURLString(from: draft.urlString) else { return nil }
        let now = Date()
        let displayName = resolvedDisplayName(for: normalizedURLString)
        return NetworkShare(
            id: draft.id ?? provisionalShareID,
            displayName: displayName,
            urlString: normalizedURLString,
            mountPath: NetworkShare.normalizedMountPath(
                draft.mountPath,
                displayName: displayName,
                urlString: normalizedURLString
            ),
            keepMounted: draft.keepMounted,
            mountAtLaunch: draft.mountAtLaunch,
            autoConnectWhenReachable: draft.autoConnectWhenReachable,
            pauseState: draft.pauseState,
            wakeOnLAN: draft.wakeOnLAN,
            rules: draft.rules,
            healthCheck: draft.healthCheck,
            cachedIPAddress: draft.cachedIPAddress,
            ipAddressChangeObservations: draft.ipAddressChangeObservations,
            createdAt: draft.createdAt ?? now,
            updatedAt: now
        )
    }

    private func verifyVPN() {
        let requiredName = draft.vpnName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requiredName.isEmpty else { return }

        isVerifyingVPN = true
        Task {
            await networkService.refreshNetworkDetailsNow()
            let exactName = networkService.activeVPNNames.first {
                $0.localizedCaseInsensitiveCompare(requiredName) == .orderedSame
            }

            if let exactName {
                vpnVerification = .connected(exactName)
            } else if !networkService.activeVPNNames.isEmpty {
                vpnVerification = .differentVPN(
                    required: requiredName,
                    active: networkService.activeVPNNames
                )
            } else if networkService.hasUnidentifiedTunnel {
                vpnVerification = .unidentifiedTunnel(requiredName)
            } else {
                vpnVerification = .disconnected(requiredName)
            }
            isVerifyingVPN = false
        }
    }

    private func testSetup() {
        validationMessage = validate()
        guard validationMessage == nil, let share = makeShareFromDraft() else { return }

        isTestingSetup = true
        readinessReport = nil
        Task {
            readinessReport = await appModel.connectionDoctor.run(for: share, attemptMount: true)
            isTestingSetup = false
        }
    }

    private func readinessSymbol(for status: DiagnosticStepStatus) -> String {
        switch status {
        case .passed: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .failed: "xmark.circle.fill"
        case .information: "info.circle.fill"
        }
    }

    private func readinessColor(for status: DiagnosticStepStatus) -> Color {
        switch status {
        case .passed: .green
        case .warning: .orange
        case .failed: .red
        case .information: .blue
        }
    }

    private func validate() -> String? {
        guard let components = networkURLComponents(from: draft.urlString) else {
            return "Use an SMB, NFS, or WebDAV address such as smb://server.local/Share."
        }

        if components.user != nil || components.password != nil {
            return "Remove credentials from the address."
        }

        if components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty {
            return "Include the share name in the address."
        }

        if draft.limitsToRegisteredNetwork
            && draft.registeredSubnets.isEmpty
            && draft.wifiNetworkName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Register the network while connected to it, or turn off the network condition."
        }

        if draft.usesVPNRule {
            let vpnName = draft.vpnName.trimmingCharacters(in: .whitespacesAndNewlines)
            if vpnName.isEmpty {
                return "Choose a VPN from System Settings, or turn off the VPN condition."
            }
            if configuredSystemVPN(named: vpnName) == nil {
                return "Choose a VPN that is available in System Settings."
            }
        }

        if draft.wakeOnLANEnabled {
            if WakeOnLANConfiguration.normalizedMACAddress(draft.wakeOnLANMACAddress) == nil {
                return "Add a valid Wake-on-LAN MAC address."
            }

            let broadcastAddress = draft.wakeOnLANBroadcastAddress
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedBroadcastAddress = broadcastAddress.isEmpty
                ? WakeOnLANConfiguration.defaultBroadcastAddress
                : broadcastAddress

            if !WakeOnLANService.isValidIPv4Address(resolvedBroadcastAddress) {
                return "Use an IPv4 broadcast address like 255.255.255.255."
            }
        }

        if settings.isDuplicateShare(urlString: draft.urlString, excluding: draft.id) {
            return "This network share address is already configured."
        }

        return nil
    }

    private var inferredDisplayName: String? {
        guard let normalizedURLString = normalizedNetworkURLString(from: draft.urlString) else { return nil }
        return NetworkShare.inferredShareName(from: normalizedURLString)
    }

    private var inferredMountPath: String {
        guard let normalizedURLString = normalizedNetworkURLString(from: draft.urlString) else {
            return "/Volumes/OtterNAS"
        }

        return NetworkShare.defaultMountPath(
            displayName: resolvedDisplayName(for: normalizedURLString),
            urlString: normalizedURLString
        )
    }

    private func resolvedDisplayName(for normalizedURLString: String) -> String {
        let trimmedName = draft.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty {
            return trimmedName
        }

        return NetworkShare.inferredShareName(from: normalizedURLString) ?? "Share"
    }

    private func normalizedNetworkURLString(from rawValue: String) -> String? {
        guard var components = networkURLComponents(from: rawValue),
              !components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty
        else { return nil }

        components.scheme = components.scheme?.lowercased()
        return components.string
    }

    private func networkURLComponents(from rawValue: String) -> URLComponents? {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)

        if value.hasPrefix("//") {
            value = "smb:\(value)"
        } else if !value.contains("://") {
            value = "smb://\(value)"
        }

        guard var components = URLComponents(string: value),
              NetworkShareProtocol(urlScheme: components.scheme) != nil,
              let host = components.host?.trimmingCharacters(in: .whitespacesAndNewlines),
              !host.isEmpty
        else {
            return nil
        }

        components.scheme = components.scheme?.lowercased()
        components.host = host
        return components
    }

}
