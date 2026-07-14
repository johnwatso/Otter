import AppKit
import SwiftUI

struct ShareEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var networkService: NetworkReachabilityService
    @EnvironmentObject private var settings: SettingsStore
    @State private var draft: DraftShare
    @State private var validationMessage: String?
    @State private var mountedShareSuggestions: [MountedShareSuggestion] = []
    @State private var isShowingFinderImportHelp = false
    @State private var isShowingAdvanced = false
    @State private var usesCustomVPNName = false

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
                                draft.vpnName = ""
                                draft.matchesAnyVPN = true
                                usesCustomVPNName = false
                            }
                        }
                    ))

                    if draft.limitsToRegisteredNetwork {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Otter registers the network this share was set up on. It connects when your Mac is back on that network — Wi-Fi or Ethernet — or while your VPN is active, and disconnects the share everywhere else.")
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

                            Picker("VPN", selection: vpnSelection) {
                                Text("Any VPN").tag(VPNNameSelection.any)

                                ForEach(networkService.knownVPNNames, id: \.self) { vpnName in
                                    Text(vpnName).tag(VPNNameSelection.known(vpnName))
                                }

                                Text("Other...").tag(VPNNameSelection.custom)
                            }
                            .pickerStyle(.menu)
                            .padding(.top, 4)

                            if vpnSelection.wrappedValue == .custom {
                                TextField("VPN name", text: $draft.vpnName, prompt: Text("Office VPN"))
                                    .textFieldStyle(.roundedBorder)
                                    .padding(.leading, 12)
                            }

                            if vpnSelection.wrappedValue != .any {
                                Text("Only this VPN will connect the share; other VPNs count as unregistered networks.")
                                    .font(.footnote)
                                    .foregroundStyle(.tertiary)
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

                if let validationMessage {
                    Section {
                        Text(validationMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            .padding(20)

            Divider()

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
            .padding(20)
        }
        .frame(width: 540)
        .onAppear {
            resetDraftIfNeeded()
            networkService.refreshNetworkDetails()
            if !isEditing {
                refreshMountedShares()
            }
        }
        .onChange(of: networkService.currentWiFiNetworkName) {
            fillDraftFromCurrentNetwork()
        }
        .onChange(of: networkService.currentIPv4Subnets) {
            fillDraftFromCurrentNetwork()
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
        usesCustomVPNName = !draft.vpnName.isEmpty && !networkService.knownVPNNames.contains(draft.vpnName)
        validationMessage = nil
    }

    private var vpnSelection: Binding<VPNNameSelection> {
        Binding {
            if draft.matchesAnyVPN {
                return .any
            }

            if usesCustomVPNName {
                return .custom
            }

            if networkService.knownVPNNames.contains(draft.vpnName) {
                return .known(draft.vpnName)
            }

            return .custom
        } set: { selection in
            switch selection {
            case .any:
                draft.matchesAnyVPN = true
                draft.vpnName = ""
                usesCustomVPNName = false
            case let .known(vpnName):
                draft.matchesAnyVPN = false
                draft.vpnName = vpnName
                usesCustomVPNName = false
            case .custom:
                draft.matchesAnyVPN = false
                usesCustomVPNName = true
            }
        }
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
        guard validationMessage == nil,
              let normalizedURLString = normalizedSMBURLString(from: draft.urlString)
        else { return }

        let now = Date()
        let displayName = resolvedDisplayName(for: normalizedURLString)
        let mountPath = NetworkShare.normalizedMountPath(
            draft.mountPath,
            displayName: displayName,
            urlString: normalizedURLString
        )
        let share = NetworkShare(
            id: draft.id ?? UUID(),
            displayName: displayName,
            urlString: normalizedURLString,
            mountPath: mountPath,
            keepMounted: draft.keepMounted,
            mountAtLaunch: draft.mountAtLaunch,
            autoConnectWhenReachable: draft.autoConnectWhenReachable,
            wakeOnLAN: draft.wakeOnLAN,
            rules: draft.rules,
            cachedIPAddress: draft.cachedIPAddress,
            createdAt: draft.createdAt ?? now,
            updatedAt: now
        )

        onSave(share)
        dismiss()
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

        if draft.limitsToRegisteredNetwork && !draft.matchesAnyVPN && draft.vpnName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Enter the VPN name, or choose Any VPN."
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
