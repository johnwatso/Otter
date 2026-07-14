import Foundation

struct OtterConfigurationArchive: Codable, Equatable {
    static let currentFormatVersion = 1

    let formatVersion: Int
    let exportedAt: Date
    let shares: [PortableShareConfiguration]
    let monitoring: PortableMonitoringConfiguration

    init(
        formatVersion: Int = Self.currentFormatVersion,
        exportedAt: Date = Date(),
        shares: [PortableShareConfiguration],
        monitoring: PortableMonitoringConfiguration
    ) {
        self.formatVersion = formatVersion
        self.exportedAt = exportedAt
        self.shares = shares
        self.monitoring = monitoring
    }
}

struct PortableMonitoringConfiguration: Codable, Equatable {
    let fallbackCheckInterval: TimeInterval
    let recoverUnresponsiveMounts: Bool
}

struct PortableShareConfiguration: Codable, Equatable {
    let id: UUID
    let displayName: String
    let urlString: String
    let mountPath: String
    let keepMounted: Bool
    let mountAtLaunch: Bool
    let autoConnectWhenReachable: Bool
    let wakeOnLAN: WakeOnLANConfiguration
    let rules: ShareRules

    init(share: NetworkShare) {
        id = share.id
        displayName = share.displayName
        if var components = URLComponents(string: share.urlString) {
            components.user = nil
            components.password = nil
            urlString = components.string ?? share.urlString
        } else {
            urlString = share.urlString
        }
        mountPath = share.mountPath
        keepMounted = share.keepMounted
        mountAtLaunch = share.mountAtLaunch
        autoConnectWhenReachable = share.autoConnectWhenReachable
        wakeOnLAN = share.wakeOnLAN
        rules = share.rules
    }

    func makeNetworkShare(id: UUID? = nil) -> NetworkShare {
        NetworkShare(
            id: id ?? self.id,
            displayName: displayName,
            urlString: urlString,
            mountPath: mountPath,
            keepMounted: keepMounted,
            mountAtLaunch: mountAtLaunch,
            autoConnectWhenReachable: autoConnectWhenReachable,
            wakeOnLAN: wakeOnLAN,
            rules: rules
        )
    }
}

enum ConfigurationImportStrategy {
    case merge
    case replace
}

struct ConfigurationImportResult: Equatable {
    let added: Int
    let updated: Int
    let removed: Int
}

enum ConfigurationTransferError: LocalizedError {
    case unsupportedVersion(Int)
    case invalidConfiguration

    var errorDescription: String? {
        switch self {
        case let .unsupportedVersion(version):
            "This file uses unsupported Otter configuration format \(version)."
        case .invalidConfiguration:
            "The file does not contain a valid Otter configuration."
        }
    }
}

enum ConfigurationTransferService {
    static func archive(shares: [NetworkShare], preferences: AppPreferences) -> OtterConfigurationArchive {
        OtterConfigurationArchive(
            shares: shares.map(PortableShareConfiguration.init),
            monitoring: PortableMonitoringConfiguration(
                fallbackCheckInterval: preferences.fallbackCheckInterval,
                recoverUnresponsiveMounts: preferences.recoverUnresponsiveMounts
            )
        )
    }

    static func encode(_ archive: OtterConfigurationArchive) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(archive)
    }

    static func decode(_ data: Data) throws -> OtterConfigurationArchive {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let archive = try? decoder.decode(OtterConfigurationArchive.self, from: data) else {
            throw ConfigurationTransferError.invalidConfiguration
        }
        guard archive.formatVersion == OtterConfigurationArchive.currentFormatVersion else {
            throw ConfigurationTransferError.unsupportedVersion(archive.formatVersion)
        }
        guard archive.shares.allSatisfy({
            guard let components = URLComponents(string: $0.urlString) else { return false }
            return components.scheme?.lowercased() == "smb"
                && components.host?.isEmpty == false
                && components.user == nil
                && components.password == nil
                && !components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty
        }) else {
            throw ConfigurationTransferError.invalidConfiguration
        }
        return archive
    }
}
