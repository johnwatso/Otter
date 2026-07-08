import Foundation

struct NetworkShare: Identifiable, Codable, Hashable {
    var id: UUID
    var displayName: String
    var urlString: String
    var mountPath: String
    var keepMounted: Bool
    var mountAtLaunch: Bool
    var rules: ShareRules
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        displayName: String,
        urlString: String,
        mountPath: String,
        keepMounted: Bool = true,
        mountAtLaunch: Bool = true,
        rules: ShareRules = ShareRules(),
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.urlString = urlString
        self.mountPath = mountPath
        self.keepMounted = keepMounted
        self.mountAtLaunch = mountAtLaunch
        self.rules = rules
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
        case rules
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
        rules = try container.decodeIfPresent(ShareRules.self, forKey: .rules) ?? ShareRules()
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

typealias ShareWiFiNetworkAction = ShareRuleAction
