import AppKit
import SwiftUI

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
                DetailHeroHeader(
                    symbol: "externaldrive.fill",
                    badge: status.circleSymbol,
                    color: status.color,
                    title: currentShare.displayName,
                    subtitle: currentShare.serverDisplayName(customNames: settings.preferences.serverNames),
                    statusText: status.label,
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

                // Reliability sits next to the status it explains, ahead of
                // the static configuration below.
                DetailCard("Reliability") {
                    let summary = eventLog.reliabilitySummary(for: currentShare.id)
                    DetailRow(label: "Last 7 days", value: summary.isStable
                        ? "No recorded problems"
                        : "\(String.counted(summary.connectionDrops, "drop")) · \(String.counted(summary.failures, "failure")) · \(String.counted(summary.healthFailures, "health warning"))")
                    if let lastProblemAt = summary.lastProblemAt {
                        DetailRow(label: "Last problem", value: lastProblemAt.formatted(date: .abbreviated, time: .shortened))
                    }
                    DetailRow(
                        label: "Health checks",
                        value: currentShare.healthCheck.isEnabled ? healthCheckDescription : "Off"
                    )
                }

                DetailCard("Details") {
                    if let customServerName = settings.customServerName(for: currentShare) {
                        DetailRow(label: "Server", value: customServerName)
                        DetailRow(label: "Address", value: currentShare.host ?? "Unknown")
                    } else {
                        DetailRow(label: "Server", value: currentShare.host ?? "Unknown")
                    }
                    DetailRow(label: "Share", value: NetworkShare.inferredShareName(from: currentShare.urlString) ?? currentShare.displayName)
                    DetailRow(label: "Mount location", value: currentShare.mountPath)
                    DetailStatusRow(
                        label: "Keychain credentials",
                        isOn: hasKeychainCredentials,
                        onText: "Saved",
                        offText: "Not found"
                    )

                    if runtimeState.needsCredentials {
                        Button {
                            refreshCredentials()
                        } label: {
                            Label("Refresh Credentials in Finder", systemImage: "key.fill")
                        }
                        .tahoeSecondaryActionButton()
                    }

                    if currentShare.hasUnstableIPAddress() {
                        HStack(alignment: .top, spacing: 7) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .accessibilityLabel("Warning")
                            Text("The LAN address has changed repeatedly this month. Otter still connects by hostname first; a DHCP reservation may improve fallback reliability.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                    }
                } accessory: {
                    ServerNameButton(share: currentShare)
                }

                // Read-only. Everything here is changed in the share editor.
                DetailCard("Connection") {
                    DetailRow(label: "Connects", value: currentShare.connectionMode.summaryTitle)
                    if let pauseState = settings.effectivePauseState(for: currentShare) {
                        DetailRow(label: "Automatic mounting", value: pauseDescription(pauseState))
                    }
                    if currentShare.connectionMode.usesRemoteAccess,
                       let vpnName = currentShare.rules.requiredVPNName {
                        DetailRow(label: "VPN", value: "\(vpnName) · \(currentShare.rules.shouldConnectVPNAutomatically ? "starts automatically" : "connect manually")")
                    }
                    if currentShare.wakeOnLAN.isEnabled {
                        ConfigStatusRow(label: "Wake sleeping server")
                    }
                } accessory: {
                    if settings.isManagedShare(id: currentShare.id) {
                        Label("Managed", systemImage: "checkmark.shield.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(24)
        }
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear {
            networkService.refreshNetworkDetails()
        }
    }

    private func statusLines(status: ShareStatus, runtimeState: ShareRuntimeState) -> [String] {
        var lines: [String] = []
        if case .connected = status {
            if let mountedAt = runtimeState.mountedAt {
                lines.append("Mounted since \(Self.relativeDayTime(mountedAt))")
            }
        } else {
            lines.append(status.detail ?? "Retrying automatically")
        }
        if let lastConnected = runtimeState.lastConnectedAt {
            lines.append("Last connected \(Self.relativeDayTime(lastConnected))")
        }
        return lines
    }

    private var dropWarning: String? {
        let dropCount = appModel.screenshotDemoDropCount(for: currentShare.id)
            ?? eventLog.connectionDropCount(for: currentShare.id)
        return dropCount > 0 ? "Connection dropped \(String.counted(dropCount, "time")) in the last 24 hours" : nil
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

    private func pauseDescription(_ pauseState: PauseState) -> String {
        if let resumeAt = pauseState.resumeAt {
            return "Paused until \(resumeAt.formatted(date: .abbreviated, time: .shortened))"
        }
        return "Paused until resumed"
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
        if !currentShare.healthCheck.sentinelRelativePath.isEmpty { parts.append("Checks \(currentShare.healthCheck.sentinelRelativePath)") }
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

    private var diagnosticShares: [NetworkShare] {
        NetworkShareServerGroup.diagnosticShares(
            containing: currentShare,
            in: settings.shares
        )
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<NetworkShare, Value>) -> Binding<Value> {
        Binding {
            currentShare[keyPath: keyPath]
        } set: { value in
            settings.updateShare(id: currentShare.id) { share in
                share[keyPath: keyPath] = value
            }
        }
    }

}

struct ServerDetailView<Actions: View>: View {
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var monitor: ShareMonitor
    @EnvironmentObject private var eventLog: ShareEventLog
    let group: NetworkShareServerGroup
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        let summary = statusSummary

        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                DetailHeroHeader(
                    symbol: "server.rack",
                    badge: summary.symbol,
                    color: summary.color,
                    title: group.serverName,
                    subtitle: group.shareCountLabel,
                    statusText: summary.label,
                    lines: [summary.detail],
                    warning: connectionDropCount > 0
                        ? "Connection dropped \(String.counted(connectionDropCount, "time")) across this server in the last 24 hours"
                        : nil,
                    actions: actions
                )

                DetailCard("Shares") {
                    ForEach(currentShares) { share in
                        ServerShareStatusRow(share: share)
                    }
                }

                DetailCard("Details") {
                    DetailRow(label: "Server", value: group.serverName)
                    if let host = currentShares.first?.host,
                       host.localizedCaseInsensitiveCompare(group.serverName) != .orderedSame {
                        DetailRow(label: "Address", value: host)
                    }
                    DetailRow(label: "Protocol", value: "SMB")
                } accessory: {
                    if let share = currentShares.first {
                        ServerNameButton(share: share)
                    }
                }

                DetailCard("Connection") {
                    DetailRow(label: "Connects", value: connectionModeSummary)
                    ServerConfigSummaryRow(
                        label: "Wake sleeping server",
                        enabledCount: currentShares.filter { $0.wakeOnLAN.isEnabled }.count,
                        totalCount: currentShares.count
                    )
                }
            }
            .padding(24)
        }
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var currentShares: [NetworkShare] {
        group.shares.map { settings.share(id: $0.id) ?? $0 }
    }

    private var connectionModeSummary: String {
        let modes = Set(currentShares.map(\.connectionMode))
        guard let mode = modes.first, modes.count == 1 else { return "Mixed" }
        return mode.summaryTitle
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
            ? (statuses.count == 2 ? "Both shares connected" : "All \(statuses.count) shares connected")
            : "\(connectedCount) of \(statuses.count) shares connected"

        if !statuses.isEmpty && connectedCount == statuses.count {
            return ServerStatusSummary(
                symbol: "checkmark.circle.fill",
                color: .green,
                label: "Connected",
                detail: detail
            )
        }
        if statuses.contains(where: { if case .failed = $0 { true } else { false } }) {
            return ServerStatusSummary(
                symbol: "exclamationmark.circle.fill",
                color: .red,
                label: "Some shares need attention",
                detail: detail
            )
        }
        if statuses.contains(.reconnecting) {
            return ServerStatusSummary(
                symbol: "arrow.triangle.2.circlepath.circle.fill",
                color: .blue,
                label: "Connecting shares",
                detail: detail
            )
        }
        if connectedCount > 0 {
            return ServerStatusSummary(
                symbol: "circle.lefthalf.filled",
                color: .orange,
                label: "Partially connected",
                detail: detail
            )
        }
        if statuses.contains(where: { if case .paused = $0 { true } else { false } }) {
            return ServerStatusSummary(
                symbol: "pause.circle.fill",
                color: .indigo,
                label: "Automatic mounting paused",
                detail: detail
            )
        }
        return ServerStatusSummary(
            symbol: "minus.circle.fill",
            color: .secondary,
            label: "No shares connected",
            detail: detail
        )
    }
}

private struct ServerStatusSummary {
    let symbol: String
    let color: Color
    let label: String
    let detail: String
}

private struct ServerShareStatusRow: View {
    @EnvironmentObject private var monitor: ShareMonitor
    let share: NetworkShare

    var body: some View {
        let status = monitor.status(for: share)

        HStack(spacing: 8) {
            Image(systemName: status.circleSymbol)
                .font(.caption)
                .foregroundStyle(status.color)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(share.displayName)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                // Only show the share path when it adds something beyond the name.
                if let subtitle, subtitle.localizedCaseInsensitiveCompare(share.displayName) != .orderedSame {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Text(status.label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 1)
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String? {
        NetworkShare.inferredShareName(from: share.urlString) ?? share.mountPath
    }
}

private struct ServerConfigSummaryRow: View {
    let label: String
    let enabledCount: Int
    let totalCount: Int

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .accessibilityHidden(true)
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.primary)
            Spacer()
            Text(value)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 1)
    }

    private var symbol: String {
        if enabledCount == 0 { return "minus.circle" }
        if enabledCount == totalCount { return "checkmark.circle.fill" }
        return "circle.lefthalf.filled"
    }

    private var color: Color {
        if enabledCount == 0 { return .secondary }
        if enabledCount == totalCount { return .green }
        return .orange
    }

    private var value: String {
        if enabledCount == 0 { return "Off for all" }
        if enabledCount == totalCount { return "On for all" }
        return "On for \(enabledCount) of \(totalCount)"
    }
}

/// The top of a detail pane: what this is, whether it is healthy, and what the
/// user can do about it, so the answer to "is it OK?" is the first thing seen.
struct DetailHeroHeader<Actions: View>: View {
    let symbol: String
    let badge: String
    let color: Color
    let title: String
    var subtitle: String?
    let statusText: String
    var lines: [String] = []
    var warning: String?
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 16) {
                ZStack(alignment: .bottomTrailing) {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(color.opacity(0.14))
                        .frame(width: 64, height: 64)
                        .overlay {
                            Image(systemName: symbol)
                                .font(.system(size: 28, weight: .medium))
                                .foregroundStyle(color)
                        }

                    Image(systemName: badge)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(color)
                        .background(Circle().fill(Color(NSColor.windowBackgroundColor)).padding(-2))
                        .offset(x: 5, y: 5)
                }
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.title2.weight(.semibold))
                        .lineLimit(1)
                    Text(statusText)
                        .font(.headline)
                        .foregroundStyle(color)
                    if let subtitle {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }

            if !lines.isEmpty || warning != nil {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(lines, id: \.self) { line in
                        Text(line).foregroundStyle(.secondary)
                    }
                    if let warning {
                        Text(warning).foregroundStyle(.orange)
                    }
                }
                .font(.subheadline)
            }

            HStack(spacing: 8) {
                actions()
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// A titled group of rows on a raised, rounded surface.
struct DetailCard<Content: View, Accessory: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    @ViewBuilder let accessory: () -> Accessory

    init(
        _ title: String,
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder accessory: @escaping () -> Accessory
    ) {
        self.title = title
        self.content = content
        self.accessory = accessory
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
                .strokeBorder(Color.primary.opacity(0.07))
        )
    }
}

extension DetailCard where Accessory == EmptyView {
    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.init(title, content: content, accessory: { EmptyView() })
    }
}

