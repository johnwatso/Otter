import AppKit
import SwiftUI

// MARK: - Share

struct ShareDetailView<Actions: View>: View {
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var monitor: ShareMonitor
    @EnvironmentObject private var networkService: NetworkReachabilityService
    @EnvironmentObject private var eventLog: ShareEventLog
    let share: NetworkShare
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        let status = monitor.status(for: currentShare)
        let runtimeState = monitor.runtimeState(for: currentShare)

        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                DetailHeader(
                    symbol: appModel.shareIcon(for: currentShare),
                    title: currentShare.displayName,
                    status: status,
                    statusContext: statusContext,
                    lines: statusLines(status: status, runtimeState: runtimeState),
                    warning: dropWarning,
                    symbolChoices: ShareSymbol.choices,
                    defaultSymbol: ShareSymbol.default,
                    onSelectSymbol: { settings.setShareIcon($0, for: currentShare) },
                    actions: actions
                )

                if status.offersVPNSettingsAction {
                    Button {
                        openVPNSettings()
                    } label: {
                        Label("Open VPN Settings", systemImage: "gearshape")
                    }
                    .tahoeSecondaryActionButton()
                }

                reliabilityCard(runtimeState: runtimeState)

                DetailCard("Connection Details") {
                    DetailRow(label: "Address", value: currentShare.host ?? "Unknown", copyValue: currentShare.host)
                    DetailRow(label: "Protocol", value: currentShare.connectionProtocol?.title ?? "Unknown")
                    if !currentShare.orderedCachedIPAddresses.isEmpty {
                        DetailRow(
                            label: "Fallback",
                            value: currentShare.orderedCachedIPAddresses.joined(separator: ", "),
                            copyValue: currentShare.orderedCachedIPAddresses.first
                        )
                    }
                    DetailRow(label: "Mount point", value: currentShare.mountPath, copyValue: currentShare.mountPath)
                    DetailStatusRow(
                        label: "Credentials",
                        isOn: hasKeychainCredentials,
                        onText: "Saved in Keychain",
                        offText: "Not found"
                    )

                    if runtimeState.needsCredentials {
                        Button {
                            refreshCredentials()
                        } label: {
                            Label("Refresh Credentials in Finder", systemImage: "key.fill")
                        }
                        .tahoeCompactActionButton()
                    }

                    if currentShare.hasUnstableIPAddress() {
                        Label {
                            Text("The LAN address has changed repeatedly this month. Otter still connects by hostname first; a DHCP reservation may improve fallback reliability.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                    }
                }

                DetailCard("Connection Behavior", accessory: {
                    if settings.isManagedShare(id: currentShare.id) {
                        Label("Managed", systemImage: "checkmark.shield.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }) {
                    ConnectionBehaviourRows(shareIDs: [currentShare.id])
                }
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear {
            networkService.refreshNetworkDetails()
        }
    }

    // MARK: Reliability

    private func reliabilityCard(runtimeState: ShareRuntimeState) -> some View {
        ReliabilityCard(shareIDs: [currentShare.id], lastCheckedAt: runtimeState.lastCheckedAt)
    }

    static func milliseconds(_ value: Double) -> String {
        value < 10 ? String(format: "%.1f ms", value) : String(format: "%.0f ms", value)
    }

    // MARK: Status text

    private var statusContext: String? {
        "to \(currentShare.serverDisplayName(customNames: settings.preferences.serverNames))"
    }

    private func statusLines(status: ShareStatus, runtimeState: ShareRuntimeState) -> [String] {
        var lines: [String] = []
        if case .connected = status {
            if let mountedAt = runtimeState.mountedAt {
                lines.append("Mounted for \(Self.duration(since: mountedAt))")
            }
        } else {
            lines.append(status.detail ?? "Retrying automatically")
            if let lastConnected = runtimeState.lastConnectedAt {
                lines.append("Last connected \(Self.relativeDayTime(lastConnected))")
            }
        }
        return lines
    }

    private var dropWarning: String? {
        let dropCount = appModel.screenshotDemoDropCount(for: currentShare.id)
            ?? eventLog.connectionDropCount(for: currentShare.id)
        return dropCount > 0 ? "Dropped \(String.counted(dropCount, "time")) in the last 24 hours" : nil
    }

    /// "2 hours", "5 minutes" — the coarsest unit that is still meaningful.
    static func duration(since date: Date) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.unitsStyle = .full
        formatter.maximumUnitCount = 1
        let interval = max(0, Date().timeIntervalSince(date))
        return interval < 60 ? "less than a minute" : (formatter.string(from: interval) ?? "a while")
    }

    /// "today at 10:05 AM", "yesterday at 9:12 PM", "on Oct 3 at 8:40 AM" —
    /// a bare time is misleading once the date has rolled over.
    static func relativeDayTime(_ date: Date) -> String {
        let calendar = Calendar.current
        let time = date.formatted(.dateTime.hour().minute())
        if calendar.isDateInToday(date) {
            return "today at \(time)"
        } else if calendar.isDateInYesterday(date) {
            return "yesterday at \(time)"
        } else {
            return "on \(date.formatted(.dateTime.month(.abbreviated).day())) at \(time)"
        }
    }

    private func openVPNSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Network-Settings.extension?VPN") else { return }
        NSWorkspace.shared.open(url)
    }

    private func refreshCredentials() {
        guard let url = currentShare.url else { return }
        NSWorkspace.shared.open(url)
    }

    private var healthCheckDescription: String {
        var parts = ["Responsive"]
        if currentShare.healthCheck.requiresWritableVolume { parts.append("Writable") }
        return parts.joined(separator: " · ")
    }

    private var hasKeychainCredentials: Bool {
        if let demoValue = appModel.screenshotDemoHasCredentials(for: currentShare.id) {
            return demoValue
        }

        guard let url = currentShare.url,
              let host = url.host(percentEncoded: false)
        else { return false }

        if settings.hasCredentials(for: host) {
            return true
        }
        if currentShare.cachedIPAddresses.contains(where: settings.hasCredentials(for:)) {
            return true
        }
        return false
    }

    private var currentShare: NetworkShare {
        settings.share(id: share.id) ?? share
    }
}

// MARK: - Server

struct ServerDetailView<Actions: View>: View {
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var monitor: ShareMonitor
    @EnvironmentObject private var eventLog: ShareEventLog
    let group: NetworkShareServerGroup
    let onSelectShare: (NetworkShare) -> Void
    @ViewBuilder let actions: () -> Actions

    private var serverSymbol: String {
        group.shares.first.map { appModel.serverIcon(for: $0) } ?? ServerSymbol.default
    }

    var body: some View {
        let summary = statusSummary

        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                DetailHeader(
                    symbol: serverSymbol,
                    title: group.serverName,
                    status: summary.status,
                    statusText: summary.label,
                    lines: [summary.detail],
                    warning: connectionDropCount > 0
                        ? "Dropped \(String.counted(connectionDropCount, "time")) across this server in the last 24 hours"
                        : nil,
                    onSelectSymbol: group.shares.first.map { share in
                        { settings.setServerIcon($0, for: share) }
                    },
                    actions: actions
                )

                DetailCard("Shares") {
                    VStack(spacing: 0) {
                        ForEach(Array(currentShares.enumerated()), id: \.element.id) { index, share in
                            if index > 0 {
                                Divider()
                            }
                            ServerShareRow(share: share) {
                                onSelectShare(share)
                            }
                        }
                    }
                }

                ReliabilityCard(
                    shareIDs: currentShares.map(\.id),
                    lastCheckedAt: currentShares.compactMap { monitor.runtimeState(for: $0).lastCheckedAt }.max()
                )

                DetailCard("Server Details") {
                    DetailRow(
                        label: "Address",
                        value: currentShares.first?.host ?? group.serverName,
                        copyValue: currentShares.first?.host
                    )
                    DetailRow(label: "Protocol", value: currentShares.first?.connectionProtocol?.title ?? "SMB")
                    DetailRow(label: "Shares", value: String.counted(currentShares.count, "share"))
                }

                DetailCard("Connection Behavior") {
                    ConnectionBehaviourRows(shareIDs: currentShares.map(\.id), isServer: true)
                }
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var currentShares: [NetworkShare] {
        group.shares.map { settings.share(id: $0.id) ?? $0 }
    }

    private var connectionDropCount: Int {
        currentShares.reduce(into: 0) { count, share in
            count += appModel.screenshotDemoDropCount(for: share.id)
                ?? eventLog.connectionDropCount(for: share.id)
        }
    }

    private var statusSummary: ServerStatusSummary {
        let statuses = currentShares.map { monitor.status(for: $0) }
        let connectedCount = statuses.filter { $0 == .connected }.count
        let detail = connectedCount == statuses.count
            ? (statuses.count == 2 ? "Both shares mounted" : "All \(statuses.count) shares mounted")
            : "\(connectedCount) of \(statuses.count) shares mounted"

        if !statuses.isEmpty && connectedCount == statuses.count {
            return ServerStatusSummary(status: .connected, label: "Connected", detail: detail)
        }
        if statuses.contains(where: { if case .failed = $0 { true } else { false } }) {
            return ServerStatusSummary(status: statuses.first(where: { if case .failed = $0 { true } else { false } }) ?? .disconnected, label: "Some shares need attention", detail: detail)
        }
        if statuses.contains(.reconnecting) {
            return ServerStatusSummary(status: .reconnecting, label: "Reconnecting", detail: detail)
        }
        if connectedCount > 0 {
            return ServerStatusSummary(status: .reconnecting, label: "Partially connected", detail: detail)
        }
        if statuses.contains(where: { if case .paused = $0 { true } else { false } }) {
            return ServerStatusSummary(status: statuses.first(where: { if case .paused = $0 { true } else { false } }) ?? .disconnected, label: "Automatic mounting paused", detail: detail)
        }
        return ServerStatusSummary(status: .disconnected, label: "Not connected", detail: detail)
    }
}

private struct ServerStatusSummary {
    /// Only supplies the symbol and colour for the header.
    let status: ShareStatus
    let label: String
    let detail: String
}

private struct ServerShareRow: View {
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var monitor: ShareMonitor
    let share: NetworkShare
    let onSelect: () -> Void

    var body: some View {
        let status = monitor.status(for: share)
        let isConnected = status == .connected

        HStack(spacing: 12) {
            Image(systemName: appModel.shareIcon(for: share))
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(share.displayName)
                    .fontWeight(.medium)
                    .lineLimit(1)
                StatusLabel(status: status)
                    .font(.subheadline)
            }

            Spacer(minLength: 8)

            Text(share.mountPath)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 180, alignment: .trailing)

            if isConnected {
                Button("Open") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: share.mountPath)])
                }
                .tahoeCompactActionButton()
            }

