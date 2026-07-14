import AppKit
import SwiftUI

@main
@MainActor
struct OtterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appModel: AppModel

    init() {
        let isRunningTests = AppRuntime.isRunningTests
        let model = AppModel(isRunningTests: isRunningTests)
        _appModel = StateObject(wrappedValue: model)
        if !isRunningTests {
            model.start()
        }
        appDelegate.appModel = model
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
                .environmentObject(appModel)
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
                .environmentObject(appModel.eventLog)
                .frame(minWidth: 600, minHeight: 560)
        }
        .defaultSize(width: 600, height: 600)

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
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var monitor: ShareMonitor
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: monitor.menuBarSystemImage)
            .onAppear {
                openManageSharesOnFirstRun()
            }
            .onReceive(appModel.$shouldOpenSharesWindow) { shouldOpen in
                if shouldOpen {
                    openWindow(id: AppModel.sharesWindowID)
                    NSApp.activate(ignoringOtherApps: true)
                    appModel.shouldOpenSharesWindow = false
                }
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

class AppDelegate: NSObject, NSApplicationDelegate {
    var appModel: AppModel?

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        appModel?.triggerOpenSharesWindow()
        return true
    }
}
