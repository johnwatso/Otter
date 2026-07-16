import Foundation

struct PauseState: Codable, Equatable, Hashable {
    var isPaused: Bool
    var resumeAt: Date?

    static let inactive = PauseState(isPaused: false, resumeAt: nil)

    static func paused(until resumeAt: Date? = nil) -> PauseState {
        PauseState(isPaused: true, resumeAt: resumeAt)
    }

    func isActive(at date: Date = Date()) -> Bool {
        guard isPaused else { return false }
        guard let resumeAt else { return true }
        return resumeAt > date
    }

    mutating func clearIfExpired(at date: Date = Date()) {
        if !isPaused || resumeAt.map({ $0 <= date }) == true {
            self = .inactive
        }
    }
}

enum AppPresenceMode: String, Codable, CaseIterable, Equatable, Identifiable {
    case dockAndMenuBar
    case dockOnly
    case menuBarOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dockAndMenuBar:
            "Dock + Menu Bar"
        case .dockOnly:
            "Dock Only"
        case .menuBarOnly:
            "Menu Bar Only"
        }
    }

    var detail: String {
        switch self {
        case .dockAndMenuBar:
            "Keep Otter easy to reach from both the Dock and the menu bar."
        case .dockOnly:
            "Use Otter like a regular app without a menu bar item."
        case .menuBarOnly:
            "Keep Otter out of the Dock and control it from the menu bar."
        }
    }

    var systemImage: String {
        switch self {
        case .dockAndMenuBar:
            "menubar.dock.rectangle"
        case .dockOnly:
            "dock.rectangle"
        case .menuBarOnly:
            "menubar.rectangle"
        }
    }

    var showsDockIcon: Bool {
        self != .menuBarOnly
    }

    var showsMenuBarIcon: Bool {
        self != .dockOnly
    }

    func shouldShowDockIcon(duringOnboarding: Bool) -> Bool {
        duringOnboarding || showsDockIcon
    }

    func shouldShowMenuBarIcon(duringOnboarding: Bool) -> Bool {
        duringOnboarding || showsMenuBarIcon
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)

        switch rawValue {
        case Self.dockAndMenuBar.rawValue, "alwaysShowDockIcon", "dockWhilePreferencesOpen":
            self = .dockAndMenuBar
        case Self.dockOnly.rawValue:
            self = .dockOnly
        case Self.menuBarOnly.rawValue:
            self = .menuBarOnly
        default:
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown app presence mode: \(rawValue)"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

struct AppPreferences: Codable, Equatable {
    static let defaultFallbackCheckInterval: TimeInterval = 60

    var fallbackCheckInterval: TimeInterval = Self.defaultFallbackCheckInterval
    var appPresenceMode: AppPresenceMode = .dockAndMenuBar
    var notificationsEnabled: Bool = true
    var notifyConnectionChanges: Bool = true
    var notifyProblems: Bool = true
    var notificationSoundsEnabled: Bool = false
    var pauseState: PauseState = .inactive
    var recoverUnresponsiveMounts: Bool = false
    var hasCompletedOnboarding: Bool = false

    init(
        fallbackCheckInterval: TimeInterval = Self.defaultFallbackCheckInterval,
        appPresenceMode: AppPresenceMode = .dockAndMenuBar,
        notificationsEnabled: Bool = true,
        notifyConnectionChanges: Bool = true,
        notifyProblems: Bool = true,
        notificationSoundsEnabled: Bool = false,
        pauseState: PauseState = .inactive,
        recoverUnresponsiveMounts: Bool = false,
        hasCompletedOnboarding: Bool = false
    ) {
        self.fallbackCheckInterval = fallbackCheckInterval
        self.appPresenceMode = appPresenceMode
        self.notificationsEnabled = notificationsEnabled
        self.notifyConnectionChanges = notifyConnectionChanges
        self.notifyProblems = notifyProblems
        self.notificationSoundsEnabled = notificationSoundsEnabled
        self.pauseState = pauseState
        self.recoverUnresponsiveMounts = recoverUnresponsiveMounts
        self.hasCompletedOnboarding = hasCompletedOnboarding
        normalize()
    }

    private enum CodingKeys: String, CodingKey {
        case fallbackCheckInterval
        case appPresenceMode
        case notificationsEnabled
        case notifyConnectionChanges
        case notifyProblems
        case notificationSoundsEnabled
        case pauseState
        case recoverUnresponsiveMounts
        case hasCompletedOnboarding
        case showDockIconWhenPreferencesOpen
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fallbackCheckInterval = try container.decodeIfPresent(TimeInterval.self, forKey: .fallbackCheckInterval) ?? Self.defaultFallbackCheckInterval
        if let appPresenceMode = try container.decodeIfPresent(AppPresenceMode.self, forKey: .appPresenceMode) {
            self.appPresenceMode = appPresenceMode
        } else {
            let showDockIconWhenPreferencesOpen = try container.decodeIfPresent(Bool.self, forKey: .showDockIconWhenPreferencesOpen) ?? true
            self.appPresenceMode = showDockIconWhenPreferencesOpen ? .dockAndMenuBar : .menuBarOnly
        }
        notificationsEnabled = try container.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? true
        notifyConnectionChanges = try container.decodeIfPresent(Bool.self, forKey: .notifyConnectionChanges) ?? true
        notifyProblems = try container.decodeIfPresent(Bool.self, forKey: .notifyProblems) ?? true
        notificationSoundsEnabled = try container.decodeIfPresent(Bool.self, forKey: .notificationSoundsEnabled) ?? false
        pauseState = try container.decodeIfPresent(PauseState.self, forKey: .pauseState) ?? .inactive
        recoverUnresponsiveMounts = try container.decodeIfPresent(Bool.self, forKey: .recoverUnresponsiveMounts) ?? false
        hasCompletedOnboarding = try container.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding) ?? false
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
        try container.encode(pauseState, forKey: .pauseState)
        try container.encode(recoverUnresponsiveMounts, forKey: .recoverUnresponsiveMounts)
        try container.encode(hasCompletedOnboarding, forKey: .hasCompletedOnboarding)
    }

    mutating func normalize() {
        fallbackCheckInterval = min(max(fallbackCheckInterval, 15), 3600)
        pauseState.clearIfExpired()
    }
}