            Menu {
                if !isConnected {
                    Button {
                        Task { await monitor.mount(share) }
                    } label: {
                        Label("Connect", systemImage: "arrow.triangle.2.circlepath")
                    }
                } else {
                    Button {
                        Task { await monitor.disconnect(share, pauseAutomaticMounting: share.connectsAutomatically) }
                    } label: {
                        Label("Disconnect", systemImage: "eject")
                    }
                }
                Button {
                    appModel.requestEditShare(share)
                } label: {
                    Label("Share Settings…", systemImage: "gearshape")
                }
                .disabled(settings.isManagedShare(id: share.id))
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .menuIndicator(.hidden)
            .tahoeSecondaryMenu()
            .fixedSize()
            .help("Actions for this share")
            .accessibilityLabel("More actions for \(share.displayName)")
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        // A tap gesture alone is invisible to the keyboard and VoiceOver.
        .focusable(interactions: .activate)
        .onKeyPress(.return) {
            onSelect()
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(share.displayName)
        .accessibilityValue(status.label)
        .accessibilityHint("Shows this share's details")
        .accessibilityAction(named: "Show Details", onSelect)
    }
}

// MARK: - Connection behaviour

/// The two per-share behaviours worth changing from the detail pane, mapped
/// onto the existing model. "Keep connected" is the connection mode (with a VPN
/// rule it stays Adaptive); Wake-on-LAN only turns on once a MAC address has
/// been set up in the share editor.
private struct ConnectionBehaviourRows: View {
    @EnvironmentObject private var settings: SettingsStore
    let shareIDs: [NetworkShare.ID]
    var isServer = false

