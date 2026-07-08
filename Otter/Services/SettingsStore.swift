import Foundation

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
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.shares = Self.load([NetworkShare].self, from: defaults, key: Keys.shares) ?? []

        var loadedPreferences = Self.load(AppPreferences.self, from: defaults, key: Keys.preferences) ?? AppPreferences()
        loadedPreferences.normalize()
        self.preferences = loadedPreferences
    }

    func share(id: NetworkShare.ID) -> NetworkShare? {
        shares.first { $0.id == id }
    }

    func addShare(_ share: NetworkShare) {
        shares.append(share)
    }

    func updateShare(_ share: NetworkShare) {
        guard let index = shares.firstIndex(where: { $0.id == share.id }) else {
            addShare(share)
            return
        }

        var updated = share
        updated.updatedAt = Date()
        shares[index] = updated
    }

    func updateShare(id: NetworkShare.ID, _ update: (inout NetworkShare) -> Void) {
        guard let index = shares.firstIndex(where: { $0.id == id }) else { return }
        var share = shares[index]
        update(&share)
        share.updatedAt = Date()
        shares[index] = share
    }

    func removeShare(id: NetworkShare.ID) {
        shares.removeAll { $0.id == id }
    }

    func setAllKeepMounted(_ enabled: Bool) {
        shares = shares.map { share in
            var updated = share
            updated.keepMounted = enabled
            updated.updatedAt = Date()
            return updated
        }
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

    private func savePreferences() {
        save(preferences, key: Keys.preferences)
    }

    private func save<T: Encodable>(_ value: T, key: String) {
        do {
            defaults.set(try encoder.encode(value), forKey: key)
        } catch {
            assertionFailure("Unable to save \(key): \(error.localizedDescription)")
        }
    }

    private static func load<T: Decodable>(_ type: T.Type, from defaults: UserDefaults, key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
