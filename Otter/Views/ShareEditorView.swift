import AppKit
import SwiftUI

struct ShareEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var networkService: NetworkReachabilityService
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var discovery: SMBDiscoveryService
    @State private var draft: DraftShare
    @State private var validationIssue: ValidationIssue?
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
    @State private var stage: EditorStage
    @State private var isShowingSavedConnectionHelp = false
    @FocusState private var focusedField: ValidationField?

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
        // Adding a share starts by choosing one. Editing, or arriving with a
        // share already picked, skips straight to its settings.
        _stage = State(initialValue: share == nil && prefill == nil ? .discovery : .configure)

        self.onSave = onSave
        self.onCancel = onCancel
    }

    private enum EditorStage: Hashable {
        case discovery
        case configure
        case advanced
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            ScrollViewReader { proxy in
                Group {
                    switch stage {
                    case .discovery:
                        discoveryForm
                    case .configure:
                        configureForm
                    case .advanced:
                        advancedForm
                    }
                }
                .formStyle(.grouped)
                .onChange(of: validationIssue) { _, issue in
                    guard let issue else { return }
                    revealField(issue.field, using: proxy)
                }
            }

            Divider()

            actionBar
        }
        .frame(width: 540)
        // Let the sheet follow its content. The scrollable form still keeps
        // longer saved-connection lists and advanced settings within a
        // sensible sheet height.
        .frame(maxHeight: 720)
        .onAppear {
            resetDraftIfNeeded()
            networkService.refreshNetworkDetails()
            if stage == .discovery {
                refreshMountedShares()
                discovery.start()
                refreshSavedSMBShares()
            }
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

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let backTitle = backNavigationTitle {
                Button {
                    navigate(to: stage == .advanced ? .configure : .discovery)
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.backward")
                            .font(.callout.weight(.semibold))
                        Text(backTitle)
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }

            switch stage {
            case .discovery:
                Text("Add Share")
                    .font(.title2)
                    .fontWeight(.bold)
            case .configure:
                VStack(alignment: .leading, spacing: 1) {
                    Text(headerTitle)
                        .font(.title2)
                        .fontWeight(.bold)

                    if let headerSubtitle {
                        Text(headerSubtitle)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            case .advanced:
                Text("Advanced")
                    .font(.title2)
                    .fontWeight(.bold)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private var actionBar: some View {
        HStack {
            Button("Cancel") {
                cancel()
            }
            .tahoeSecondaryActionButton()
            .keyboardShortcut(.cancelAction)

            Spacer()

            // Nothing has been chosen yet on the discovery screen, so there is
            // no action to confirm.
            if stage != .discovery {
                Button(confirmationTitle) {
                    save()
                }
                .tahoePrimaryActionButton()
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var backNavigationTitle: String? {
        switch stage {
        case .discovery:
            nil
        case .configure:
            isEditing || appliesToShareCount != nil ? nil : "Available Shares"
        case .advanced:
            headerTitle
        }
    }

    private var headerTitle: String {
        if let appliesToShareCount {
            return "Settings for \(appliesToShareCount) Shares"
        }

        let trimmedName = draft.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty {
            return trimmedName
        }

        return inferredDisplayName ?? (isEditing ? "Settings" : "New Share")
    }

    private var headerSubtitle: String? {
        guard appliesToShareCount == nil else { return nil }

        let trimmedURL = draft.urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedURL.isEmpty ? nil : trimmedURL
    }

    private func navigate(to destination: EditorStage) {
        guard stage != destination else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            stage = destination
        }
    }

    private var confirmationTitle: String {
        isEditing ? "Done" : "Add Share"
    }

    // MARK: - Discovery

    private var discoveryForm: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                availableSharesSection
                quickActions

                Divider()

                savedConnectionsSection
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
        }
    }

    private var availableSharesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Available Shares")

            if shareBrowserServers.isEmpty {
                HStack(spacing: 8) {
                    if discovery.state == .searching {
                        ProgressView()
                            .controlSize(.small)
                        Text("Searching the local network…")
                    } else {
                        Text("No SMB servers found on this network.")
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.vertical, 8)
            } else {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(shareBrowserServers) { server in
                        serverGroup(server)
                    }
                }

                if discovery.state == .searching {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Still searching…")
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }

            if let shareBrowserMessage {
                Text(shareBrowserMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var quickActions: some View {
        HStack(spacing: 10) {
            discoveryAction(
                title: "Choose Mounted Volume…",
                subtitle: "Add from an already mounted volume",
                image: "folder"
            ) {
                chooseMountedShare()
            }

            discoveryAction(
                title: "Refresh",
                subtitle: "Scan for available shares",
                image: "arrow.clockwise"
            ) {
                refreshMountedShares()
                discovery.restart()
            }
        }
    }

    private var savedConnectionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionTitle("Saved Connections")

                Spacer()

                Button {
                    refreshSavedSMBShares()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh saved connections")
                .accessibilityLabel("Refresh saved connections")
                .disabled(isRefreshingSavedSMBShares)

                Button {
                    isShowingSavedConnectionHelp.toggle()
                } label: {
                    Image(systemName: "info.circle")
                }
                .buttonStyle(.borderless)
                .help("About saved connections")
                .accessibilityLabel("About saved connections")
                .popover(isPresented: $isShowingSavedConnectionHelp, arrowEdge: .bottom) {
                    Text("Connections you have signed into before. Passwords and usernames stay in Keychain — Otter only checks whether a server is reachable after you choose one.")
                        .font(.callout)
                        .frame(width: 260, alignment: .leading)
                        .padding(12)
                }
            }

            if isRefreshingSavedSMBShares {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Checking Keychain…")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.vertical, 8)
            } else if savedSMBShares.isEmpty {
                VStack(spacing: 4) {
                    Image(systemName: "bookmark")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                    Text("No saved connections")
                        .font(.callout.weight(.medium))
                    Text("Saved connections will appear here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 78)
                .accessibilityElement(children: .combine)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(savedSMBShares.enumerated()), id: \.element.id) { index, savedShare in
                        savedConnectionRow(savedShare)

                        if index < savedSMBShares.count - 1 {
                            Divider()
                                .padding(.leading, 28)
                        }
                    }
                }
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.headline)
    }

    private func discoveryAction(
        title: String,
        subtitle: String,
        image: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: image)
                    .font(.title3)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.callout.weight(.medium))
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.roundedRectangle)
        .controlSize(.large)
    }

    private func savedConnectionRow(_ savedShare: SavedSMBShare) -> some View {
        Button {
            browseShares(using: savedShare)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "externaldrive.fill")
                    .foregroundStyle(.secondary)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text(savedShare.displayName)
                        .font(.callout.weight(.medium))
                    Text(savedShare.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if browsingSavedShareID == savedShare.id {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text(savedShare.hasSharePath ? "Mount" : "Browse Shares…")
                        .foregroundStyle(.secondary)
                    rowChevron
                }
            }
            .padding(.vertical, 9)
        }
        .buttonStyle(.plain)
        .disabled(isBrowsingShares)
        .accessibilityLabel("\(savedShare.hasSharePath ? "Mount" : "Browse shares on") \(savedShare.displayName)")
    }

    // MARK: - Configure

    private var configureForm: some View {
        Form {
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

                if draft.automaticConnectionMode == .manual {
                    Toggle("Mount once when Otter starts", isOn: $draft.mountAtLaunch)
                }

            }

            Section("Remote Access") {
                vpnConfiguration
                    .id(ValidationField.vpn)
            }

            Section {
                Button {
                    navigate(to: .advanced)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Advanced")
                            Text(advancedSummary)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        rowChevron
                    }
                }
            }

            if isEditing && appliesToShareCount == nil {
                diagnosticsSections
            }
        }
    }

    private var advancedSummary: String {
        if appliesToShareCount != nil {
            return "Network access, Wake-on-LAN, health checks"
        }
        return "Share details, network access, Wake-on-LAN, health checks"
    }

    // MARK: - Advanced

    private var advancedForm: some View {
        Form {
            if appliesToShareCount == nil {
                Section("Share Details") {
                    TextField("Name", text: $draft.displayName, prompt: Text(inferredDisplayName ?? "OtterNAS"))
                        .focused($focusedField, equals: .shareName)
                        .id(ValidationField.shareName)

                    TextField("Network address", text: $draft.urlString, prompt: Text(selectedProtocol.exampleURL))
                        .focused($focusedField, equals: .address)
                        .id(ValidationField.address)
                    validationNotice(for: .address)

                    Picker("Protocol", selection: protocolSelection) {
                        ForEach(NetworkShareProtocol.allCases, id: \.self) { protocolKind in
                            Text(protocolKind.title).tag(protocolKind)
                        }
                    }

                    if isEditing {
                        Button {
                            chooseMountedShare()
                        } label: {
                            Label("Auto-fill details from Finder…", systemImage: "arrow.down.doc.fill")
                        }
                        .tahoeCompactActionButton()
                        .padding(.vertical, 2)
                    }
                }

            }

            Section("Wake-on-LAN") {
                wakeOnLANSettings
            }

            Section("Health Checks") {
                healthCheckSettings
            }
        }
    }

    @ViewBuilder
    private var wakeOnLANSettings: some View {
        Toggle("Wake this server before connecting", isOn: $draft.wakeOnLANEnabled)
            .id(ValidationField.wakeOnLAN)

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
            .tahoeCompactActionButton()
            .disabled(isDiscoveringWakeOnLANSettings)

            Text("Otter fills these in while the share is mounted. It cannot discover them over a VPN or after the server sleeps.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            if let wakeOnLANDiscoveryMessage {
                Text(wakeOnLANDiscoveryMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }

        validationNotice(for: .wakeOnLAN)
    }

    @ViewBuilder
    private var healthCheckSettings: some View {
        Toggle("Check mounted volume", isOn: $draft.healthCheck.isEnabled)

        Text("Otter periodically confirms the mounted volume responds. Enable this for important shares, especially backups, to catch disconnected or read-only volumes early.")
            .font(.footnote)
            .foregroundStyle(.secondary)

        if draft.healthCheck.isEnabled {
            Toggle("Require writable volume", isOn: $draft.healthCheck.requiresWritableVolume)
            TextField("Expected file (optional)", text: $draft.healthCheck.sentinelRelativePath, prompt: Text(".otter-health"))
        }
    }

    // MARK: - Diagnostics

    // Credentials and diagnostics describe a share that already exists. A new
    // share has nothing to report on yet, and running them would mount a share
    // the user can still cancel.
    @ViewBuilder
    private var diagnosticsSections: some View {
        Section("Credentials") {
            HStack(spacing: 8) {
                Image(systemName: hasKeychainCredentials ? "checkmark.circle.fill" : "minus.circle")
                    .foregroundStyle(hasKeychainCredentials ? .green : .secondary)
                Text(hasKeychainCredentials ? "Credentials found in macOS Keychain." : "No credentials found in macOS Keychain.")
                    .font(.subheadline)
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

        if let fallbackURL = fallbackURLString {
            Section("Fallback Address") {
                LabeledContent("Fallback IP", value: fallbackURL)

                if let host = hostFromURL, !NetworkShare.isIPAddress(host) {
                    Text("Otter caches this server's local IP while you are on the same network, then uses it over a VPN where mDNS names don't resolve. Give the server a static IP so the cached address stays valid.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var rowChevron: some View {
        Image(systemName: "chevron.forward")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func validationNotice(for field: ValidationField) -> some View {
        if let validationIssue, validationIssue.field == field {
            Label(validationIssue.message, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Scrolls the offending control into view and focuses it where it can take
    /// focus.
    private func revealField(_ field: ValidationField, using proxy: ScrollViewProxy) {
        navigate(to: stage(containing: field))

        // The destination screen may have just been swapped in, so let it mount
        // before asking the scroll view to find the row.
        Task { @MainActor in
            await Task.yield()
            withAnimation {
                proxy.scrollTo(field, anchor: .center)
            }

            switch field {
            case .shareName, .address:
                focusedField = field
            case .vpn, .wakeOnLAN:
                break
            }
        }
    }

    private func stage(containing field: ValidationField) -> EditorStage {
        switch field {
        case .vpn:
            .configure
        case .shareName, .address, .wakeOnLAN:
            .advanced
        }
    }

    private func cancel() {
        onCancel()
        dismiss()
    }

    /// One server and the shares Otter already knows about on it. Servers that
    /// have not been browsed yet appear with no nested shares — Otter cannot
    /// list a server's shares without mounting one, so browsing stays an
    /// explicit hand-off to Finder.
    private struct ShareBrowserServer: Identifiable {
        let id: String
        let name: String
        let shares: [MountedShareSuggestion]
        let discovered: DiscoveredSMBServer?

        var isNearby: Bool { discovered != nil }
    }

    private var shareBrowserServers: [ShareBrowserServer] {
        var unclaimed = mountedShareSuggestions
        var servers: [ShareBrowserServer] = []

        for discovered in discovery.servers {
            let matches = unclaimed.filter { $0.matches(server: discovered) }
            let matchedIDs = Set(matches.map(\.id))
            unclaimed.removeAll { matchedIDs.contains($0.id) }

            servers.append(
                ShareBrowserServer(
                    id: discovered.id,
                    name: discovered.name,
                    shares: sortedByName(matches),
                    discovered: discovered
                )
            )
        }

        // A mounted share whose server is not advertising itself right now
        // still needs a home, so group the leftovers by their own host.
        let groupedByHost = Dictionary(grouping: unclaimed) { suggestion in
            URL(string: suggestion.urlString)?.host(percentEncoded: false) ?? suggestion.displayName
        }

        for (host, shares) in groupedByHost {
            servers.append(
                ShareBrowserServer(
                    id: "host:\(host)",
                    name: host,
                    shares: sortedByName(shares),
                    discovered: nil
                )
            )
        }

        return servers.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func sortedByName(_ suggestions: [MountedShareSuggestion]) -> [MountedShareSuggestion] {
        suggestions.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    private var isBrowsingShares: Bool {
        browsingServerID != nil || browsingSavedShareID != nil
    }

    private func serverGroup(_ server: ShareBrowserServer) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            serverHeaderRow(server)

            if server.shares.isEmpty {
                Text(server.isNearby
                    ? "No shares mounted yet."
                    : "Not on this network right now.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 30)
                    .padding(.vertical, 4)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(server.shares.enumerated()), id: \.element.id) { index, share in
                        shareRow(share)

                        if index < server.shares.count - 1 {
                            Divider()
                                .padding(.leading, 30)
                        }
                    }
                }
            }
        }
    }

    private func serverHeaderRow(_ server: ShareBrowserServer) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "server.rack")
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(server.name)
                    .font(.subheadline.weight(.semibold))

                if server.isNearby {
                    Label("Online", systemImage: "circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                        .labelStyle(.titleAndIcon)
                }
            }

            Spacer()

            if browsingServerID == server.discovered?.id {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Browsing shares on \(server.name)")
            } else if let discovered = server.discovered {
                Button(server.shares.isEmpty ? "Browse Shares…" : "Browse Other Shares…") {
                    browseShares(on: discovered)
                }
                .tahoeCompactActionButton()
                .disabled(isBrowsingShares)
                .accessibilityLabel("Browse shares on \(server.name)")
            }
        }
    }

    private func shareRow(_ suggestion: MountedShareSuggestion) -> some View {
        let isAlreadyAdded = settings.isDuplicateShare(urlString: suggestion.urlString, excluding: draft.id)

        return HStack(spacing: 9) {
            Image(systemName: "externaldrive.fill")
                .foregroundStyle(.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(suggestion.displayName)
                    .font(.callout.weight(.medium))
                Text(suggestion.mountPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            if isAlreadyAdded {
                Text("Added")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("Already added")
            } else {
                Button("Add") {
                    apply(suggestion)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel("Add \(suggestion.displayName)")
            }
        }
        .padding(.vertical, 11)
        .help(suggestion.mountPath)
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
        validationIssue = nil
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
            return "Otter starts this VPN when needed to keep the share connected."
        }

        return "Otter waits for this VPN, then connects the share."
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
            validationIssue = ValidationIssue(field: .address, message: error.localizedDescription)
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
        validationIssue = nil

        // Choosing a share is what moves the add flow forward. When editing,
        // this is only auto-fill and the user stays where they are.
        if !isEditing {
            shareBrowserMessage = nil
            navigate(to: .configure)
        }
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

    private func save() {
        validationIssue = validate()
        guard validationIssue == nil, let share = makeShareFromDraft() else { return }

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
        validationIssue = validate()
        guard validationIssue == nil, let share = makeShareFromDraft() else { return }

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

    private func validate() -> ValidationIssue? {
        guard let components = networkURLComponents(from: draft.urlString) else {
            return ValidationIssue(
                field: .address,
                message: "Use an SMB, NFS, or WebDAV address such as smb://server.local/Share."
            )
        }

        if components.user != nil || components.password != nil {
            return ValidationIssue(field: .address, message: "Remove credentials from the address.")
        }

        if components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty {
            return ValidationIssue(field: .address, message: "Include the share name in the address.")
        }

        if draft.usesVPNRule {
            let vpnName = draft.vpnName.trimmingCharacters(in: .whitespacesAndNewlines)
            if vpnName.isEmpty {
                return ValidationIssue(
                    field: .vpn,
                    message: "Choose a VPN from System Settings, or turn off the VPN condition."
                )
            }
            if configuredSystemVPN(named: vpnName) == nil {
                return ValidationIssue(
                    field: .vpn,
                    message: "Choose a VPN that is available in System Settings."
                )
            }
        }

        if draft.wakeOnLANEnabled {
            if WakeOnLANConfiguration.normalizedMACAddress(draft.wakeOnLANMACAddress) == nil {
                return ValidationIssue(field: .wakeOnLAN, message: "Add a valid Wake-on-LAN MAC address.")
            }

            let broadcastAddress = draft.wakeOnLANBroadcastAddress
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedBroadcastAddress = broadcastAddress.isEmpty
                ? WakeOnLANConfiguration.defaultBroadcastAddress
                : broadcastAddress

            if !WakeOnLANService.isValidIPv4Address(resolvedBroadcastAddress) {
                return ValidationIssue(
                    field: .wakeOnLAN,
                    message: "Use an IPv4 broadcast address like 255.255.255.255."
                )
            }
        }

        if settings.isDuplicateShare(urlString: draft.urlString, excluding: draft.id) {
            return ValidationIssue(
                field: .address,
                message: "This network share address is already configured."
            )
        }

        return nil
    }

    private var inferredDisplayName: String? {
        guard let normalizedURLString = normalizedNetworkURLString(from: draft.urlString) else { return nil }
        return NetworkShare.inferredShareName(from: normalizedURLString)
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
