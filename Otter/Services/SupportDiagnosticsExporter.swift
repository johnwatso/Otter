import AppKit
import Foundation
import UniformTypeIdentifiers

/// Presents a responsive, window-attached export flow for Otter's existing
/// redacted support package. The payload remains JSON so support tooling can
/// consume it without parsing a display-oriented report.
@MainActor
enum SupportDiagnosticsExporter {
    static let fileType = UTType(filenameExtension: "ottersupport", conformingTo: .json) ?? .json

    static func makeData(
        settings: SettingsStore,
        eventLog: ShareEventLog,
        monitor: ShareMonitor,
        networkService: NetworkReachabilityService,
        notificationService: NotificationService,
        loginItemService: LoginItemService
    ) throws -> Data {
        let package = SupportPackageService.make(
            settings: settings,
            eventLog: eventLog,
            monitor: monitor,
            networkService: networkService,
            notificationService: notificationService,
            loginItemService: loginItemService
        )
        return try SupportPackageService.encode(package)
    }

    static func defaultFilename(for date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return "Otter-support-\(formatter.string(from: date)).ottersupport"
    }

    static func defaultFileURL(for date: Date = Date()) -> URL {
        let directory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return directory.appendingPathComponent(defaultFilename(for: date))
    }

    static func presentSavePanel(
        settings: SettingsStore,
        eventLog: ShareEventLog,
        monitor: ShareMonitor,
        networkService: NetworkReachabilityService,
        notificationService: NotificationService,
        loginItemService: LoginItemService
    ) async -> Result<URL?, Error> {
        let progressSheet = presentProgressSheet()
        defer { dismiss(progressSheet) }

        // Let the progress UI render before collecting the snapshot. This is
        // usually fast, but it keeps exports of a full activity log responsive.
        await Task.yield()

        let data: Data
        do {
            data = try makeData(
                settings: settings,
                eventLog: eventLog,
                monitor: monitor,
                networkService: networkService,
                notificationService: notificationService,
                loginItemService: loginItemService
            )
        } catch {
            return .failure(error)
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [fileType]
        panel.nameFieldStringValue = defaultFilename()
        panel.title = "Export Otter Support Package"
        panel.message = "Save a redacted diagnostic package to share with support."
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first

        guard await present(panel) == .OK, let url = panel.url else {
            return .success(nil)
        }

        do {
            try data.write(to: url, options: .atomic)
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return .success(url)
        } catch {
            return .failure(error)
        }
    }

    private static func present(_ panel: NSSavePanel) async -> NSApplication.ModalResponse {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else {
            return panel.runModal()
        }

        return await withCheckedContinuation { continuation in
            panel.beginSheetModal(for: window) { response in
                continuation.resume(returning: response)
            }
        }
    }

    private struct ProgressSheet {
        let panel: NSPanel
        let parentWindow: NSWindow?
    }

    private static func presentProgressSheet() -> ProgressSheet {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 145),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        panel.title = "Export Otter Support Package"
        panel.isReleasedWhenClosed = false
        panel.isMovable = false
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        let content = NSView(frame: panel.contentView?.bounds ?? .zero)

        let progress = NSProgressIndicator(frame: NSRect(x: 27, y: 62, width: 28, height: 28))
        progress.style = .spinning
        progress.controlSize = .regular
        progress.startAnimation(nil)
        content.addSubview(progress)

        let title = NSTextField(labelWithString: "Preparing diagnostics…")
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        title.frame = NSRect(x: 75, y: 81, width: 270, height: 22)
        content.addSubview(title)

        let detail = NSTextField(wrappingLabelWithString: "Collecting and redacting activity data. Your server, share, and account details are excluded.")
        detail.font = .systemFont(ofSize: 13)
        detail.textColor = .secondaryLabelColor
        detail.maximumNumberOfLines = 2
        detail.frame = NSRect(x: 75, y: 37, width: 270, height: 38)
        content.addSubview(detail)

        panel.contentView = content
        if let parentWindow = NSApp.keyWindow ?? NSApp.mainWindow {
            parentWindow.beginSheet(panel)
            return ProgressSheet(panel: panel, parentWindow: parentWindow)
        }

        panel.center()
        panel.level = .floating
        panel.makeKeyAndOrderFront(nil)
        return ProgressSheet(panel: panel, parentWindow: nil)
    }

    private static func dismiss(_ progressSheet: ProgressSheet) {
        if let parentWindow = progressSheet.parentWindow {
            parentWindow.endSheet(progressSheet.panel)
        } else {
            progressSheet.panel.orderOut(nil)
        }
    }
}
