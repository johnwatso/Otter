import Darwin
import Foundation

struct IPAddressChangeObservation: Codable, Hashable, Sendable {
    let previousAddress: String
    let currentAddress: String
    let observedAt: Date
}

enum CachedIPAddressUpdate: Equatable, Sendable {
    case ignored
    case unchanged
    case initial
    case changed(recentChangeCount: Int)

    var didChangeAddress: Bool {
        if case .changed = self { return true }
        return false
    }
}

struct NetworkShare: Identifiable, Codable, Hashable {
    static let ipAddressInstabilityWindow: TimeInterval = 30 * 24 * 60 * 60
    static let ipAddressInstabilityThreshold = 2
    private static let ipAddressHistoryRetention: TimeInterval = 180 * 24 * 60 * 60
    private static let maxIPAddressChangeObservations = 12

    var id: UUID
    var displayName: String
    var urlString: String
    var mountPath: String
    var keepMounted: Bool
    var mountAtLaunch: Bool
    var autoConnectWhenReachable: Bool
    var pauseState: PauseState
    var wakeOnLAN: WakeOnLANConfiguration
    var rules: ShareRules
    var cachedIPAddress: String?
    var ipAddressChangeObservations: [IPAddressChangeObservation]
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        displayName: String,
        urlString: String,
        mountPath: String,
        keepMounted: Bool = true,
        mountAtLaunch: Bool = true,
        autoConnectWhenReachable: Bool = false,
        pauseState: PauseState = .inactive,
        wakeOnLAN: WakeOnLANConfiguration = WakeOnLANConfiguration(),
        rules: ShareRules = ShareRules(),
        cachedIPAddress: String? = nil,
        ipAddressChangeObservations: [IPAddressChangeObservation] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.urlString = urlString
        self.mountPath = mountPath
        self.keepMounted = keepMounted
        self.mountAtLaunch = mountAtLaunch
        self.autoConnectWhenReachable = autoConnectWhenReachable
        self.pauseState = pauseState
        self.wakeOnLAN = wakeOnLAN
        self.rules = rules
        self.cachedIPAddress = cachedIPAddress
        self.ipAddressChangeObservations = ipAddressChangeObservations
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        normalize()
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case urlString
        case mountPath
        case keepMounted
        case mountAtLaunch
        case autoConnectWhenReachable
        case pauseState
        case wakeOnLAN
        case rules
        case cachedIPAddress
        case ipAddressChangeObservations
        case createdAt
        case updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        urlString = try container.decode(String.self, forKey: .urlString)
        mountPath = try container.decode(String.self, forKey: .mountPath)
        keepMounted = try container.decode(Bool.self, forKey: .keepMounted)
        mountAtLaunch = try container.decode(Bool.self, forKey: .mountAtLaunch)
        autoConnectWhenReachable = try container.decodeIfPresent(Bool.self, forKey: .autoConnectWhenReachable) ?? false
        pauseState = try container.decodeIfPresent(PauseState.self, forKey: .pauseState) ?? .inactive
        wakeOnLAN = try container.decodeIfPresent(WakeOnLANConfiguration.self, forKey: .wakeOnLAN) ?? WakeOnLANConfiguration()
        rules = try container.decodeIfPresent(ShareRules.self, forKey: .rules) ?? ShareRules()
        cachedIPAddress = try container.decodeIfPresent(String.self, forKey: .cachedIPAddress)
        ipAddressChangeObservations = try container.decodeIfPresent(
            [IPAddressChangeObservation].self,
            forKey: .ipAddressChangeObservations
        ) ?? []
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        normalize()
    }

    var url: URL? {
        URL(string: urlString)
    }

    var host: String? {
        url?.host(percentEncoded: false)
    }

    var serverIdentity: String? {
        guard let host else { return nil }
        return Self.normalizedServerIdentity(host)
    }

    var serverDisplayName: String {
        guard let host else { return "Unknown Server" }

        let trimmedHost = host
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))

        if let serviceMarker = trimmedHost.range(of: "._smb._tcp.", options: .caseInsensitive) {
            return String(trimmedHost[..<serviceMarker.lowerBound])
        }

        if trimmedHost.lowercased().hasSuffix(".local") {
            return String(trimmedHost.dropLast(".local".count))
        }

        return trimmedHost.isEmpty ? "Unknown Server" : trimmedHost
    }

    mutating func normalize() {
        displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        urlString = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        mountPath = Self.normalizedMountPath(mountPath, displayName: displayName, urlString: urlString)
        pauseState.clearIfExpired()
        wakeOnLAN.normalize()
        rules.normalize()
        cachedIPAddress = cachedIPAddress?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cachedIPAddress?.isEmpty == true {
            cachedIPAddress = nil
        }
        ipAddressChangeObservations = Array(
            ipAddressChangeObservations
                .filter {
                    Self.isIPAddress($0.previousAddress)
                        && Self.isIPAddress($0.currentAddress)
                        && $0.previousAddress != $0.currentAddress
                }
                .sorted { $0.observedAt < $1.observedAt }
                .suffix(Self.maxIPAddressChangeObservations)
        )
    }

    mutating func recordResolvedIPAddress(
        _ address: String,
        observedAt date: Date = Date()
    ) -> CachedIPAddressUpdate {
        let normalizedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isIPAddress(normalizedAddress) else { return .ignored }

        if cachedIPAddress?.localizedCaseInsensitiveCompare(normalizedAddress) == .orderedSame {
            return .unchanged
        }

        let previousAddress = cachedIPAddress
        cachedIPAddress = normalizedAddress

        guard let previousAddress else { return .initial }

        ipAddressChangeObservations.append(
            IPAddressChangeObservation(
                previousAddress: previousAddress,
                currentAddress: normalizedAddress,
                observedAt: date
            )
        )
        let retentionCutoff = date.addingTimeInterval(-Self.ipAddressHistoryRetention)
        ipAddressChangeObservations = Array(
            ipAddressChangeObservations
                .filter { $0.observedAt >= retentionCutoff }
                .sorted { $0.observedAt < $1.observedAt }
                .suffix(Self.maxIPAddressChangeObservations)
        )

        return .changed(recentChangeCount: recentIPAddressChangeCount(at: date))
    }

    func recentIPAddressChangeCount(
        at date: Date = Date(),
        within interval: TimeInterval = NetworkShare.ipAddressInstabilityWindow
    ) -> Int {
        let cutoff = date.addingTimeInterval(-interval)
        return ipAddressChangeObservations.filter {
            $0.observedAt >= cutoff && $0.observedAt <= date
        }.count
    }

    func hasUnstableIPAddress(at date: Date = Date()) -> Bool {
        recentIPAddressChangeCount(at: date) >= Self.ipAddressInstabilityThreshold
    }

    static func inferredShareName(from urlString: String) -> String? {
        guard let components = URLComponents(string: urlString) else { return nil }

        return components.path
            .removingPercentEncoding?
            .split(separator: "/", omittingEmptySubsequences: true)
            .last
            .map(String.init)
    }

    static func isIPAddress(_ host: String) -> Bool {
        var sin = in_addr()
        var sin6 = in6_addr()
        return host.withCString { inet_pton(AF_INET, $0, &sin) } == 1
            || host.withCString { inet_pton(AF_INET6, $0, &sin6) } == 1
    }

    private static func normalizedServerIdentity(_ host: String) -> String? {
        var normalized = host
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()

        if let serviceMarker = normalized.range(of: "._smb._tcp.") {
            normalized = String(normalized[..<serviceMarker.lowerBound])
        } else if normalized.hasSuffix(".local") {
            normalized.removeLast(".local".count)
        }

        return normalized.isEmpty ? nil : normalized
    }

    static func resolveIPAddress(
        for hostname: String,
        using resolver: any HostResolving = SystemHostResolver()
    ) async -> String? {
        await resolver.resolveIPAddress(for: hostname)
    }

    static func resolveIPAddresses(
        for hostname: String,
        using resolver: any HostResolving = SystemHostResolver()
    ) async -> [String] {
        await resolver.resolveIPAddresses(for: hostname)
    }

    static func defaultMountPath(displayName: String, urlString: String) -> String {
        let volumeName = sanitizedVolumeName(inferredShareName(from: urlString))
            ?? sanitizedVolumeName(displayName)
            ?? "Share"

        return "/Volumes/\(volumeName)"
    }

    static func normalizedMountPath(_ mountPath: String, displayName: String, urlString: String) -> String {
        let fallback = defaultMountPath(displayName: displayName, urlString: urlString)
        let trimmedPath = mountPath.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedPath.isEmpty,
              trimmedPath != "/",
              trimmedPath != "/Volumes",
              trimmedPath != "/Volumes/"
        else {
            return fallback
        }

        if !trimmedPath.hasPrefix("/") {
            return "/Volumes/\(sanitizedVolumeName(trimmedPath) ?? sanitizedVolumeName(fallback) ?? "Share")"
        }

        let standardizedPath = URL(fileURLWithPath: (trimmedPath as NSString).expandingTildeInPath)
            .standardizedFileURL
            .path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        guard !standardizedPath.isEmpty else { return fallback }

        let absolutePath = "/\(standardizedPath)"
        if absolutePath.hasPrefix("/Volumes/") {
            return absolutePath
        }

        let lastPathComponent = URL(fileURLWithPath: absolutePath).lastPathComponent
        return "/Volumes/\(sanitizedVolumeName(lastPathComponent) ?? sanitizedVolumeName(fallback) ?? "Share")"
    }

    private static func sanitizedVolumeName(_ value: String?) -> String? {
        guard let value else { return nil }

        let trimmedName = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        guard !trimmedName.isEmpty else { return nil }

        return trimmedName
            .split(separator: "/", omittingEmptySubsequences: true)
            .last
            .map(String.init)
    }
}

