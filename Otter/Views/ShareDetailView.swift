import AppKit
import SwiftUI

struct ShareDetailView: View {
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var monitor: ShareMonitor
    @EnvironmentObject private var networkService: NetworkReachabilityService
    @EnvironmentObject private var eventLog: ShareEventLog
    let share: NetworkShare

    @State private var isShowingConditions = false

    var body: some View {
        let status = monitor.status(for: currentShare)
        let runtimeState = monitor.runtimeState(for: currentShare)

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                
                // Status Section
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Image(systemName: status.circleSymbol)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(status.color)
                            .accessibilityHidden(true)

                        Text(status.label)
                            .font(.headline)
                            .foregroundStyle(.primary)
                    }
                    
                    VStack(alignment: .leading, spacing: 1) {
                        if case .connected = status {
                            if let mountedAt = runtimeState.mountedAt {
                                Text("Mounted since \(Self.relativeDayTime(mountedAt))")
                            }
                        } else {
                            if let detail = status.detail {
                                Text(detail)
                            } else {
                                Text("Retrying automatically")
                            }
                        }
                        
                        if let lastConnected = runtimeState.lastConnectedAt {
                            Text("Last connected \(Self.relativeDayTime(lastConnected))")
                        }

                        let dropCount = appModel.screenshotDemoDropCount(for: currentShare.id)
                            ?? eventLog.connectionDropCount(for: currentShare.id)
                        if dropCount > 0 {
                            Text("Connection dropped ^[\(dropCount) time](inflect: true) in the last 24 hours")
                                .foregroundStyle(.orange)
                        }
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 14)
                    .accessibilityElement(children: .combine)

