import AppKit
import Combine
import Foundation

// Finder lists a server twice when the address a share is mounted through is an
// alias of the name the server advertises: browsing finds "NAS" while the mount
// was made against "NAS.local", so the Network view grows a second row for the
// same machine even though /Volumes holds a single mounted volume.
//
// The same server can also end up genuinely mounted twice — a hostname mount
// alongside the cached-IP fallback, which macOS parks at "Vault-1".
//
// This service resolves both: it reconnects a share through the server's
// canonical name, and unmounts the redundant copies of a share that is already
// mounted somewhere else. It only ever touches volumes that belong to a share
// Otter is configured to manage.
enum ServerAlias {
    /// The server behind a host string, with every alias form stripped.
    /// `NAS`, `nas.local` and `NAS._smb._tcp.local` share one identity.
    static func identity(for host: String) -> String? {
        var normalized = host
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()

        guard !normalized.isEmpty else { return nil }

        if let serviceMarker = normalized.range(of: "._smb._tcp.") {
            normalized = String(normalized[..<serviceMarker.lowerBound])
        } else if normalized.hasSuffix("._smb._tcp") {
            normalized.removeLast("._smb._tcp".count)
        } else if normalized.hasSuffix(".local") {
            normalized.removeLast(".local".count)
        }

        return normalized.isEmpty ? nil : normalized
    }

    /// The host Finder browses this server under, when `host` is an alias of it.
    ///
    /// Returns nil when the host is already the browsed name, is an IP address,
    /// or is an ordinary DNS name — a name outside `.local` is the address the
    /// user chose, not an alias Otter should rewrite.
    static func canonicalHost(for host: String, advertisedNames: [String] = []) -> String? {
        let trimmedHost = host
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))

        guard !trimmedHost.isEmpty,
              !NetworkShare.isIPAddress(trimmedHost),
              let identity = identity(for: trimmedHost),
              identity != trimmedHost.lowercased()
        else {
            return nil
        }

        // Bonjour knows the exact spelling Finder displays. Fall back to the
        // stripped identity when discovery isn't running or the server isn't
        // currently advertising.
        if let advertisedName = advertisedNames.first(where: { self.identity(for: $0) == identity }),
           !advertisedName.isEmpty,
           advertisedName.lowercased() != trimmedHost.lowercased() {
            return advertisedName
        }

        return identity
    }

    /// The server's name with any alias suffix removed, keeping the spelling
    /// it was written with. Keychain lookups match a server name exactly,
    /// capitalization included, so the case cannot be normalized away.
    static func displayName(for host: String) -> String? {
        var normalized = host
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))

        if let serviceMarker = normalized.range(of: "._smb._tcp.", options: .caseInsensitive) {
            normalized = String(normalized[..<serviceMarker.lowerBound])
        } else if normalized.lowercased().hasSuffix("._smb._tcp") {
            normalized.removeLast("._smb._tcp".count)
        } else if normalized.lowercased().hasSuffix(".local") {
            normalized.removeLast(".local".count)
        }

        return normalized.isEmpty ? nil : normalized
    }

    /// Every spelling macOS may have filed this server's SMB password under.
    /// A password saved while connecting through Finder is commonly stored
    /// against the Bonjour service name — "NAS._smb._tcp.local" — rather than
    /// the address that was typed, so a share moving between aliases has to
    /// look for its credentials under all of them.
    static func credentialHostCandidates(for host: String) -> [String] {
        let trimmedHost = host
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))

        guard !trimmedHost.isEmpty else { return [] }
        guard !NetworkShare.isIPAddress(trimmedHost), let name = displayName(for: trimmedHost) else {
            return [trimmedHost]
        }
        // Only a single-label name has Bonjour spellings. An ordinary DNS name
        // such as "nas.example.com" is stored as itself.
        guard !name.contains(".") else { return [trimmedHost] }

        let lowercasedName = name.lowercased()
        let spellings = [
            trimmedHost,
            name,
            "\(name).local",
            "\(name)._smb._tcp.local",
            lowercasedName,
            "\(lowercasedName).local",
            "\(lowercasedName)._smb._tcp.local"
        ]

        var candidates: [String] = []
        for spelling in spellings where !spelling.isEmpty && !candidates.contains(spelling) {
            candidates.append(spelling)
        }
        return candidates
    }

    static func urlString(for share: NetworkShare, replacingHostWith host: String) -> String? {
        guard let url = share.url,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else {
            return nil
        }

        components.host = host
        return components.string
    }
}