struct NetworkShareServerGroup: Identifiable, Hashable {
    let id: String
    let serverName: String
    let shares: [NetworkShare]

    var isGrouped: Bool {
        shares.count > 1
    }

    static func make(from shares: [NetworkShare]) -> [NetworkShareServerGroup] {
        var sharesByKey: [String: [NetworkShare]] = [:]
        var serverNamesByKey: [String: String] = [:]
        var orderedKeys: [String] = []

        for share in shares {
            let key = share.serverIdentity.map { "server:\($0)" } ?? "share:\(share.id.uuidString)"
            if sharesByKey[key] == nil {
                orderedKeys.append(key)
                serverNamesByKey[key] = share.serverDisplayName
            }
            sharesByKey[key, default: []].append(share)
        }

        return orderedKeys.compactMap { key in
            guard let groupedShares = sharesByKey[key],
                  let serverName = serverNamesByKey[key]
            else { return nil }

            return NetworkShareServerGroup(
                id: key,
                serverName: serverName,
                shares: groupedShares
            )
        }
    }
}

struct WakeOnLANConfiguration: Codable, Hashable {
    static let defaultBroadcastAddress = "255.255.255.255"
    static let defaultPort = 9

    var isEnabled: Bool
    var macAddress: String
    var broadcastAddress: String
    var port: Int

