import Foundation

struct MountedShareSuggestion: Identifiable, Hashable, Sendable {
    var id: String { mountPath }

    let displayName: String
    let urlString: String
    let mountPath: String

    static func discover() -> [MountedShareSuggestion] {
        let fileManager = FileManager.default
        let keys = resourceKeys

        guard let volumeURLs = fileManager.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys), options: []) else {
            return []
        }

        return volumeURLs
            .compactMap { try? make(from: $0) }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    static func make(from selectedURL: URL) throws -> MountedShareSuggestion {
        let values = try selectedURL.resourceValues(forKeys: resourceKeys)
        let volumeURL = values.volume ?? selectedURL
        let volumeValues = try volumeURL.resourceValues(forKeys: resourceKeys)
        let remountURL = values.volumeURLForRemounting ?? volumeValues.volumeURLForRemounting

        guard let remountURL else {
            throw MountedShareSuggestionError.notNetworkShare
        }

        guard let urlString = sanitizedSMBURLString(from: remountURL) else {
            throw MountedShareSuggestionError.notSMBShare
        }

        let displayName = values.volumeLocalizedName
            ?? volumeValues.volumeLocalizedName
            ?? values.volumeName
            ?? volumeValues.volumeName
            ?? volumeURL.lastPathComponent

        return MountedShareSuggestion(
            displayName: displayName,
            urlString: urlString,
            mountPath: volumeURL.standardizedFileURL.resolvingSymlinksInPath().path
        )
    }

    func matches(server: DiscoveredSMBServer) -> Bool {
        matches(host: server.hostName) || matches(host: server.name)
    }

    func matches(host: String) -> Bool {
        guard let suggestionHost = URL(string: urlString)?.host(percentEncoded: false) else { return false }
        return Self.normalizedServerIdentity(suggestionHost) == Self.normalizedServerIdentity(host)
    }

    func isSameShare(as other: MountedShareSuggestion) -> Bool {
        if let location = NetworkShareLocation(url: URL(string: urlString)),
           let otherLocation = NetworkShareLocation(url: URL(string: other.urlString)),
           location == otherLocation {
            return true
        }

        return Self.normalizedMountPath(mountPath) == Self.normalizedMountPath(other.mountPath)
    }

    static func finderImportCandidates(
        in suggestions: [MountedShareSuggestion],
        for server: DiscoveredSMBServer,
        excludingMountPaths existingMountPaths: Set<String>
    ) -> [MountedShareSuggestion] {
        let matchingServerShares = suggestions.filter { $0.matches(server: server) }
        if !matchingServerShares.isEmpty {
            return matchingServerShares
        }

        let newlyMountedShares = suggestions.filter {
            !existingMountPaths.contains($0.mountPath)
        }
        // If the mount advertises an unexpected alias, accept it only when the
        // Finder round-trip produced one unambiguous new SMB volume.
        return newlyMountedShares.count == 1 ? newlyMountedShares : []
    }

    private static func normalizedServerIdentity(_ value: String) -> String {
        var normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()

        if let serviceMarker = normalized.range(of: "._smb._tcp.") {
            normalized = String(normalized[..<serviceMarker.lowerBound])
        } else if normalized.hasSuffix(".local") {
            normalized.removeLast(".local".count)
        }
        return normalized
    }

    private static func normalizedMountPath(_ path: String) -> String {
        URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }

    private static var resourceKeys: Set<URLResourceKey> {
        [
            .volumeURLKey,
            .volumeURLForRemountingKey,
            .volumeLocalizedNameKey,
            .volumeNameKey
        ]
    }

    private static func sanitizedSMBURLString(from url: URL) -> String? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "smb",
              components.host?.isEmpty == false,
              !components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty
        else {
            return nil
        }

        components.scheme = "smb"
        components.user = nil
        components.password = nil
        return components.string
    }
}

/// Identifies the control a validation failure belongs to, so the editor can
/// reveal, scroll to, and annotate that control instead of reporting the
/// problem far away from its cause.
enum ValidationField: Hashable {
    case shareName
    case address
    case vpn
    case wakeOnLAN
}

struct ValidationIssue: Equatable {
    let field: ValidationField
    let message: String
}

enum VPNNameSelection: Hashable {
    case unconfigured
    case known(String)
    case custom
}

enum VPNVerificationResult: Equatable {
    case connected(String)
    case differentVPN(required: String, active: [String])
    case unidentifiedTunnel(String)
    case disconnected(String)

