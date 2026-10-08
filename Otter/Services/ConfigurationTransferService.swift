import CryptoKit
import Foundation

struct OtterConfigurationArchive: Codable, Equatable {
    static let currentFormatVersion = 2

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
    let connectionMode: ConnectionMode
    let prefersIPv4: Bool
    let wakeOnLAN: WakeOnLANConfiguration
    let rules: ShareRules
    let healthCheck: ShareHealthCheckConfiguration

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
        connectionMode = share.connectionMode
        prefersIPv4 = share.prefersIPv4
        wakeOnLAN = share.wakeOnLAN
        rules = share.rules
        healthCheck = share.healthCheck
    }

    private enum CodingKeys: String, CodingKey {
        case id, displayName, urlString, mountPath, connectionMode, prefersIPv4, wakeOnLAN, rules, healthCheck
        // Read from — and written for — configurations produced before
        // connection modes replaced the three separate switches.
        case keepMounted, mountAtLaunch, autoConnectWhenReachable
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        urlString = try container.decode(String.self, forKey: .urlString)
        mountPath = try container.decode(String.self, forKey: .mountPath)
        prefersIPv4 = try container.decodeIfPresent(Bool.self, forKey: .prefersIPv4) ?? true
        wakeOnLAN = try container.decodeIfPresent(WakeOnLANConfiguration.self, forKey: .wakeOnLAN) ?? WakeOnLANConfiguration()
        rules = try container.decodeIfPresent(ShareRules.self, forKey: .rules) ?? ShareRules()
        if let storedMode = try container.decodeIfPresent(ConnectionMode.self, forKey: .connectionMode) {
            connectionMode = storedMode
        } else {
            connectionMode = NetworkShare.migratedConnectionMode(
                keepMounted: try container.decodeIfPresent(Bool.self, forKey: .keepMounted) ?? true,
                mountAtLaunch: try container.decodeIfPresent(Bool.self, forKey: .mountAtLaunch) ?? true,
                autoConnectWhenReachable: try container.decodeIfPresent(Bool.self, forKey: .autoConnectWhenReachable) ?? false,
                rules: rules
            )
        }
        healthCheck = try container.decodeIfPresent(ShareHealthCheckConfiguration.self, forKey: .healthCheck) ?? ShareHealthCheckConfiguration()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(urlString, forKey: .urlString)
        try container.encode(mountPath, forKey: .mountPath)
        try container.encode(connectionMode, forKey: .connectionMode)
        // Written so a Mac still running an older Otter can import this file.
        try container.encode(connectionMode.maintainsConnection, forKey: .keepMounted)
        try container.encode(connectionMode.connectsAutomatically, forKey: .mountAtLaunch)
        try container.encode(connectionMode == .adaptive, forKey: .autoConnectWhenReachable)
        try container.encode(prefersIPv4, forKey: .prefersIPv4)
        try container.encode(wakeOnLAN, forKey: .wakeOnLAN)
        try container.encode(rules, forKey: .rules)
        try container.encode(healthCheck, forKey: .healthCheck)
    }

    func makeNetworkShare(id: UUID? = nil) -> NetworkShare {
        NetworkShare(
            id: id ?? self.id,
            displayName: displayName,
            urlString: urlString,
            mountPath: mountPath,
            connectionMode: connectionMode,
            wakeOnLAN: wakeOnLAN,
            rules: rules,
            healthCheck: healthCheck,
            prefersIPv4: prefersIPv4
        )
    }
}

struct ManagedConfigurationPayload: Codable, Equatable {
    static let currentFormatVersion = 2

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
              (1...ManagedConfigurationPayload.currentFormatVersion).contains(payload.formatVersion),
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
        return NetworkShareProtocol(urlScheme: components.scheme) != nil
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
    case invalidBackupPassword

    var errorDescription: String? {
        switch self {
        case let .unsupportedVersion(version):
            "This file uses unsupported Otter configuration format \(version)."
        case .invalidConfiguration:
            "The file does not contain a valid Otter configuration."
        case .invalidBackupPassword:
            "The backup password is incorrect or this protected backup is damaged."
        }
    }
}