    init(
        isEnabled: Bool = false,
        macAddress: String = "",
        broadcastAddress: String = Self.defaultBroadcastAddress,
        port: Int = Self.defaultPort
    ) {
        self.isEnabled = isEnabled
        self.macAddress = macAddress
        self.broadcastAddress = broadcastAddress
        self.port = port
        normalize()
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled
        case macAddress
        case broadcastAddress
        case port
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        macAddress = try container.decodeIfPresent(String.self, forKey: .macAddress) ?? ""
        broadcastAddress = try container.decodeIfPresent(String.self, forKey: .broadcastAddress) ?? Self.defaultBroadcastAddress
        port = try container.decodeIfPresent(Int.self, forKey: .port) ?? Self.defaultPort
        normalize()
    }

    var normalizedMACAddress: String? {
        Self.normalizedMACAddress(macAddress)
    }

    var canSendWakePacket: Bool {
        isEnabled && normalizedMACAddress != nil
    }

    mutating func normalize() {
        macAddress = macAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        if let normalizedMACAddress {
            macAddress = normalizedMACAddress
        }

        broadcastAddress = broadcastAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        if broadcastAddress.isEmpty {
            broadcastAddress = Self.defaultBroadcastAddress
        }

        port = min(max(port, 1), 65_535)
    }

