import AppKit
import SwiftUI

@main
@MainActor
struct OtterApp: App {
    @StateObject private var appModel: AppModel

    init() {
        let model = AppModel()
        _appModel = StateObject(wrappedValue: model)
        model.start()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(appModel)
                .environmentObject(appModel.settings)
                .environmentObject(appModel.monitor)
                .environmentObject(appModel.networkService)
                .environmentObject(appModel.updaterViewModel)
        } label: {
            MenuBarLabel()
                .environmentObject(appModel.monitor)
                .environmentObject(appModel.settings)
        }
        .menuBarExtraStyle(.menu)

        Window("Manage Shares", id: AppModel.sharesWindowID) {
            ShareManagementView()
                .environmentObject(appModel)
                .environmentObject(appModel.settings)
                .environmentObject(appModel.monitor)
                .environmentObject(appModel.networkService)
                .environmentObject(appModel.loginItemService)
        }
        .defaultSize(width: 760, height: 480)

        Window("Preferences", id: AppModel.preferencesWindowID) {
            PreferencesView()
                .environmentObject(appModel)
                .environmentObject(appModel.settings)
                .environmentObject(appModel.networkService)
                .environmentObject(appModel.notificationService)
                .environmentObject(appModel.loginItemService)
                .environmentObject(appModel.updaterViewModel)
        }
        .defaultSize(width: 520, height: 420)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
    }
}

private struct MenuBarLabel: View {
    @EnvironmentObject private var monitor: ShareMonitor
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 3) {
            Image("MenuBarOtter")
                .renderingMode(.template)

            if let badgeSystemImage = monitor.menuBarBadgeSystemImage {
                Image(systemName: badgeSystemImage)
                    .imageScale(.small)
            }
        }
        .onAppear {
            openManageSharesOnFirstRun()
        }
    }

    // A fresh install is just an empty menu bar icon; open Manage Shares so
    // there's something to do. The delay lets the window scenes register first.
    private func openManageSharesOnFirstRun() {
        guard settings.shares.isEmpty else { return }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard settings.shares.isEmpty else { return }
            openWindow(id: AppModel.sharesWindowID)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