    private var shares: [NetworkShare] {
        shareIDs.compactMap { settings.share(id: $0) }
    }

    private var isManaged: Bool {
        shareIDs.contains { settings.isManagedShare(id: $0) }
    }

    private var keepsConnected: Bool {
        !shares.isEmpty && shares.allSatisfy { $0.connectionMode.maintainsConnection }
    }

    private var wakesServer: Bool {
        !shares.isEmpty && shares.allSatisfy { $0.wakeOnLAN.isEnabled }
    }

    private var canEnableWake: Bool {
        !shares.isEmpty && shares.allSatisfy {
            WakeOnLANConfiguration.normalizedMACAddress($0.wakeOnLAN.macAddress) != nil
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            BehaviourRow(
                symbol: "arrow.triangle.2.circlepath",
                title: isServer ? "Keep all shares connected" : "Keep connected",
                subtitle: keepsConnected
                    ? (isServer ? "Automatically reconnect shares when unavailable." : "Automatically reconnect when unavailable.")
                    : "Connect only when requested.",
                isOn: Binding(
                    get: { keepsConnected },
                    set: { setKeepsConnected($0) }
                )
            )
            .disabled(isManaged)

            Divider().padding(.leading, 44)

            BehaviourRow(
                symbol: "moon.fill",
                title: isServer ? "Wake this server when needed" : "Wake sleeping server",
                subtitle: wakeSubtitle,
                isOn: Binding(
                    get: { wakesServer },
                    set: { setWakesServer($0) }
                )
            )
            .disabled(isManaged || (!wakesServer && !canEnableWake))
        }
    }

