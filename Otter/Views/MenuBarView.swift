import AppKit
import SwiftUI

struct MenuBarView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var monitor: ShareMonitor
    @EnvironmentObject private var updaterViewModel: UpdaterViewModel
    @EnvironmentObject private var newShareDetector: NewShareDetectionService

    private var shares: [NetworkShare] {
        appModel.screenshotDemoShares ?? settings.shares
    }

    private var shareGroups: [NetworkShareServerGroup] {
        NetworkShareServerGroup.make(from: shares, serverNames: settings.preferences.serverNames)
    }

    private var hasAutomaticShares: Bool {
        shares.contains(where: { $0.connectsAutomatically })
    }

    // Shares first, one row each; then the few things that apply to all of
    // them.
    var body: some View {
        Group {
            if !newShareDetector.pendingSuggestions.isEmpty {
                ForEach(newShareDetector.pendingSuggestions) { suggestion in
                    DetectedShareMenu(suggestion: suggestion)
                }

                Divider()
            }

            if shares.isEmpty {
                Text("No shares configured")
            } else {
                ForEach(shareGroups) { group in
                    if group.isGrouped || settings.preferences.alwaysShowServerName {
                        Section(group.serverName) {
                            ForEach(group.shares) { share in
                                ShareMenu(share: share)
                            }
                        }
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
                Label("Add Share…", systemImage: "plus")
            }
            .keyboardShortcut("n")

            Button {
                Task { await monitor.mountAll() }
            } label: {
                Label("Connect All", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(shares.isEmpty)

            Button {
                Task { await monitor.disconnectAll() }
            } label: {
                Label(hasAutomaticShares ? "Disconnect & Pause All" : "Disconnect All", systemImage: "eject")
            }
            .disabled(shares.isEmpty)

            GlobalPauseMenu()

            Divider()

            Button {
                showShares()
            } label: {
                Label("Manage Shares", systemImage: "externaldrive")
            }

            Button {
                showPreferences()
            } label: {
                Label("Settings…", systemImage: "gearshape")
            }
            .keyboardShortcut(",")

            CheckForUpdatesButton(updaterViewModel: updaterViewModel)

            Button {
                NSApp.terminate(nil)
            } label: {
                Label("Quit Otter", systemImage: "power")
            }
            .keyboardShortcut("q")
        }
        // Menu content falls back to title-only labels; ask for the symbols.
        .labelStyle(.titleAndIcon)
    }

    private func showPreferences() {
        openSettings()
        bringOtterToFront()
    }

    private func showShares() {
        openWindow(id: AppModel.sharesWindowID)
        bringOtterToFront(windowTitled: "Manage Shares")
    }
}

// Observes the updater itself so the item enables once Sparkle is ready. Menu
// commands are not views that SwiftUI re-renders on their own, so reading
// `canCheckForUpdates` through anything that is not observed leaves the item
// stuck in its launch-time, disabled state.
struct CheckForUpdatesButton: View {
    @ObservedObject var updaterViewModel: UpdaterViewModel

    var body: some View {
        Button {
            updaterViewModel.checkForUpdates()
        } label: {
            Label("Check for Updates…", systemImage: "arrow.down.circle")
        }
        .disabled(!updaterViewModel.isConfigured || !updaterViewModel.canCheckForUpdates)
    }
}

// A share that appeared while Otter was running. The offer stays in the menu
// until it's answered, whether or not the notification was seen.
private struct DetectedShareMenu: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var newShareDetector: NewShareDetectionService
    let suggestion: MountedShareSuggestion

    var body: some View {
        Menu {
            Button {
                appModel.manageDetectedShare(suggestion)
                showShares()
            } label: {
                Label("Keep This Mounted", systemImage: "externaldrive.badge.plus")
            }

            Button {
                appModel.reviewDetectedShare(suggestion)
                showShares()
            } label: {
                Label("Set Up…", systemImage: "gearshape")
            }

            Divider()

            Button {
                newShareDetector.dismiss(suggestion)
            } label: {
                Label("Not Now", systemImage: "xmark")
            }

            Button {
                newShareDetector.ignore(suggestion)
            } label: {
                Label("Don't Ask Again", systemImage: "bell.slash")
            }
        } label: {
            Label {
                Text("New share: \(suggestion.displayName)")
            } icon: {
                Image(systemName: "externaldrive.badge.questionmark")
            }
        }
    }

    private func showShares() {
        openWindow(id: AppModel.sharesWindowID)
        bringOtterToFront(windowTitled: "Manage Shares")
    }
}

private struct ShareMenu: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var monitor: ShareMonitor
    let share: NetworkShare

    var body: some View {
        let status = monitor.status(for: share)

        Menu {
            if case .connected = status {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: share.mountPath)])
                } label: {
                    Label("Open in Finder", systemImage: "folder")
                }

                Button {
                    Task {
                        await monitor.disconnect(
                            share,
                            pauseAutomaticMounting: share.connectsAutomatically
                        )
                    }
                } label: {
                    Label(share.connectsAutomatically ? "Disconnect & Pause" : "Disconnect", systemImage: "eject")
                }
            } else {
                Button {
                    Task { await monitor.mount(share) }
                } label: {
                    Label("Connect", systemImage: "arrow.triangle.2.circlepath")
                }

                if monitor.runtimeState(for: share).needsCredentials, let url = share.url {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Label("Connect Once in Finder…", systemImage: "person.badge.key")
                    }
                }
            }
        } label: {
            // A healthy share is just its name; anything else says why.
            Label {
                Text(status == .connected ? share.displayName : "\(share.displayName) – \(status.label)")
            } icon: {
                // A share the user gave an icon shows it; otherwise the icon
                // reflects its state. Anything but healthy is also spelled out
                // in the title.
                Image(systemName: appModel.customShareIcon(for: share) ?? status.systemImage)
            }
        }
    }
}

struct GlobalPauseMenu: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var monitor: ShareMonitor

    private var hasAutomaticShares: Bool {
        settings.shares.contains(where: { $0.connectsAutomatically })
    }

    var body: some View {
        if hasAutomaticShares {
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
}

struct SharePauseMenu: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var monitor: ShareMonitor
    let share: NetworkShare

    private var currentShare: NetworkShare {
        settings.share(id: share.id) ?? share
    }

    var body: some View {
        if currentShare.connectsAutomatically {
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
}

struct ShareGroupPauseMenu: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var monitor: ShareMonitor
    let shares: [NetworkShare]

    private var currentShares: [NetworkShare] {
        shares
            .map { settings.share(id: $0.id) ?? $0 }
            .filter(\.connectsAutomatically)
    }

    private var areAllSharesPaused: Bool {
        !currentShares.isEmpty && currentShares.allSatisfy { $0.pauseState.isActive() }
    }

    var body: some View {
        if !currentShares.isEmpty {
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
}

@MainActor @ViewBuilder
private func pauseButtons(action: @escaping @MainActor (Date?) -> Void) -> some View {
    Button("For 1 Hour") {
        action(Date().addingTimeInterval(60 * 60))
    }
    Button("Until Tomorrow") {
        let calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date()))
        action(tomorrow)
    }
    Button("Until I Resume") {
        action(nil)
    }
}