// Credentials are only ever included inside this encrypted envelope. Plain
// .otterconfig files remain safe to put under source control or send to IT.
private struct CredentialedConfigurationArchive: Codable {
    let configuration: OtterConfigurationArchive
    let credentials: [PortableCredential]
}

struct ProtectedConfigurationBackup: Codable, Equatable {
    static let currentFormatVersion = 1
    let formatVersion: Int
    let salt: Data
    let encryptedPayload: Data
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
        guard (1...OtterConfigurationArchive.currentFormatVersion).contains(archive.formatVersion) else {
            throw ConfigurationTransferError.unsupportedVersion(archive.formatVersion)
        }
        guard archive.shares.allSatisfy({
            guard let components = URLComponents(string: $0.urlString) else { return false }
            return NetworkShareProtocol(urlScheme: components.scheme) != nil
                && components.host?.isEmpty == false
                && components.user == nil
                && components.password == nil
                && !components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty
        }) else {
            throw ConfigurationTransferError.invalidConfiguration
        }
        return archive
    }

    static func encodeProtectedBackup(
        _ archive: OtterConfigurationArchive,
        credentials: [PortableCredential],
        password: String
    ) throws -> Data {
        let normalizedPassword = password.trimmingCharacters(in: .newlines)
        guard !normalizedPassword.isEmpty else { throw ConfigurationTransferError.invalidBackupPassword }
        let payload = try JSONEncoder.otterEncoder.encode(
            CredentialedConfigurationArchive(configuration: archive, credentials: credentials)
        )
        let salt = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
        let key = derivedKey(password: normalizedPassword, salt: salt)
        let sealedBox = try AES.GCM.seal(payload, using: key)
        guard let sealed = sealedBox.combined else { throw ConfigurationTransferError.invalidConfiguration }
        return try JSONEncoder.otterEncoder.encode(
            ProtectedConfigurationBackup(
                formatVersion: ProtectedConfigurationBackup.currentFormatVersion,
                salt: salt,
                encryptedPayload: sealed
            )
        )
    }

    static func decodeProtectedBackup(
        _ data: Data,
        password: String
    ) throws -> (archive: OtterConfigurationArchive, credentials: [PortableCredential]) {
        let backup = try JSONDecoder.otterDecoder.decode(ProtectedConfigurationBackup.self, from: data)
        guard backup.formatVersion == ProtectedConfigurationBackup.currentFormatVersion else {
            throw ConfigurationTransferError.unsupportedVersion(backup.formatVersion)
        }
        do {
            let key = derivedKey(password: password.trimmingCharacters(in: .newlines), salt: backup.salt)
            let box = try AES.GCM.SealedBox(combined: backup.encryptedPayload)
            let payload = try AES.GCM.open(box, using: key)
            let protectedArchive = try JSONDecoder.otterDecoder.decode(CredentialedConfigurationArchive.self, from: payload)
            // Validate configurations exactly as plain imports do.
            _ = try decode(try encode(protectedArchive.configuration))
            return (protectedArchive.configuration, protectedArchive.credentials)
        } catch let error as ConfigurationTransferError {
            throw error
        } catch {
            throw ConfigurationTransferError.invalidBackupPassword
        }
    }

    private static func derivedKey(password: String, salt: Data) -> SymmetricKey {
        // PBKDF2 is not exposed by CryptoKit. Rehashing a salted SHA-256 value
        // gives a deliberately expensive local-file key derivation without a
        // dependency, and the random salt prevents precomputed attacks.
        var material = Data(password.utf8) + salt
        for _ in 0..<100_000 {
            material = Data(SHA256.hash(data: material))
        }
        return SymmetricKey(data: material)
    }
}