/// A duplicated connection Otter resolved, kept for the menu and diagnostics.
struct ResolvedConnectionDuplicate: Identifiable, Equatable {
    enum Resolution: Equatable {
        /// The share was reconnected through the server's browsed name.
        case reconnectedUnderCanonicalHost(from: String, to: String)
        /// Redundant copies of an already-mounted share were unmounted.
        case unmountedRedundantVolumes([String])
    }

    let id = UUID()
    let shareID: NetworkShare.ID
    let shareName: String
    let resolution: Resolution
    let date: Date

    var summary: String {
        switch resolution {
        case let .reconnectedUnderCanonicalHost(fromHost, toHost):
            "Reconnected \(shareName) as \(toHost) instead of \(fromHost)."
        case let .unmountedRedundantVolumes(paths):
            paths.count == 1
                ? "Disconnected a duplicate copy of \(shareName) at \(paths[0])."
                : "Disconnected \(paths.count) duplicate copies of \(shareName)."
        }
    }
}

@MainActor
final class ShareDeduplicationService: ObservableObject {
    @Published private(set) var recentResolutions: [ResolvedConnectionDuplicate] = []

    private let settings: SettingsStore
    private let monitor: ShareMonitor
    private let eventLog: ShareEventLog
    private let credentialStore: any CredentialStoring
    private let resolver: any HostResolving
    private let advertisedServerNames: @MainActor () -> [String]
    private let discoverVolumes: @Sendable () async -> [MountedShareSuggestion]
    private let unmountVolume: @Sendable (URL) async -> Bool
    private let workspaceNotificationCenter: NotificationCenter
    private let scanDelay: TimeInterval
    private let now: () -> Date

    private var observers: [NSObjectProtocol] = []
    private var cancellables = Set<AnyCancellable>()
    private var scanTask: Task<Void, Never>?
    private var isScanning = false
    private var hasStarted = false
    // A canonical host that failed to mount is not tried again while Otter
    // runs, so a server whose browsed name doesn't resolve can't put a share
    // into a reconnect loop.
    private var rejectedCanonicalHosts: [NetworkShare.ID: Set<String>] = [:]

    private static let maxRecentResolutions = 10

    init(
        settings: SettingsStore,
        monitor: ShareMonitor,
        eventLog: ShareEventLog,
        credentialStore: any CredentialStoring = KeychainCredentialStore(),
        resolver: any HostResolving = SystemHostResolver(),
        advertisedServerNames: @escaping @MainActor () -> [String] = { [] },
        discoverVolumes: @escaping @Sendable () async -> [MountedShareSuggestion] = {
            await Task.detached(priority: .utility) { MountedShareSuggestion.discover() }.value
        },
        unmountVolume: @escaping @Sendable (URL) async -> Bool = { url in
            await withCheckedContinuation { continuation in
                // Deliberately unforced: a volume something is still writing to
                // stays mounted, and the duplicate is cleaned up on a later scan.
                FileManager.default.unmountVolume(at: url, options: []) { error in
                    continuation.resume(returning: error == nil)
                }
            }
        },
        workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        scanDelay: TimeInterval = 2,
        now: @escaping () -> Date = Date.init
    ) {
        self.settings = settings
        self.monitor = monitor
        self.eventLog = eventLog
        self.credentialStore = credentialStore
        self.resolver = resolver
        self.advertisedServerNames = advertisedServerNames
        self.discoverVolumes = discoverVolumes
        self.unmountVolume = unmountVolume
        self.workspaceNotificationCenter = workspaceNotificationCenter
        self.scanDelay = scanDelay
        self.now = now
    }

    var isEnabled: Bool {
        settings.preferences.deduplicateConnections && settings.preferences.hasCompletedOnboarding
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true

        installObservers()
        scheduleScan()
    }

    // MARK: - Scanning

    func scan() async {
        guard isEnabled, !settings.isGloballyPaused, !isScanning else { return }

        isScanning = true
        defer { isScanning = false }

        let volumes = await discoverVolumes()

        for share in settings.shares {
            await unmountRedundantVolumes(for: share, in: volumes)
        }

        // Re-read the shares: an unmount above can move a share's mount path.
        for share in settings.shares {
            await reconnectUnderCanonicalHost(for: share)
        }
    }

