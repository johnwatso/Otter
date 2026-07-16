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
        guard let host = URL(string: urlString)?.host(percentEncoded: false) else { return false }
        let suggestionIdentity = Self.normalizedServerIdentity(host)
        return suggestionIdentity == Self.normalizedServerIdentity(server.hostName)
            || suggestionIdentity == Self.normalizedServerIdentity(server.name)
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
            "Connected to \u{201c}\(name)\u{201d}."
        case let .differentVPN(required, active):
            "Otter detected \u{201c}\(active.joined(separator: ", "))\u{201d}, not \u{201c}\(required)\u{201d}."
        case let .unidentifiedTunnel(name):
            "A VPN tunnel is active, but macOS did not identify it as \u{201c}\(name)\u{201d}."
        case let .disconnected(name):
            "Connect to \u{201c}\(name)\u{201d}, then verify again."
        }
    }

    var isVerified: Bool {
        if case .connected = self { return true }
        return false
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
    var keepMounted: Bool
    var mountAtLaunch: Bool
    var cachedIPAddress: String?
    var ipAddressChangeObservations: [IPAddressChangeObservation]
    var autoConnectWhenReachable: Bool
    var pauseState: PauseState
    var wakeOnLANEnabled: Bool
    var wakeOnLANMACAddress: String
    var wakeOnLANBroadcastAddress: String
    var wakeOnLANPort: Int
    var limitsToRegisteredNetwork: Bool
    var wifiNetworkName: String
    var registeredSubnets: [String]
    var usesVPNRule: Bool
    var vpnName: String
    var createdAt: Date?

    init(share: NetworkShare?) {
        id = share?.id
        displayName = share?.displayName ?? ""
        urlString = share?.urlString ?? ""
        mountPath = share?.mountPath ?? ""
        keepMounted = share?.keepMounted ?? true
        mountAtLaunch = share?.mountAtLaunch ?? true
        cachedIPAddress = share?.cachedIPAddress
        ipAddressChangeObservations = share?.ipAddressChangeObservations ?? []
        autoConnectWhenReachable = share?.autoConnectWhenReachable ?? false
        pauseState = share?.pauseState ?? .inactive
        wakeOnLANEnabled = share?.wakeOnLAN.isEnabled ?? false
        wakeOnLANMACAddress = share?.wakeOnLAN.macAddress ?? ""
        wakeOnLANBroadcastAddress = share?.wakeOnLAN.broadcastAddress ?? WakeOnLANConfiguration.defaultBroadcastAddress
        wakeOnLANPort = share?.wakeOnLAN.port ?? WakeOnLANConfiguration.defaultPort
        limitsToRegisteredNetwork = share?.rules.hasNetworkRule ?? false
        wifiNetworkName = share?.rules.wifiNetworkName ?? ""
        registeredSubnets = share?.rules.registeredSubnets ?? []
        // An enabled rule with no name is the retired "arbitrary VPN" format.
        // Present it as off so editing and saving an older share removes that
        // rule instead of trapping the user behind an unselectable validation.
        usesVPNRule = share?.rules.requiredVPNName != nil
        vpnName = share?.rules.vpnName ?? ""
        createdAt = share?.createdAt
    }

    var rules: ShareRules {
        ShareRules(
            wifiNetworkName: limitsToRegisteredNetwork ? wifiNetworkName : "",
            registeredSubnets: limitsToRegisteredNetwork ? registeredSubnets : [],
            vpnRuleEnabled: usesVPNRule,
            vpnName: usesVPNRule ? vpnName : ""
        )
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
