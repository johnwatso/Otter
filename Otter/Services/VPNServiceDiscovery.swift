import AppKit
import Foundation
import SystemConfiguration

struct SystemVPNService: Equatable, Sendable {
    let name: String
    let id: String
}

struct VPNConnectionIdentity: Equatable, Sendable {
    let activeNames: [String]
    let isConnected: Bool
    let hasUnidentifiedTunnel: Bool

    init(
        hasActiveTunnel: Bool,
        identifiedNames: Set<String>,
        hasIdentifiedProfile: Bool? = nil
    ) {
        activeNames = identifiedNames.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
        // A third-party Network Extension can expose a live tunnel interface
        // without exposing its profile name to Otter. The tunnel still counts
        // as connected; its name is descriptive rather than authoritative.
        isConnected = hasActiveTunnel || !activeNames.isEmpty
        let profileIsIdentified = hasIdentifiedProfile ?? !activeNames.isEmpty
        hasUnidentifiedTunnel = hasActiveTunnel && !profileIsIdentified
    }
}

enum VPNServiceDiscovery {
    // System Settings can display VPN configurations owned by another app's
    // Network Extension. Those configurations are visible here, but macOS does
    // not necessarily expose a connection handle that Otter can start.
    static func detectedVPNServices() -> [SystemVPNService] {
        guard let preferences = SCPreferencesCreate(nil, "Otter.NetworkDetails" as CFString, nil),
              let services = SCNetworkServiceCopyAll(preferences) as? [SCNetworkService]
        else {
            return []
        }

        return services.compactMap { service in
            guard let serviceName = SCNetworkServiceGetName(service) as String?,
                  !serviceName.isEmpty,
                  isVPNService(service, serviceName: serviceName),
                  let serviceID = SCNetworkServiceGetServiceID(service) as String?
            else {
                return nil
            }

            return SystemVPNService(name: serviceName, id: serviceID)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func controllableVPNServices() -> [SystemVPNService] {
        detectedVPNServices().filter { service in
            SCNetworkConnectionCreateWithServiceID(nil, service.id as CFString, nil, nil) != nil
        }
    }

    static func detectedVPNService(named serviceName: String) -> SystemVPNService? {
        detectedVPNServices().first {
            $0.name.localizedCaseInsensitiveCompare(serviceName) == .orderedSame
        }
    }

    // Personal VPNs configured in System Settings (IKEv2, L2TP, ...) report a live
    // connection status through SCNetworkConnection, which tells us exactly which
    // configured VPN is connected rather than inferring it from tunnel interfaces.
    static func connectedVPNServiceNames() -> Set<String> {
        guard let preferences = SCPreferencesCreate(nil, "Otter.NetworkDetails" as CFString, nil),
              let services = SCNetworkServiceCopyAll(preferences) as? [SCNetworkService]
        else {
            return []
        }

        var names = Set<String>()

        for service in services {
            guard let serviceName = SCNetworkServiceGetName(service) as String?,
                  !serviceName.isEmpty,
                  isVPNService(service, serviceName: serviceName),
                  let serviceID = SCNetworkServiceGetServiceID(service) as String?,
                  let connection = SCNetworkConnectionCreateWithServiceID(nil, serviceID as CFString, nil, nil),
                  SCNetworkConnectionGetStatus(connection) == .connected
            else {
                continue
            }

            names.insert(serviceName)
        }

        return names
    }

    private static let vpnAppBundleIDPrefixes: [(prefix: String, name: String)] = [
        ("com.tailscale", "Tailscale"),
        ("io.tailscale", "Tailscale"),
        ("com.wireguard", "WireGuard"),
        ("com.nordvpn", "NordVPN"),
        ("com.nordsec", "NordVPN"),
        ("net.mullvad", "Mullvad VPN"),
        ("ch.protonvpn", "Proton VPN"),
        ("com.protonvpn", "Proton VPN"),
        ("com.expressvpn", "ExpressVPN"),
        ("com.privateinternetaccess", "Private Internet Access"),
        ("com.surfshark", "Surfshark"),
        ("com.windscribe", "Windscribe"),
        ("com.cloudflare", "Cloudflare WARP"),
        ("com.cisco.anyconnect", "Cisco AnyConnect"),
        ("com.cisco.secureclient", "Cisco Secure Client"),
        ("com.paloaltonetworks", "GlobalProtect"),
        ("com.fortinet", "FortiClient"),
        ("com.zscaler", "Zscaler"),
        ("net.openvpn", "OpenVPN Connect"),
        ("com.viscosityvpn", "Viscosity"),
        ("net.tunnelblick", "Tunnelblick")
    ]

    static func runningVPNAppNames() -> Set<String> {
        var names = Set<String>()

        for application in NSWorkspace.shared.runningApplications {
            guard let bundleID = application.bundleIdentifier?.lowercased() else { continue }

            for entry in vpnAppBundleIDPrefixes where bundleID.hasPrefix(entry.prefix) {
                names.insert(entry.name)
            }
        }

        return names
    }

    static func readKnownVPNNames() -> [String] {
        detectedVPNServices().map(\.name)
    }

    static func readControllableVPNNames() -> [String] {
        controllableVPNServices().map(\.name)
    }

    private static func isVPNService(_ service: SCNetworkService, serviceName: String) -> Bool {
        if serviceNameContainsVPNMarker(serviceName) {
            return true
        }

        guard let interface = SCNetworkServiceGetInterface(service) else {
            return false
        }

        return isVPNInterface(interface)
    }

    private static func isVPNInterface(_ interface: SCNetworkInterface) -> Bool {
        let interfaceValues = [
            SCNetworkInterfaceGetInterfaceType(interface) as String?,
            SCNetworkInterfaceGetBSDName(interface) as String?
        ]
        .compactMap { $0?.lowercased() }

        let vpnMarkers = [
            "vpn",
            "ppp",
            "ipsec",
            "l2tp",
            "pptp",
            "ikev2"
        ]

        return interfaceValues.contains { value in
            vpnMarkers.contains { value.contains($0) }
        }
    }

    private static func serviceNameContainsVPNMarker(_ serviceName: String) -> Bool {
        let normalizedName = serviceName.lowercased()
        let vpnMarkers = ["vpn", "wireguard", "tailscale", "zerotier", "openvpn", "nord", "mullvad"]
        return vpnMarkers.contains { normalizedName.contains($0) }
    }

    static func vpnServiceNames(for interfaceNames: [String]) -> [String] {
        guard !interfaceNames.isEmpty else { return [] }

        guard let store = SCDynamicStoreCreate(nil, "Otter.NetworkDetails" as CFString, nil, nil),
              let keys = SCDynamicStoreCopyKeyList(store, "State:/Network/Service/.*/IPv[46]" as CFString) as? [String]
        else {
            return []
        }

        let interfaceNameSet = Set(interfaceNames)
        var serviceNames = Set<String>()

        for key in keys {
            guard let state = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any],
                  let interfaceName = state["InterfaceName"] as? String,
                  interfaceNameSet.contains(interfaceName),
                  let serviceID = serviceID(from: key),
                  let serviceName = serviceName(for: serviceID, store: store),
                  isActiveVPNService(serviceID: serviceID, serviceName: serviceName, store: store)
            else {
                continue
            }

            serviceNames.insert(serviceName)
        }

        return Array(serviceNames).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private static func isActiveVPNService(serviceID: String, serviceName: String, store: SCDynamicStore) -> Bool {
        if serviceNameContainsVPNMarker(serviceName) {
            return true
        }

        let setupValues = setupValues(for: serviceID, store: store)
        let vpnMarkers = ["vpn", "ppp", "ipsec", "l2tp", "pptp", "ikev2", "wireguard", "tailscale", "zerotier", "openvpn"]

        return setupValues.contains { value in
            vpnMarkers.contains { value.contains($0) }
        }
    }

    static func sorted(_ names: Set<String>) -> [String] {
        names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private static func serviceID(from key: String) -> String? {
        let components = key.split(separator: "/")
        guard components.count >= 4,
              components[0] == "State:",
              components[1] == "Network",
              components[2] == "Service"
        else {
            return nil
        }

        return String(components[3])
    }

    private static func serviceName(for serviceID: String, store: SCDynamicStore) -> String? {
        let keys = [
            "Setup:/Network/Service/\(serviceID)",
            "Setup:/Network/Service/\(serviceID)/Interface"
        ]

        for key in keys {
            guard let setup = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any] else {
                continue
            }

            if let name = setup["UserDefinedName"] as? String, !name.isEmpty {
                return name
            }

            if let name = setup["DeviceName"] as? String, !name.isEmpty {
                return name
            }
        }

        return nil
    }

    private static func setupValues(for serviceID: String, store: SCDynamicStore) -> [String] {
        let keys = [
            "Setup:/Network/Service/\(serviceID)",
            "Setup:/Network/Service/\(serviceID)/Interface",
            "Setup:/Network/Service/\(serviceID)/PPP",
            "Setup:/Network/Service/\(serviceID)/IPSec"
        ]

        return keys.flatMap { key -> [String] in
            guard let setup = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any] else {
                return []
            }

            return setup.values.compactMap { value in
                if let value = value as? String {
                    return value.lowercased()
                }

                return nil
            }
        }
    }
}

enum SystemVPNConnectionError: LocalizedError, Equatable, Sendable {
    case serviceNotFound(String)
    case notControllable(String)
    case connectionUnavailable(String)
    case startFailed(String, String)
    case disconnected(String)
    case timedOut(String)

