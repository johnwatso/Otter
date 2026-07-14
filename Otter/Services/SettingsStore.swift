import Foundation
import os

@MainActor
final class SettingsStore: ObservableObject {
    @Published var shares: [NetworkShare] {
        didSet { saveShares() }
    }

    @Published var preferences: AppPreferences {
        didSet {
            savePreferences()
        }
    }

    private enum Keys {
        static let shares = "configuredShares"
        static let preferences = "preferences"
    }

    private let defaults: UserDefaults
    private let credentialStore: any CredentialStoring
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        defaults: UserDefaults = .standard,
        credentialStore: any CredentialStoring = KeychainCredentialStore()
    ) {
        self.defaults = defaults
        self.credentialStore = credentialStore
        let loadedShares = Self.load([NetworkShare].self, from: defaults, key: Keys.shares) ?? []
        self.shares = loadedShares

        var loadedPreferences = Self.load(AppPreferences.self, from: defaults, key: Keys.preferences) ?? AppPreferences()
        loadedPreferences.normalize()
        if !loadedShares.isEmpty {
            // Existing installations should not be sent through the first-run
            // assistant when this preference is introduced.
            loadedPreferences.hasCompletedOnboarding = true
        }
        self.preferences = loadedPreferences
    }

    func share(id: NetworkShare.ID) -> NetworkShare? {
        shares.first { $0.id == id }
    }

    func hasCredentials(for host: String) -> Bool {
        credentialStore.hasCredentials(for: host)
    }

    @discardableResult
    func recordResolvedIPAddress(
        _ address: String,
        for shareID: NetworkShare.ID,
        observedAt date: Date = Date()
    ) -> CachedIPAddressUpdate {
        recordResolvedIPAddresses([address], for: shareID, observedAt: date)
    }

    @discardableResult
    func recordResolvedIPAddresses(
        _ addresses: [String],
        for shareID: NetworkShare.ID,
        observedAt date: Date = Date()
    ) -> CachedIPAddressUpdate {
        guard let index = shares.firstIndex(where: { $0.id == shareID }) else {
            return .ignored
        }

        let validAddresses = addresses.filter(NetworkShare.isIPAddress)
        guard !validAddresses.isEmpty else { return .ignored }

        // A Bonjour host can advertise several interfaces. Keep the current
        // fallback when it remains valid so reordered answers do not look like
        // DHCP churn.
        let selectedAddress = shares[index].cachedIPAddress.flatMap { cachedAddress in
            validAddresses.first {
                $0.localizedCaseInsensitiveCompare(cachedAddress) == .orderedSame
            }
        } ?? validAddresses[0]

        let previousCachedIPAddress = shares[index].cachedIPAddress
        var updatedShare = shares[index]
        let result = updatedShare.recordResolvedIPAddress(selectedAddress, observedAt: date)

        switch result {
        case .ignored, .unchanged:
            return result
        case .initial, .changed:
            // Learned addresses are runtime observations, not user edits, so do
            // not change the configuration's updatedAt timestamp.
            shares[index] = updatedShare
            removeFallbackCredentialIfUnused(
                previousCachedIPAddress,
                replacingWith: updatedShare.cachedIPAddress
            )
            return result
        }
    }

    func addShare(_ share: NetworkShare) {
        shares.append(share)
    }

    func updateShare(_ share: NetworkShare) {
        guard let index = shares.firstIndex(where: { $0.id == share.id }) else {
            addShare(share)
            return
        }

        let previousCachedIPAddress = shares[index].cachedIPAddress
        var updated = share
        if !Self.hostsMatch(shares[index].host, updated.host) {
            updated.cachedIPAddress = nil
            updated.ipAddressChangeObservations = []
        }
        updated.updatedAt = Date()
        shares[index] = updated
        removeFallbackCredentialIfUnused(previousCachedIPAddress, replacingWith: updated.cachedIPAddress)
    }

    func updateShare(id: NetworkShare.ID, _ update: (inout NetworkShare) -> Void) {
        guard let index = shares.firstIndex(where: { $0.id == id }) else { return }
        var share = shares[index]
        let previousCachedIPAddress = share.cachedIPAddress
        let previousHost = share.host
        update(&share)
        if !Self.hostsMatch(previousHost, share.host) {
            share.cachedIPAddress = nil
            share.ipAddressChangeObservations = []
        }
        share.updatedAt = Date()
        shares[index] = share
        removeFallbackCredentialIfUnused(previousCachedIPAddress, replacingWith: share.cachedIPAddress)
    }

    func removeShare(id: NetworkShare.ID) {
        let cachedIPAddress = shares.first(where: { $0.id == id })?.cachedIPAddress
        shares.removeAll { $0.id == id }
        removeFallbackCredentialIfUnused(cachedIPAddress, replacingWith: nil)
    }

    func isDuplicateShare(urlString: String, excluding shareID: NetworkShare.ID? = nil) -> Bool {
        var value = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("//") {
            value = "smb:\(value)"
        } else if !value.lowercased().hasPrefix("smb://") {
            value = "smb://\(value)"
        }

        guard var components = URLComponents(string: value),
              components.scheme?.lowercased() == "smb",
              let host = components.host?.trimmingCharacters(in: .whitespacesAndNewlines),
              !host.isEmpty
        else {
            return false
        }

        components.scheme = "smb"
        components.host = host
        guard let normalizedURL = components.string else { return false }

        return shares.contains { share in
            share.id != shareID && share.urlString.localizedCaseInsensitiveCompare(normalizedURL) == .orderedSame
        }
    }

    func setAllKeepMounted(_ enabled: Bool) {
        shares = shares.map { share in
            var updated = share
            updated.keepMounted = enabled
            updated.updatedAt = Date()
            return updated
        }
    }

    var isGloballyPaused: Bool {
        preferences.pauseState.isActive()
    }

    func effectivePauseState(for share: NetworkShare, at date: Date = Date()) -> PauseState? {
        if preferences.pauseState.isActive(at: date) {
            return preferences.pauseState
        }
        if share.pauseState.isActive(at: date) {
            return share.pauseState
        }
        return nil
    }

    func pauseAll(until resumeAt: Date?) {
        updatePreferences { preferences in
            preferences.pauseState = .paused(until: resumeAt)
        }
    }

    func resumeAll(clearSharePauses: Bool = false) {
        updatePreferences { preferences in
            preferences.pauseState = .inactive
        }

        guard clearSharePauses else { return }
        shares = shares.map { share in
            var updated = share
            updated.pauseState = .inactive
            updated.updatedAt = Date()
            return updated
        }
    }

    func pauseShare(id: NetworkShare.ID, until resumeAt: Date?) {
        updateShare(id: id) { share in
            share.pauseState = .paused(until: resumeAt)
        }
    }

    func resumeShare(id: NetworkShare.ID) {
        updateShare(id: id) { share in
            share.pauseState = .inactive
        }
    }

    @discardableResult
    func clearExpiredPauses(at date: Date = Date()) -> Bool {
        var changed = false

        if preferences.pauseState.isPaused && !preferences.pauseState.isActive(at: date) {
            var updatedPreferences = preferences
            updatedPreferences.pauseState = .inactive
            preferences = updatedPreferences
            changed = true
        }

        let updatedShares = shares.map { share in
            guard share.pauseState.isPaused, !share.pauseState.isActive(at: date) else { return share }
            var updated = share
            updated.pauseState = .inactive
            updated.updatedAt = date
            changed = true
            return updated
        }
        if changed && updatedShares != shares {
            shares = updatedShares
        }

        return changed
    }

    func nextPauseResumeDate(after date: Date = Date()) -> Date? {
        let pauseStates = [preferences.pauseState] + shares.map(\.pauseState)
        return pauseStates.compactMap { pauseState in
            pauseState.isActive(at: date) ? pauseState.resumeAt : nil
        }.min()
    }

    func completeOnboarding() {
        updatePreferences { preferences in
            preferences.hasCompletedOnboarding = true
        }
    }

    func configurationArchive() -> OtterConfigurationArchive {
        ConfigurationTransferService.archive(shares: shares, preferences: preferences)
    }

    @discardableResult
    func importConfiguration(
        _ archive: OtterConfigurationArchive,
        strategy: ConfigurationImportStrategy
    ) -> ConfigurationImportResult {
        let incoming = archive.shares

        let result: ConfigurationImportResult
        switch strategy {
        case .replace:
            let previousCount = shares.count
            let previousFallbackHosts = Set(shares.compactMap(\.cachedIPAddress))
            for host in previousFallbackHosts {
                credentialStore.removeFallbackCredentials(for: host)
            }

            var usedIDs = Set<UUID>()
            shares = incoming.map { configuration in
                let id = usedIDs.insert(configuration.id).inserted ? configuration.id : UUID()
                return configuration.makeNetworkShare(id: id)
            }
            result = ConfigurationImportResult(
                added: shares.count,
                updated: 0,
                removed: previousCount
            )

        case .merge:
            var mergedShares = shares
            var added = 0
            var updated = 0

            for configuration in incoming {
                if let existingIndex = mergedShares.firstIndex(where: {
                    Self.normalizedShareAddress($0.urlString) == Self.normalizedShareAddress(configuration.urlString)
                }) {
                    let existing = mergedShares[existingIndex]
                    var replacement = configuration.makeNetworkShare(id: existing.id)
                    replacement.cachedIPAddress = existing.cachedIPAddress
                    replacement.ipAddressChangeObservations = existing.ipAddressChangeObservations
                    replacement.pauseState = existing.pauseState
                    replacement.createdAt = existing.createdAt
                    replacement.updatedAt = Date()
                    mergedShares[existingIndex] = replacement
                    updated += 1
                } else {
                    let id = mergedShares.contains(where: { $0.id == configuration.id }) ? UUID() : configuration.id
                    mergedShares.append(configuration.makeNetworkShare(id: id))
                    added += 1
                }
            }

            shares = mergedShares
            result = ConfigurationImportResult(added: added, updated: updated, removed: 0)
        }

        updatePreferences { preferences in
            preferences.fallbackCheckInterval = archive.monitoring.fallbackCheckInterval
            preferences.recoverUnresponsiveMounts = archive.monitoring.recoverUnresponsiveMounts
        }
        return result
    }

    func updatePreferences(_ update: (inout AppPreferences) -> Void) {
        var updated = preferences
        update(&updated)
        updated.normalize()
        preferences = updated
    }

    private func saveShares() {
        save(shares, key: Keys.shares)
    }

    private static func normalizedShareAddress(_ value: String) -> String {
        guard var components = URLComponents(string: value) else {
            return value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        if components.port == 445 {
            components.port = nil
        }
        components.path = "/" + components.path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return components.string?.lowercased() ?? value.lowercased()
    }

    private static func hostsMatch(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, let rhs else { return lhs == nil && rhs == nil }
        return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedSame
    }

    private func savePreferences() {
        save(preferences, key: Keys.preferences)
    }

    private func removeFallbackCredentialIfUnused(_ previousHost: String?, replacingWith newHost: String?) {
        guard let previousHost,
              previousHost.localizedCaseInsensitiveCompare(newHost ?? "") != .orderedSame,
              !shares.contains(where: {
                  $0.cachedIPAddress?.localizedCaseInsensitiveCompare(previousHost) == .orderedSame
              })
        else { return }

        credentialStore.removeFallbackCredentials(for: previousHost)
    }

    private func save<T: Encodable>(_ value: T, key: String) {
        do {
            defaults.set(try encoder.encode(value), forKey: key)
        } catch {
            assertionFailure("Unable to save \(key): \(error.localizedDescription)")
        }
    }

    private static let logger = Logger(subsystem: "io.github.johnwatso.Otter", category: "SettingsStore")

    private static func load<T: Decodable>(_ type: T.Type, from defaults: UserDefaults, key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }

        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            // Keep the unreadable payload so it isn't destroyed by the next save.
            logger.error("Couldn't decode \(key, privacy: .public): \(error.localizedDescription, privacy: .public)")
            defaults.set(data, forKey: "\(key).corrupted")
            return nil
        }
    }
}