    /// Removes the extra copies of a share that macOS mounted more than once,
    /// keeping the volume that matches how the share is configured.
    private func unmountRedundantVolumes(for share: NetworkShare, in volumes: [MountedShareSuggestion]) async {
        let matches = Self.volumes(volumes, matching: share)
        guard matches.count > 1,
              let preferred = Self.preferredVolume(among: matches, for: share)
        else {
            return
        }

        var unmountedPaths: [String] = []
        for redundant in matches where redundant.mountPath != preferred.mountPath {
            let volumeURL = URL(fileURLWithPath: redundant.mountPath, isDirectory: true)
            guard volumeURL.standardizedFileURL.path.hasPrefix("/Volumes/") else { continue }
            guard await unmountVolume(volumeURL) else { continue }
            unmountedPaths.append(redundant.mountPath)
        }

        guard !unmountedPaths.isEmpty else { return }

        settings.updateShare(id: share.id) { $0.mountPath = preferred.mountPath }
        record(
            ResolvedConnectionDuplicate(
                shareID: share.id,
                shareName: share.displayName,
                resolution: .unmountedRedundantVolumes(unmountedPaths),
                date: now()
            ),
            for: share
        )
    }

    /// Reconnects a share whose address is an alias of the name the server is
    /// browsed under, so Finder stops listing the server twice.
    private func reconnectUnderCanonicalHost(for share: NetworkShare) async {
        // Only a connected share is worth reconnecting: the server is known to
        // be reachable right now, so a failure means the canonical name is
        // wrong rather than that the server is away.
        guard monitor.status(for: share) == .connected,
              !settings.isManagedShare(id: share.id),
              let host = share.host,
              let canonicalHost = ServerAlias.canonicalHost(
                  for: host,
                  advertisedNames: advertisedServerNames()
              ),
              rejectedCanonicalHosts[share.id]?.contains(canonicalHost.lowercased()) != true,
              let canonicalURLString = ServerAlias.urlString(for: share, replacingHostWith: canonicalHost),
              !settings.isDuplicateShare(urlString: canonicalURLString, excluding: share.id),
              await isSameServer(host, canonicalHost)
        else {
            return
        }

        // Silent maintenance must never provoke a password dialog: if this
        // server has a saved password that cannot be carried over to the new
        // address, the duplicate Finder entry is the smaller problem.
        let credentials = carryCredentialsForward(from: host, to: canonicalHost)
        guard credentials != .unavailable else {
            rejectedCanonicalHosts[share.id, default: []].insert(canonicalHost.lowercased())
            return
        }

        settings.updateShare(id: share.id) { $0.urlString = canonicalURLString }

        // The unmount has to match the volume as it is mounted now, so it uses
        // the share as it was before the address was rewritten.
        let reconnected = await monitor.remountForMaintenance(share)

        if reconnected, monitor.status(for: share) == .connected {
            record(
                ResolvedConnectionDuplicate(
                    shareID: share.id,
                    shareName: share.displayName,
                    resolution: .reconnectedUnderCanonicalHost(from: host, to: canonicalHost),
                    date: now()
                ),
                for: share
            )
            return
        }

        // The browsed name didn't work. Put the share back exactly as it was
        // and leave the duplicate Finder entry alone.
        rejectedCanonicalHosts[share.id, default: []].insert(canonicalHost.lowercased())
        settings.updateShare(id: share.id) { $0.urlString = share.urlString }
        if credentials == .copied {
            credentialStore.removeFallbackCredentials(for: canonicalHost)
        }
        await monitor.retry(share)
    }

    private enum CredentialCarry {
        /// The new address can already authenticate on its own.
        case alreadySaved
        /// The saved password was copied across to the new address.
        case copied
        /// This server has no saved password under any of its names, so there
        /// is nothing to carry and nothing to prompt for.
        case none
        /// A saved password exists but could not be copied — several accounts
        /// are stored for the server, and picking one is the user's call.
        case unavailable
    }

    private func carryCredentialsForward(from host: String, to canonicalHost: String) -> CredentialCarry {
        if credentialStore.hasCredentials(for: canonicalHost) { return .alreadySaved }
        guard let savedHost = credentialStore.savedCredentialHost(matching: host) else { return .none }
        return credentialStore.syncCredentials(fromHost: savedHost, toHost: canonicalHost) ? .copied : .unavailable
    }

