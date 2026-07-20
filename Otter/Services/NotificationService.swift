import Foundation
import UserNotifications

enum ShareNotificationAction: Sendable {
    case retry
    case openInFinder
    case pause
    case showShare
}

@MainActor
final class NotificationService: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined

    private let settings: SettingsStore
    private let center = UNUserNotificationCenter.current()

    // Shares that already got a problem notification for the current outage.
    // Retry cycles flip between "waiting" and "failed" states, and without this
    // every retry would fire another notification.
    private var problemNotificationTracker = ProblemNotificationTracker()
    var actionHandler: ((ShareNotificationAction, NetworkShare.ID) -> Void)?

    private enum ActionIdentifier {
        static let retry = "share.retry"
        static let openInFinder = "share.open"
        static let pause = "share.pause"
        static let category = "share-status"
        static let shareIDKey = "shareID"
    }

    init(settings: SettingsStore) {
        self.settings = settings
        super.init()
    }

    var authorizationStatusTitle: String {
        switch authorizationStatus {
        case .notDetermined:
            "Not asked yet"
        case .denied:
            "Off"
        case .authorized:
            "Allowed"
        case .provisional:
            "Allowed quietly"
        case .ephemeral:
            "Allowed temporarily"
        @unknown default:
            "Unknown"
        }
    }

    var canAskForAuthorization: Bool {
        authorizationStatus == .notDetermined
    }

    func start() {
        center.delegate = self
        registerNotificationActions()

        Task {
            await refreshAuthorizationStatus()

            // Ask at launch rather than from a background status change, so the
            // permission dialog appears at a predictable moment.
            if authorizationStatus == .notDetermined,
               settings.preferences.notificationsEnabled,
               settings.preferences.hasCompletedOnboarding {
                await requestAuthorization()
            }
        }
    }

    func refreshAuthorizationStatus() async {
        let notificationSettings = await center.notificationSettings()
        authorizationStatus = notificationSettings.authorizationStatus
    }

    @discardableResult
    func requestAuthorization() async -> Bool {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            await refreshAuthorizationStatus()
            return granted
        } catch {
            await refreshAuthorizationStatus()
            return false
        }
    }

    func notifyStatusChange(for share: NetworkShare, previous: ShareStatus, current: ShareStatus) {
        guard previous != current else { return }

        // Recovery ends the outage even when connection-change notifications are
        // disabled. Keeping this independent of delivery preferences ensures a
        // later outage can notify again.
        problemNotificationTracker.resolveIfNeeded(shareID: share.id, status: current)

        guard
              settings.preferences.notificationsEnabled,
              let message = notificationMessage(for: share, previous: previous, current: current)
        else {
            return
        }

        if message.kind.isProblem {
            guard problemNotificationTracker.beginProblemDelivery(for: share.id) else { return }
        }

        Task {
            let delivered = await deliver(message)
            if message.kind.isProblem && !delivered {
                problemNotificationTracker.problemDeliveryFailed(for: share.id)
            }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let shouldPlaySound = await MainActor.run {
            self.settings.preferences.notificationSoundsEnabled
        }

        var options: UNNotificationPresentationOptions = [.banner]
        if shouldPlaySound {
            options.insert(.sound)
        }
        return options
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let shareIDString = response.notification.request.content.userInfo[ActionIdentifier.shareIDKey] as? String,
              let shareID = UUID(uuidString: shareIDString)
        else { return }

        let action: ShareNotificationAction
        switch response.actionIdentifier {
        case ActionIdentifier.retry:
            action = .retry
        case ActionIdentifier.openInFinder:
            action = .openInFinder
        case ActionIdentifier.pause:
            action = .pause
        case UNNotificationDefaultActionIdentifier:
            action = .showShare
        default:
            return
        }

        await MainActor.run {
            self.actionHandler?(action, shareID)
        }
    }

    private func deliver(_ message: ShareNotificationMessage) async -> Bool {
        guard await hasPermissionToNotify() else { return false }

        let content = UNMutableNotificationContent()
        content.title = message.title
        content.body = message.body
        content.threadIdentifier = "share.\(message.shareID.uuidString)"
        content.categoryIdentifier = ActionIdentifier.category
        content.userInfo[ActionIdentifier.shareIDKey] = message.shareID.uuidString

        if settings.preferences.notificationSoundsEnabled {
            content.sound = .default
        }

        let request = UNNotificationRequest(
            identifier: "\(message.shareID.uuidString).\(message.kind.rawValue)",
            content: content,
            trigger: nil
        )

        do {
            try await center.add(request)
            return true
        } catch {
            return false
        }
    }

    private func registerNotificationActions() {
        let retry = UNNotificationAction(
            identifier: ActionIdentifier.retry,
            title: "Retry Now",
            options: []
        )
        let open = UNNotificationAction(
            identifier: ActionIdentifier.openInFinder,
            title: "Open in Finder",
            options: [.foreground]
        )
        let pause = UNNotificationAction(
            identifier: ActionIdentifier.pause,
            title: "Pause Automatic Mounting",
            options: []
        )
        let category = UNNotificationCategory(
            identifier: ActionIdentifier.category,
            actions: [retry, open, pause],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])
    }

    private func hasPermissionToNotify() async -> Bool {
        await refreshAuthorizationStatus()

        switch authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined, .denied:
            return false
        @unknown default:
            return false
        }
    }

    private func notificationMessage(
        for share: NetworkShare,
        previous: ShareStatus,
        current: ShareStatus
    ) -> ShareNotificationMessage? {
        switch current {
        case .connected:
            guard settings.preferences.notifyConnectionChanges else { return nil }
            return ShareNotificationMessage(
                shareID: share.id,
                kind: .connected,
                title: "\(share.displayName) connected",
                body: "The share is available in Finder."
            )
        case .disconnected:
            guard settings.preferences.notifyConnectionChanges,
                  previous == .connected
            else { return nil }

            return ShareNotificationMessage(
                shareID: share.id,
                kind: .disconnected,
                title: "\(share.displayName) disconnected",
                body: "The share is no longer mounted."
            )
        case .waitingForNetwork:
            guard settings.preferences.notifyProblems else { return nil }
            return ShareNotificationMessage(
                shareID: share.id,
                kind: .waitingForNetwork,
                title: "\(share.displayName) is waiting for the network",
                body: "Otter will try again when the server is reachable."
            )
        case let .waitingForAllowedNetwork(requirement):
            guard settings.preferences.notifyConnectionChanges,
                  previous == .connected
            else { return nil }

            return ShareNotificationMessage(
                shareID: share.id,
                kind: .waitingForAllowedNetwork,
                title: "\(share.displayName) paused by rule",
                body: "Connect to \(requirement) to mount this share."
            )
        case let .waitingForVPN(name):
            guard settings.preferences.notifyProblems else { return nil }
            return ShareNotificationMessage(
                shareID: share.id,
                kind: .waitingForVPN,
                title: "\(share.displayName) is waiting for VPN",
                body: "Connect to “\(name)” to access this server."
            )
        case .waitingForAccess:
            return nil
        case .waitingForServerOnVPN:
            guard settings.preferences.notifyProblems else { return nil }
            return ShareNotificationMessage(
                shareID: share.id,
                kind: .waitingForServerOnVPN,
                title: "\(share.displayName) is unavailable over VPN",
                body: "A VPN is connected, but the server isn’t responding. Check that the correct VPN is active."
            )
        case let .failed(message):
            guard settings.preferences.notifyProblems else { return nil }
            return ShareNotificationMessage(
                shareID: share.id,
                kind: .failed,
                title: "Couldn't connect \(share.displayName)",
                body: message
            )
        case .paused, .wakePacketSent, .reconnecting:
            return nil
        }
    }
}

