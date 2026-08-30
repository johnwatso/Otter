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
        MenuBarExtra(isInserted: menuBarExtraBinding) {
            MenuBarView()
                .environmentObject(appModel)
                .environmentObject(appModel.settings)
                .environmentObject(appModel.monitor)
                .environmentObject(appModel.networkService)
                .environmentObject(appModel.updaterViewModel)
                .environmentObject(appModel.newShareDetector)
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
                .environmentObject(appModel.notificationService)
                .environmentObject(appModel.eventLog)
                .environmentObject(appModel.discoveryService)
                .environmentObject(appModel.newShareDetector)
                .frame(minWidth: 660, minHeight: 560)
        }
        // macOS caps a sheet at its parent window's height, so the share
        // editor can only be as tall as this window allows.
        .defaultSize(width: 680, height: 720)
        .commands {
            OtterCommands(appModel: appModel)
        }

        // The Settings scene, not a plain Window: only this scene gets the
        // native preferences toolbar, which is what draws each tab's SF Symbol
        // above its title. In an ordinary window the same TabView collapses to
        // a segmented control and the icons are dropped.
        SwiftUI.Settings {
            PreferencesView()
                .environmentObject(appModel)
                .environmentObject(appModel.settings)
                .environmentObject(appModel.networkService)
                .environmentObject(appModel.notificationService)
                .environmentObject(appModel.loginItemService)
                .environmentObject(appModel.updaterViewModel)
                .environmentObject(appModel.newShareDetector)
        }
    }

    private var menuBarExtraBinding: Binding<Bool> {
        Binding(
            get: { appModel.isMenuBarExtraInserted },
            set: { _ in appModel.refreshDockIconVisibility() }
        )
    }
}

private struct OtterCommands: Commands {
    let appModel: AppModel

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Otter") {
                showAboutPanel()
            }
        }

        // No .appSettings override: the Settings scene installs its own
        // "Settings…" item, and replacing the group removes the responder that
        // actually opens the window.

        CommandGroup(replacing: .help) {
            Button("Check for Updates…") {
                appModel.updaterViewModel.checkForUpdates()
            }
            .disabled(!appModel.updaterViewModel.canCheckForUpdates)

            Button("Export Diagnostics…") {
                Task { @MainActor in
                    _ = await appModel.exportSupportPackage()
                }
            }

            Divider()

            Link("Otter on GitHub", destination: Self.repositoryURL)
        }
    }

    private static let repositoryURL = URL(string: "https://github.com/johnwatso/Otter")!
}

@MainActor
private func showAboutPanel() {
    let websiteURL = URL(string: "https://www.get-otter.com")!
    let paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.alignment = .center
    paragraphStyle.lineSpacing = 3

    let credits = NSMutableAttributedString(
        string: "www.get-otter.com",
        attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.linkColor,
            .link: websiteURL,
            .paragraphStyle: paragraphStyle
        ]
    )
    credits.append(NSAttributedString(
        string: "\nMade in NZ ",
        attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraphStyle
        ]
    ))

    let heartAttachment = NSTextAttachment()
    let heartConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        .applying(NSImage.SymbolConfiguration(hierarchicalColor: .systemRed))
    heartAttachment.image = NSImage(
        systemSymbolName: "heart.fill",
        accessibilityDescription: "Love"
    )?.withSymbolConfiguration(heartConfiguration)
    heartAttachment.bounds = CGRect(x: 0, y: -2, width: 12, height: 12)
    credits.append(NSAttributedString(attachment: heartAttachment))

    NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    NSApp.activate(ignoringOtherApps: true)
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

    // Closing Manage Shares or Preferences is not quitting: Otter keeps
    // monitoring mounts from the menu bar. Without this the app is torn down
    // with its last window and the menu bar item disappears with it.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Paired with NSSupportsAutomaticTermination = false in Info.plist.
        // The plist key is what a stale copy of the app in /Applications still
        // carries, so hold the process open from code as well: a share monitor
        // that the system is free to quit while it sits idle is no monitor.
        ProcessInfo.processInfo.disableAutomaticTermination("Otter monitors network shares in the background")
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        appModel?.triggerOpenSharesWindow()
        return true
    }
}