    static func normalizedMACAddress(_ value: String) -> String? {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty else { return nil }

        var nibbles: [UInt8] = []
        nibbles.reserveCapacity(12)

        for scalar in trimmedValue.unicodeScalars {
            if let value = hexValue(for: scalar) {
                nibbles.append(value)
                continue
            }

            guard scalar == ":" || scalar == "-" || scalar == "." else {
                return nil
            }
        }

        guard nibbles.count == 12 else { return nil }

        var pairs: [String] = []
        pairs.reserveCapacity(6)

        for index in stride(from: 0, to: nibbles.count, by: 2) {
            let byte = (nibbles[index] << 4) | nibbles[index + 1]
            pairs.append(String(format: "%02X", byte))
        }

        return pairs.joined(separator: ":")
    }

    static func macAddressBytes(from value: String) -> [UInt8]? {
        guard let normalizedMACAddress = normalizedMACAddress(value) else { return nil }

        return normalizedMACAddress
            .split(separator: ":")
            .compactMap { UInt8($0, radix: 16) }
    }

    private static func hexValue(for scalar: Unicode.Scalar) -> UInt8? {
        switch scalar.value {
        case 48...57:
            UInt8(scalar.value - 48)
        case 65...70:
            UInt8(scalar.value - 55)
        case 97...102:
            UInt8(scalar.value - 87)
        default:
            nil
        }
    }
}

struct ShareRules: Codable, Hashable {
    var wifiNetworkName: String
    // IPv4 networks (CIDR strings like "192.168.1.0/24") captured when the
    // network condition was configured. Being on any of them identifies the
    // registered network, whether the Mac is on Wi-Fi or Ethernet.
    var registeredSubnets: [String]
    var vpnRuleEnabled: Bool
    var vpnName: String

    init(
        wifiNetworkName: String = "",
        registeredSubnets: [String] = [],
        vpnRuleEnabled: Bool = false,
        vpnName: String = ""
    ) {
        self.wifiNetworkName = wifiNetworkName
        self.registeredSubnets = registeredSubnets
        self.vpnRuleEnabled = vpnRuleEnabled
        self.vpnName = vpnName
        normalize()
    }

    private enum CodingKeys: String, CodingKey {
        case wifiNetworkName
        case registeredSubnets
        case vpnRuleEnabled
        case vpnName
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        wifiNetworkName = try container.decodeIfPresent(String.self, forKey: .wifiNetworkName) ?? ""
        registeredSubnets = try container.decodeIfPresent([String].self, forKey: .registeredSubnets) ?? []
        vpnRuleEnabled = try container.decodeIfPresent(Bool.self, forKey: .vpnRuleEnabled) ?? false
        vpnName = try container.decodeIfPresent(String.self, forKey: .vpnName) ?? ""
        normalize()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(wifiNetworkName, forKey: .wifiNetworkName)
        try container.encode(registeredSubnets, forKey: .registeredSubnets)
        try container.encode(vpnRuleEnabled, forKey: .vpnRuleEnabled)
        try container.encode(vpnName, forKey: .vpnName)
    }

    var hasWiFiNetworkRule: Bool {
        requiredWiFiNetworkName != nil
    }

    var hasNetworkRule: Bool {
        requiredWiFiNetworkName != nil || !registeredSubnets.isEmpty
    }

