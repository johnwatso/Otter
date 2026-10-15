import AppKit
import SwiftUI

// MARK: - Share

struct ShareDetailView<Actions: View>: View {
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var monitor: ShareMonitor
    @EnvironmentObject private var networkService: NetworkReachabilityService
    @EnvironmentObject private var eventLog: ShareEventLog
    @EnvironmentObject private var latencyHistory: ShareLatencyHistory
    let share: NetworkShare
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        let status = monitor.status(for: currentShare)
        let runtimeState = monitor.runtimeState(for: currentShare)

        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                DetailHeader(
                    symbol: "externaldrive.fill",
                    title: currentShare.displayName,
                    status: status,
                    statusContext: statusContext,
                    lines: statusLines(status: status, runtimeState: runtimeState),
                    warning: dropWarning,
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

                DetailCard("Connection Behaviour", accessory: {
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
        let summary = eventLog.reliabilitySummary(for: currentShare.id)
        let problems = eventLog.dailyProblemCounts(for: currentShare.id)
        let latency = latencyHistory.recent(for: currentShare.id)
        let days = zip(problems, latency).map { ReliabilityDay(problems: $0, latency: $1) }

        return DetailCard("Reliability") {
            HStack(spacing: 8) {
                Image(systemName: summary.isStable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(summary.isStable ? Color.green : Color.orange)
                    .accessibilityHidden(true)
                Text(summary.isStable
                     ? "No recorded problems"
                     : "\(String.counted(summary.connectionDrops, "drop")) · \(String.counted(summary.failures, "failure")) · \(String.counted(summary.healthFailures, "health warning"))")
                    .font(.headline)
                Text("Last 7 days")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            ReliabilityStrip(days: days)

            VStack(alignment: .leading, spacing: 4) {
                if let responseText = responseTimeText(latency) {
                    Text(responseText)
                } else {
                    Text("Response times appear after Otter's next few checks.")
                }
                if let lastProblemAt = summary.lastProblemAt {
                    Text("Last problem \(lastProblemAt.formatted(date: .abbreviated, time: .shortened))")
                }
                if let lastCheckedAt = runtimeState.lastCheckedAt {
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
        if let today = latency.last ?? nil {
            return "Response time \(Self.milliseconds(today.averageMilliseconds)) today · \(Self.milliseconds(weekAverage)) over 7 days"
        }
        return "Response time \(Self.milliseconds(weekAverage)) over 7 days"
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
    let onAddShare: () -> Void
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        let summary = statusSummary

        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                DetailHeader(
                    symbol: "server.rack",
                    title: group.serverName,
                    status: summary.status,
                    statusText: summary.label,
                    lines: [summary.detail],
                    warning: connectionDropCount > 0
                        ? "Dropped \(String.counted(connectionDropCount, "time")) across this server in the last 24 hours"
                        : nil,
                    actions: actions
                )

                DetailCard("Shares", accessory: {
                    Button("Add Share", action: onAddShare)
                        .tahoeCompactActionButton()
                }) {
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

                DetailCard("Server Details") {
                    DetailRow(
                        label: "Address",
                        value: currentShares.first?.host ?? group.serverName,
                        copyValue: currentShares.first?.host
                    )
                    DetailRow(label: "Protocol", value: currentShares.first?.connectionProtocol?.title ?? "SMB")
                    DetailRow(label: "Shares", value: String.counted(currentShares.count, "share"))
                }

                DetailCard("Connection Behaviour") {
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
            Image(systemName: "externaldrive.fill")
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
                        Label("Mount Now", systemImage: "arrow.triangle.2.circlepath")
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
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More actions for \(share.displayName)")
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
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
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 18) {
                Image(systemName: symbol)
                    .font(.system(size: 34, weight: .regular))
                    .foregroundStyle(.secondary)
                    .frame(width: 76, height: 76)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .accessibilityHidden(true)

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
                            .foregroundStyle(.orange)
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
                    Text(symbols[index])
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
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
            Text(value)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            if let copyValue, !copyValue.isEmpty {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(copyValue, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .imageScale(.small)
                }
                .buttonStyle(.borderless)
                .help("Copy \(label.lowercased())")
                .accessibilityLabel("Copy \(label.lowercased())")
                .opacity(isHovering ? 1 : 0)
            }
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