    private var wakeSubtitle: String {
        if !wakesServer && !canEnableWake {
            return "Add a MAC address in Share Settings to enable."
        }
        return isServer ? "Send wake-on-LAN when connecting." : "Send wake-on-LAN when needed."
    }

    private func setKeepsConnected(_ enabled: Bool) {
        for id in shareIDs {
            settings.updateShare(id: id) { share in
                if enabled {
                    share.connectionMode = share.rules.requiredVPNName != nil ? .adaptive : .keepConnected
                } else {
                    share.connectionMode = .manual
                }
            }
        }
    }

    private func setWakesServer(_ enabled: Bool) {
        for id in shareIDs {
            settings.updateShare(id: id) { share in
                share.wakeOnLAN.isEnabled = enabled
            }
        }
    }
}

/// The icon, title and subtitle of a behaviour row, without its control, for
/// rows that disclose more settings instead of toggling one.
struct BehaviourRowLabel: View {
    let symbol: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
                .background(Color.primary.opacity(0.06), in: Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .fontWeight(.medium)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }
}

struct BehaviourRow: View {
    let symbol: String
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            BehaviourRowLabel(symbol: symbol, title: title, subtitle: subtitle)

            Spacer(minLength: 12)

            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Shared components

extension ShareStatus {
    /// Calm when healthy, orange while Otter is working on it, red when it
    /// needs attention, grey when it is off by choice.
    var tint: Color {
        switch self {
        case .connected:
            .green
        case .reconnecting, .waitingForNetwork, .waitingForAllowedNetwork, .waitingForVPN,
             .waitingForAccess, .waitingForServerOnVPN, .wakePacketSent:
            .orange
        case .failed:
            .red
        case .disconnected, .paused:
            .secondary
        }
    }
}

extension Color {
    /// Orange that stays legible as small text on a light background; plain
    /// `.orange` is fine for symbols but fails contrast as caption text.
    static let warningText = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? .systemOrange
            : NSColor(srgbRed: 0.69, green: 0.33, blue: 0, alpha: 1)
    })
}

/// Symbol and word together, so status never depends on colour alone.
struct StatusLabel: View {
    let status: ShareStatus
    var text: String?

    var body: some View {
        Label {
            Text(text ?? status.label)
                .foregroundStyle(status.tint)
        } icon: {
            Image(systemName: status.circleSymbol)
                .foregroundStyle(status.tint)
        }
        .labelStyle(.titleAndIcon)
    }
}

/// The top of a detail pane: a restrained icon tile, the name, and a single
/// status line, with the actions underneath.
struct DetailHeader<Actions: View>: View {
    let symbol: String
    let title: String
    let status: ShareStatus
    var statusText: String?
    var statusContext: String?
    var lines: [String] = []
    var warning: String?
    /// When set, the icon becomes a button that lets the user pick another symbol.
    var symbolChoices: [SymbolChoice] = ServerSymbol.choices
    var defaultSymbol: String = ServerSymbol.default
    var onSelectSymbol: ((String?) -> Void)?
    @ViewBuilder let actions: () -> Actions