    var hasVPNRule: Bool {
        vpnRuleEnabled
    }

    var requiredWiFiNetworkName: String? {
        let trimmedName = wifiNetworkName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedName.isEmpty ? nil : trimmedName
    }

    var requiredVPNName: String? {
        let trimmedName = vpnName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedName.isEmpty ? nil : trimmedName
    }

    mutating func normalize() {
        wifiNetworkName = wifiNetworkName.trimmingCharacters(in: .whitespacesAndNewlines)
        vpnName = vpnName.trimmingCharacters(in: .whitespacesAndNewlines)
        registeredSubnets = registeredSubnets
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

struct ShareRuleEvaluation: Equatable {
    var allowsConnection: Bool
    var blockedStatus: ShareStatus?
    var shouldDisconnectMountedShare: Bool
    var shouldAttemptMount: Bool

    static let noRules = ShareRuleEvaluation(
        allowsConnection: true,
        blockedStatus: nil,
        shouldDisconnectMountedShare: false,
        shouldAttemptMount: false
    )
}

extension ShareRules {
    // Pure rule evaluation over a snapshot of network state, so it can be unit
    // tested without the monitor or live services.
    func evaluate(
        currentWiFiNetworkName: String?,
        isVPNConnected: Bool,
        activeVPNNames: [String],
        currentIPv4Subnets: [String] = []
    ) -> ShareRuleEvaluation {
        if hasNetworkRule {
            let currentNetworkName = currentWiFiNetworkName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let matchesWiFiName = requiredWiFiNetworkName.map { requiredName in
                currentNetworkName?.localizedCaseInsensitiveCompare(requiredName) == .orderedSame
            } ?? false
            let matchesRegisteredSubnet = !registeredSubnets.isEmpty && currentIPv4Subnets.contains { registeredSubnets.contains($0) }
            // Shares configured before subnet capture existed have nothing to
            // compare against, so any wired connection keeps counting as a match.
            let isLegacyEthernet = registeredSubnets.isEmpty && currentNetworkName == nil && !isVPNConnected

            // macOS does not expose the profile name of a tunnel created by
            // another app. A configured VPN therefore acts as an alternative
            // connection path: a live tunnel triggers the server check, while
            // vpnName remains the service Otter starts or asks the user to open.
            let isVPNActive = vpnRuleEnabled && requiredVPNName != nil && isVPNConnected

            let matches = matchesWiFiName || matchesRegisteredSubnet || isLegacyEthernet || isVPNActive

            if !matches {
                let requirement = requiredVPNName.map {
                    "the registered network or VPN “\($0)”"
                } ?? "the registered network"
                return ShareRuleEvaluation(
                    allowsConnection: false,
                    blockedStatus: .waitingForAllowedNetwork(requirement),
                    shouldDisconnectMountedShare: true,
                    shouldAttemptMount: false
                )
            }
            
            return ShareRuleEvaluation(
                allowsConnection: true,
                blockedStatus: nil,
                shouldDisconnectMountedShare: false,
                shouldAttemptMount: true
            )
        }

        if vpnRuleEnabled {
            guard let requiredVPNName else {
                return ShareRuleEvaluation(
                    allowsConnection: false,
                    blockedStatus: .waitingForAllowedNetwork("a VPN selected in this share’s settings"),
                    shouldDisconnectMountedShare: true,
                    shouldAttemptMount: false
                )
            }

            let matches = isVPNConnected

            if !matches {
                return ShareRuleEvaluation(
                    allowsConnection: false,
                    blockedStatus: .waitingForVPN(requiredVPNName),
                    shouldDisconnectMountedShare: true,
                    shouldAttemptMount: false
                )
            }
            
            return ShareRuleEvaluation(
                allowsConnection: true,
                blockedStatus: nil,
                shouldDisconnectMountedShare: false,
                shouldAttemptMount: true
            )
        }

        return .noRules
    }
}