    var message: String {
        switch self {
        case let .connected(name):
            "A VPN connection is active (\u{201c}\(name)\u{201d}). Otter will check the server."
        case let .differentVPN(_, active):
            "A VPN connection is active (\u{201c}\(active.joined(separator: ", "))\u{201d}). Otter will check the server."
        case .unidentifiedTunnel:
            "A VPN tunnel is active. Otter will check the server."
        case let .disconnected(name):
            "Connect to \u{201c}\(name)\u{201d}, then verify again."
        }
    }

    var isVerified: Bool {
        switch self {
        case .connected, .differentVPN, .unidentifiedTunnel:
            true
        case .disconnected:
            false
        }
    }
}

private enum MountedShareSuggestionError: LocalizedError {
    case notNetworkShare
    case notSMBShare

    var errorDescription: String? {
        switch self {
        case .notNetworkShare:
            "Choose a mounted network share."
        case .notSMBShare:
            "Choose a mounted SMB share."
        }
    }
}

struct DraftShare {
    var id: UUID?
    var displayName: String
    var urlString: String
    var mountPath: String
    var connectionMode: ConnectionMode
    var prefersIPv4: Bool
    var cachedIPAddresses: [String]
    var ipAddressChangeObservations: [IPAddressChangeObservation]
    var pauseState: PauseState
    var wakeOnLANEnabled: Bool
    var wakeOnLANMACAddress: String
    var wakeOnLANBroadcastAddress: String
    var wakeOnLANPort: Int
    var usesVPNRule: Bool
    var vpnName: String
    var connectVPNAutomatically: Bool
    var healthCheck: ShareHealthCheckConfiguration
    var createdAt: Date?

    init(share: NetworkShare?) {
        id = share?.id
        displayName = share?.displayName ?? ""
        urlString = share?.urlString ?? ""
        mountPath = share?.mountPath ?? ""
        connectionMode = share?.connectionMode ?? .keepConnected
        prefersIPv4 = share?.prefersIPv4 ?? true
        cachedIPAddresses = share?.cachedIPAddresses ?? []
        ipAddressChangeObservations = share?.ipAddressChangeObservations ?? []
        pauseState = share?.pauseState ?? .inactive
        wakeOnLANEnabled = share?.wakeOnLAN.isEnabled ?? false
        wakeOnLANMACAddress = share?.wakeOnLAN.macAddress ?? ""
        wakeOnLANBroadcastAddress = share?.wakeOnLAN.broadcastAddress ?? WakeOnLANConfiguration.defaultBroadcastAddress
        wakeOnLANPort = share?.wakeOnLAN.port ?? WakeOnLANConfiguration.defaultPort
        // An enabled rule with no name is the retired "arbitrary VPN" format.
        // Present it as off so editing and saving an older share removes that
        // rule instead of trapping the user behind an unselectable validation.
        usesVPNRule = share?.rules.requiredVPNName != nil
        vpnName = share?.rules.vpnName ?? ""
        connectVPNAutomatically = share?.rules.connectVPNAutomatically ?? true
        healthCheck = share?.healthCheck ?? ShareHealthCheckConfiguration()
        createdAt = share?.createdAt
    }

    var orderedCachedIPAddresses: [String] {
        let preferred = cachedIPAddresses.filter {
            prefersIPv4 ? NetworkShare.isIPv4Address($0) : NetworkShare.isIPv6Address($0)
        }
        let alternate = cachedIPAddresses.filter {
            prefersIPv4 ? NetworkShare.isIPv6Address($0) : NetworkShare.isIPv4Address($0)
        }
        return preferred + alternate
    }

    /// Remote access settings are kept on the share whatever the mode, so
    /// switching to Keep Connected — which hides them — never discards a VPN
    /// the user may want again in Adaptive or Manual.
    var rules: ShareRules {
        ShareRules(
            wifiNetworkName: "",
            registeredSubnets: [],
            vpnRuleEnabled: usesVPNRule,
            vpnName: usesVPNRule ? vpnName : "",
            connectVPNAutomatically: usesVPNRule && connectVPNAutomatically
        )
    }

    var showsRemoteAccess: Bool {
        connectionMode.usesRemoteAccess
    }

    var wakeOnLAN: WakeOnLANConfiguration {
        WakeOnLANConfiguration(
            isEnabled: wakeOnLANEnabled,
            macAddress: wakeOnLANMACAddress,
            broadcastAddress: wakeOnLANBroadcastAddress,
            port: wakeOnLANPort
        )
    }

}