private extension JSONEncoder {
    static var otterEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var otterDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

struct OtterSupportPackage: Codable, Equatable {
    static let currentFormatVersion = 2

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
    let architecture: String
    let isOnline: Bool
    let monitorIsChecking: Bool
    let globallyPaused: Bool
    let activeNamedVPNCount: Int
    let hasUnidentifiedTunnel: Bool
    let configuredVPNCount: Int
    let controllableVPNCount: Int
    let notifications: String
    let startsAtLogin: Bool
    let loginItemRequiresApproval: Bool
    let fallbackCheckInterval: TimeInterval
    let recoversUnresponsiveMounts: Bool
    let detectsNewShares: Bool
    let deduplicatesConnections: Bool
}

struct SupportShare: Codable, Equatable {
    let reference: String
    let status: String
    let statusDetail: String?
    let hasSavedCredentials: Bool
    let hasCachedFallbackAddress: Bool
    let recentAddressChangeCount: Int
    let connectionMode: String
    let keepsMounted: Bool
    let mountsAtLogin: Bool
    let usesRegisteredNetworkRule: Bool
    let usesNamedVPNRule: Bool
    let startsVPNAutomatically: Bool
    let vpnCanBeStartedByOtter: Bool
    let wakeOnLANEnabled: Bool
    let healthCheckEnabled: Bool
    let requiresWritableVolume: Bool
    let hasSentinelCheck: Bool
    let failureCount: Int
    let needsCredentials: Bool
    let lastCheckedAt: Date?
    let nextRetryAt: Date?
    let mountedAt: Date?
    let lastConnectedAt: Date?
    let connectionDrops: Int
    let connectionFailures: Int
    let healthFailures: Int
    let lastProblemAt: Date?
}

struct SupportEvent: Codable, Equatable {
    let shareReference: String
    let date: Date
    let kind: String
    let detail: String?
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
                || share.cachedIPAddresses.contains(where: settings.hasCredentials(for:))
            let requiredVPNName = share.rules.requiredVPNName
            let runtime = monitor.runtimeState(for: share)
            let reliability = eventLog.reliabilitySummary(for: share.id, at: generatedAt)

            return SupportShare(
                reference: "Share \(index + 1)",
                status: monitor.status(for: share).label,
                statusDetail: diagnosticDetail(runtime.status.detail),
                hasSavedCredentials: hasSavedCredentials,
                hasCachedFallbackAddress: !share.cachedIPAddresses.isEmpty,
                recentAddressChangeCount: share.recentIPAddressChangeCount(at: generatedAt),
                connectionMode: share.connectionMode.rawValue,
                keepsMounted: share.maintainsConnection,
                mountsAtLogin: share.connectsAutomatically,
                usesRegisteredNetworkRule: share.rules.hasNetworkRule,
                usesNamedVPNRule: requiredVPNName != nil,
                startsVPNAutomatically: share.rules.shouldConnectVPNAutomatically,
                vpnCanBeStartedByOtter: requiredVPNName.map(networkService.canControlVPN(named:)) ?? false,
                wakeOnLANEnabled: share.wakeOnLAN.isEnabled,
                healthCheckEnabled: share.healthCheck.isEnabled,
                requiresWritableVolume: share.healthCheck.requiresWritableVolume,
                hasSentinelCheck: !share.healthCheck.sentinelRelativePath.isEmpty,
                failureCount: runtime.failureCount,
                needsCredentials: runtime.needsCredentials,
                lastCheckedAt: runtime.lastCheckedAt,
                nextRetryAt: runtime.nextRetryDate,
                mountedAt: runtime.mountedAt,
                lastConnectedAt: runtime.lastConnectedAt,
                connectionDrops: reliability.connectionDrops,
                connectionFailures: reliability.failures,
                healthFailures: reliability.healthFailures,
                lastProblemAt: reliability.lastProblemAt
            )
        }

        let events = eventLog.events.compactMap { event -> SupportEvent? in
            guard let shareReference = referenceByShareID[event.shareID] else { return nil }
            return SupportEvent(
                shareReference: shareReference,
                date: event.date,
                kind: event.kind.rawValue,
                detail: diagnosticDetail(event.detail, for: event.kind)
            )
        }

