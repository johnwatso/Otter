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

        Window("Preferences", id: AppModel.preferencesWindowID) {
            PreferencesView()
                .environmentObject(appModel)
                .environmentObject(appModel.settings)
                .environmentObject(appModel.networkService)
                .environmentObject(appModel.notificationService)
                .environmentObject(appModel.loginItemService)
                .environmentObject(appModel.updaterViewModel)
                .environmentObject(appModel.newShareDetector)
        }
        .defaultSize(width: 520, height: 420)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            OtterCommands()
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
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Otter") {
                showAboutPanel()
            }
        }

        CommandGroup(replacing: .appSettings) {
            Button("Preferences…") {
                openWindow(id: AppModel.preferencesWindowID)
                NSApp.activate(ignoringOtherApps: true)
            }
            .keyboardShortcut(",", modifiers: .command)
        }
    }
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

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        appModel?.triggerOpenSharesWindow()
        return true
    }
}
