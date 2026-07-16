import AppKit
import SwiftUI

struct MenuBarView: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var monitor: ShareMonitor
    @EnvironmentObject private var networkService: NetworkReachabilityService
    @EnvironmentObject private var updaterViewModel: UpdaterViewModel

    private var shares: [NetworkShare] {
        appModel.screenshotDemoShares ?? settings.shares
    }

    private var shareGroups: [NetworkShareServerGroup] {
        NetworkShareServerGroup.make(from: shares)
    }

    var body: some View {
        if shares.isEmpty {
            Text("No shares configured")
        } else {
            ForEach(shareGroups) { group in
                if group.isGrouped {
                    ServerShareMenu(group: group)
                } else if let share = group.shares.first {
                    ShareMenu(share: share)
                }
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
        .disabled(shares.isEmpty)

        Button {
            Task { await monitor.disconnectAll() }
        } label: {
            Label("Disconnect & Pause All", systemImage: "eject")
        }
        .disabled(shares.isEmpty)

        GlobalPauseMenu()

        Divider()

        networkStatusLabel
        if networkService.isVPNConnected || networkService.hasUnidentifiedTunnel {
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

        Button {
            updaterViewModel.checkForUpdates()
        } label: {
            Label("Check for Updates...", systemImage: "arrow.down.circle")
        }
        .disabled(!updaterViewModel.canCheckForUpdates)

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

private struct ServerShareMenu: View {
    @EnvironmentObject private var monitor: ShareMonitor
    let group: NetworkShareServerGroup

    var body: some View {
        Menu {
            Button {
                Task {
                    for share in group.shares {
                        await monitor.mount(share)
                    }
                }
            } label: {
                Label("Mount All Shares", systemImage: "arrow.triangle.2.circlepath")
            }

            ShareGroupPauseMenu(shares: group.shares)

            Button {
                Task {
                    for share in group.shares {
                        await monitor.pause(
                            share,
                            until: nil,
                            disconnect: monitor.status(for: share) == .connected
                        )
                    }
                }
            } label: {
                Label("Disconnect & Pause All", systemImage: "eject")
            }
            .disabled(!group.shares.contains { monitor.status(for: $0) == .connected })

            Divider()

            ForEach(group.shares) { share in
                ShareMenu(share: share)
            }
        } label: {
            Label {
                Text("\(group.serverName) - \(group.shares.count) shares")
            } icon: {
                Image(systemName: "server.rack")
            }
        }
    }
}

private struct ShareMenu: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var settings: SettingsStore
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

            if share.wakeOnLAN.isEnabled {
                Button {
                    Task { await monitor.wake(share) }
                } label: {
                    Label("Wake Server", systemImage: "power")
                }
            }

            SharePauseMenu(share: share)

            Button {
                Task { await monitor.disconnect(share) }
            } label: {
                Label("Disconnect & Pause", systemImage: "eject")
            }

            Button {
                appModel.requestEditShare(share)
                openWindow(id: AppModel.sharesWindowID)
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            .disabled(settings.isManagedShare(id: share.id))

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

struct GlobalPauseMenu: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var monitor: ShareMonitor

    var body: some View {
        if settings.isGloballyPaused {
            Button {
                Task { await monitor.resumeAll() }
            } label: {
                Label("Resume Automatic Mounting", systemImage: "play.fill")
            }
        } else {
            Menu {
                pauseButtons { resumeAt in
                    Task { await monitor.pauseAll(until: resumeAt) }
                }
            } label: {
                Label("Pause Automatic Mounting", systemImage: "pause.fill")
            }
        }
    }
}

struct SharePauseMenu: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var monitor: ShareMonitor
    let share: NetworkShare

    private var currentShare: NetworkShare {
        settings.share(id: share.id) ?? share
    }

    var body: some View {
        if currentShare.pauseState.isActive() {
            Button {
                Task { await monitor.resume(currentShare) }
            } label: {
                Label("Resume Automatic Mounting", systemImage: "play.fill")
            }
        } else {
            Menu {
                pauseButtons { resumeAt in
                    Task { await monitor.pause(currentShare, until: resumeAt) }
                }
            } label: {
                Label("Pause Automatic Mounting", systemImage: "pause.fill")
            }
        }
    }
}

struct ShareGroupPauseMenu: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var monitor: ShareMonitor
    let shares: [NetworkShare]

    private var currentShares: [NetworkShare] {
        shares.map { settings.share(id: $0.id) ?? $0 }
    }

    private var areAllSharesPaused: Bool {
        !currentShares.isEmpty && currentShares.allSatisfy { $0.pauseState.isActive() }
    }

    var body: some View {
        if areAllSharesPaused {
            Button {
                Task {
                    for share in currentShares {
                        await monitor.resume(share)
                    }
                }
            } label: {
                Label("Resume Automatic Mounting for All", systemImage: "play.fill")
            }
        } else {
            Menu {
                pauseButtons { resumeAt in
                    Task {
                        for share in currentShares {
                            await monitor.pause(share, until: resumeAt)
                        }
                    }
                }
            } label: {
                Label("Pause Automatic Mounting for All", systemImage: "pause.fill")
            }
        }
    }
}

@ViewBuilder
private func pauseButtons(action: @escaping (Date?) -> Void) -> some View {
    Button("For 1 Hour") {
        action(Date().addingTimeInterval(60 * 60))
    }
    Button("Until Tomorrow") {
        let calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date()))
        action(tomorrow)
    }
    Button("Until Resumed") {
        action(nil)
    }
}