        return OtterSupportPackage(
            formatVersion: OtterSupportPackage.currentFormatVersion,
            generatedAt: generatedAt,
            privacyNotice: "Server addresses, share names, mount paths, network names, VPN names, usernames, passwords, and free-form event details are omitted. Safe error categories and numeric mount codes are retained.",
            environment: SupportEnvironment(
                otterVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown",
                otterBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown",
                macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                architecture: runtimeArchitecture,
                isOnline: networkService.isOnline,
                monitorIsChecking: monitor.isChecking,
                globallyPaused: settings.isGloballyPaused,
                activeNamedVPNCount: networkService.activeVPNNames.count,
                hasUnidentifiedTunnel: networkService.hasUnidentifiedTunnel,
                configuredVPNCount: networkService.knownVPNNames.count,
                controllableVPNCount: networkService.controllableVPNNames.count,
                notifications: notificationService.authorizationStatusTitle,
                startsAtLogin: loginItemService.isEnabled,
                loginItemRequiresApproval: loginItemService.requiresApproval,
                fallbackCheckInterval: settings.preferences.fallbackCheckInterval,
                recoversUnresponsiveMounts: settings.preferences.recoverUnresponsiveMounts,
                detectsNewShares: settings.preferences.detectNewShares,
                deduplicatesConnections: settings.preferences.deduplicateConnections
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

    static func textData(_ package: OtterSupportPackage) -> Data {
        Data(renderText(package).utf8)
    }

    static func renderText(_ package: OtterSupportPackage, now: Date? = nil) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let reference = now ?? package.generatedAt
        let environment = package.environment

        var output = "=== Otter Diagnostic Report ===\n"
        output += "Generated: \(formatter.string(from: package.generatedAt))\n"
        output += "App: \(environment.otterVersion) (build \(environment.otterBuild))\n"
        output += "OS: \(environment.macOSVersion) · arch \(environment.architecture)\n"
        output += "Privacy: \(package.privacyNotice)\n\n"

        output += "=== Environment ===\n"
        output += "online=\(environment.isOnline) monitorChecking=\(environment.monitorIsChecking) globallyPaused=\(environment.globallyPaused)\n"
        output += "VPN: activeNamed=\(environment.activeNamedVPNCount) unidentifiedTunnel=\(environment.hasUnidentifiedTunnel) configured=\(environment.configuredVPNCount) controllable=\(environment.controllableVPNCount)\n"
        output += "notifications=\(environment.notifications) startsAtLogin=\(environment.startsAtLogin) loginItemRequiresApproval=\(environment.loginItemRequiresApproval)\n"
        output += "fallbackCheck=\(formatDuration(environment.fallbackCheckInterval)) recoverUnresponsiveMounts=\(environment.recoversUnresponsiveMounts) detectNewShares=\(environment.detectsNewShares) deduplicateConnections=\(environment.deduplicatesConnections)\n\n"

        output += "=== Shares (\(package.shares.count)) ===\n"
        if package.shares.isEmpty {
            output += "(none)\n"
        } else {
            for share in package.shares {
                output += "[\(share.reference)] status=\(share.status) mode=\(share.connectionMode) failures=\(share.failureCount) needsCredentials=\(share.needsCredentials)\n"
                if let statusDetail = share.statusDetail {
                    output += "  statusDetail=\(statusDetail)\n"
                }
                output += "  keepMounted=\(share.keepsMounted) mountAtLogin=\(share.mountsAtLogin) savedCredentials=\(share.hasSavedCredentials) cachedFallback=\(share.hasCachedFallbackAddress) addressChanges30d=\(share.recentAddressChangeCount)\n"
                output += "  networkRule=\(share.usesRegisteredNetworkRule) VPNRule=\(share.usesNamedVPNRule) autoStartVPN=\(share.startsVPNAutomatically) VPNControllable=\(share.vpnCanBeStartedByOtter) wakeOnLAN=\(share.wakeOnLANEnabled)\n"
                output += "  healthCheck=\(share.healthCheckEnabled) writableRequired=\(share.requiresWritableVolume) sentinelConfigured=\(share.hasSentinelCheck)\n"
                let timestamps = [
                    timestamp("lastChecked", share.lastCheckedAt, reference: reference, formatter: formatter),
                    timestamp("nextRetry", share.nextRetryAt, reference: reference, formatter: formatter),
                    timestamp("mountedAt", share.mountedAt, reference: reference, formatter: formatter),
                    timestamp("lastConnected", share.lastConnectedAt, reference: reference, formatter: formatter),
                    timestamp("lastProblem", share.lastProblemAt, reference: reference, formatter: formatter)
                ].compactMap { $0 }
                if !timestamps.isEmpty {
                    output += "  \(timestamps.joined(separator: " "))\n"
                }
                output += "  reliability7d: drops=\(share.connectionDrops) connectionFailures=\(share.connectionFailures) healthFailures=\(share.healthFailures)\n"
            }
        }
        output += "\n"

        let events = package.events.sorted { $0.date < $1.date }
        output += "=== Events (oldest → newest, \(events.count)) ===\n"
        if events.isEmpty {
            output += "(none)\n"
        } else {
            for event in events {
                output += "\(formatter.string(from: event.date))  [\(event.shareReference)]  \(event.kind)"
                if let detail = event.detail, !detail.isEmpty {
                    output += "  \(detail)"
                }
                output += "\n"
            }
        }

        return output
    }

    private static var runtimeArchitecture: String {
#if arch(arm64)
        "arm64"
#elseif arch(x86_64)
        "x86_64"
#else
        "unknown"
#endif
    }

    private static func timestamp(
        _ name: String,
        _ date: Date?,
        reference: Date,
        formatter: ISO8601DateFormatter
    ) -> String? {
        guard let date else { return nil }
        let interval = date.timeIntervalSince(reference)
        let relation = interval > 0
            ? "in \(formatDuration(interval))"
            : "\(formatDuration(-interval)) ago"
        return "\(name)=\(formatter.string(from: date)) (\(relation))"
    }

    private static func formatDuration(_ interval: TimeInterval) -> String {
        let seconds = Int(max(0, interval).rounded())
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3_600 { return "\(seconds / 60)m\(seconds % 60)s" }
        let hours = seconds / 3_600
        return "\(hours)h\((seconds % 3_600) / 60)m"
    }

    private static func diagnosticDetail(
        _ detail: String?,
        for kind: ShareEventKind? = nil
    ) -> String? {
        guard let detail = detail?.trimmingCharacters(in: .whitespacesAndNewlines), !detail.isEmpty else {
            return nil
        }
        let lowercased = detail.lowercased()

        if let expression = try? NSRegularExpression(pattern: #"(?i)mount error\s+(-?\d+)"#),
           let match = expression.firstMatch(
               in: detail,
               range: NSRange(detail.startIndex..<detail.endIndex, in: detail)
           ),
           let codeRange = Range(match.range(at: 1), in: detail) {
            return "macOS returned mount error \(detail[codeRange])."
        }
        if lowercased.contains("authenticate") || lowercased.contains("credential") {
            return "macOS authentication or saved credentials require attention."
        }
        if lowercased.contains("network address is invalid") || lowercased.contains("invalid address") {
            return "The network address was rejected as invalid."
        }
        if lowercased.contains("server didn't respond") || lowercased.contains("server did not respond") {
            return "The server did not respond."
        }
        if lowercased.contains("not writable") {
            return "The mounted volume is not writable."
        }
        if lowercased.contains("expected file") && lowercased.contains("missing") {
            return "A configured sentinel file is missing."
        }
        if lowercased.contains("could not be read") || lowercased.contains("stopped responding") {
            return "The mounted volume could not be read or stopped responding."
        }

        switch kind {
        case .blockedByRule:
            return "Connection conditions prevented mounting."
        case .credentialsRequired:
            return "Finder credentials need to be refreshed."
        case .duplicateResolved:
            return "A duplicate connection was reconciled with the preferred server name."
        case .recoveryAttempted:
            return "Otter attempted safe recovery of an unresponsive volume."
        case .mountFailed:
            return "A mount attempt failed."
        case .healthCheckFailed:
            return "A mounted-volume health check failed."
        case .unresponsiveDetected:
            return "The mounted volume stopped responding."
        case .mounted, .connectionLost, .disconnected, .wakePacketSent, .none:
            return nil
        }
    }
}
