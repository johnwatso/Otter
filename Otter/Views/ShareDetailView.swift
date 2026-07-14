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
                    Text("Configuration")
                        .font(.subheadline)
                        .fontWeight(.bold)
                        .foregroundStyle(.secondary)
                    
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
                            DetailRow(label: "Connect on", value: "Registered network or VPN")
                            if !currentShare.rules.registeredSubnets.isEmpty {
                                DetailRow(label: "Network", value: currentShare.rules.registeredSubnets.joined(separator: ", "))
                            }
                            if let ssid = currentShare.rules.requiredWiFiNetworkName {
                                DetailRow(label: "Wi-Fi", value: ssid)
                            }
                            DetailRow(label: "VPN", value: currentShare.rules.requiredVPNName ?? "Any VPN")
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
