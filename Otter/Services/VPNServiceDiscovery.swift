import AppKit
import Foundation
import SystemConfiguration

struct VPNConnectionIdentity: Equatable, Sendable {
    let activeNames: [String]
    let isConnected: Bool
    let hasUnidentifiedTunnel: Bool

    init(hasActiveTunnel: Bool, identifiedNames: Set<String>) {
        activeNames = identifiedNames.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
        isConnected = !activeNames.isEmpty
        hasUnidentifiedTunnel = hasActiveTunnel && activeNames.isEmpty
    }
}

enum VPNServiceDiscovery {
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

    static func readKnownVPNNames(including activeVPNNames: [String]) -> [String] {
        var names = Set(activeVPNNames)

        guard let preferences = SCPreferencesCreate(nil, "Otter.NetworkDetails" as CFString, nil),
              let services = SCNetworkServiceCopyAll(preferences) as? [SCNetworkService]
        else {
            return sorted(names)
        }

        for service in services {
            guard let serviceName = SCNetworkServiceGetName(service) as String?,
                  isVPNService(service, serviceName: serviceName),
                  !serviceName.isEmpty
            else {
                continue
            }

            names.insert(serviceName)
        }

        return sorted(names)
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
