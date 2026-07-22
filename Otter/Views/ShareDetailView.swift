import AppKit
import SwiftUI

struct ShareDetailView: View {
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var monitor: ShareMonitor
    @EnvironmentObject private var networkService: NetworkReachabilityService
    @EnvironmentObject private var eventLog: ShareEventLog
    let share: NetworkShare

    var body: some View {
        let status = monitor.status(for: currentShare)
        let runtimeState = monitor.runtimeState(for: currentShare)

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                
                // Status Section
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Image(systemName: status.circleSymbol)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(status.color)

                        Text(status.label)
                            .font(.headline)
                            .foregroundStyle(.primary)
                    }
                    
                    VStack(alignment: .leading, spacing: 1) {
                        if case .connected = status {
                            if let mountedAt = runtimeState.mountedAt {
                                Text("Mounted since \(mountedAt, format: .dateTime.hour().minute())")
                            }
                        } else {
                            if let detail = status.detail {
                                Text(detail)
                            } else {
                                Text("Retrying automatically")
                            }
                        }
                        
                        if let lastConnected = runtimeState.lastConnectedAt {
                            Text(formatLastConnected(lastConnected))
                        }

                        let dropCount = appModel.screenshotDemoDropCount(for: currentShare.id)
                            ?? eventLog.connectionDropCount(for: currentShare.id)
                        if dropCount > 0 {
                            Text("Connection dropped \(dropCount) time\(dropCount == 1 ? "" : "s") in the last 24 hours")
                                .foregroundStyle(.orange)
                        }
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 14)

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
                