struct ProblemNotificationTracker {
    private(set) var notifiedShareIDs = Set<NetworkShare.ID>()

    mutating func beginProblemDelivery(for shareID: NetworkShare.ID) -> Bool {
        notifiedShareIDs.insert(shareID).inserted
    }

    mutating func problemDeliveryFailed(for shareID: NetworkShare.ID) {
        notifiedShareIDs.remove(shareID)
    }

    mutating func resolveIfNeeded(shareID: NetworkShare.ID, status: ShareStatus) {
        switch status {
        case .connected, .disconnected, .paused, .waitingForAllowedNetwork, .waitingForAccess:
            notifiedShareIDs.remove(shareID)
        case .waitingForNetwork, .waitingForVPN, .waitingForServerOnVPN, .wakePacketSent, .reconnecting, .failed:
            break
        }
    }
}

private struct ShareNotificationMessage {
    let shareID: NetworkShare.ID
    let kind: ShareNotificationKind
    let title: String
    let body: String
}

private enum ShareNotificationKind: String {
    case connected
    case disconnected
    case waitingForNetwork
    case waitingForAllowedNetwork
    case waitingForVPN
    case waitingForServerOnVPN
    case failed

    var isProblem: Bool {
        switch self {
        case .waitingForNetwork, .waitingForVPN, .waitingForServerOnVPN, .failed:
            true
        case .connected, .disconnected, .waitingForAllowedNetwork:
            false
        }
    }
}
