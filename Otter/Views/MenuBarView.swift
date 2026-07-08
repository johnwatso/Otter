import AppKit
import SwiftUI

struct MenuBarView: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var monitor: ShareMonitor
    @EnvironmentObject private var networkService: NetworkReachabilityService
    @EnvironmentObject private var updateService: UpdateService

    var body: some View {
        if settings.shares.isEmpty {
            Text("No shares configured")
        } else {
            ForEach(settings.shares) { share in
                ShareMenu(share: share)
            }
        }

        Divider()

        Button {
            appModel.requestNewShare()
            showShares()
        } label: {
            Label("Add Share", systemImage: "plus")
        }

        Button {
            Task { await monitor.mountAll() }
        } label: {
            Label("Mount All", systemImage: "arrow.triangle.2.circlepath")
        }
        .disabled(settings.shares.isEmpty)

        Button {
            Task { await monitor.disconnectAll() }
        } label: {
            Label("Disconnect All", systemImage: "eject")
        }
        .disabled(settings.shares.isEmpty)

        Divider()

        networkStatusLabel
        if networkService.isVPNConnected {
            vpnStatusLabel
        }

        Divider()

        Button {
            showShares()
        } label: {
            Label("Manage Shares", systemImage: "externaldrive")
        }

        Button {
            showPreferences()
        } label: {
            Label("Preferences", systemImage: "gearshape")
        }

        if updateService.updateAvailable, let latestVersion = updateService.latestVersion {
            Button {
                NSWorkspace.shared.open(updateService.releaseURL)
            } label: {
                Label("Update Available (\(latestVersion))...", systemImage: "arrow.down.circle")
            }
        }

        Button {
            NSApp.terminate(nil)
        } label: {
            Label("Quit Otter", systemImage: "power")
        }
    }

    private var networkStatusLabel: some View {
        Label(
            networkStatusText,
            systemImage: networkService.isOnline ? "wifi" : "wifi.slash"
        )
    }

    private var vpnStatusLabel: some View {
        Label("VPN: \(vpnStatusText)", systemImage: "lock.shield")
    }

    private var vpnStatusText: String {
        networkService.currentVPNDisplayName
    }

    private var networkStatusText: String {
        if let networkName = networkService.currentWiFiNetworkName {
            return "Wi-Fi: \(networkName)"
        }

        return networkService.isOnline ? "Network available" : "No active network"
    }

    private func showPreferences() {
        openWindow(id: AppModel.preferencesWindowID)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showShares() {
        openWindow(id: AppModel.sharesWindowID)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct ShareMenu: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var monitor: ShareMonitor
    let share: NetworkShare

    var body: some View {
        Menu {
            statusLabel

            Divider()

            Button {
                Task { await monitor.mount(share) }
            } label: {
                Label("Mount Now", systemImage: "arrow.triangle.2.circlepath")
            }

            Button {
                Task { await monitor.disconnect(share) }
            } label: {
                Label("Disconnect", systemImage: "eject")
            }

            Button {
                appModel.requestEditShare(share)
                openWindow(id: AppModel.sharesWindowID)
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("Edit", systemImage: "pencil")
            }

            if case .connected = monitor.status(for: share) {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: share.mountPath)])
                } label: {
                    Label("Show in Finder", systemImage: "finder")
                }
            }

            if monitor.runtimeState(for: share).needsCredentials, let url = share.url {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Label("Connect Once in Finder...", systemImage: "person.badge.key")
                }
            }
        } label: {
            Label {
                Text("\(share.displayName) - \(monitor.status(for: share).label)")
            } icon: {
                Image(systemName: monitor.status(for: share).systemImage)
            }
        }
    }

    private var statusLabel: some View {
        let status = monitor.status(for: share)
        return Label(status.label, systemImage: status.systemImage)
    }
}
