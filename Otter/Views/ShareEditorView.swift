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
    @State private var isShowingFinderImportHelp = false
    @State private var isShowingAdvanced = false
    @State private var readinessReport: ConnectionDiagnosticReport?
    @State private var isTestingSetup = false
    @State private var isVerifyingVPN = false
    @State private var vpnVerification: VPNVerificationResult?
    @State private var provisionalShareID = UUID()
    @State private var browsingServerID: DiscoveredSMBServer.ID?
    @State private var shareBrowserMessage: String?

    private let sourceShare: NetworkShare?
    let onSave: (NetworkShare) -> Void
    let onCancel: () -> Void

    init(
        share: NetworkShare?,
        onSave: @escaping (NetworkShare) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.sourceShare = share
        _draft = State(initialValue: DraftShare(share: share))
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(isEditing ? "Settings" : "New Share")
                    .font(.title2)
                    .fontWeight(.bold)
                if isEditing {
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
                    Section {
                        if mountedShareSuggestions.isEmpty {
                            Button {
                                chooseMountedShare()
                            } label: {
                                Label("Select a mounted volume...", systemImage: "externaldrive.badge.plus")
                            }
                            .tahoeSecondaryActionButton()
                        } else {
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

                            Button {
                                chooseMountedShare()
                            } label: {
                                Label("Choose Other...", systemImage: "folder")
                            }
                            .tahoeSecondaryActionButton()
                        }

                        Button {
                            refreshMountedShares()
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        .tahoeSecondaryActionButton()
                    } header: {
                        finderSectionHeader
                    }

                    if !discovery.servers.isEmpty || discovery.state == .searching {
                        Section("Nearby SMB Servers") {
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
                                                Text("Browse Shares\u{2026}")
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                    }
                                    .disabled(browsingServerID != nil)
                                }
                            }

                            if let shareBrowserMessage {
                                Text(shareBrowserMessage)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("macOS will show the server's shares and handle sign-in. Save the password to Keychain when prompted.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                // General Section
                Section("General") {
                    TextField("Share name", text: $draft.displayName, prompt: Text(inferredDisplayName ?? "Dawn"))
                    TextField("Server address", text: $draft.urlString, prompt: Text("smb://server.local/Dawn"))
                    TextField("Share path", text: $draft.mountPath, prompt: Text(inferredMountPath))
                    LabeledContent("Protocol", value: "SMB")
                    
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

                // Automation Section
                Section("Automation") {
                    Toggle("Reconnect automatically", isOn: $draft.keepMounted)
                    Toggle("Mount at login", isOn: $draft.mountAtLaunch)
                    Toggle("Connect when server becomes available", isOn: $draft.autoConnectWhenReachable)
                    Toggle("Wake server automatically", isOn: $draft.wakeOnLANEnabled)
                    
                    if draft.wakeOnLANEnabled {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Send a Wake-on-LAN packet before attempting to connect.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            
                            TextField("MAC address", text: $draft.wakeOnLANMACAddress, prompt: Text("AA:BB:CC:DD:EE:FF"))
                            TextField(
                                "Broadcast address",
                                text: $draft.wakeOnLANBroadcastAddress,
                                prompt: Text(WakeOnLANConfiguration.defaultBroadcastAddress)
                            )
                            
                            Stepper(value: $draft.wakeOnLANPort, in: 1...65_535, step: 1) {
                                Text("Port: \(draft.wakeOnLANPort)")
                            }
                        }
                        .padding(.leading, 20)
                    }
                }

                // Conditions Section
                Section("Conditions") {
                    Toggle("Only connect on the registered network", isOn: Binding(
                        get: { draft.limitsToRegisteredNetwork },
                        set: { isOn in
                            draft.limitsToRegisteredNetwork = isOn
                            if isOn {
                                registerCurrentNetworkIfNeeded()
                            } else {
                                draft.registeredSubnets = []
                                draft.wifiNetworkName = ""
                            }
                        }
                    ))

                    if draft.limitsToRegisteredNetwork {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Otter registers the network this share was set up on and only connects when your Mac is back on that network — Wi-Fi or Ethernet.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)

                            HStack(spacing: 8) {
                                LabeledContent(
                                    "Registered network",
                                    value: draft.registeredSubnets.isEmpty ? "None" : draft.registeredSubnets.joined(separator: ", ")
                                )

                                if !networkService.currentIPv4Subnets.isEmpty && networkService.currentIPv4Subnets != draft.registeredSubnets {
                                    Button {
                                        registerCurrentNetwork()
                                    } label: {
                                        Label(
                                            draft.registeredSubnets.isEmpty ? "Register Current Network" : "Re-register",
                                            systemImage: "location"
                                        )
                                    }
                                    .tahoeCompactActionButton()
                                }
                            }

                            HStack(spacing: 8) {
                                TextField("Wi-Fi name", text: $draft.wifiNetworkName, prompt: Text("Optional"))

                                if let currentSSID = networkService.currentWiFiNetworkName, currentSSID != draft.wifiNetworkName {
                                    Button {
                                        draft.wifiNetworkName = currentSSID
                                    } label: {
                                        Label("Use Current", systemImage: "location.fill")
                                    }
                                    .tahoeCompactActionButton()
                                }
                            }

                            Text("The Wi-Fi name is an extra way to recognize the registered network, useful if the router hands out a different subnet later.")
                                .font(.footnote)
                                .foregroundStyle(.tertiary)

                            if draft.registeredSubnets.isEmpty && draft.wifiNetworkName.isEmpty && networkService.wifiNameRequiresLocationPermission {
                                locationPermissionNotice
                            }
                        }
                        .padding(.leading, 20)
                    }

                    Toggle("Connect through a VPN", isOn: Binding(
                        get: { draft.usesVPNRule },
                        set: { isOn in
                            draft.usesVPNRule = isOn
                            if !isOn {
                                draft.vpnName = ""
                            }
                        }
                    ))

                    if draft.usesVPNRule {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Choose the specific VPN required to access this server. Otter connects it automatically when macOS allows it.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)

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
                            .padding(.top, 4)

                            if vpnSelection.wrappedValue == .custom {
                                Text("This saved VPN is no longer available. Choose another VPN from System Settings.")
                                    .font(.footnote)
                                    .foregroundStyle(.orange)
                            } else if vpnSelection.wrappedValue == .unconfigured {
                                Text("Select a VPN to enable this condition.")
                                    .font(.footnote)
                                    .foregroundStyle(.orange)
                            } else {
                                Text(vpnRuleDescription)
                                    .font(.footnote)
                                    .foregroundStyle(.tertiary)
                            }

                            if !draft.vpnName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
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
                        .padding(.leading, 20)
                    }
                }

                // Credentials Section
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

                    Text("Checks the network, named VPN, credentials, SMB service, and mount. macOS may ask you to sign in or choose a share.")
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
            }
        }
        .onChange(of: networkService.currentWiFiNetworkName) {
            fillDraftFromCurrentNetwork()
        }
        .onChange(of: networkService.currentIPv4Subnets) {
            fillDraftFromCurrentNetwork()
        }
        .onDisappear {
            if !isEditing {
                discovery.stop()
            }
        }
    }

    private var finderSectionHeader: some View {
        HStack(spacing: 6) {
            Text("Quick Start: Auto-Fill from Finder")

            Button {
                isShowingFinderImportHelp.toggle()
            } label: {
                Image(systemName: "info.circle")
                    .imageScale(.small)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("About auto-filling shares")
            .accessibilityLabel("About auto-filling shares")
            .popover(isPresented: $isShowingFinderImportHelp, arrowEdge: .trailing) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Choose a mounted SMB share to automatically populate the name, network address, and Finder path fields.")
                    Text("Nothing changes until you click Save.")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
                .padding(14)
                .frame(width: 260, alignment: .leading)
            }
        }
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
            case let .known(vpnName):
                draft.vpnName = vpnName
            case .custom:
                break
            }
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
            return "Connect to this VPN when Otter asks. The share mounts automatically when the VPN becomes active."
        }

        return draft.limitsToRegisteredNetwork
            ? "When the registered network is unavailable, Otter connects this VPN before mounting. No other VPN satisfies this rule."
            : "Otter connects this VPN before mounting. No other VPN satisfies this rule."
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

    private func apply(_ suggestion: MountedShareSuggestion) {
        draft.displayName = suggestion.displayName
        draft.urlString = suggestion.urlString
        draft.mountPath = suggestion.mountPath
        validationMessage = nil
    }

    private func browseShares(on server: DiscoveredSMBServer) {
        guard browsingServerID == nil else { return }
        browsingServerID = server.id
        shareBrowserMessage = nil

        Task {
            do {
                let suggestions = try await appModel.shareBrowserService.browse(server)
                if suggestions.isEmpty {
                    shareBrowserMessage = "No share was selected."
                } else {
                    let merged = Set(mountedShareSuggestions).union(suggestions)
                    mountedShareSuggestions = merged.sorted {
                        $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
                    }
                    if suggestions.count == 1, let suggestion = suggestions.first {
                        apply(suggestion)
                    }
                    shareBrowserMessage = "Selected \(suggestions.count) share\(suggestions.count == 1 ? "" : "s")."
                }
            } catch {
                shareBrowserMessage = "Couldn't browse this server: \(error.localizedDescription)"
            }
            browsingServerID = nil
        }
    }

    private func registerCurrentNetwork() {
        draft.registeredSubnets = networkService.currentIPv4Subnets
        if let currentSSID = networkService.currentWiFiNetworkName {
            draft.wifiNetworkName = currentSSID
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
        guard let normalizedURLString = normalizedSMBURLString(from: draft.urlString) else { return nil }
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
        guard let components = smbURLComponents(from: draft.urlString) else {
            return "Use a network address like smb://server.local/Dawn."
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
        guard let normalizedURLString = normalizedSMBURLString(from: draft.urlString) else { return nil }
        return NetworkShare.inferredShareName(from: normalizedURLString)
    }

    private var inferredMountPath: String {
        guard let normalizedURLString = normalizedSMBURLString(from: draft.urlString) else {
            return "/Volumes/Dawn"
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

    private func normalizedSMBURLString(from rawValue: String) -> String? {
        guard var components = smbURLComponents(from: rawValue),
              !components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty
        else { return nil }

        components.scheme = "smb"
        return components.string
    }

    private func smbURLComponents(from rawValue: String) -> URLComponents? {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)

        if value.hasPrefix("//") {
            value = "smb:\(value)"
        } else if !value.lowercased().hasPrefix("smb://") {
            value = "smb://\(value)"
        }

        guard var components = URLComponents(string: value),
              components.scheme?.lowercased() == "smb",
              let host = components.host?.trimmingCharacters(in: .whitespacesAndNewlines),
              !host.isEmpty
        else {
            return nil
        }

        components.scheme = "smb"
        components.host = host
        return components
    }

}
