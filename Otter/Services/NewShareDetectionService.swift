import AppKit
import Combine
import Foundation

// Watches for SMB volumes that appear while Otter is running. A share the user
// mounts in Finder that Otter isn't managing yet becomes a pending offer: a
// notification, plus a menu bar item that stays until the offer is answered.
//
// Volumes that were already mounted when Otter started are treated as known —
// the offer is about shares that show up while Otter is watching.
@MainActor
final class NewShareDetectionService: ObservableObject {
    @Published private(set) var pendingSuggestions: [MountedShareSuggestion] = []
    @Published private(set) var ignoredShareCount = 0

    // Finder-driven flows (onboarding, the share editor's volume picker) mount
    // shares the user is already adding. Offering those back would be noise, so
    // scans made while a flow is open only record what is mounted.
    var isSuppressed = false

    private let settings: SettingsStore
    private let notificationService: any DetectedShareNotifying
    private let defaults: UserDefaults
    private let workspaceNotificationCenter: NotificationCenter
    private let scanDelay: TimeInterval
    private let discoverShares: @Sendable () async -> [MountedShareSuggestion]

    private var observers: [NSObjectProtocol] = []
    private var cancellables = Set<AnyCancellable>()
    private var scanTask: Task<Void, Never>?
    private var hasPendingAnnouncement = false
    private var knownAddresses = Set<String>()
    private var ignoredAddresses = Set<String>()
    private var hasStarted = false

    private static let ignoredAddressesKey = "ignoredDetectedShareAddresses"

    init(
        settings: SettingsStore,
        notificationService: any DetectedShareNotifying,
        defaults: UserDefaults = .standard,
        workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        scanDelay: TimeInterval = 1,
        discoverShares: @escaping @Sendable () async -> [MountedShareSuggestion] = {
            await Task.detached(priority: .utility) { MountedShareSuggestion.discover() }.value
        }
    ) {
        self.settings = settings
        self.notificationService = notificationService
        self.defaults = defaults
        self.workspaceNotificationCenter = workspaceNotificationCenter
        self.scanDelay = scanDelay
        self.discoverShares = discoverShares
        self.ignoredAddresses = Set(defaults.stringArray(forKey: Self.ignoredAddressesKey) ?? [])
        self.ignoredShareCount = ignoredAddresses.count
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true

        installObservers()
        scheduleScan(announcing: false, delay: 0)
    }

    var isDetectionEnabled: Bool {
        settings.preferences.detectNewShares && settings.preferences.hasCompletedOnboarding
    }

    func scan(announcing: Bool) async {
        let suggestions = await discoverShares()

        var detected: [String: MountedShareSuggestion] = [:]
        for suggestion in suggestions {
            guard let key = Self.addressKey(for: suggestion) else { continue }
            if detected[key] == nil {
                detected[key] = suggestion
            }
        }

        // Drop offers whose volume was unmounted, that were added in the
        // meantime, or that the user has since chosen to ignore.
        pendingSuggestions = pendingSuggestions.filter { suggestion in
            guard let key = Self.addressKey(for: suggestion), detected[key] != nil else { return false }
            return !ignoredAddresses.contains(key) && !isConfigured(suggestion, in: settings.shares)
        }
        knownAddresses.formIntersection(detected.keys)

        guard announcing, !isSuppressed, isDetectionEnabled else {
            // Record what is mounted so enabling detection later doesn't
            // announce a backlog of volumes the user already knows about.
            knownAddresses.formUnion(detected.keys)
            return
        }

        let newlyMounted = detected
            .filter { key, suggestion in
                !knownAddresses.contains(key)
                    && !ignoredAddresses.contains(key)
                    && !isConfigured(suggestion, in: settings.shares)
            }
            .values
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }

        knownAddresses.formUnion(detected.keys)

