import AppIntents
import AppKit
import Foundation

struct OtterShareEntity: AppEntity, Identifiable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Otter Share")
    static let defaultQuery = OtterShareQuery()

    let id: UUID
    let name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

struct OtterShareQuery: EntityStringQuery {
    func entities(for identifiers: [UUID]) async throws -> [OtterShareEntity] {
        await OtterIntentBridge.entities(identifiers: Set(identifiers))
    }

    func entities(matching string: String) async throws -> [OtterShareEntity] {
        await OtterIntentBridge.entities(matching: string)
    }

    func suggestedEntities() async throws -> [OtterShareEntity] {
        await OtterIntentBridge.entities()
    }
}

struct MountOtterShareIntent: AppIntent {
    static let title: LocalizedStringResource = "Mount Otter Share"
    static let description = IntentDescription("Mounts a configured network share now.")
    static let openAppWhenRun = false

    @Parameter(title: "Share")
    var share: OtterShareEntity

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = try await OtterIntentBridge.mount(shareID: share.id)
        return .result(dialog: "\(message)")
    }
}

struct DisconnectOtterShareIntent: AppIntent {
    static let title: LocalizedStringResource = "Disconnect and Pause Otter Share"
    static let description = IntentDescription("Disconnects a configured share and pauses its automatic mounting.")
    static let openAppWhenRun = false

    @Parameter(title: "Share")
    var share: OtterShareEntity

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = try await OtterIntentBridge.disconnect(shareID: share.id)
        return .result(dialog: "\(message)")
    }
}

struct PauseOtterIntent: AppIntent {
    static let title: LocalizedStringResource = "Pause Otter"
    static let description = IntentDescription("Pauses all automatic share mounting until resumed.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = try await OtterIntentBridge.pauseAll()
        return .result(dialog: "\(message)")
    }
}

struct ResumeOtterIntent: AppIntent {
    static let title: LocalizedStringResource = "Resume Otter"
    static let description = IntentDescription("Resumes automatic mounting for all configured shares.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = try await OtterIntentBridge.resumeAll()
        return .result(dialog: "\(message)")
    }
}

struct GetOtterShareStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Otter Share Status"
    static let description = IntentDescription("Returns the current connection status of a configured share.")
    static let openAppWhenRun = false

    @Parameter(title: "Share")
    var share: OtterShareEntity

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = try await OtterIntentBridge.status(shareID: share.id)
        return .result(dialog: "\(message)")
    }
}

struct GetOtterReliabilityIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Otter Share Reliability"
    static let description = IntentDescription("Returns a seven-day reliability summary for a configured network share.")
    static let openAppWhenRun = false

    @Parameter(title: "Share")
    var share: OtterShareEntity

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = try await OtterIntentBridge.reliability(shareID: share.id)
        return .result(dialog: "\(message)")
    }
}

struct RefreshOtterShareCredentialsIntent: AppIntent {
    static let title: LocalizedStringResource = "Refresh Otter Share Credentials"
    static let description = IntentDescription("Opens a network share in Finder so macOS can update its Keychain credentials.")
    static let openAppWhenRun = false

    @Parameter(title: "Share")
    var share: OtterShareEntity

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = try await OtterIntentBridge.refreshCredentials(shareID: share.id)
        return .result(dialog: "\(message)")
    }
}

struct OtterAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PauseOtterIntent(),
            phrases: ["Pause \(.applicationName)"],
            shortTitle: "Pause Otter",
            systemImageName: "pause.fill"
        )
        AppShortcut(
            intent: ResumeOtterIntent(),
            phrases: ["Resume \(.applicationName)"],
            shortTitle: "Resume Otter",
            systemImageName: "play.fill"
        )
    }
}

enum OtterIntentError: LocalizedError {
    case appUnavailable
    case shareNotFound

    var errorDescription: String? {
        switch self {
        case .appUnavailable:
            "Open Otter once before running this shortcut."
        case .shareNotFound:
            "That share is no longer configured in Otter."
        }
    }
}

@MainActor
enum OtterIntentBridge {
    private static weak var appModel: AppModel?

    static func configure(with appModel: AppModel) {
        self.appModel = appModel
    }

    static func entities(identifiers: Set<UUID>? = nil, matching query: String? = nil) -> [OtterShareEntity] {
        guard let appModel else { return [] }
        return appModel.settings.shares
            .filter { identifiers == nil || identifiers?.contains($0.id) == true }
            .filter { query == nil || $0.displayName.localizedCaseInsensitiveContains(query ?? "") }
            .map { OtterShareEntity(id: $0.id, name: $0.displayName) }
    }

    static func mount(shareID: UUID) async throws -> String {
        let (appModel, share) = try resolve(shareID: shareID)
        await appModel.monitor.mount(share)
        return "\(share.displayName) is \(appModel.monitor.status(for: share).label.lowercased())."
    }

    static func disconnect(shareID: UUID) async throws -> String {
        let (appModel, share) = try resolve(shareID: shareID)
        await appModel.monitor.disconnect(share)
        return "\(share.displayName) was disconnected and automatic mounting is paused."
    }

    static func pauseAll() async throws -> String {
        guard let appModel else { throw OtterIntentError.appUnavailable }
        await appModel.monitor.pauseAll(until: nil)
        return "Automatic mounting is paused."
    }

    static func resumeAll() async throws -> String {
        guard let appModel else { throw OtterIntentError.appUnavailable }
        await appModel.monitor.resumeAll()
        return "Automatic mounting is active."
    }

    static func status(shareID: UUID) throws -> String {
        let (appModel, share) = try resolve(shareID: shareID)
        let status = appModel.monitor.status(for: share)
        return "\(share.displayName): \(status.label)."
    }

    static func reliability(shareID: UUID) throws -> String {
        let (appModel, share) = try resolve(shareID: shareID)
        let summary = appModel.eventLog.reliabilitySummary(for: share.id)
        if summary.isStable {
            return "\(share.displayName) has had no recorded problems in the last seven days."
        }
        return "\(share.displayName): \(summary.connectionDrops) connection drops, \(summary.failures) connection failures, and \(summary.healthFailures) health-check failures in the last seven days."
    }

    static func refreshCredentials(shareID: UUID) throws -> String {
        let (_, share) = try resolve(shareID: shareID)
        guard let url = share.url else { throw OtterIntentError.shareNotFound }
        NSWorkspace.shared.open(url)
        return "Finder opened \(share.displayName). Sign in and save the password to Keychain if prompted."
    }

    private static func resolve(shareID: UUID) throws -> (AppModel, NetworkShare) {
        guard let appModel else { throw OtterIntentError.appUnavailable }
        guard let share = appModel.settings.share(id: shareID) else { throw OtterIntentError.shareNotFound }
        return (appModel, share)
    }
}
