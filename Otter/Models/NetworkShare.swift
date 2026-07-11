import Foundation
import Security

struct NetworkShare: Identifiable, Codable, Hashable {
    var id: UUID
    var displayName: String
    var urlString: String
    var mountPath: String
    var keepMounted: Bool
    var mountAtLaunch: Bool
    var autoConnectWhenReachable: Bool
    var wakeOnLAN: WakeOnLANConfiguration
    var rules: ShareRules
    var cachedIPAddress: String?
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
        wakeOnLAN: WakeOnLANConfiguration = WakeOnLANConfiguration(),
        rules: ShareRules = ShareRules(),
        cachedIPAddress: String? = nil,
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
        self.wakeOnLAN = wakeOnLAN
        self.rules = rules
        self.cachedIPAddress = cachedIPAddress
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
        case wakeOnLAN
        case rules
        case cachedIPAddress
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
        wakeOnLAN = try container.decodeIfPresent(WakeOnLANConfiguration.self, forKey: .wakeOnLAN) ?? WakeOnLANConfiguration()
        rules = try container.decodeIfPresent(ShareRules.self, forKey: .rules) ?? ShareRules()
        cachedIPAddress = try container.decodeIfPresent(String.self, forKey: .cachedIPAddress)
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

    mutating func normalize() {
        displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        urlString = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        mountPath = Self.normalizedMountPath(mountPath, displayName: displayName, urlString: urlString)
        wakeOnLAN.normalize()
        rules.normalize()
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

    static func checkKeychainHasCredentials(for host: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: host,
            kSecAttrProtocol as String: kSecAttrProtocolSMB,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }

    static func syncKeychainCredentials(fromHost: String, toHost: String) {
        guard !fromHost.isEmpty, !toHost.isEmpty, fromHost != toHost else { return }
        
        // If the destination host already has credentials, do nothing
        if checkKeychainHasCredentials(for: toHost) {
            return
        }
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: fromHost,
            kSecAttrProtocol as String: kSecAttrProtocolSMB,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let dict = result as? [String: Any],
              let account = dict[kSecAttrAccount as String] as? String,
              let passwordData = dict[kSecValueData as String] as? Data
        else {
            return
        }
        
        let newQuery: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: toHost,
            kSecAttrProtocol as String: kSecAttrProtocolSMB,
            kSecAttrAccount as String: account,
            kSecValueData as String: passwordData,
            kSecAttrLabel as String: "Otter: \(toHost)",
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        
        _ = SecItemAdd(newQuery as CFDictionary, nil)
    }

    static func resolveIPAddress(for hostname: String) async -> String? {
        await Task.detached(priority: .utility) { () -> String? in
            var res: UnsafeMutablePointer<addrinfo>?
            let status = getaddrinfo(hostname, nil, nil, &res)
            guard status == 0, let first = res else { return nil }
            defer { freeaddrinfo(res) }

            var hostnameBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let nameInfoStatus = getnameinfo(
                first.pointee.ai_addr,
                first.pointee.ai_addrlen,
                &hostnameBuffer,
                socklen_t(hostnameBuffer.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard nameInfoStatus == 0 else { return nil }
            return String(cString: hostnameBuffer)
        }.value
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
    var wifiNetworkAction: ShareRuleAction
    var vpnRuleEnabled: Bool
    var vpnName: String
    var vpnAction: ShareRuleAction

    init(
        wifiNetworkName: String = "",
        wifiNetworkAction: ShareRuleAction = .connect,
        vpnRuleEnabled: Bool = false,
        vpnName: String = "",
        vpnAction: ShareRuleAction = .connect
    ) {
        self.wifiNetworkName = wifiNetworkName
        self.wifiNetworkAction = wifiNetworkAction
        self.vpnRuleEnabled = vpnRuleEnabled
        self.vpnName = vpnName
        self.vpnAction = vpnAction
        normalize()
    }

    private enum CodingKeys: String, CodingKey {
        case wifiNetworkName
        case wifiNetworkAction
        case vpnRuleEnabled
        case vpnName
        case vpnAction
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        wifiNetworkName = try container.decodeIfPresent(String.self, forKey: .wifiNetworkName) ?? ""
        wifiNetworkAction = try container.decodeIfPresent(ShareRuleAction.self, forKey: .wifiNetworkAction) ?? .connect
        vpnRuleEnabled = try container.decodeIfPresent(Bool.self, forKey: .vpnRuleEnabled) ?? false
        vpnName = try container.decodeIfPresent(String.self, forKey: .vpnName) ?? ""
        vpnAction = try container.decodeIfPresent(ShareRuleAction.self, forKey: .vpnAction) ?? .connect
        normalize()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(wifiNetworkName, forKey: .wifiNetworkName)
        try container.encode(wifiNetworkAction, forKey: .wifiNetworkAction)
        try container.encode(vpnRuleEnabled, forKey: .vpnRuleEnabled)
        try container.encode(vpnName, forKey: .vpnName)
        try container.encode(vpnAction, forKey: .vpnAction)
    }

    var hasWiFiNetworkRule: Bool {
        requiredWiFiNetworkName != nil
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

    var vpnRuleTitle: String {
        requiredVPNName ?? "Any VPN"
    }

    mutating func normalize() {
        wifiNetworkName = wifiNetworkName.trimmingCharacters(in: .whitespacesAndNewlines)
        vpnName = vpnName.trimmingCharacters(in: .whitespacesAndNewlines)
        wifiNetworkAction = .connect
        vpnAction = .connect
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
        activeVPNNames: [String]
    ) -> ShareRuleEvaluation {
        if let requiredWiFiNetworkName {
            let currentNetworkName = currentWiFiNetworkName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let isHomeWiFi = currentNetworkName?.localizedCaseInsensitiveCompare(requiredWiFiNetworkName) == .orderedSame
            let isEthernet = currentNetworkName == nil && !isVPNConnected
            
            let isVPNActive: Bool
            if vpnRuleEnabled {
                if let requiredVPNName = requiredVPNName {
                    isVPNActive = activeVPNNames.contains { activeVPNName in
                        activeVPNName.localizedCaseInsensitiveCompare(requiredVPNName) == .orderedSame
                    }
                } else {
                    isVPNActive = isVPNConnected
                }
            } else {
                isVPNActive = isVPNConnected
            }

            let matches = isHomeWiFi || isEthernet || isVPNActive

            if !matches {
                let vpnSuffix = vpnRuleEnabled && !vpnName.isEmpty ? " \(vpnName)" : ""
                return ShareRuleEvaluation(
                    allowsConnection: false,
                    blockedStatus: .waitingForAllowedNetwork("Home network or VPN\(vpnSuffix)"),
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
            let matches: Bool
            if let requiredVPNName {
                matches = activeVPNNames.contains { activeVPNName in
                    activeVPNName.localizedCaseInsensitiveCompare(requiredVPNName) == .orderedSame
                }
            } else {
                matches = isVPNConnected
            }

            if !matches {
                let requirement = requiredVPNName.map { "VPN \($0)" } ?? "a VPN"
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

        return .noRules
    }
}

enum ShareRuleAction: String, Codable, CaseIterable, Hashable, Identifiable {
    case connect
    case disconnect

    var id: String { rawValue }

    var title: String {
        switch self {
        case .connect:
            "Connect"
        case .disconnect:
            "Disconnect"
        }
    }
}
