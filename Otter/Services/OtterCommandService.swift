import Foundation

/// Local automation bridge used by the bundled `otterctl` command. It uses
/// macOS distributed notifications rather than a network listener, so Otter
/// never opens a port merely to support shell automation.
@MainActor
final class OtterCommandService {
    static let requestNotification = Notification.Name("io.github.johnwatso.Otter.command")
    static let responsePrefix = "io.github.johnwatso.Otter.command-response."

    private let appModel: AppModel
    private var observer: NSObjectProtocol?
    private var completedResponses: [String: String] = [:]

    private enum ShareSelection {
        case matches([NetworkShare])
        case error(String)
    }

    init(appModel: AppModel) {
        self.appModel = appModel
    }

    func start() {
        guard observer == nil else { return }
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Self.requestNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                self?.handle(notification)
            }
        }
    }

    deinit {
        if let observer {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
    }

    private func handle(_ notification: Notification) {
        guard let requestID = notification.userInfo?["requestID"] as? String,
              let command = notification.userInfo?["command"] as? String,
              !requestID.isEmpty
        else {
            return
        }

        if let response = completedResponses[requestID] {
            respond(to: requestID, message: response)
            return
        }

        let shareName = notification.userInfo?["share"] as? String
        let outputPath = notification.userInfo?["outputPath"] as? String

        Task { @MainActor in
            let response = await execute(command: command, shareName: shareName, outputPath: outputPath)
            completedResponses[requestID] = response
            if completedResponses.count > 100 {
                completedResponses.removeAll(keepingCapacity: true)
            }
            respond(to: requestID, message: response)
        }
    }

    private func execute(command: String, shareName: String?, outputPath: String?) async -> String {
        let shares: [NetworkShare]
        switch matchingShares(named: shareName) {
        case let .matches(matches):
            shares = matches
        case let .error(message):
            return "error: \(message)"
        }

        switch command {
        case "status":
            return statusText(for: shares)
        case "mount":
            if shareName == nil || shareName?.isEmpty == true {
                await appModel.monitor.mountAll()
                return "Mounting all shares."
            }
            for share in shares {
                await appModel.monitor.mount(share)
            }
            return "Mounting \(shares.map(\.displayName).joined(separator: ", "))."
        case "disconnect":
            if shareName == nil || shareName?.isEmpty == true {
                await appModel.monitor.disconnectAll()
                return "Disconnected and paused all shares."
            }
            for share in shares {
                await appModel.monitor.disconnect(share)
            }
            return "Disconnected and paused \(shares.map(\.displayName).joined(separator: ", "))."
        case "pause":
            if shareName == nil || shareName?.isEmpty == true {
                await appModel.monitor.pauseAll(until: nil)
                return "Paused automatic mounting for all shares."
            }
            for share in shares {
                await appModel.monitor.pause(share, until: nil)
            }
            return "Paused automatic mounting for \(shares.map(\.displayName).joined(separator: ", "))."
        case "resume":
            if shareName == nil || shareName?.isEmpty == true {
                await appModel.monitor.resumeAll()
                return "Resumed automatic mounting for all shares."
            }
            for share in shares {
                await appModel.monitor.resume(share)
            }
            return "Resumed automatic mounting for \(shares.map(\.displayName).joined(separator: ", "))."
        case "export-diagnostics":
            return exportDiagnostics(to: outputPath)
        default:
            return "error: Unsupported command “\(command)”."
        }
    }

    private func matchingShares(named name: String?) -> ShareSelection {
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            return .matches(appModel.settings.shares)
        }

        let matches = appModel.settings.shares.filter { share in
            share.displayName.localizedCaseInsensitiveCompare(name) == .orderedSame
                || share.id.uuidString.localizedCaseInsensitiveCompare(name) == .orderedSame
        }
        guard !matches.isEmpty else {
            return .error("No share named “\(name)” is configured.")
        }
        guard matches.count == 1 else {
            return .error("More than one share is named “\(name)”; use its UUID from `otterctl status`.")
        }
        return .matches(matches)
    }

    private func statusText(for shares: [NetworkShare]) -> String {
        if shares.isEmpty {
            return "No shares configured."
        }

        return shares.map { share in
            "\(share.displayName)\t\(appModel.monitor.status(for: share).label)\t\(share.id.uuidString)"
        }
        .joined(separator: "\n")
    }

    private func exportDiagnostics(to outputPath: String?) -> String {
        let url = outputPath
            .map { URL(fileURLWithPath: $0).standardizedFileURL }
            ?? SupportDiagnosticsExporter.defaultFileURL()

        do {
            let data = try SupportDiagnosticsExporter.makeData(
                settings: appModel.settings,
                eventLog: appModel.eventLog,
                monitor: appModel.monitor,
                networkService: appModel.networkService,
                notificationService: appModel.notificationService,
                loginItemService: appModel.loginItemService
            )
            try data.write(to: url, options: .atomic)
            return "Exported redacted diagnostics to \(url.path)."
        } catch {
            return "error: Couldn't export diagnostics: \(error.localizedDescription)"
        }
    }

    private func respond(to requestID: String, message: String) {
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(Self.responsePrefix + requestID),
            object: requestID,
            userInfo: ["message": message],
            options: [.deliverImmediately]
        )
    }
}
