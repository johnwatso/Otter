import AppKit
import Darwin
import Foundation

private enum Otterctl {
    static let requestNotification = Notification.Name("io.github.johnwatso.Otter.command")
    static let responsePrefix = "io.github.johnwatso.Otter.command-response."
    static let appBundleIdentifier = "io.github.johnwatso.Otter"

    static func run(arguments: [String]) -> Int32 {
        guard let command = arguments.first else {
            print(usage)
            return 64
        }

        if ["help", "--help", "-h"].contains(command) {
            print(usage)
            return 0
        }

        guard ["status", "mount", "disconnect", "pause", "resume", "export-diagnostics"].contains(command) else {
            fputs("otterctl: unknown command \(command)\n", stderr)
            print(usage)
            return 64
        }

        let remaining = Array(arguments.dropFirst())
        let share: String?
        let outputPath: String?
        if command == "export-diagnostics" {
            guard remaining.count <= 1 else {
                fputs("otterctl: export-diagnostics accepts at most one output path\n", stderr)
                return 64
            }
            share = nil
            outputPath = remaining.first
        } else {
            guard remaining.count <= 1 else {
                fputs("otterctl: commands accept one optional share name or UUID\n", stderr)
                return 64
            }
            share = remaining.first
            outputPath = nil
        }

        launchOtterIfAvailable()

        let requestID = UUID().uuidString
        let responseName = Notification.Name(responsePrefix + requestID)
        var response: String?
        let center = DistributedNotificationCenter.default()
        let observer = center.addObserver(forName: responseName, object: requestID, queue: .main) { notification in
            response = notification.userInfo?["message"] as? String
        }
        defer { center.removeObserver(observer) }

        let deadline = Date().addingTimeInterval(20)
        var lastPost = Date.distantPast
        while Date() < deadline && response == nil {
            if Date().timeIntervalSince(lastPost) >= 0.5 {
                center.postNotificationName(
                    requestNotification,
                    object: requestID,
                    userInfo: [
                        "requestID": requestID,
                        "command": command,
                        "share": share ?? "",
                        "outputPath": outputPath ?? ""
                    ],
                    options: [.deliverImmediately]
                )
                lastPost = Date()
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }

        guard let response else {
            fputs("otterctl: Otter did not respond. Open Otter and try again.\n", stderr)
            return 69
        }

        if response.hasPrefix("error:") {
            fputs("otterctl: \(response.dropFirst("error: ".count))\n", stderr)
            return 1
        }
        print(response)
        return 0
    }

    private static func launchOtterIfAvailable() {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: appBundleIdentifier) else {
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, _ in }
    }

    private static let usage = """
    Usage: otterctl <command> [share-name-or-UUID]

    Commands:
      status [share]                 Print each share's current status and UUID.
      mount [share]                  Mount one share, or all shares when omitted.
      disconnect [share]             Disconnect and pause one share, or all shares.
      pause [share]                  Pause automatic mounting.
      resume [share]                 Resume automatic mounting.
      export-diagnostics [path]      Write a redacted .ottersupport package.
    """
}

exit(Otterctl.run(arguments: Array(CommandLine.arguments.dropFirst())))