struct DetailRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(.vertical, 1)
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
            Spacer()
            Label {
                Text(isOn ? onText : offText)
                    .foregroundStyle(.primary)
            } icon: {
                Image(systemName: isOn ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(isOn ? .green : .red)
            }
            .font(.subheadline)
            .labelStyle(.titleAndIcon)
        }
        .padding(.vertical, 1)
        .accessibilityElement(children: .combine)
    }
}

/// Lets the user choose the server name shown by Otter. The custom name applies
/// to every share on that server without changing its network address.
private struct ServerNameButton: View {
    @EnvironmentObject private var settings: SettingsStore
    let share: NetworkShare
    @State private var isEditing = false
    @State private var draftName = ""

    var body: some View {
        let customName = settings.customServerName(for: share)

        Button {
            draftName = customName ?? share.serverDisplayName
            isEditing = true
        } label: {
            Image(systemName: "pencil")
                .imageScale(.small)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(customName == nil && share.isAddressedByIP ? "Add Server Name…" : "Rename Server…")
        .accessibilityLabel(customName == nil && share.isAddressedByIP ? "Add Server Name" : "Rename Server")
        .alert(customName == nil && share.isAddressedByIP ? "Add Server Name" : "Rename Server", isPresented: $isEditing) {
            TextField("Server name", text: $draftName)
            Button("Save") {
                settings.setCustomServerName(draftName, for: share)
            }
            if customName != nil {
                Button("Use Address Name", role: .destructive) {
                    settings.setCustomServerName(nil, for: share)
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This name is shown only in Otter and applies to every share on this server. Its network address remains \(share.host ?? "unchanged").")
        }
    }
}

private struct ConfigStatusRow: View {
    let label: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.primary)
            Spacer()
        }
        .padding(.vertical, 1)
    }
}