        for suggestion in newlyMounted {
            pendingSuggestions.append(suggestion)
            notificationService.notifyDetectedShare(suggestion)
        }
    }

    // Adds the detected volume as a share Otter keeps mounted.
    @discardableResult
    func manage(_ suggestion: MountedShareSuggestion) -> NetworkShare? {
        dismiss(suggestion)

        guard !settings.isDuplicateShare(urlString: suggestion.urlString) else { return nil }

        let share = NetworkShare(
            displayName: suggestion.displayName,
            urlString: suggestion.urlString,
            mountPath: suggestion.mountPath
        )
        settings.addShare(share)
        return share
    }

    // Answers the offer for now. The share is offered again if it is unmounted
    // and mounted again later.
    func dismiss(_ suggestion: MountedShareSuggestion) {
        pendingSuggestions.removeAll { $0.id == suggestion.id }
        notificationService.withdrawDetectedShareNotification(for: suggestion)
    }

    // Answers the offer permanently.
    func ignore(_ suggestion: MountedShareSuggestion) {
        if let key = Self.addressKey(for: suggestion) {
            ignoredAddresses.insert(key)
            saveIgnoredAddresses()
        }
        dismiss(suggestion)
    }

    // Clears the delivered notification without answering the offer, so the
    // menu bar item remains while the user sets the share up.
    func acknowledgeNotification(for suggestion: MountedShareSuggestion) {
        notificationService.withdrawDetectedShareNotification(for: suggestion)
    }

    func resetIgnoredShares() {
        guard !ignoredAddresses.isEmpty else { return }
        ignoredAddresses.removeAll()
        saveIgnoredAddresses()
    }

    func pendingSuggestion(withMountPath mountPath: String) -> MountedShareSuggestion? {
        pendingSuggestions.first { $0.mountPath == mountPath }
    }

    private func installObservers() {
        let events: [(Notification.Name, Bool)] = [
            (NSWorkspace.didMountNotification, true),
            (NSWorkspace.didUnmountNotification, false)
        ]

        // Delivered on the posting thread rather than through OperationQueue,
        // since the handler only hops to the main actor to schedule the scan.
        observers = events.map { name, announcing in
            workspaceNotificationCenter.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                Task { @MainActor in
                    self?.scheduleScan(announcing: announcing)
                }
            }
        }

        settings.$shares
            .dropFirst()
            .sink { [weak self] shares in
                Task { @MainActor in
                    self?.pruneConfiguredOffers(in: shares)
                }
            }
            .store(in: &cancellables)

        settings.$preferences
            .map(\.detectNewShares)
            .removeDuplicates()
            .sink { [weak self] isEnabled in
                Task { @MainActor in
                    guard let self, !isEnabled else { return }
                    for suggestion in self.pendingSuggestions {
                        self.notificationService.withdrawDetectedShareNotification(for: suggestion)
                    }
                    self.pendingSuggestions.removeAll()
                }
            }
            .store(in: &cancellables)
    }

    private func scheduleScan(announcing: Bool, delay: TimeInterval? = nil) {
        // A single mount can produce several volume events, and NetFS needs a
        // moment before the new volume reports its remount URL. Coalescing
        // keeps the announcement rather than taking the last event's: a mount
        // followed closely by an unmount elsewhere still offers what appeared.
        scanTask?.cancel()
        hasPendingAnnouncement = hasPendingAnnouncement || announcing

        let scanDelay = delay ?? self.scanDelay
        scanTask = Task { [weak self] in
            if scanDelay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(max(scanDelay, 0) * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }
            await self?.runScheduledScan()
        }
    }

    private func runScheduledScan() async {
        let announcing = hasPendingAnnouncement
        hasPendingAnnouncement = false
        await scan(announcing: announcing)
    }

    private func pruneConfiguredOffers(in shares: [NetworkShare]) {
        for suggestion in pendingSuggestions where isConfigured(suggestion, in: shares) {
            dismiss(suggestion)
        }
    }

    private func isConfigured(_ suggestion: MountedShareSuggestion, in shares: [NetworkShare]) -> Bool {
        let suggestionKey = Self.addressKey(for: suggestion)
        let suggestionPath = Self.normalizedPath(suggestion.mountPath)

        return shares.contains { share in
            if let suggestionKey, Self.addressKey(for: share.url) == suggestionKey {
                return true
            }
            return Self.normalizedPath(share.mountPath) == suggestionPath
        }
    }

    private func saveIgnoredAddresses() {
        ignoredShareCount = ignoredAddresses.count
        defaults.set(Array(ignoredAddresses), forKey: Self.ignoredAddressesKey)
    }

    // Server and share name identify a mount, matching how Otter recognizes its
    // own mounted volumes. A deeper folder path or a mount point renamed by
    // macOS ("Media-1") is still the same share.
    private static func addressKey(for suggestion: MountedShareSuggestion) -> String? {
        addressKey(for: URL(string: suggestion.urlString))
    }

    private static func addressKey(for url: URL?) -> String? {
        guard let location = SMBShareLocation(url: url) else { return nil }
        return "\(location.host):\(location.port)/\(location.sharePath)"
    }

    private static func normalizedPath(_ path: String) -> String {
        guard !path.isEmpty else { return "" }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }
}