                    if status.offersVPNSettingsAction {
                        Button {
                            openVPNSettings()
                        } label: {
                            Label("Open VPN Settings", systemImage: "gearshape")
                        }
                        .tahoeSecondaryActionButton()
                        .padding(.top, 8)
                        .padding(.leading, 14)
                    }
                }
                
                Divider()

                // Reliability sits next to the status it explains, ahead of
                // the static configuration below.
                VStack(alignment: .leading, spacing: 10) {
                    DetailSectionHeader("Reliability")
                    let summary = eventLog.reliabilitySummary(for: currentShare.id)
                    VStack(spacing: 6) {
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
                }

                Divider()
                
                // Server / Connection Details Section
                VStack(alignment: .leading, spacing: 10) {
                    DetailSectionHeader("Details")

                    VStack(spacing: 6) {
                        if let customServerName = settings.customServerName(for: currentShare) {
                            DetailRow(label: "Server", value: customServerName)
                            DetailRow(label: "Address", value: currentShare.host ?? "Unknown")
                        } else {
                            DetailRow(label: "Server", value: currentShare.host ?? "Unknown")
                        }
                        ForEach(currentShare.orderedCachedIPAddresses, id: \.self) { address in
                            DetailRow(
                                label: NetworkShare.isIPv4Address(address) ? "IPv4 address" : "IPv6 address",
                                value: address
                            )
                        }
                        DetailRow(label: "Share", value: NetworkShare.inferredShareName(from: currentShare.urlString) ?? currentShare.displayName)
                        DetailRow(label: "Mount location", value: currentShare.mountPath)
                        DetailRow(label: "Protocol", value: currentShare.connectionProtocol?.title ?? "Unknown")
                        DetailStatusRow(
                            label: "Keychain credentials",
                            isOn: hasKeychainCredentials,
                            onText: "Saved",
                            offText: "Not found"
                        )

                        ServerNameButton(share: currentShare)

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
                            .padding(.top, 3)
                        }
                    }
                }
                
                Divider()
                
                NASDiagnosticsSection(
                    shares: diagnosticShares,
                    serverName: diagnosticShares.count > 1
                        ? currentShare.serverDisplayName(customNames: settings.preferences.serverNames)
                        : nil
                )

                Divider()

                // Configuration Section (Read-Only)
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        DetailSectionHeader("Configuration")
                        if settings.isManagedShare(id: currentShare.id) {
                            Label("Managed", systemImage: "checkmark.shield.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    
                    VStack(spacing: 6) {
                        DetailRow(label: "Connection mode", value: currentShare.connectionMode.title)
                        if let pauseState = settings.effectivePauseState(for: currentShare) {
                            DetailRow(label: "Automatic mounting", value: pauseDescription(pauseState))
                        }
                        if currentShare.connectionMode.usesRemoteAccess,
                           let vpnName = currentShare.rules.requiredVPNName {
                            DetailRow(label: "Remote access", value: vpnName)
                        }
                        if currentShare.wakeOnLAN.isEnabled {
                            ConfigStatusRow(label: "Wake sleeping server")
                        }
                        DetailRow(label: "Address preference", value: currentShare.prefersIPv4 ? "IPv4 first" : "IPv6 first")
                    }
                }
                
                Divider()
                
                // Conditions Section (Read-Only). Collapsed by default: the
                // one-line summary in the label answers the usual question.
                DisclosureGroup(isExpanded: $isShowingConditions) {
                    VStack(spacing: 6) {
                        if currentShare.rules.hasNetworkRule || currentShare.rules.hasVPNRule {
                            if !currentShare.rules.registeredSubnets.isEmpty {
                                DetailRow(label: "Network", value: currentShare.rules.registeredSubnets.joined(separator: ", "))
                            }
                            if let ssid = currentShare.rules.requiredWiFiNetworkName {
                                DetailRow(label: "Wi-Fi", value: ssid)
                            }
                            if currentShare.rules.hasVPNRule {
                                DetailRow(label: "VPN", value: currentShare.rules.requiredVPNName ?? "Selection required")
                                DetailRow(
                                    label: "VPN startup",
                                    value: currentShare.rules.shouldConnectVPNAutomatically ? "Automatic" : "Manual"
                                )
                            }
                        } else {
                            DetailRow(label: "Network", value: "No restrictions")
                        }
                    }
                    .padding(.top, 8)
                } label: {
                    HStack {
                        DetailSectionHeader("Conditions")
                        Spacer()
                        Text(connectionConditionLabel)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.18)) { isShowingConditions.toggle() }
                    }
                }
                
            }
            .padding(20)
        }
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear {
            networkService.refreshNetworkDetails()
        }
    }

    private var connectionConditionLabel: String {
        switch (currentShare.rules.hasNetworkRule, currentShare.rules.hasVPNRule) {
        case (true, true):
            return "Registered network or VPN"
        case (true, false):
            return "Registered network"
        case (false, true):
            return "VPN connection"
        case (false, false):
            return "Any network"
        }
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

struct ServerDetailView: View {
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var monitor: ShareMonitor
    @EnvironmentObject private var eventLog: ShareEventLog
    let group: NetworkShareServerGroup

    var body: some View {
        let summary = statusSummary

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Image(systemName: summary.symbol)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(summary.color)
                            .accessibilityHidden(true)

                        Text(summary.label)
                            .font(.headline)
                            .foregroundStyle(.primary)
                    }

                    Text(summary.detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 14)

                    if connectionDropCount > 0 {
                        Text("Connection dropped ^[\(connectionDropCount) time](inflect: true) across this server in the last 24 hours")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                            .padding(.leading, 14)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    DetailSectionHeader("Details")

                    VStack(spacing: 6) {
                        DetailRow(label: "Server", value: group.serverName)
                        if let host = currentShares.first?.host,
                           host.localizedCaseInsensitiveCompare(group.serverName) != .orderedSame {
                            DetailRow(label: "Address", value: host)
                        }
                        DetailRow(label: "Protocol", value: "SMB")

                        if let share = currentShares.first {
                            ServerNameButton(share: share)
                        }
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    DetailSectionHeader("Shares")

                    VStack(spacing: 8) {
                        ForEach(currentShares) { share in
                            ServerShareStatusRow(share: share)
                        }
                    }
                }

                Divider()

                NASDiagnosticsSection(shares: currentShares, serverName: group.serverName)

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    DetailSectionHeader("Configuration Summary")

                    VStack(spacing: 6) {
                        DetailRow(label: "Connection mode", value: connectionModeSummary)
                        ServerConfigSummaryRow(
                            label: "Wake sleeping server",
                            enabledCount: currentShares.filter { $0.wakeOnLAN.isEnabled }.count,
                            totalCount: currentShares.count
                        )
                    }
                }
            }
            .padding(20)
        }
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var currentShares: [NetworkShare] {
        group.shares.map { settings.share(id: $0.id) ?? $0 }
    }

    private var connectionModeSummary: String {
        let modes = Set(currentShares.map(\.connectionMode))
        guard let mode = modes.first, modes.count == 1 else { return "Mixed" }
        return mode.title
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
                .font(.subheadline)
                .foregroundStyle(.primary)
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
            .font(.subheadline)
            .fontWeight(.bold)
            .foregroundStyle(.secondary)
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
            Label(
                customName == nil && share.isAddressedByIP ? "Add Server Name…" : "Rename Server…",
                systemImage: "character.cursor.ibeam"
            )
        }
        .tahoeSecondaryActionButton()
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