    @State private var isPickingSymbol = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 18) {
                if let onSelectSymbol {
                    Button {
                        isPickingSymbol = true
                    } label: {
                        symbolTile
                    }
                    .buttonStyle(.plain)
                    .help("Change icon")
                    .accessibilityLabel("Change icon")
                    .popover(isPresented: $isPickingSymbol, arrowEdge: .bottom) {
                        SymbolPicker(
                            title: "Icon",
                            choices: symbolChoices,
                            defaultSymbol: defaultSymbol,
                            selection: symbol
                        ) { choice in
                            onSelectSymbol(choice)
                            isPickingSymbol = false
                        }
                    }
                } else {
                    symbolTile
                        .accessibilityHidden(true)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.title.weight(.semibold))
                        .lineLimit(2)

                    HStack(spacing: 5) {
                        StatusLabel(status: status, text: statusText)
                            .fontWeight(.medium)
                        if let statusContext {
                            Text(statusContext)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    ForEach(lines, id: \.self) { line in
                        Text(line)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if let warning {
                        Text(warning)
                            .font(.subheadline)
                            .foregroundStyle(Color.warningText)
                    }
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                actions()
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var symbolTile: some View {
        Image(systemName: symbol)
            .font(.largeTitle)
            .foregroundStyle(.secondary)
            .frame(width: 64, height: 64)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct SymbolChoice: Hashable {
    let symbol: String
    let name: String

    init(_ symbol: String, _ name: String) {
        self.symbol = symbol
        self.name = name
    }
}

/// The symbols a share can be shown with.
enum ShareSymbol {
    static let `default` = "externaldrive.fill"

    static let choices: [SymbolChoice] = [
        SymbolChoice("externaldrive.fill", "Drive"),
        SymbolChoice("folder.fill", "Folder"),
        SymbolChoice("archivebox.fill", "Archive"),
        SymbolChoice("clock.arrow.circlepath", "Backups"),
        SymbolChoice("photo.on.rectangle", "Photos"),
        SymbolChoice("film.stack", "Movies"),
        SymbolChoice("play.rectangle.fill", "Video"),
        SymbolChoice("tv.fill", "TV"),
        SymbolChoice("music.note", "Music"),
        SymbolChoice("camera.fill", "Camera"),
        SymbolChoice("doc.fill", "Documents"),
        SymbolChoice("briefcase.fill", "Work"),
        SymbolChoice("person.2.fill", "Shared"),
        SymbolChoice("house.fill", "Home"),
        SymbolChoice("books.vertical.fill", "Library"),
        SymbolChoice("gamecontroller.fill", "Games"),
        SymbolChoice("shippingbox.fill", "Storage"),
        SymbolChoice("lock.fill", "Private"),
        SymbolChoice("cloud.fill", "Cloud"),
        SymbolChoice("externaldrive.fill.badge.timemachine", "Time Machine"),
    ]
}

/// The symbols a server can be shown with.
enum ServerSymbol {
    static let `default` = "server.rack"

    static let choices: [SymbolChoice] = [
        SymbolChoice("server.rack", "Server rack"),
        SymbolChoice("macpro.gen3.server", "Mac Pro rack"),
        SymbolChoice("macpro.gen3", "Mac Pro (2019)"),
        SymbolChoice("macpro.gen2", "Mac Pro (2013)"),
        SymbolChoice("macpro.gen1", "Mac Pro (tower)"),
        SymbolChoice("macstudio", "Mac Studio"),
        SymbolChoice("macmini", "Mac mini"),
        SymbolChoice("desktopcomputer", "Desktop"),
        SymbolChoice("laptopcomputer", "Laptop"),
        SymbolChoice("display", "Display"),
        SymbolChoice("xserve", "Xserve"),
        SymbolChoice("externaldrive.fill", "External drive"),
        SymbolChoice("internaldrive.fill", "Internal drive"),
        SymbolChoice("opticaldiscdrive.fill", "Disc drive"),
        SymbolChoice("cpu", "Chip"),
        SymbolChoice("airport.extreme", "Router"),
        SymbolChoice("network", "Network"),
        SymbolChoice("icloud.fill", "Cloud"),
        SymbolChoice("house.fill", "Home"),
        SymbolChoice("building.2.fill", "Office"),
    ]
}

/// A grid of symbols to choose an icon from.
struct SymbolPicker: View {
    let title: String
    let choices: [SymbolChoice]
    let defaultSymbol: String
    let selection: String
    let onSelect: (String?) -> Void

    private let columns = Array(repeating: GridItem(.fixed(44), spacing: 8), count: 5)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)

            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(choices, id: \.symbol) { choice in
                    Button {
                        onSelect(choice.symbol == defaultSymbol ? nil : choice.symbol)
                    } label: {
                        Image(systemName: choice.symbol)
                            .font(.title2)
                            .frame(width: 44, height: 44)
                            .background(
                                choice.symbol == selection
                                    ? Color.accentColor.opacity(0.22)
                                    : Color.primary.opacity(0.06),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                            )
                            .overlay {
                                if choice.symbol == selection {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .stroke(Color.accentColor, lineWidth: 1.5)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .help(choice.name)
                    .accessibilityLabel(choice.name)
                    .accessibilityAddTraits(choice.symbol == selection ? .isSelected : [])
                }
            }
        }
        .padding(16)
    }
}

/// A titled group of rows on a quiet rounded surface.
struct DetailCard<Content: View, Accessory: View>: View {
    let title: String
    @ViewBuilder let accessory: () -> Accessory
    @ViewBuilder let content: () -> Content

    init(
        _ title: String,
        @ViewBuilder accessory: @escaping () -> Accessory,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.accessory = accessory
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                DetailSectionHeader(title)
                Spacer()
                accessory()
            }

            VStack(alignment: .leading, spacing: 9) {
                content()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        )
    }
}

extension DetailCard where Accessory == EmptyView {
    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.init(title, accessory: { EmptyView() }, content: content)
    }
}

struct ReliabilityDay {
    let problems: Int
    let latency: DailyLatency?
}

/// The last seven days of drops, failures and response times. For a server it
/// combines every share on it: problems add up day by day, and response times
/// are averaged across all the samples taken that day.
private struct ReliabilityCard: View {
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var eventLog: ShareEventLog
    @EnvironmentObject private var latencyHistory: ShareLatencyHistory
    let shareIDs: [NetworkShare.ID]
    let lastCheckedAt: Date?

    private var isCombined: Bool { shareIDs.count > 1 }

    private struct Combined {
        var summary: ShareReliabilitySummary
        var problems: [Int]
        var latency: [DailyLatency?]
    }

    private var combined: Combined {
        let perShare = shareIDs.map { id -> Combined in
            if let demo = appModel.screenshotDemoReliability(for: id) {
                return Combined(summary: demo.summary, problems: demo.problems, latency: demo.latency)
            }
            return Combined(
                summary: eventLog.reliabilitySummary(for: id),
                problems: eventLog.dailyProblemCounts(for: id),
                latency: latencyHistory.recent(for: id)
            )
        }

        let dayCount = perShare.map(\.problems.count).max() ?? 7
        let problems = (0..<dayCount).map { day in
            perShare.reduce(0) { $0 + ($1.problems.indices.contains(day) ? $1.problems[day] : 0) }
        }
        let latency: [DailyLatency?] = (0..<dayCount).map { day in
            let samples = perShare.compactMap { $0.latency.indices.contains(day) ? $0.latency[day] : nil }
            guard let first = samples.first else { return nil }
            return samples.dropFirst().reduce(first) { merged, next in
                DailyLatency(
                    day: merged.day,
                    sampleCount: merged.sampleCount + next.sampleCount,
                    totalMilliseconds: merged.totalMilliseconds + next.totalMilliseconds,
                    slowestMilliseconds: max(merged.slowestMilliseconds, next.slowestMilliseconds)
                )
            }
        }
        let summary = ShareReliabilitySummary(
            connectionDrops: perShare.reduce(0) { $0 + $1.summary.connectionDrops },
            failures: perShare.reduce(0) { $0 + $1.summary.failures },
            healthFailures: perShare.reduce(0) { $0 + $1.summary.healthFailures },
            lastProblemAt: perShare.compactMap(\.summary.lastProblemAt).max()
        )
        return Combined(summary: summary, problems: problems, latency: latency)
    }

    var body: some View {
        let data = combined
        let summary = data.summary
        let days = zip(data.problems, data.latency).map { ReliabilityDay(problems: $0, latency: $1) }

        DetailCard("Reliability") {
            HStack(spacing: 8) {
                Image(systemName: summary.isStable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(summary.isStable ? Color.green : Color.orange)
                    .accessibilityHidden(true)
                Text(summary.isStable
                     ? "No recorded problems"
                     : "\(String.counted(summary.connectionDrops, "drop")) · \(String.counted(summary.failures, "failure")) · \(String.counted(summary.healthFailures, "health warning"))")
                    .font(.headline)
                Text(isCombined ? "Last 7 days · \(String.counted(shareIDs.count, "share"))" : "Last 7 days")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            ReliabilityStrip(days: days)

            VStack(alignment: .leading, spacing: 4) {
                if let responseText = responseTimeText(data.latency) {
                    Text(responseText)
                } else {
                    Text("Response times appear after Otter's next few checks.")
                }
                if let lastProblemAt = summary.lastProblemAt {
                    Text("Last problem \(lastProblemAt.formatted(date: .abbreviated, time: .shortened))")
                }
                if let lastCheckedAt {
                    Text("Last checked \(lastCheckedAt.formatted(.relative(presentation: .named)))")
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
    }

    /// "Response time 12 ms today · 14 ms over 7 days".
    private func responseTimeText(_ latency: [DailyLatency?]) -> String? {
        let measured = latency.compactMap { $0 }
        guard !measured.isEmpty else { return nil }
        let samples = measured.reduce(0) { $0 + $1.sampleCount }
        let weekAverage = measured.reduce(0) { $0 + $1.totalMilliseconds } / Double(samples)
        let milliseconds = ShareDetailView<EmptyView>.milliseconds
        if let today = latency.last ?? nil {
            return "Response time \(milliseconds(today.averageMilliseconds)) today · \(milliseconds(weekAverage)) over 7 days"
        }
        return "Response time \(milliseconds(weekAverage)) over 7 days"
    }
}

/// Seven bars, oldest to newest. Green is a day Otter measured the share and
/// recorded no problem, orange a day with at least one problem, and grey a day
/// with no measurements at all (Otter was not running or the share was not
/// mounted), so grey never claims the share was fine.
private struct ReliabilityStrip: View {
    let days: [ReliabilityDay]

    private var weekdaySymbols: [String] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return (0..<days.count).reversed().map { offset in
            let day = calendar.date(byAdding: .day, value: -offset, to: today) ?? today
            return day.formatted(.dateTime.weekday(.narrow))
        }
    }

    var body: some View {
        let symbols = weekdaySymbols

        HStack(spacing: 6) {
            ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                VStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(color(for: day))
                        .frame(height: 22)
                        // A mark as well as a colour, so a problem day is
                        // distinguishable without telling orange from green.
                        .overlay {
                            if day.problems > 0 {
                                Image(systemName: "exclamationmark")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.white)
                            }
                        }
                    Text(symbols[index])
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .help(description(of: day))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(description(of: day))
            }
        }
    }

    private func color(for day: ReliabilityDay) -> Color {
        if day.problems > 0 { return .orange }
        return day.latency == nil ? Color.primary.opacity(0.12) : Color.green.opacity(0.55)
    }

    private func description(of day: ReliabilityDay) -> String {
        var parts: [String] = []
        if let latency = day.latency {
            parts.append("Response time \(ShareDetailView<EmptyView>.milliseconds(latency.averageMilliseconds)), slowest \(ShareDetailView<EmptyView>.milliseconds(latency.slowestMilliseconds))")
        } else {
            parts.append("No measurements")
        }
        parts.append(day.problems == 0 ? "no problems recorded" : String.counted(day.problems, "problem") + " recorded")
        return parts.joined(separator: ", ")
    }
}

struct DetailRow: View {
    let label: String
    let value: String
    var copyValue: String?
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(minWidth: 96, alignment: .leading)
            Spacer()

            // Sits to the left of the value so every value keeps the same right
            // edge. It is always laid out and only fades in on hover, so the row
            // never changes size and nothing jiggles as the pointer moves over it.
            if let copyValue, !copyValue.isEmpty {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(copyValue, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .imageScale(.small)
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.borderless)
                .opacity(isHovering ? 1 : 0)
                .allowsHitTesting(isHovering)
                .help("Copy \(label.lowercased())")
                .accessibilityLabel("Copy \(label.lowercased())")
            }

            Text(value)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
    }
}

struct DetailSectionHeader: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.headline)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A detail row whose value is a yes/no state, shown with a colored symbol
/// instead of typed check marks so it matches the status dots elsewhere.
struct DetailStatusRow: View {
    let label: String
    let isOn: Bool
    let onText: String
    let offText: String

    var body: some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(minWidth: 96, alignment: .leading)
            Spacer()
            Label {
                Text(isOn ? onText : offText)
                    .foregroundStyle(.primary)
            } icon: {
                Image(systemName: isOn ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(isOn ? .green : .red)
            }
            .font(.subheadline.weight(.medium))
            .labelStyle(.titleAndIcon)
        }
        .padding(.vertical, 1)
        .accessibilityElement(children: .combine)
    }
}
