import Darwin
import Foundation

enum NetworkShareProtocol: String, Codable, CaseIterable, Hashable {
    case smb
    case nfs
    case webdav

    init?(urlScheme: String?) {
        switch urlScheme?.lowercased() {
        case "smb": self = .smb
        case "nfs": self = .nfs
        case "http", "https", "webdav", "webdavs": self = .webdav
        default: return nil
        }
    }

    var title: String {
        switch self {
        case .smb: "SMB"
        case .nfs: "NFS"
        case .webdav: "WebDAV"
        }
    }

    var exampleURL: String {
        switch self {
        case .smb: "smb://server.local/Share"
        case .nfs: "nfs://server.local/export"
        case .webdav: "https://server.example.com/dav"
        }
    }
}

/// How Otter is expected to keep a share connected.
///
/// The mode is the single source of truth for automatic mounting. Remote
/// access (VPN) configuration stays saved on every share, but only applies to
/// the modes that are location aware — see `usesRemoteAccess`.
enum ConnectionMode: String, Codable, CaseIterable, Hashable, Sendable {
    /// Persistent and directly reachable: the server is expected to answer on
    /// the current network, so Otter mounts, monitors and restores the share.
    case keepConnected
    /// Persistent and location aware: Otter connects over the local network
    /// when it can, and brings up the configured VPN when it cannot.
    case adaptive
    /// User initiated and location aware: Otter connects only when asked,
    /// starting the configured VPN first if the share needs it.
    case manual
    /// Automatic but not persistent: one attempt at launch, then Otter leaves
    /// the share alone.
    case connectOnce

    var title: String {
        switch self {
        case .keepConnected: "Keep Connected"
        case .adaptive: "Adaptive"
        case .manual: "Manual"
        case .connectOnce: "Connect Once"
        }
    }

    var detail: String {
        switch self {
        case .keepConnected: "Always keep this share mounted."
        case .adaptive: "Keep this share connected using the local network or VPN."
        case .manual: "Connect only when requested."
        case .connectOnce: "Connect automatically once, but don’t reconnect if it drops."
        }
    }

    /// Whether the share's VPN configuration participates in connecting it.
    /// Keep Connected is deliberately not location aware, so its saved remote
    /// access settings are preserved but inert.
    var usesRemoteAccess: Bool {
        self != .keepConnected
    }

    /// Whether Otter re-mounts the share whenever it is not connected.
    var maintainsConnection: Bool {
        switch self {
        case .keepConnected, .adaptive: true
        case .manual, .connectOnce: false
        }
    }

    /// Whether Otter mounts the share on its own at launch/login.
    var connectsAutomatically: Bool {
        self != .manual
    }

    /// Whether Otter should keep retrying, and complain, when the share is not
    /// available. Modes that do not maintain the connection stay quiet unless
    /// the attempt was explicitly requested.
    var reportsUnexpectedProblems: Bool {
        maintainsConnection
    }
}

struct ShareHealthCheckConfiguration: Codable, Hashable {
    var isEnabled: Bool
    var requiresWritableVolume: Bool
    var sentinelRelativePath: String

    init(
        isEnabled: Bool = true,
        requiresWritableVolume: Bool = false,
        sentinelRelativePath: String = ""
    ) {
        self.isEnabled = isEnabled
        self.requiresWritableVolume = requiresWritableVolume
        self.sentinelRelativePath = sentinelRelativePath
        normalize()
    }

    mutating func normalize() {
        sentinelRelativePath = sentinelRelativePath
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        // A sentinel must stay inside the mounted volume; never let a health
        // check turn into an arbitrary filesystem probe.
        if sentinelRelativePath.split(separator: "/").contains("..") {
            sentinelRelativePath = ""
        }
    }

