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
                        }

                        Button {
                            refreshMountedShares()
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
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
                        .buttonStyle(.bordered)
                        .controlSize(.small)
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
                    Toggle("Limit connections to home network or VPN", isOn: Binding(
                        get: { draft.usesWiFiNetworkRule },
                        set: { newValue in
                            draft.usesWiFiNetworkRule = newValue
                            if newValue {
                                if draft.wifiNetworkName.isEmpty, let currentSSID = networkService.currentWiFiNetworkName {
                                    draft.wifiNetworkName = currentSSID
                                }
                                draft.usesVPNRule = true
                                draft.matchesAnyVPN = true
                            } else {
                                draft.usesVPNRule = false
                                draft.wifiNetworkName = ""
                                draft.vpnName = ""
                                draft.matchesAnyVPN = false
                            }
                        }
                    ))
                    
                    if draft.usesWiFiNetworkRule {
                        VStack(alignment: .leading, spacing: 6) {
                            if !draft.wifiNetworkName.isEmpty {
                                LabeledContent("Home Wi-Fi", value: draft.wifiNetworkName)
                            } else {
                                LabeledContent("Home Wi-Fi", value: "Not registered")
                                Text("Connect to your home Wi-Fi while configuring to automatically register it.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            
                            Toggle("Require specific VPN profile", isOn: Binding(
                                get: { !draft.matchesAnyVPN },
                                set: { newValue in
                                    draft.matchesAnyVPN = !newValue
                                    if !newValue {
                                        draft.vpnName = ""
                                    }
                                }
                            ))
                            .font(.subheadline)
                            .padding(.top, 4)
                            
                            if !draft.matchesAnyVPN {
                                VStack(alignment: .leading, spacing: 4) {
                                    if networkService.knownVPNNames.isEmpty {
                                        TextField("VPN profile name", text: $draft.vpnName, prompt: Text("Office VPN"))
                                            .textFieldStyle(.roundedBorder)
                                    } else {
                                        Picker("VPN Profile", selection: vpnSelection) {
                                            Text("Choose VPN...").tag(VPNNameSelection.none)
                                            
                                            ForEach(networkService.knownVPNNames, id: \.self) { vpnName in
                                                Text(vpnName).tag(VPNNameSelection.known(vpnName))
                                            }
                                            
                                            Text("Other...").tag(VPNNameSelection.custom)
                                        }
                                        .pickerStyle(.menu)
                                        
                                        if vpnSelection.wrappedValue == .custom {
                                            TextField("VPN name", text: $draft.vpnName, prompt: Text("Other VPN"))
                                                .textFieldStyle(.roundedBorder)
                                        }
                                    }
                                }
                                .padding(.leading, 12)
                            }
                            
                            Text("Ethernet and allowed VPN connections are trusted.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .padding(.top, 2)
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
                Button("Cancel") {
                    onCancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Done") {
                    save()
                }
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
        
        if NetworkShare.checkKeychainHasCredentials(for: host) {
            return true
        }
        if let cachedIP = draft.cachedIPAddress, NetworkShare.checkKeychainHasCredentials(for: cachedIP) {
            return true
        }
        return false
    }

    private var isEditing: Bool {
        sourceShare != nil
    }

    private enum NetworkConstraint: Hashable {
        case any
        case wifi
    }

    private var networkConstraintBinding: Binding<NetworkConstraint> {
        Binding {
            draft.usesWiFiNetworkRule ? .wifi : .any
        } set: { constraint in
            draft.usesWiFiNetworkRule = (constraint == .wifi)
        }
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
            if usesCustomVPNName {
                return .custom
            }

            if draft.vpnName.isEmpty {
                return .none
            }

            if networkService.knownVPNNames.contains(draft.vpnName) {
                return .known(draft.vpnName)
            }

            return .custom
        } set: { selection in
            switch selection {
            case .none:
                usesCustomVPNName = false
                draft.vpnName = ""
            case let .known(vpnName):
                usesCustomVPNName = false
                draft.vpnName = vpnName
            case .custom:
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
            } else {
                Button {
                    openLocationPrivacySettings()
                } label: {
                    Label("Open Location Settings", systemImage: "gearshape")
                }
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

    private func useCurrentWiFiNetwork() {
        Task {
            await networkService.refreshNetworkDetailsNow()
            guard let networkName = networkService.currentWiFiNetworkName else { return }
            draft.wifiNetworkName = networkName
        }
    }

    private func useCurrentVPN() {
        Task {
            await networkService.refreshNetworkDetailsNow()

            // Without a name to match, the only rule that can work is "any VPN".
            guard let vpnName = networkService.activeVPNNames.first else {
                if networkService.isVPNConnected {
                    draft.matchesAnyVPN = true
                }
                return
            }

            draft.matchesAnyVPN = false
            draft.vpnName = vpnName
            usesCustomVPNName = !networkService.knownVPNNames.contains(vpnName)
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

        if draft.usesWiFiNetworkRule && draft.wifiNetworkName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Add a Wi-Fi network name, or turn off the network rule."
        }

        if draft.usesVPNRule && !draft.matchesAnyVPN && draft.vpnName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Choose a VPN, or match any VPN."
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

    private var currentWiFiNetworkLabel: String {
        networkService.currentWiFiNetworkName ?? "Unavailable"
    }

    private var currentVPNLabel: String {
        networkService.currentVPNDisplayName
    }
}

private struct MountedShareSuggestion: Identifiable, Hashable {
    var id: String { mountPath }

    let displayName: String
    let urlString: String
    let mountPath: String

    static func discover() -> [MountedShareSuggestion] {
        let fileManager = FileManager.default
        let keys = resourceKeys

        guard let volumeURLs = fileManager.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys), options: []) else {
            return []
        }

        return volumeURLs
            .compactMap { try? make(from: $0) }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    static func make(from selectedURL: URL) throws -> MountedShareSuggestion {
        let values = try selectedURL.resourceValues(forKeys: resourceKeys)
        let volumeURL = values.volume ?? selectedURL
        let volumeValues = try volumeURL.resourceValues(forKeys: resourceKeys)
        let remountURL = values.volumeURLForRemounting ?? volumeValues.volumeURLForRemounting

        guard let remountURL else {
            throw MountedShareSuggestionError.notNetworkShare
        }

        guard let urlString = sanitizedSMBURLString(from: remountURL) else {
            throw MountedShareSuggestionError.notSMBShare
        }

        let displayName = values.volumeLocalizedName
            ?? volumeValues.volumeLocalizedName
            ?? values.volumeName
            ?? volumeValues.volumeName
            ?? volumeURL.lastPathComponent

        return MountedShareSuggestion(
            displayName: displayName,
            urlString: urlString,
            mountPath: volumeURL.standardizedFileURL.resolvingSymlinksInPath().path
        )
    }

    private static var resourceKeys: Set<URLResourceKey> {
        [
            .volumeURLKey,
            .volumeURLForRemountingKey,
            .volumeLocalizedNameKey,
            .volumeNameKey
        ]
    }

    private static func sanitizedSMBURLString(from url: URL) -> String? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "smb",
              components.host?.isEmpty == false,
              !components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty
        else {
            return nil
        }

        components.scheme = "smb"
        components.user = nil
        components.password = nil
        return components.string
    }
}

private enum VPNNameSelection: Hashable {
    case none
    case known(String)
    case custom
}

private enum MountedShareSuggestionError: LocalizedError {
    case notNetworkShare
    case notSMBShare

    var errorDescription: String? {
        switch self {
        case .notNetworkShare:
            "Choose a mounted network share."
        case .notSMBShare:
            "Choose a mounted SMB share."
        }
    }
}

private struct DraftShare {
    var id: UUID?
    var displayName: String
    var urlString: String
    var mountPath: String
    var keepMounted: Bool
    var mountAtLaunch: Bool
    var cachedIPAddress: String?
    var autoConnectWhenReachable: Bool
    var wakeOnLANEnabled: Bool
    var wakeOnLANMACAddress: String
    var wakeOnLANBroadcastAddress: String
    var wakeOnLANPort: Int
    var usesWiFiNetworkRule: Bool
    var wifiNetworkName: String
    var wifiNetworkAction: ShareRuleAction
    var usesVPNRule: Bool
    var matchesAnyVPN: Bool
    var vpnName: String
    var vpnAction: ShareRuleAction
    var createdAt: Date?

    init(share: NetworkShare?) {
        id = share?.id
        displayName = share?.displayName ?? ""
        urlString = share?.urlString ?? ""
        mountPath = share?.mountPath ?? ""
        keepMounted = share?.keepMounted ?? true
        mountAtLaunch = share?.mountAtLaunch ?? true
        cachedIPAddress = share?.cachedIPAddress
        autoConnectWhenReachable = share?.autoConnectWhenReachable ?? false
        wakeOnLANEnabled = share?.wakeOnLAN.isEnabled ?? false
        wakeOnLANMACAddress = share?.wakeOnLAN.macAddress ?? ""
        wakeOnLANBroadcastAddress = share?.wakeOnLAN.broadcastAddress ?? WakeOnLANConfiguration.defaultBroadcastAddress
        wakeOnLANPort = share?.wakeOnLAN.port ?? WakeOnLANConfiguration.defaultPort
        usesWiFiNetworkRule = share?.rules.hasWiFiNetworkRule ?? false
        wifiNetworkName = share?.rules.wifiNetworkName ?? ""
        wifiNetworkAction = share?.rules.wifiNetworkAction ?? .connect
        usesVPNRule = share?.rules.hasVPNRule ?? false
        matchesAnyVPN = share?.rules.hasVPNRule == true ? share?.rules.requiredVPNName == nil : true
        vpnName = share?.rules.vpnName ?? ""
        vpnAction = share?.rules.vpnAction ?? .connect
        createdAt = share?.createdAt
    }

    var rules: ShareRules {
        ShareRules(
            wifiNetworkName: usesWiFiNetworkRule ? wifiNetworkName : "",
            wifiNetworkAction: wifiNetworkAction,
            vpnRuleEnabled: usesVPNRule,
            vpnName: usesVPNRule && !matchesAnyVPN ? vpnName : "",
            vpnAction: vpnAction
        )
    }

    var wakeOnLAN: WakeOnLANConfiguration {
        WakeOnLANConfiguration(
            isEnabled: wakeOnLANEnabled,
            macAddress: wakeOnLANMACAddress,
            broadcastAddress: wakeOnLANBroadcastAddress,
            port: wakeOnLANPort
        )
    }
}
