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
        } label: {
            MenuBarLabel()
                .environmentObject(appModel.monitor)
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
        }
        .defaultSize(width: 520, height: 420)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
    }
}

private struct MenuBarLabel: View {
    @EnvironmentObject private var monitor: ShareMonitor

    var body: some View {
        Image(systemName: monitor.menuBarSystemImage)
    }
}
