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

            AdvancedPreferencesView()
                .tabItem {
                    PreferencesTabItem(tab: .advanced)
                }
                .tag(PreferencesTab.advanced)

            UpdatesPreferencesView()
                .tabItem {
                    PreferencesTabItem(tab: .updates)
                }
                .tag(PreferencesTab.updates)
        }
        .padding(.top, -2)
        // A fixed, compact height keeps the window from resizing between
        // tabs; each tab's form scrolls when it needs more room.
        .frame(width: 520, height: 360, alignment: .top)
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
    @State private var connectionDoctorShare: NetworkShare?
    @State private var shareToRemove: NetworkShare?
    @State private var isAskingPauseDuration = false
    @State private var collapsedServerIDs = Set<String>()
    @State private var renamingServerShare: NetworkShare?
    @State private var serverNameDraft = ""
    @State private var isShowingOnboarding = false
    @State private var editingServerShareIDs: [NetworkShare.ID] = []
    private var shares: [NetworkShare] {
        appModel.screenshotDemoShares ?? settings.shares
    }

    private var shareGroups: [NetworkShareServerGroup] {
        NetworkShareServerGroup.make(from: shares, serverNames: settings.preferences.serverNames)
    }

    /// A server with several shares always gets a heading; a lone share only
    /// does when the user asks to always see the server name.
    private func showsServerHeading(_ group: NetworkShareServerGroup) -> Bool {
        group.isGrouped || settings.preferences.alwaysShowServerName
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
                if let selectedServerGroup {
                    Button {
                        editAllShares(in: selectedServerGroup)
                    } label: {
                        Label("Edit All Shares…", systemImage: "gearshape")
                    }
                    .disabled(editableShares(in: selectedServerGroup).isEmpty)
                    .help("Edit every share on this server")
                } else {
                    Button {
                        if let selectedShare {
                            appModel.requestEditShare(selectedShare)
                        }
                    } label: {
                        Label("Share Settings…", systemImage: "gearshape")
                    }
                    .disabled(selectedShare.map { settings.isManagedShare(id: $0.id) } ?? true)
                    .help(selectedShare.map { settings.isManagedShare(id: $0.id) } == true
                          ? "This share is managed by your organization"
                          : "Share Settings")
                }

                Button {
                    isShowingActivityLog = true
                } label: {
                    Label("Activity Log", systemImage: "clock.arrow.circlepath")
                }
                .help("Activity Log")

                if let selectedServerGroup {
                    // Connection Doctor checks one share at a time; on a server
                    // let the user pick which one rather than disabling it.
                    Menu {
                        ForEach(selectedServerGroup.shares) { share in
                            Button(share.displayName) {
                                connectionDoctorShare = share
                            }
                        }
                    } label: {
                        Label("Diagnose", systemImage: "stethoscope")
                    }
                    .help("Diagnose a share")
                } else {
                    Button {
                        connectionDoctorShare = selectedShare
                    } label: {
                        Label("Diagnose", systemImage: "stethoscope")
                    }
                    .disabled(selectedShare == nil)
                    .help("Diagnose")
                }
            }
        }
        .sheet(isPresented: $isShowingActivityLog) {
            ActivityLogView(
                initialShareFilter: selectedShare?.id,
                includedShareIDs: selectedServerGroup.map { Set($0.shares.map(\.id)) },
                includedSharesLabel: selectedServerGroup?.serverName
            )
        }
        .confirmationDialog(
            "Remove “\(shareToRemove?.displayName ?? "Share")”?",
            isPresented: Binding(
                get: { shareToRemove != nil },
                set: { if !$0 { shareToRemove = nil } }
            ),
            presenting: shareToRemove
        ) { share in
            Button("Remove Share", role: .destructive) {
                removeShare(share)
            }
            Button("Cancel", role: .cancel) { }
        } message: { _ in
            Text("Otter will stop keeping this share connected. If it's mounted now, it stays mounted until you eject it.")
        }
        .alert(renameServerAlertTitle, isPresented: Binding(
            get: { renamingServerShare != nil },
            set: { if !$0 { renamingServerShare = nil } }
        )) {
            TextField("Server name", text: $serverNameDraft)
            Button("Save") {
                if let share = renamingServerShare {
                    settings.setCustomServerName(serverNameDraft, for: share)
                }
                renamingServerShare = nil
            }
            if let share = renamingServerShare, settings.customServerName(for: share) != nil {
                Button("Use Address Name", role: .destructive) {
                    settings.setCustomServerName(nil, for: share)
                    renamingServerShare = nil
                }
            }
            Button("Cancel", role: .cancel) { renamingServerShare = nil }
        } message: {
            Text("This name is shown only in Otter and applies to every share on this server. Its network address remains \(renamingServerShare?.host ?? "unchanged").")
        }
        .confirmationDialog(
            pauseDurationTitle,
            isPresented: $isAskingPauseDuration,
            titleVisibility: .visible
        ) {
            Button("Pause for 1 Hour") {
                Task { await disconnectSelectedShares(pausingUntil: Date().addingTimeInterval(60 * 60)) }
            }
            Button("Pause Until Tomorrow") {
                let calendar = Calendar.current
                let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date()))
                Task { await disconnectSelectedShares(pausingUntil: tomorrow) }
            }
            Button("Pause Until I Resume") {
                Task { await disconnectSelectedShares(pausingUntil: nil) }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Otter reconnects shares automatically. Choose how long to leave it paused.")
        }
        .sheet(item: $connectionDoctorShare) { share in
            ConnectionDoctorView(share: share)
        }
        .sheet(isPresented: $isShowingOnboarding) {
            OnboardingView { share in
                if let share {
                    selection = .share(share.id)
                }
            }
        }
        .sheet(item: $appModel.editorRequest) { request in
            let editingShare = share(for: request)

            ShareEditorView(
                share: editingShare,
                prefill: prefill(for: request),
                appliesToShareCount: editingServerShareIDs.isEmpty ? nil : editingServerShareIDs.count
            ) { savedShare in
                let isServerEdit = !editingServerShareIDs.isEmpty
                if settings.share(id: savedShare.id) == nil {
                    settings.addShare(savedShare)
                } else {
                    settings.updateShare(savedShare)
                }

                applyServerSettings(from: savedShare)

                if !isServerEdit {
                    selection = .share(savedShare.id)
                }
                appModel.editorRequest = nil
            } onCancel: {
                editingServerShareIDs.removeAll()
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
                appModel.sharesWindowDidAppear()
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

            presentRequestedOnboardingIfNeeded()
        }
        .onChange(of: appModel.screenshotDemoShares != nil) {
            selection = defaultSelection
        }
        .onChange(of: selectionValidationSignature) {
            validateSelection()
        }
        .onChange(of: appModel.shouldPresentOnboarding) { _, shouldPresent in
            presentRequestedOnboardingIfNeeded()
        }
        .onDisappear {
            if didRegisterWindowAppearance {
                didRegisterWindowAppearance = false
                appModel.preferencesWindowDidDisappear()
                appModel.sharesWindowDidDisappear()
            }
        }
    }

    private func presentRequestedOnboardingIfNeeded() {
        guard appModel.shouldPresentOnboarding else { return }
        isShowingOnboarding = true
        appModel.shouldPresentOnboarding = false
    }

    // A native sidebar list, so selection, material and focus rings follow the
    // system. A server is a collapsible, selectable heading for its shares.
    private var sidebar: some View {
        List(selection: $selection) {
            ForEach(shareGroups) { group in
                if showsServerHeading(group) {
                    DisclosureGroup(isExpanded: expansionBinding(for: group.id)) {
                        ForEach(group.shares) { share in
                            ShareListRow(share: share, isSelected: selection == .share(share.id))
                                .tag(ShareManagementSelection.share(share.id))
                                .contextMenu { shareContextMenu(share) }
                        }
                    } label: {
                        ServerListHeader(group: group, isSelected: selection == .server(group.id))
                    }
                    .tag(ShareManagementSelection.server(group.id))
                } else if let share = group.shares.first {
                    ShareListRow(share: share, isSelected: selection == .share(share.id))
                        .tag(ShareManagementSelection.share(share.id))
                        .contextMenu { shareContextMenu(share) }
                }
            }
        }
        .listStyle(.sidebar)
        .onDeleteCommand {
            if canRemoveSelectedShare { shareToRemove = selectedShare }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if !shares.isEmpty {
                    SidebarStatusFooter(shares: shares)
                }

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
                        shareToRemove = selectedShare
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

    @ViewBuilder
    private func shareContextMenu(_ share: NetworkShare) -> some View {
        let isConnected = monitor.status(for: share) == .connected
        let isManaged = settings.isManagedShare(id: share.id)

        if isConnected {
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: share.mountPath)])
            } label: {
                Label("Open in Finder", systemImage: "folder")
            }
            Button {
                Task { await monitor.disconnect(share, pauseAutomaticMounting: share.connectsAutomatically) }
            } label: {
                Label("Disconnect", systemImage: "eject")
            }
        } else {
            Button {
                Task { await monitor.mount(share) }
            } label: {
                Label("Connect", systemImage: "arrow.triangle.2.circlepath")
            }
        }

        Divider()

        Button {
            connectionDoctorShare = share
        } label: {
            Label("Diagnose…", systemImage: "stethoscope")
        }
        Button {
            appModel.requestEditShare(share)
        } label: {
            Label("Share Settings…", systemImage: "gearshape")
        }
        .disabled(isManaged)

        Divider()

        Button(role: .destructive) {
            shareToRemove = share
        } label: {
            Label("Remove Share…", systemImage: "trash")
        }
        .disabled(isManaged)
    }

    private func expansionBinding(for serverID: String) -> Binding<Bool> {
        Binding {
            !collapsedServerIDs.contains(serverID)
        } set: { isExpanded in
            if isExpanded {
                collapsedServerIDs.remove(serverID)
            } else {
                collapsedServerIDs.insert(serverID)
            }
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
                    Label("Add Share…", systemImage: "plus")
                }
                .tahoePrimaryActionButton()
            }
        } else if let selectedServerGroup {
            ServerDetailView(
                group: selectedServerGroup,
                onSelectShare: { share in
                    withAnimation(.easeInOut(duration: 0.18)) { selection = .share(share.id) }
                }
            ) { heroActions }
        } else if let selectedShare {
            ShareDetailView(share: selectedShare) { heroActions }
        } else {
            EmptyShareDetailView()
        }
    }

    /// The things to do with the selection, shown under its status. Connecting
    /// leads until everything is mounted, then Open in Finder takes over.
    @ViewBuilder
    private var heroActions: some View {
        let isServer = selectedServerGroup != nil

        if areAllSelectedSharesConnected {
            // A server's shares each have their own Open button, so the
            // server header doesn't repeat it.
            if !isServer {
                Button(action: showSelectedSharesInFinder) {
                    Label("Open in Finder", systemImage: "folder")
                }
                .tahoePrimaryActionButton()
                .help("Show in Finder")
            }
        } else {
            Button {
                Task { await mountSelectedShares() }
            } label: {
                Label(connectActionTitle, systemImage: "arrow.triangle.2.circlepath")
            }
            .tahoePrimaryActionButton()
            .disabled(selectedShares.isEmpty)
        }

        if canDisconnectSelectedShares {
            Button {
                if selectedSharesNeedPausePrompt {
                    isAskingPauseDuration = true
                } else {
                    Task { await disconnectSelectedShares(pausingUntil: nil) }
                }
            } label: {
                Label(isServer ? "Disconnect All" : "Disconnect", systemImage: "eject")
            }
            .tahoeSecondaryActionButton()
            .help(disconnectSelectedSharesHelp)
        }

        Menu {
            if !automaticSelectedShares.isEmpty {
                if areAllAutomaticSelectedSharesPaused {
                    Button {
                        Task { for share in automaticSelectedShares { await monitor.resume(share) } }
                    } label: {
                        Label("Resume Automatic Mounting", systemImage: "play.fill")
                    }
                } else {
                    Section("Pause Automatic Mounting") {
                        Button("For 1 Hour") {
                            pauseSelectedShares(until: Date().addingTimeInterval(60 * 60))
                        }
                        Button("Until Tomorrow") {
                            let calendar = Calendar.current
                            pauseSelectedShares(until: calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date())))
                        }
                        Button("Until I Resume") {
                            pauseSelectedShares(until: nil)
                        }
                    }
                }
                Divider()
            }

            if let selectedServerGroup {
                Button {
                    editAllShares(in: selectedServerGroup)
                } label: {
                    Label("Edit All Shares…", systemImage: "gearshape")
                }
                .disabled(editableShares(in: selectedServerGroup).isEmpty)
            } else if let selectedShare {
                Button {
                    appModel.requestEditShare(selectedShare)
                } label: {
                    Label("Share Settings…", systemImage: "gearshape")
                }
                .disabled(settings.isManagedShare(id: selectedShare.id))
            }

            if let representative = selectedShares.first {
                Button {
                    serverNameDraft = settings.customServerName(for: representative) ?? representative.serverDisplayName
                    renamingServerShare = representative
                } label: {
                    Label(
                        settings.customServerName(for: representative) == nil && representative.isAddressedByIP
                            ? "Add Server Name…" : "Rename Server…",
                        systemImage: "character.cursor.ibeam"
                    )
                }
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
                .frame(width: 20, height: 16)
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .tahoeSecondaryMenu()
        .help("More actions")
        .accessibilityLabel("More actions")
    }

    private var connectActionTitle: String {
        if selectedServerGroup != nil { return "Connect All" }
        let hasConnectedBefore = selectedShare.map { monitor.runtimeState(for: $0).lastConnectedAt != nil } ?? false
        return hasConnectedBefore ? "Reconnect" : "Connect"
    }

    /// Hosts the rename dialog so it can be opened from the actions menu.
    private var renameServerAlertTitle: String {
        guard let share = renamingServerShare else { return "Rename Server" }
        return settings.customServerName(for: share) == nil && share.isAddressedByIP ? "Add Server Name" : "Rename Server"
    }

    private var selectedShare: NetworkShare? {
        guard case let .share(id) = selection else { return nil }
        return shares.first { $0.id == id }
    }

    private var selectedServerGroup: NetworkShareServerGroup? {
        guard case let .server(id) = selection else { return nil }
        return shareGroups.first { $0.id == id && showsServerHeading($0) }
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

    private var mountSelectedSharesHelp: String {
        if areAllSelectedSharesConnected {
            return selectedServerGroup == nil ? "Already connected" : "All shares on this server are connected"
        }
        return selectedServerGroup == nil ? "Connect" : "Connect all shares on this server"
    }

    private var canDisconnectSelectedShares: Bool {
        selectedShares.contains { monitor.status(for: $0) == .connected }
    }

    private var selectedSharesUseAutomaticMounting: Bool {
        selectedShares.contains(where: { $0.connectsAutomatically })
    }

    /// Shares that reconnect on their own would simply come back, so
    /// disconnecting one asks how long Otter should leave it alone.
    private var selectedSharesNeedPausePrompt: Bool {
        selectedShares.contains { share in
            let current = settings.share(id: share.id) ?? share
            return current.connectsAutomatically && !current.pauseState.isActive()
        }
    }

    private var automaticSelectedShares: [NetworkShare] {
        selectedShares
            .map { settings.share(id: $0.id) ?? $0 }
            .filter(\.connectsAutomatically)
    }

    private var areAllAutomaticSelectedSharesPaused: Bool {
        !automaticSelectedShares.isEmpty && automaticSelectedShares.allSatisfy { $0.pauseState.isActive() }
    }

    private func pauseSelectedShares(until resumeAt: Date?) {
        let shares = automaticSelectedShares
        Task { for share in shares { await monitor.pause(share, until: resumeAt) } }
    }

    private var disconnectSelectedSharesHelp: String {
        let isGroup = selectedServerGroup != nil
        if selectedSharesNeedPausePrompt {
            return isGroup
                ? "Disconnect every share on this server and choose how long to pause automatic mounting"
                : "Disconnect and choose how long to pause automatic mounting"
        }
        return isGroup ? "Disconnect every share on this server" : "Disconnect this share"
    }

    private var pauseDurationTitle: String {
        if let selectedShare {
            return "Disconnect “\(selectedShare.displayName)”?"
        }
        return "Disconnect all shares on \(selectedServerGroup?.serverName ?? "this server")?"
    }

    private var canRemoveSelectedShare: Bool {
        guard let selectedShare else { return false }
        return settings.share(id: selectedShare.id) != nil
            && !settings.isManagedShare(id: selectedShare.id)
    }

    private func removeShare(_ share: NetworkShare) {
        guard let selectedIndex = settings.shares.firstIndex(where: { $0.id == share.id })
        else { return }

        settings.removeShare(id: share.id)
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

    private func prefill(for request: ShareEditorRequest) -> MountedShareSuggestion? {
        if case let .addDetected(suggestion) = request.mode {
            return suggestion
        }

        return nil
    }

    private func selectShare(for request: ShareEditorRequest) {
        guard editingServerShareIDs.isEmpty else { return }
        if case let .edit(id) = request.mode {
            selection = .share(id)
        }
    }

    private func editableShares(in group: NetworkShareServerGroup) -> [NetworkShare] {
        group.shares.filter { share in
            settings.share(id: share.id) != nil && !settings.isManagedShare(id: share.id)
        }
    }

    private func editAllShares(in group: NetworkShareServerGroup) {
        let editableShares = editableShares(in: group)
        guard let sourceShare = editableShares.first else { return }

        editingServerShareIDs = editableShares.map(\.id)
        appModel.editorRequest = ShareEditorRequest(mode: .edit(sourceShare.id))
    }

    private func applyServerSettings(from source: NetworkShare) {
        guard !editingServerShareIDs.isEmpty else { return }

        for shareID in editingServerShareIDs where shareID != source.id {
            settings.updateShare(id: shareID) { share in
                share.connectionMode = source.connectionMode
                share.wakeOnLAN = source.wakeOnLAN
                share.rules = source.rules
                share.healthCheck = source.healthCheck
            }
        }

        editingServerShareIDs.removeAll()
    }

    private var defaultSelection: ShareManagementSelection? {
        guard let firstGroup = shareGroups.first else { return nil }
        if showsServerHeading(firstGroup) {
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
            isValid = shareGroups.contains { $0.id == id && showsServerHeading($0) }
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

    private func disconnectSelectedShares(pausingUntil resumeAt: Date?) async {
        for share in selectedShares {
            if share.connectsAutomatically {
                await monitor.pause(
                    share,
                    until: resumeAt,
                    disconnect: monitor.status(for: share) == .connected
                )
            } else if monitor.status(for: share) == .connected {
                await monitor.disconnect(share, pauseAutomaticMounting: false)
            }
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

/// Overall health at a glance, mirroring what the menu bar icon reports, so
/// the sidebar's spare space answers "is everything OK?" without a click.
private struct SidebarStatusFooter: View {
    @EnvironmentObject private var monitor: ShareMonitor
    @EnvironmentObject private var networkService: NetworkReachabilityService
    let shares: [NetworkShare]

    var body: some View {
        let connectedCount = shares.filter { monitor.status(for: $0) == .connected }.count
        let allConnected = connectedCount == shares.count
        let noneConnected = connectedCount == 0

        HStack(alignment: .top, spacing: 8) {
            Image(systemName: allConnected ? "checkmark.circle.fill" : (noneConnected ? "minus.circle.fill" : "exclamationmark.circle.fill"))
                .foregroundStyle(allConnected ? Color.green : (noneConnected ? Color.secondary : Color.orange))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(allConnected
                     ? (shares.count == 1 ? "Share connected" : "All shares connected")
                     : (noneConnected ? "No shares connected" : "Some shares disconnected"))
                    .fontWeight(.medium)
                Text(networkService.isOnline
                     ? "\(connectedCount) of \(shares.count) mounted"
                     : "Network unavailable · \(connectedCount) of \(shares.count) mounted")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .font(.subheadline)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }
}

private struct ServerListHeader: View {
    @EnvironmentObject private var settings: SettingsStore
    let group: NetworkShareServerGroup
    let isSelected: Bool
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var monitor: ShareMonitor
    @State private var isRenaming = false
    @State private var draftName = ""

    var body: some View {
        Label {
            HStack(spacing: 6) {
                Text(group.serverName)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text("\(connectedCount)/\(group.shares.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
            }
        } icon: {
            Image(systemName: appModel.serverIcon(for: representativeShare))
                .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                .frame(width: 22)
        }
        .padding(.vertical, 3)
        .contextMenu {
            Button {
                draftName = settings.customServerName(for: representativeShare) ?? group.serverName
                isRenaming = true
            } label: {
                Label("Rename Server…", systemImage: "character.cursor.ibeam")
            }
        }
        .alert("Rename Server", isPresented: $isRenaming) {
            TextField("Server name", text: $draftName)
            Button("Save") {
                settings.setCustomServerName(draftName, for: representativeShare)
            }
            if settings.customServerName(for: representativeShare) != nil {
                Button("Use Address Name", role: .destructive) {
                    settings.setCustomServerName(nil, for: representativeShare)
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This name is shown only in Otter and applies to every share on this server. Its network address remains \(representativeShare.host ?? "unchanged").")
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue("\(connectedCount) of \(group.shares.count) connected")
    }

    private var connectedCount: Int {
        group.shares.filter { monitor.status(for: $0) == .connected }.count
    }

    private var representativeShare: NetworkShare {
        group.shares[0]
    }
}

private enum PreferencesTab: String, CaseIterable, Hashable, Identifiable {
    case general
    case advanced
    case updates

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general:
            "General"
        case .advanced:
            "Advanced"
        case .updates:
            "Updates"
        }
    }

    var systemImage: String {
        switch self {
        case .general:
            "gearshape"
        case .advanced:
            "wrench.and.screwdriver"
        case .updates:
            "arrow.clockwise.circle"
        }
    }
}

// A plain Label: the Settings scene draws the toolbar tab from it, so the
// system owns the icon size, spacing and weight.
private struct PreferencesTabItem: View {
    let tab: PreferencesTab

    var body: some View {
        Label(tab.title, systemImage: tab.systemImage)
    }
}

private struct GeneralPreferencesView: View {
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var loginItemService: LoginItemService
    @EnvironmentObject private var newShareDetector: NewShareDetectionService

    var body: some View {
        Form {
            Section {
                Picker("App Presence", selection: appPresenceBinding) {
                    ForEach(AppPresenceMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                SettingsSecondaryText(settings.preferences.appPresenceMode.detail)

                Toggle("Always show server name", isOn: alwaysShowServerNameBinding)
                SettingsSecondaryText("Show a server heading in the menu bar and share list even when it contains only one share.")

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
                        .foregroundStyle(Color.warningText)
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
                Toggle("Offer to manage newly mounted shares", isOn: detectNewSharesBinding)
                SettingsSecondaryText("When a share is mounted outside Otter while Otter is running, Otter offers to keep it connected. The offer waits in the menu bar until you answer it.")

                if newShareDetector.ignoredShareCount > 0 {
                    Button {
                        newShareDetector.resetIgnoredShares()
                    } label: {
                        Label(
                            "Offer Ignored Shares Again (\(newShareDetector.ignoredShareCount))",
                            systemImage: "bell.badge"
                        )
                    }
                    .settingsActionButton()
                }
            } header: {
                Text("New Shares")
            }

            Section {
                Toggle("Connect VPN when a share is opened in Finder", isOn: connectVPNOnMountAttemptBinding)
                SettingsSecondaryText("If you open an SMB share while away from its network, Otter starts the VPN set on your shares, mounts them in the background and tells you when they are ready. Applies to shares set to connect their VPN automatically.")
            } header: {
                Text("VPN")
            }

            NotificationsPreferencesSections()
        }
        .compactPreferencesForm()
    }

    private var connectVPNOnMountAttemptBinding: Binding<Bool> {
        Binding {
            settings.preferences.connectVPNOnMountAttempt
        } set: { newValue in
            settings.updatePreferences { preferences in
                preferences.connectVPNOnMountAttempt = newValue
            }
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

    private var detectNewSharesBinding: Binding<Bool> {
        Binding {
            settings.preferences.detectNewShares
        } set: { newValue in
            settings.updatePreferences { preferences in
                preferences.detectNewShares = newValue
            }
        }
    }

    private var alwaysShowServerNameBinding: Binding<Bool> {
        Binding {
            settings.preferences.alwaysShowServerName
        } set: { newValue in
            settings.updatePreferences { preferences in
                preferences.alwaysShowServerName = newValue
            }
        }
    }
}

private struct NotificationsPreferencesSections: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var notificationService: NotificationService

    var body: some View {
        Group {
            Section {
                Toggle("Notifications", isOn: notificationsEnabledBinding)
                SettingsSecondaryText("Uses temporary banners by default.")

                if settings.preferences.notificationsEnabled {
                    Toggle("Connection changes", isOn: preferenceBinding(\.notifyConnectionChanges))
                    Toggle("Problems", isOn: preferenceBinding(\.notifyProblems))
                    Toggle("Play sound", isOn: preferenceBinding(\.notificationSoundsEnabled))
                }
            } header: {
                Text("Notifications")
            }

            Section {
                LabeledContent("macOS notifications", value: notificationService.authorizationStatusTitle)

                if notificationService.authorizationStatus == .denied {
                    SettingsSecondaryText("Enable Otter in System Settings → Notifications to receive alerts.")
                }

                if notificationService.canAskForAuthorization {
                    Button {
                        Task { await notificationService.requestAuthorization() }
                    } label: {
                        Label("Allow Notifications", systemImage: "bell.badge")
                    }
                    .settingsActionButton()
                }
            } header: {
                Text("Permission")
            }
        }
        .onAppear {
            Task { await notificationService.refreshAuthorizationStatus() }
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

    private func preferenceBinding(_ keyPath: WritableKeyPath<AppPreferences, Bool>) -> Binding<Bool> {
        Binding {
            settings.preferences[keyPath: keyPath]
        } set: { newValue in
            settings.updatePreferences { preferences in
                preferences[keyPath: keyPath] = newValue
            }
        }
    }
}

private struct AdvancedPreferencesView: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var networkService: NetworkReachabilityService
    @State private var configurationMessage: String?
    @State private var supportPackageMessage: String?

    var body: some View {
        Form {
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

                Toggle("Clean up duplicate connections", isOn: Binding(
                    get: { settings.preferences.deduplicateConnections },
                    set: { enabled in
                        settings.updatePreferences { $0.deduplicateConnections = enabled }
                    }
                ))
                .disabled(settings.hasManagedMonitoringSettings)
                SettingsSecondaryText("Finder lists a server twice when a share is mounted through an alias of its name, such as “nas.local” instead of “nas”. Otter reconnects the share through the browsed name and unmounts any second copy of a share it already has mounted.")

                if settings.hasManagedMonitoringSettings {
                    Label("These monitoring settings are managed by your organization.", systemImage: "checkmark.shield")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
                            Task {
                                // macOS shows no prompt at all when Location
                                // Services is off system-wide, so send the user
                                // to the switch rather than leave the button
                                // doing nothing.
                                if await NetworkReachabilityService.locationServicesEnabled() {
                                    networkService.requestLocationAuthorization()
                                } else {
                                    openLocationPrivacySettings()
                                }
                            }
                        } else {
                            openLocationPrivacySettings()
                        }
                    } label: {
                        Label(
                            networkService.canRequestLocationAuthorization ? "Allow Location Access" : "Open Location Settings",
                            systemImage: "location"
                        )
                    }
                    .settingsActionButton()
                }

                LabeledContent("Active VPN", value: activeVPNLabel)

                if networkService.isVPNNameUnavailable {
                    Label("An unidentified tunnel is active. It does not satisfy VPN share rules.", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if networkService.knownVPNNames.isEmpty {
                    LabeledContent("VPNs in System Settings", value: "None found")
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

            } header: {
                HStack {
                    Text("Network")
                    Spacer()
                    Button {
                        networkService.refreshNetworkDetails()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .help("Refresh Wi-Fi and VPN status")
                }
            }

            Section {
                LabeledContent("Configuration") {
                    HStack {
                        Button(action: exportConfiguration) {
                            Label("Export…", systemImage: "square.and.arrow.up")
                                .frame(width: 84)
                        }
                        Button(action: importConfiguration) {
                            Label("Import…", systemImage: "square.and.arrow.down")
                                .frame(width: 84)
                        }
                    }
                    .settingsActionButton()
                }

                LabeledContent("Protected Backup") {
                    HStack {
                        Button(action: exportProtectedBackup) {
                            Label("Export…", systemImage: "lock")
                                .frame(width: 84)
                        }
                        Button(action: importProtectedBackup) {
                            Label("Restore…", systemImage: "arrow.counterclockwise")
                                .frame(width: 84)
                        }
                    }
                    .settingsActionButton()
                }

                SettingsSecondaryText("Standard exports are safe templates and never include credentials. Protected backups encrypt eligible SMB Keychain credentials with a password you choose.")

                if let configurationMessage {
                    Text(configurationMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Backup & Restore")
            }

            Section {
                Button {
                    exportSupportPackage()
                } label: {
                    Label("Export Diagnostic Logs\u{2026}", systemImage: "lifepreserver")
                }
                .settingsActionButton()

                SettingsSecondaryText("Creates a readable report with live share state, retry timing, health history, and recent events. Identifying details are removed.")

                if let supportPackageMessage {
                    Text(supportPackageMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Support")
            }

#if DEBUG
            Section {
                Toggle("Show demo shares", isOn: Binding(
                    get: { appModel.isScreenshotDemoEnabled },
                    set: { appModel.setScreenshotDemo($0) }
                ))
                SettingsSecondaryText("Replaces the share list with five fake shares in assorted states for product screenshots. Real configuration is untouched. Debug builds only.")

                Button {
                    appModel.requestOnboarding()
                    openWindow(id: AppModel.sharesWindowID)
                    bringOtterToFront(windowTitled: "Manage Shares")
                } label: {
                    Label("Run Onboarding Again", systemImage: "arrow.counterclockwise")
                }
                .settingsActionButton()
                SettingsSecondaryText("Reopens onboarding without removing shares or resetting macOS permissions. Debug builds only.")
            } header: {
                Text("Developer")
            }
#endif
        }
        .compactPreferencesForm()
        .onAppear {
            networkService.refreshNetworkDetails()
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

    private func fallbackIntervalLabel(_ value: TimeInterval) -> String {
        let seconds = Int(value)
        if seconds % 60 == 0 {
            let minutes = seconds / 60
            return .counted(minutes, "minute")
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

    private var protectedConfigurationFileType: UTType {
        UTType(filenameExtension: "otterbackup", conformingTo: .json) ?? .json
    }

    private func exportSupportPackage() {
        Task { @MainActor in
            switch await appModel.exportSupportPackage() {
            case .success(.some):
                supportPackageMessage = "Diagnostic logs exported with identifying details removed."
            case .success(.none):
                break
            case let .failure(error):
                supportPackageMessage = "Export failed: \(error.localizedDescription)"
            }
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
            importArchive(try ConfigurationTransferService.decode(Data(contentsOf: url)))
        } catch {
            configurationMessage = "Import failed: \(error.localizedDescription)"
        }
    }

    private func exportProtectedBackup() {
        guard let password = backupPassword(confirm: true) else { return }
        let panel = NSSavePanel()
        panel.title = "Export Protected Otter Backup"
        panel.nameFieldStringValue = "Otter Backup.otterbackup"
        panel.allowedContentTypes = [protectedConfigurationFileType]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let credentials = settings.portableCredentials()
            let data = try ConfigurationTransferService.encodeProtectedBackup(
                settings.configurationArchive(), credentials: credentials, password: password
            )
            try data.write(to: url, options: .atomic)
            configurationMessage = "Protected backup exported with \(String.counted(credentials.count, "SMB credential")). Keep its password safe."
        } catch {
            configurationMessage = "Protected backup failed: \(error.localizedDescription)"
        }
    }

    private func importProtectedBackup() {
        let panel = NSOpenPanel()
        panel.title = "Restore Protected Otter Backup"
        panel.allowedContentTypes = [protectedConfigurationFileType, .json]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let password = backupPassword(confirm: false)
        else { return }
        do {
            let backup = try ConfigurationTransferService.decodeProtectedBackup(Data(contentsOf: url), password: password)
            importArchive(backup.archive, credentials: backup.credentials)
        } catch {
            configurationMessage = "Restore failed: \(error.localizedDescription)"
        }
    }

    private func importArchive(_ archive: OtterConfigurationArchive, credentials: [PortableCredential] = []) {
        let alert = NSAlert()
        alert.messageText = "Import \(String.counted(archive.shares.count, "Share"))?"
        alert.informativeText = credentials.isEmpty
            ? "Merge updates matching network addresses and keeps other shares. Replace removes the current share list first."
            : "Merge updates matching network addresses and keeps other shares. Eligible SMB Keychain credentials are restored after the import."
        alert.addButton(withTitle: "Merge")
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        let strategy: ConfigurationImportStrategy
        switch alert.runModal() {
        case .alertFirstButtonReturn: strategy = .merge
        case .alertSecondButtonReturn: strategy = .replace
        default: return
        }
        let result = settings.importConfiguration(archive, strategy: strategy)
        let allowedCredentialHosts = Set<String>(archive.shares.compactMap { configuration in
            guard NetworkShareProtocol(urlScheme: URL(string: configuration.urlString)?.scheme) == .smb else { return nil }
            return URL(string: configuration.urlString)?.host(percentEncoded: false)
        })
        let restored = settings.importPortableCredentials(credentials.filter {
            allowedCredentialHosts.contains($0.host)
        })
        configurationMessage = "Imported: \(result.added) added, \(result.updated) updated, \(result.removed) removed.\(credentials.isEmpty ? "" : " Restored \(String.counted(restored, "credential")).")"
    }

    private func backupPassword(confirm: Bool) -> String? {
        let alert = NSAlert()
        alert.messageText = confirm ? "Choose a Backup Password" : "Enter Backup Password"
        alert.informativeText = confirm
            ? "Otter cannot recover this password. It protects any included SMB Keychain credentials."
            : "Enter the password used when this protected backup was exported."
        let first = NSSecureTextField(frame: NSRect(x: 0, y: 28, width: 280, height: 24))
        first.placeholderString = "Password"
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: confirm ? 56 : 24))
        accessory.addSubview(first)
        var confirmation: NSSecureTextField?
        if confirm {
            let second = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
            second.placeholderString = "Confirm password"
            accessory.addSubview(second)
            confirmation = second
        }
        alert.accessoryView = accessory
        alert.addButton(withTitle: confirm ? "Export" : "Restore")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn,
              !first.stringValue.isEmpty,
              confirmation.map({ $0.stringValue == first.stringValue }) ?? true
        else { return nil }
        return first.stringValue
    }
}


private struct UpdatesPreferencesView: View {
    @EnvironmentObject private var updaterViewModel: UpdaterViewModel
    @EnvironmentObject private var settings: SettingsStore

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
                    .disabled(!updaterViewModel.isConfigured)
                SettingsSecondaryText("Checks in the background and prompts when an update is available.")

                Toggle("Install updates unattended", isOn: automaticDownloadsBinding)
                    .disabled(!updaterViewModel.isConfigured || !updaterViewModel.automaticallyChecksForUpdates)
                SettingsSecondaryText("Downloads and installs in the background without asking, whenever macOS does not require authorization.")

                if let lastUpdateCheckDate = updaterViewModel.lastUpdateCheckDate {
                    LabeledContent("Last checked", value: lastUpdateCheckDate, format: .dateTime.day().month().hour().minute())
                }

                Button {
                    updaterViewModel.checkForUpdates()
                } label: {
                    Label("Check for Updates…", systemImage: "arrow.clockwise")
                }
                .settingsActionButton()
                .disabled(!updaterViewModel.canCheckForUpdates)

                if !updaterViewModel.isConfigured {
                    Label("This build has no update feed or signing key, so updates are unavailable.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Color.warningText)
                }
            } header: {
                Text("Updates")
            }
        }
        .compactPreferencesForm()
    }

    private var installPolicyDetail: String {
        switch settings.preferences.autoUpdateInstallPolicy {
        case .immediate:
            "Otter installs the update and relaunches as soon as the download finishes."
        case .whenIdle:
            "Otter waits until no share check is in flight, so a relaunch cannot interrupt a mount. Installs within 24 hours regardless."
        case .scheduled:
            "Otter downloads silently, then installs and relaunches at \(Self.hourLabel(settings.preferences.autoUpdateInstallHour))."
        }
    }

    private static func hourLabel(_ hour: Int) -> String {
        let date = Calendar.current.date(from: DateComponents(hour: hour, minute: 0)) ?? Date()
        return date.formatted(date: .omitted, time: .shortened)
    }

    private var automaticChecksBinding: Binding<Bool> {
        Binding {
            updaterViewModel.automaticallyChecksForUpdates
        } set: { enabled in
            updaterViewModel.automaticallyChecksForUpdates = enabled
        }
    }

    private var automaticDownloadsBinding: Binding<Bool> {
        Binding {
            updaterViewModel.automaticallyDownloadsUpdates
        } set: { enabled in
            updaterViewModel.automaticallyDownloadsUpdates = enabled
        }
    }

    private var installPolicyBinding: Binding<AutoUpdateInstallPolicy> {
        Binding {
            settings.preferences.autoUpdateInstallPolicy
        } set: { policy in
            settings.updatePreferences { $0.autoUpdateInstallPolicy = policy }
        }
    }

    private var installHourBinding: Binding<Int> {
        Binding {
            settings.preferences.autoUpdateInstallHour
        } set: { hour in
            settings.updatePreferences { $0.autoUpdateInstallHour = hour }
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
                Label("Add Share…", systemImage: "plus")
            }
            .tahoePrimaryActionButton()
        }
    }
}

private struct ShareListRow: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.backgroundProminence) private var backgroundProminence
    @EnvironmentObject private var monitor: ShareMonitor
    let share: NetworkShare
    let isSelected: Bool

    var body: some View {
        let status = monitor.status(for: share)

        HStack(spacing: 8) {
            Image(systemName: appModel.shareIcon(for: share))
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(share.displayName)
                    .lineLimit(1)

                // A healthy share needs no caption; anything else says why.
                if status != .connected {
                    Text(status.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            // Trailing, so every row's indicator lines up whatever the name length.
            Image(systemName: status.circleSymbol)
                .font(.caption2)
                // Green on the selection's blue is hard to see, so the symbol goes
                // white there; its shape still says which state it is.
                .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(status.tint))
                .accessibilityHidden(true)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityValue(status.label)
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