                // Server / Connection Details Section
                VStack(alignment: .leading, spacing: 10) {
                    Text("Details")
                        .font(.subheadline)
                        .fontWeight(.bold)
                        .foregroundStyle(.secondary)

                    VStack(spacing: 6) {
                        DetailRow(label: "Server", value: currentShare.host ?? "Unknown")
                        if let cachedIPAddress = currentShare.cachedIPAddress {
                            DetailRow(label: "LAN fallback", value: cachedIPAddress)
                        }
                        DetailRow(label: "Share", value: NetworkShare.inferredShareName(from: currentShare.urlString) ?? currentShare.displayName)
                        DetailRow(label: "Mount location", value: currentShare.mountPath)
                        DetailRow(label: "Protocol", value: "SMB")
                        DetailRow(label: "Keychain credentials", value: hasKeychainCredentials ? "✓ Saved" : "✕ Not found")

                        if currentShare.hasUnstableIPAddress() {
                            HStack(alignment: .top, spacing: 7) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
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
                
                // Configuration Section (Read-Only)
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Configuration")
                            .font(.subheadline)
                            .fontWeight(.bold)
                            .foregroundStyle(.secondary)
                        if settings.isManagedShare(id: currentShare.id) {
                            Label("Managed", systemImage: "checkmark.shield.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    
                    VStack(spacing: 6) {
                        ConfigStatusRow(label: "Reconnect automatically", isEnabled: currentShare.keepMounted)
                        if let pauseState = settings.effectivePauseState(for: currentShare) {
                            DetailRow(label: "Automatic mounting", value: pauseDescription(pauseState))
                        }
                        ConfigStatusRow(label: "Connect when server becomes available", isEnabled: currentShare.autoConnectWhenReachable)
                        ConfigStatusRow(label: "Mount at login", isEnabled: currentShare.mountAtLaunch)
                        ConfigStatusRow(label: "Wake sleeping server", isEnabled: currentShare.wakeOnLAN.isEnabled)
                    }
                }
                
                Divider()
                
                // Conditions Section (Read-Only)
                VStack(alignment: .leading, spacing: 10) {
                    Text("Conditions")
                        .font(.subheadline)
                        .fontWeight(.bold)
                        .foregroundStyle(.secondary)
                    
                    VStack(spacing: 6) {
                        if currentShare.rules.hasNetworkRule || currentShare.rules.hasVPNRule {
                            DetailRow(label: "Connect on", value: connectionConditionLabel)
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
                            DetailRow(label: "Connect on", value: "Any network")
                        }
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

    private func formatLastConnected(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "Last connected Today at \(date.formatted(.dateTime.hour().minute()))"
        } else if calendar.isDateInYesterday(date) {
            return "Last connected Yesterday at \(date.formatted(.dateTime.hour().minute()))"
        } else {
            return "Last connected on \(date.formatted(.dateTime.month().day().hour().minute()))"
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
        if let cachedIP = currentShare.cachedIPAddress, settings.hasCredentials(for: cachedIP) {
            return true
        }
        return false
    }

    private var currentShare: NetworkShare {
        settings.share(id: share.id) ?? share
    }

    private var fallbackURLString: String? {
        guard let cachedIP = currentShare.cachedIPAddress,
              let url = currentShare.url,
              let host = url.host(percentEncoded: false),
              !NetworkShare.isIPAddress(host)
        else { return nil }

        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.host = cachedIP
        return components?.string
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
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(summary.color)

                        Text(summary.label)
                            .font(.headline)
                            .foregroundStyle(.primary)
                    }

                    Text(summary.detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 14)

                    if connectionDropCount > 0 {
                        Text("Connection dropped \(connectionDropCount) time\(connectionDropCount == 1 ? "" : "s") across this server in the last 24 hours")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                            .padding(.leading, 14)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    Text("Details")
                        .font(.subheadline)
                        .fontWeight(.bold)
                        .foregroundStyle(.secondary)

                    VStack(spacing: 6) {
                        DetailRow(label: "Server", value: group.serverName)
                        if let host = currentShares.first?.host,
                           host.localizedCaseInsensitiveCompare(group.serverName) != .orderedSame {
                            DetailRow(label: "Address", value: host)
                        }
                        DetailRow(label: "Shares", value: "\(currentShares.count)")
                        DetailRow(label: "Protocol", value: "SMB")
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    Text("Shares")
                        .font(.subheadline)
                        .fontWeight(.bold)
                        .foregroundStyle(.secondary)

                    VStack(spacing: 8) {
                        ForEach(currentShares) { share in
                            ServerShareStatusRow(share: share)
                        }
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    Text("Configuration Summary")
                        .font(.subheadline)
                        .fontWeight(.bold)
                        .foregroundStyle(.secondary)

                    VStack(spacing: 6) {
                        ServerConfigSummaryRow(
                            label: "Reconnect automatically",
                            enabledCount: currentShares.filter(\.keepMounted).count,
                            totalCount: currentShares.count
                        )
                        ServerConfigSummaryRow(
                            label: "Connect when server becomes available",
                            enabledCount: currentShares.filter(\.autoConnectWhenReachable).count,
                            totalCount: currentShares.count
                        )
                        ServerConfigSummaryRow(
                            label: "Mount at login",
                            enabledCount: currentShares.filter(\.mountAtLaunch).count,
                            totalCount: currentShares.count
                        )
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

    private var connectionDropCount: Int {
        currentShares.reduce(into: 0) { count, share in
            count += appModel.screenshotDemoDropCount(for: share.id)
                ?? eventLog.connectionDropCount(for: share.id)
        }
    }

    private var statusSummary: ServerStatusSummary {
        let statuses = currentShares.map { monitor.status(for: $0) }
        let connectedCount = statuses.filter { $0 == .connected }.count
        let detail = "\(connectedCount) of \(statuses.count) shares connected"

        if !statuses.isEmpty && connectedCount == statuses.count {
            return ServerStatusSummary(
                symbol: "checkmark.circle.fill",
                color: .green,
                label: "All shares connected",
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

            VStack(alignment: .leading, spacing: 1) {
                Text(share.displayName)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                Text(NetworkShare.inferredShareName(from: share.urlString) ?? share.mountPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(status.label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 1)
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

private struct DetailRow: View {
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
    }
}

private struct ConfigStatusRow: View {
    let label: String
    let isEnabled: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isEnabled ? "checkmark.circle.fill" : "minus.circle")
                .foregroundStyle(isEnabled ? .green : .secondary)
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.primary)
            Spacer()
        }
        .padding(.vertical, 1)
    }
}