    var hasCustomChecks: Bool {
        requiresWritableVolume || !sentinelRelativePath.isEmpty
    }
}

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
    /// Where the share is actually mounted right now. Observed, not chosen —
    /// `ShareMonitor` keeps it in step with reality.
    var mountPath: String
    var connectionMode: ConnectionMode
    var pauseState: PauseState
    var wakeOnLAN: WakeOnLANConfiguration
    var rules: ShareRules
    var healthCheck: ShareHealthCheckConfiguration
    var prefersIPv4: Bool
    var cachedIPAddresses: [String]
    var ipAddressChangeObservations: [IPAddressChangeObservation]
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        displayName: String,
        urlString: String,
        mountPath: String,
        connectionMode: ConnectionMode = .keepConnected,
        pauseState: PauseState = .inactive,
        wakeOnLAN: WakeOnLANConfiguration = WakeOnLANConfiguration(),
        rules: ShareRules = ShareRules(),
        healthCheck: ShareHealthCheckConfiguration = ShareHealthCheckConfiguration(),
        prefersIPv4: Bool = true,
        cachedIPAddresses: [String] = [],
        cachedIPAddress: String? = nil,
        ipAddressChangeObservations: [IPAddressChangeObservation] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.urlString = urlString
        self.mountPath = mountPath
        self.connectionMode = connectionMode
        self.pauseState = pauseState
        self.wakeOnLAN = wakeOnLAN
        self.rules = rules
        self.healthCheck = healthCheck
        self.prefersIPv4 = prefersIPv4
        self.cachedIPAddresses = cachedIPAddresses
        if let cachedIPAddress, !self.cachedIPAddresses.contains(cachedIPAddress) {
            self.cachedIPAddresses.append(cachedIPAddress)
        }
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
        case connectionMode
        // Retained for migration from — and downgrades to — releases that
        // described the connection mode with three independent switches.
        case keepMounted
        case mountAtLaunch
        case autoConnectWhenReachable
        case pauseState
        case wakeOnLAN
        case rules
        case healthCheck
        case prefersIPv4
        case cachedIPAddresses
        // Kept for migration from releases that stored one fallback address.
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
        pauseState = try container.decodeIfPresent(PauseState.self, forKey: .pauseState) ?? .inactive
        wakeOnLAN = try container.decodeIfPresent(WakeOnLANConfiguration.self, forKey: .wakeOnLAN) ?? WakeOnLANConfiguration()
        rules = try container.decodeIfPresent(ShareRules.self, forKey: .rules) ?? ShareRules()
        if let storedMode = try container.decodeIfPresent(ConnectionMode.self, forKey: .connectionMode) {
            connectionMode = storedMode
        } else {
            connectionMode = Self.migratedConnectionMode(
                keepMounted: try container.decodeIfPresent(Bool.self, forKey: .keepMounted) ?? true,
                mountAtLaunch: try container.decodeIfPresent(Bool.self, forKey: .mountAtLaunch) ?? true,
                autoConnectWhenReachable: try container.decodeIfPresent(Bool.self, forKey: .autoConnectWhenReachable) ?? false,
                rules: rules
            )
        }
        healthCheck = try container.decodeIfPresent(ShareHealthCheckConfiguration.self, forKey: .healthCheck) ?? ShareHealthCheckConfiguration()
        prefersIPv4 = try container.decodeIfPresent(Bool.self, forKey: .prefersIPv4) ?? true
        cachedIPAddresses = try container.decodeIfPresent([String].self, forKey: .cachedIPAddresses) ?? []
        if cachedIPAddresses.isEmpty,
           let legacyAddress = try container.decodeIfPresent(String.self, forKey: .cachedIPAddress) {
            cachedIPAddresses = [legacyAddress]
        }
        ipAddressChangeObservations = try container.decodeIfPresent(
            [IPAddressChangeObservation].self,
            forKey: .ipAddressChangeObservations
        ) ?? []
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        normalize()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(urlString, forKey: .urlString)
        try container.encode(mountPath, forKey: .mountPath)
        try container.encode(connectionMode, forKey: .connectionMode)
        // Older builds read these three switches. Writing the equivalent values
        // keeps a downgrade — or a configuration file shared with a Mac that
        // has not updated yet — behaving the same way.
        try container.encode(connectionMode.maintainsConnection, forKey: .keepMounted)
        try container.encode(connectionMode.connectsAutomatically, forKey: .mountAtLaunch)
        try container.encode(connectionMode == .adaptive, forKey: .autoConnectWhenReachable)
        try container.encode(pauseState, forKey: .pauseState)
        try container.encode(wakeOnLAN, forKey: .wakeOnLAN)
        try container.encode(rules, forKey: .rules)
        try container.encode(healthCheck, forKey: .healthCheck)
        try container.encode(prefersIPv4, forKey: .prefersIPv4)
        try container.encode(cachedIPAddresses, forKey: .cachedIPAddresses)
        try container.encode(ipAddressChangeObservations, forKey: .ipAddressChangeObservations)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }

    var url: URL? {
        URL(string: urlString)
    }

    /// Otter re-mounts this share whenever it is not connected.
    var maintainsConnection: Bool {
        connectionMode.maintainsConnection
    }

    /// Otter mounts this share on its own at launch.
    var connectsAutomatically: Bool {
        connectionMode.connectsAutomatically
    }

    /// The rules that actually gate a connection attempt. Keep Connected is not
    /// location aware, so its saved remote access configuration is preserved on
    /// the share but never evaluated — switching back to Adaptive or Manual
    /// restores it untouched.
    var activeRules: ShareRules {
        connectionMode.usesRemoteAccess ? rules : ShareRules()
    }

    /// Maps the pre-4-mode representation onto a connection mode. A share that
    /// was kept mounted while depending on a VPN or a registered network was
    /// already behaving adaptively, so it keeps that behavior rather than
    /// silently losing its route.
    static func migratedConnectionMode(
        keepMounted: Bool,
        mountAtLaunch: Bool,
        autoConnectWhenReachable: Bool,
        rules: ShareRules
    ) -> ConnectionMode {
        if keepMounted {
            return rules.hasVPNRule || rules.hasNetworkRule ? .adaptive : .keepConnected
        }
        if autoConnectWhenReachable {
            return .adaptive
        }
        return mountAtLaunch ? .connectOnce : .manual
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
        healthCheck.normalize()
        cachedIPAddresses = Self.uniqueValidIPAddresses(cachedIPAddresses)
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

    var connectionProtocol: NetworkShareProtocol? {
        url.flatMap { NetworkShareProtocol(urlScheme: $0.scheme) }
    }

    var orderedCachedIPAddresses: [String] {
        let preferredFamily = cachedIPAddresses.filter {
            prefersIPv4 ? Self.isIPv4Address($0) : Self.isIPv6Address($0)
        }
        let alternateFamily = cachedIPAddresses.filter {
            prefersIPv4 ? Self.isIPv6Address($0) : Self.isIPv4Address($0)
        }
        return preferredFamily + alternateFamily
    }

    // Source-compatible access for views and older call sites that only need
    // the first fallback. New connection code should try orderedCachedIPAddresses.
    var cachedIPAddress: String? {
        get { orderedCachedIPAddresses.first }
        set { cachedIPAddresses = newValue.map { [$0] } ?? [] }
    }

    mutating func recordResolvedIPAddress(
        _ address: String,
        observedAt date: Date = Date()
    ) -> CachedIPAddressUpdate {
        recordResolvedIPAddresses([address], observedAt: date)
    }

    mutating func recordResolvedIPAddresses(
        _ addresses: [String],
        observedAt date: Date = Date()
    ) -> CachedIPAddressUpdate {
        var normalizedAddresses = Self.uniqueValidIPAddresses(addresses)
        guard !normalizedAddresses.isEmpty else { return .ignored }

        let previousAddress = cachedIPAddress
        if let previousAddress,
           let previousIndex = normalizedAddresses.firstIndex(where: {
               $0.localizedCaseInsensitiveCompare(previousAddress) == .orderedSame
           }) {
            let retainedAddress = normalizedAddresses.remove(at: previousIndex)
            normalizedAddresses.insert(retainedAddress, at: 0)
        }
        cachedIPAddresses = normalizedAddresses

        guard let currentAddress = cachedIPAddress else { return .ignored }
        guard let previousAddress else { return .initial }
        guard previousAddress.localizedCaseInsensitiveCompare(currentAddress) != .orderedSame else {
            return .unchanged
        }

        ipAddressChangeObservations.append(
            IPAddressChangeObservation(
                previousAddress: previousAddress,
                currentAddress: currentAddress,
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
        isIPv4Address(host) || isIPv6Address(host)
    }

    static func isIPv4Address(_ host: String) -> Bool {
        var sin = in_addr()
        return host.withCString { inet_pton(AF_INET, $0, &sin) } == 1
    }

    static func isIPv6Address(_ host: String) -> Bool {
        var sin6 = in6_addr()
        let addressWithoutScope = host.split(separator: "%", maxSplits: 1).first.map(String.init) ?? host
        return addressWithoutScope.withCString { inet_pton(AF_INET6, $0, &sin6) } == 1
    }

    static func urlComponentsHost(forIPAddress address: String) -> String {
        isIPv6Address(address) ? "[\(address)]" : address
    }

    private static func uniqueValidIPAddresses(_ addresses: [String]) -> [String] {
        var seen = Set<String>()
        return addresses.compactMap { address in
            let normalized = address.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isIPAddress(normalized) else { return nil }
            let key = normalized.lowercased()
            guard seen.insert(key).inserted else { return nil }
            return normalized
        }
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

    var shareCountLabel: String {
        shares.count == 1 ? "1 share" : "\(shares.count) shares"
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
    var connectVPNAutomatically: Bool

    init(
        wifiNetworkName: String = "",
        registeredSubnets: [String] = [],
        vpnRuleEnabled: Bool = false,
        vpnName: String = "",
        connectVPNAutomatically: Bool = true
    ) {
        self.wifiNetworkName = wifiNetworkName
        self.registeredSubnets = registeredSubnets
        self.vpnRuleEnabled = vpnRuleEnabled
        self.vpnName = vpnName
        self.connectVPNAutomatically = connectVPNAutomatically
        normalize()
    }

    private enum CodingKeys: String, CodingKey {
        case wifiNetworkName
        case registeredSubnets
        case vpnRuleEnabled
        case vpnName
        case connectVPNAutomatically
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        wifiNetworkName = try container.decodeIfPresent(String.self, forKey: .wifiNetworkName) ?? ""
        registeredSubnets = try container.decodeIfPresent([String].self, forKey: .registeredSubnets) ?? []
        vpnRuleEnabled = try container.decodeIfPresent(Bool.self, forKey: .vpnRuleEnabled) ?? false
        vpnName = try container.decodeIfPresent(String.self, forKey: .vpnName) ?? ""
        // VPN rules created before this option existed always tried to start
        // the selected VPN. Preserve that behavior during migration.
        connectVPNAutomatically = try container.decodeIfPresent(
            Bool.self,
            forKey: .connectVPNAutomatically
        ) ?? vpnRuleEnabled
        normalize()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(wifiNetworkName, forKey: .wifiNetworkName)
        try container.encode(registeredSubnets, forKey: .registeredSubnets)
        try container.encode(vpnRuleEnabled, forKey: .vpnRuleEnabled)
        try container.encode(vpnName, forKey: .vpnName)
        try container.encode(connectVPNAutomatically, forKey: .connectVPNAutomatically)
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

    var shouldConnectVPNAutomatically: Bool {
        hasVPNRule && requiredVPNName != nil && connectVPNAutomatically
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