    /// Confirms the two names lead to the same machine before Otter commits to
    /// the new address. A browsed name that resolves elsewhere — or not at all —
    /// is not this server.
    private func isSameServer(_ host: String, _ canonicalHost: String) async -> Bool {
        let currentAddresses = Set(await resolver.resolveIPAddresses(for: host).map { $0.lowercased() })
        guard !currentAddresses.isEmpty else { return false }

        let canonicalAddresses = Set(await resolver.resolveIPAddresses(for: canonicalHost).map { $0.lowercased() })
        guard !canonicalAddresses.isEmpty else { return false }

        return !currentAddresses.isDisjoint(with: canonicalAddresses)
    }

    private func record(_ resolution: ResolvedConnectionDuplicate, for share: NetworkShare) {
        recentResolutions.insert(resolution, at: 0)
        if recentResolutions.count > Self.maxRecentResolutions {
            recentResolutions.removeLast(recentResolutions.count - Self.maxRecentResolutions)
        }
        eventLog.record(.duplicateResolved, for: share, detail: resolution.summary)
    }

    // MARK: - Volume matching

    nonisolated static func volumes(
        _ volumes: [MountedShareSuggestion],
        matching share: NetworkShare
    ) -> [MountedShareSuggestion] {
        guard let shareLocation = NetworkShareLocation(url: share.url) else { return [] }

        let shareIdentity = share.host.flatMap { ServerAlias.identity(for: $0) }
        let cachedAddresses = Set(share.orderedCachedIPAddresses.map { $0.lowercased() })
        let sharePath = normalizedPath(share.mountPath)

        return volumes.filter { volume in
            if normalizedPath(volume.mountPath) == sharePath, !sharePath.isEmpty {
                return true
            }

            guard let volumeLocation = NetworkShareLocation(url: URL(string: volume.urlString)) else {
                return false
            }
            if volumeLocation == shareLocation {
                return true
            }

            // A mount made through the cached-IP fallback, or through another
            // spelling of the server's name, is the same share.
            guard volumeLocation.sharePath == shareLocation.sharePath,
                  volumeLocation.port == shareLocation.port
            else {
                return false
            }
            if cachedAddresses.contains(volumeLocation.host) {
                return true
            }
            return shareIdentity != nil && ServerAlias.identity(for: volumeLocation.host) == shareIdentity
        }
    }

    /// The copy worth keeping: the one the share is configured to use, then the
    /// one macOS did not have to rename ("Vault" over "Vault-1").
    nonisolated static func preferredVolume(
        among matches: [MountedShareSuggestion],
        for share: NetworkShare
    ) -> MountedShareSuggestion? {
        guard !matches.isEmpty else { return nil }

        if let configuredHost = share.host?.lowercased(),
           let addressed = matches.first(where: {
               URL(string: $0.urlString)?.host(percentEncoded: false)?.lowercased() == configuredHost
           }) {
            return addressed
        }

        return matches.min {
            if $0.mountPath.count != $1.mountPath.count {
                return $0.mountPath.count < $1.mountPath.count
            }
            return $0.mountPath < $1.mountPath
        }
    }

    private nonisolated static func normalizedPath(_ path: String) -> String {
        guard !path.isEmpty else { return "" }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }

    // MARK: - Triggers

    private func installObservers() {
        // A duplicate can only appear when something mounts, and the volume
        // needs a moment to report the address it was remounted from.
        observers = [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification].map { name in
            workspaceNotificationCenter.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                Task { @MainActor in
                    self?.scheduleScan()
                }
            }
        }

        settings.$preferences
            .map(\.deduplicateConnections)
            .removeDuplicates()
            .sink { [weak self] isEnabled in
                Task { @MainActor in
                    guard let self, isEnabled else { return }
                    self.rejectedCanonicalHosts.removeAll()
                    self.scheduleScan()
                }
            }
            .store(in: &cancellables)
    }

    private func scheduleScan() {
        guard isEnabled else { return }

        scanTask?.cancel()
        scanTask = Task { [weak self] in
            guard let self else { return }
            if scanDelay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(max(scanDelay, 0) * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }
            await self.scan()
        }
    }
}