    var errorDescription: String? {
        switch self {
        case let .serviceNotFound(name):
            return "VPN \(quoted(name)) is not available in System Settings."
        case let .notControllable(name):
            return "macOS does not allow Otter to start VPN \(quoted(name)). It may be managed by another VPN app. Connect it manually or choose a VPN Otter can control."
        case let .connectionUnavailable(name):
            return "macOS could not open VPN \(quoted(name))."
        case let .startFailed(name, detail):
            return "macOS could not start VPN \(quoted(name)): \(detail)"
        case let .disconnected(name):
            return "VPN \(quoted(name)) disconnected before it finished connecting."
        case let .timedOut(name):
            return "VPN \(quoted(name)) did not connect within 30 seconds."
        }
    }

    private func quoted(_ value: String) -> String {
        "“\(value)”"
    }
}

// Controls only VPN services macOS exposes through SystemConfiguration. This
// deliberately excludes app-only tunnels, where launching an app would not
// reliably identify or connect the user's intended VPN profile.
final class SystemVPNConnectionService: VPNConnecting, @unchecked Sendable {
    private let queue = DispatchQueue(label: "Otter.SystemVPNConnection", qos: .utility)

    func connect(named serviceName: String, timeout: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    try Self.connectSynchronously(named: serviceName, timeout: timeout)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func connectSynchronously(named serviceName: String, timeout: TimeInterval) throws {
        guard let service = VPNServiceDiscovery.detectedVPNService(named: serviceName) else {
            throw SystemVPNConnectionError.serviceNotFound(serviceName)
        }

        guard let connection = SCNetworkConnectionCreateWithServiceID(
            nil,
            service.id as CFString,
            nil,
            nil
        ) else {
            throw SystemVPNConnectionError.notControllable(service.name)
        }

        var status = SCNetworkConnectionGetStatus(connection)
        if status == .connected {
            return
        }

        if status == .disconnected {
            guard SCNetworkConnectionStart(connection, nil, true) else {
                let code = SCError()
                let detail = String(cString: SCErrorString(code))
                throw SystemVPNConnectionError.startFailed(service.name, detail)
            }
        }

        let deadline = Date().addingTimeInterval(timeout)
        var observedConnectionAttempt = status == .connecting

        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
            status = SCNetworkConnectionGetStatus(connection)

            switch status {
            case .connected:
                return
            case .connecting, .disconnecting:
                observedConnectionAttempt = true
            case .disconnected where observedConnectionAttempt:
                throw SystemVPNConnectionError.disconnected(service.name)
            case .invalid:
                throw SystemVPNConnectionError.connectionUnavailable(service.name)
            case .disconnected:
                break
            @unknown default:
                break
            }
        }

        throw SystemVPNConnectionError.timedOut(service.name)
    }
}
