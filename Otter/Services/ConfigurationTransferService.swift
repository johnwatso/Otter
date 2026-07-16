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

struct ManagedConfigurationPayload: Codable, Equatable {
    static let currentFormatVersion = 1

    let formatVersion: Int
    let shares: [PortableShareConfiguration]
    let monitoring: PortableMonitoringConfiguration?
}

enum ManagedConfigurationService {
    static let defaultsKey = "ManagedConfiguration"

    static func load(from defaults: UserDefaults) -> ManagedConfigurationPayload? {
        let directValue = defaults.object(forKey: defaultsKey)
        let managedPreferencesValue = defaults
            .dictionary(forKey: "com.apple.configuration.managed")?[defaultsKey]
        guard let value = directValue ?? managedPreferencesValue,
              let data = data(from: value)
        else { return nil }

        guard let payload = try? JSONDecoder().decode(ManagedConfigurationPayload.self, from: data),
              payload.formatVersion == ManagedConfigurationPayload.currentFormatVersion,
              payload.shares.allSatisfy(isValidManagedShare),
              Set(payload.shares.map(\.id)).count == payload.shares.count
        else { return nil }

        return payload
    }

    private static func data(from value: Any) -> Data? {
        if let data = value as? Data {
            return data
        }
        if let json = value as? String {
            return Data(json.utf8)
        }
        guard JSONSerialization.isValidJSONObject(value) else { return nil }
        return try? JSONSerialization.data(withJSONObject: value)
    }

    private static func isValidManagedShare(_ share: PortableShareConfiguration) -> Bool {
        guard let components = URLComponents(string: share.urlString) else { return false }
        return components.scheme?.lowercased() == "smb"
            && components.host?.isEmpty == false
            && components.user == nil
            && components.password == nil
            && !components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty
            && (!share.rules.vpnRuleEnabled || share.rules.requiredVPNName != nil)
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

struct OtterSupportPackage: Codable, Equatable {
    static let currentFormatVersion = 1

    let formatVersion: Int
    let generatedAt: Date
    let privacyNotice: String
    let environment: SupportEnvironment
    let shares: [SupportShare]
    let events: [SupportEvent]
}

struct SupportEnvironment: Codable, Equatable {
    let otterVersion: String
    let otterBuild: String
    let macOSVersion: String
    let isOnline: Bool
    let activeNamedVPNCount: Int
    let hasUnidentifiedTunnel: Bool
    let configuredVPNCount: Int
    let controllableVPNCount: Int
    let notifications: String
    let startsAtLogin: Bool
    let loginItemRequiresApproval: Bool
    let fallbackCheckInterval: TimeInterval
    let recoversUnresponsiveMounts: Bool
}

struct SupportShare: Codable, Equatable {
    let reference: String
    let status: String
    let hasSavedCredentials: Bool
    let hasCachedFallbackAddress: Bool
    let recentAddressChangeCount: Int
    let keepsMounted: Bool
    let mountsAtLogin: Bool
    let connectsWhenReachable: Bool
    let usesRegisteredNetworkRule: Bool
    let usesNamedVPNRule: Bool
    let vpnCanBeStartedByOtter: Bool
    let wakeOnLANEnabled: Bool
}

struct SupportEvent: Codable, Equatable {
    let shareReference: String
    let date: Date
    let kind: String
}

@MainActor
enum SupportPackageService {
    static func make(
        settings: SettingsStore,
        eventLog: ShareEventLog,
        monitor: ShareMonitor,
        networkService: NetworkReachabilityService,
        notificationService: NotificationService,
        loginItemService: LoginItemService,
        generatedAt: Date = Date()
    ) -> OtterSupportPackage {
        let referenceByShareID = Dictionary(uniqueKeysWithValues: settings.shares.enumerated().map {
            ($0.element.id, "Share \($0.offset + 1)")
        })

        let shares = settings.shares.enumerated().map { index, share in
            let host = share.host ?? ""
            let hasSavedCredentials = !host.isEmpty && settings.hasCredentials(for: host)
                || share.cachedIPAddress.map(settings.hasCredentials(for:)) == true
            let requiredVPNName = share.rules.requiredVPNName

            return SupportShare(
                reference: "Share \(index + 1)",
                status: monitor.status(for: share).label,
                hasSavedCredentials: hasSavedCredentials,
                hasCachedFallbackAddress: share.cachedIPAddress != nil,
                recentAddressChangeCount: share.recentIPAddressChangeCount(at: generatedAt),
                keepsMounted: share.keepMounted,
                mountsAtLogin: share.mountAtLaunch,
                connectsWhenReachable: share.autoConnectWhenReachable,
                usesRegisteredNetworkRule: share.rules.hasNetworkRule,
                usesNamedVPNRule: requiredVPNName != nil,
                vpnCanBeStartedByOtter: requiredVPNName.map(networkService.canControlVPN(named:)) ?? false,
                wakeOnLANEnabled: share.wakeOnLAN.isEnabled
            )
        }

        let events = eventLog.events.compactMap { event -> SupportEvent? in
            guard let shareReference = referenceByShareID[event.shareID] else { return nil }
            return SupportEvent(
                shareReference: shareReference,
                date: event.date,
                kind: event.kind.rawValue
            )
        }

        return OtterSupportPackage(
            formatVersion: OtterSupportPackage.currentFormatVersion,
            generatedAt: generatedAt,
            privacyNotice: "Server addresses, share names, mount paths, network names, VPN names, usernames, passwords, and event details are intentionally omitted.",
            environment: SupportEnvironment(
                otterVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown",
                otterBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown",
                macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                isOnline: networkService.isOnline,
                activeNamedVPNCount: networkService.activeVPNNames.count,
                hasUnidentifiedTunnel: networkService.hasUnidentifiedTunnel,
                configuredVPNCount: networkService.knownVPNNames.count,
                controllableVPNCount: networkService.controllableVPNNames.count,
                notifications: notificationService.authorizationStatusTitle,
                startsAtLogin: loginItemService.isEnabled,
                loginItemRequiresApproval: loginItemService.requiresApproval,
                fallbackCheckInterval: settings.preferences.fallbackCheckInterval,
                recoversUnresponsiveMounts: settings.preferences.recoverUnresponsiveMounts
            ),
            shares: shares,
            events: events
        )
    }

    static func encode(_ package: OtterSupportPackage) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(package)
    }
}
