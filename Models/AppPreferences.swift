import Foundation

enum AppPresenceMode: String, Codable, CaseIterable, Equatable, Identifiable {
    case menuBarOnly
    case dockWhilePreferencesOpen
    case alwaysShowDockIcon

    var id: String { rawValue }

    var title: String {
        switch self {
        case .menuBarOnly:
            "Menu bar only"
        case .dockWhilePreferencesOpen:
            "Show while settings windows are open"
        case .alwaysShowDockIcon:
            "Always show Dock icon"
        }
    }

    var detail: String {
        switch self {
        case .menuBarOnly:
            "Keep Otter out of the Dock and control it from the menu bar."
        case .dockWhilePreferencesOpen:
            "Show the Dock icon while Preferences or Manage Shares is open, then hide it again."
        case .alwaysShowDockIcon:
            "Keep Otter visible in both the Dock and the menu bar."
        }
    }
}

struct AppPreferences: Codable, Equatable {
    static let defaultFallbackCheckInterval: TimeInterval = 60

    var fallbackCheckInterval: TimeInterval = Self.defaultFallbackCheckInterval
    var appPresenceMode: AppPresenceMode = .dockWhilePreferencesOpen
    var notificationsEnabled: Bool = true
    var notifyConnectionChanges: Bool = true
    var notifyProblems: Bool = true
    var notificationSoundsEnabled: Bool = false

    init(
        fallbackCheckInterval: TimeInterval = Self.defaultFallbackCheckInterval,
        appPresenceMode: AppPresenceMode = .dockWhilePreferencesOpen,
        notificationsEnabled: Bool = true,
        notifyConnectionChanges: Bool = true,
        notifyProblems: Bool = true,
        notificationSoundsEnabled: Bool = false
    ) {
        self.fallbackCheckInterval = fallbackCheckInterval
        self.appPresenceMode = appPresenceMode
        self.notificationsEnabled = notificationsEnabled
        self.notifyConnectionChanges = notifyConnectionChanges
        self.notifyProblems = notifyProblems
        self.notificationSoundsEnabled = notificationSoundsEnabled
        normalize()
    }

    private enum CodingKeys: String, CodingKey {
        case fallbackCheckInterval
        case appPresenceMode
        case notificationsEnabled
        case notifyConnectionChanges
        case notifyProblems
        case notificationSoundsEnabled
        case showDockIconWhenPreferencesOpen
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fallbackCheckInterval = try container.decodeIfPresent(TimeInterval.self, forKey: .fallbackCheckInterval) ?? Self.defaultFallbackCheckInterval
        if let appPresenceMode = try container.decodeIfPresent(AppPresenceMode.self, forKey: .appPresenceMode) {
            self.appPresenceMode = appPresenceMode
        } else {
            let showDockIconWhenPreferencesOpen = try container.decodeIfPresent(Bool.self, forKey: .showDockIconWhenPreferencesOpen) ?? true
            self.appPresenceMode = showDockIconWhenPreferencesOpen ? .dockWhilePreferencesOpen : .menuBarOnly
        }
        notificationsEnabled = try container.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? true
        notifyConnectionChanges = try container.decodeIfPresent(Bool.self, forKey: .notifyConnectionChanges) ?? true
        notifyProblems = try container.decodeIfPresent(Bool.self, forKey: .notifyProblems) ?? true
        notificationSoundsEnabled = try container.decodeIfPresent(Bool.self, forKey: .notificationSoundsEnabled) ?? false
        normalize()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(fallbackCheckInterval, forKey: .fallbackCheckInterval)
        try container.encode(appPresenceMode, forKey: .appPresenceMode)
        try container.encode(notificationsEnabled, forKey: .notificationsEnabled)
        try container.encode(notifyConnectionChanges, forKey: .notifyConnectionChanges)
        try container.encode(notifyProblems, forKey: .notifyProblems)
        try container.encode(notificationSoundsEnabled, forKey: .notificationSoundsEnabled)
    }

    mutating func normalize() {
        fallbackCheckInterval = min(max(fallbackCheckInterval, 15), 3600)
    }
}
