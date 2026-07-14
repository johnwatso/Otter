import Foundation

struct MountedShareSuggestion: Identifiable, Hashable {
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
    case any
    case known(String)
    case custom
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
    var autoConnectWhenReachable: Bool
    var wakeOnLANEnabled: Bool
    var wakeOnLANMACAddress: String
    var wakeOnLANBroadcastAddress: String
    var wakeOnLANPort: Int
    var limitsToRegisteredNetwork: Bool
    var wifiNetworkName: String
    var registeredSubnets: [String]
    var matchesAnyVPN: Bool
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
        autoConnectWhenReachable = share?.autoConnectWhenReachable ?? false
        wakeOnLANEnabled = share?.wakeOnLAN.isEnabled ?? false
        wakeOnLANMACAddress = share?.wakeOnLAN.macAddress ?? ""
        wakeOnLANBroadcastAddress = share?.wakeOnLAN.broadcastAddress ?? WakeOnLANConfiguration.defaultBroadcastAddress
        wakeOnLANPort = share?.wakeOnLAN.port ?? WakeOnLANConfiguration.defaultPort
        // A share may carry a network rule, a VPN rule, or both; the editor
        // presents them as a single "registered network" condition.
        limitsToRegisteredNetwork = (share?.rules.hasNetworkRule ?? false) || (share?.rules.hasVPNRule ?? false)
        wifiNetworkName = share?.rules.wifiNetworkName ?? ""
        registeredSubnets = share?.rules.registeredSubnets ?? []
        matchesAnyVPN = share?.rules.requiredVPNName == nil
        vpnName = share?.rules.vpnName ?? ""
        createdAt = share?.createdAt
    }

    var rules: ShareRules {
        ShareRules(
            wifiNetworkName: limitsToRegisteredNetwork ? wifiNetworkName : "",
            registeredSubnets: limitsToRegisteredNetwork ? registeredSubnets : [],
            vpnRuleEnabled: limitsToRegisteredNetwork,
            vpnName: limitsToRegisteredNetwork && !matchesAnyVPN ? vpnName : ""
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
