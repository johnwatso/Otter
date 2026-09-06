import Foundation
import SystemConfiguration
import Darwin

struct NetworkInterfaceInspector {
    static func interfaceTypes() -> [String: String] {
        var types: [String: String] = [:]
        for interface in (SCNetworkInterfaceCopyAll() as? [SCNetworkInterface]) ?? [] {
            guard let name = SCNetworkInterfaceGetBSDName(interface) as String? else { continue }
            let type = SCNetworkInterfaceGetInterfaceType(interface)
            if type == kSCNetworkInterfaceTypeIEEE80211 { types[name] = "Wi-Fi" }
            else if type == kSCNetworkInterfaceTypeEthernet { types[name] = "Ethernet" }
            else { types[name] = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String? ?? "Other" }
        }
        return types
    }

    func inspect(address: String, isSessionAddress: Bool) async -> NetworkDiagnostic {
        var result = NetworkDiagnostic(target: address, targetIsSessionAddress: isSessionAddress)
        guard NetworkShare.isIPAddress(address) else { return result }
        let runner = DiagnosticCommandRunner()
        let route = await runner.run("/sbin/route", ["-n", "get", address.contains(":") ? "-inet6" : "-inet", address]) ?? ""
        let types = Self.interfaceTypes()
        result.interfaceTypes = types
        let name = DiagnosticParsing.capture(#"interface:\s*([a-zA-Z]+\d+)"#, in: route)?.first
        result.interface = name
        result.type = name.flatMap { types[$0] } ?? (name == nil ? nil : "Other")
        var wifiStates: [Bool] = []
        let relevant = Set(types.filter { $0.value == "Ethernet" || $0.value == "Wi-Fi" }.keys).union(name.map { [$0] } ?? [])
        for interface in relevant.sorted() {
            guard !Task.isCancelled else { break }
            guard let config = await runner.run("/sbin/ifconfig", [interface]) else { continue }
            let speed = Self.linkSpeed(config)
            result.interfaceLinkMbps[interface] = speed
            if types[interface] == "Wi-Fi", let connected = Self.activeState(config) { wifiStates.append(connected) }
            if types[interface] == "Ethernet", let speed {
                result.availableEthernetMbps = max(result.availableEthernetMbps ?? 0, speed)
            }
            if interface == name {
                result.linkMbps = speed
                result.mtu = Self.mtu(config)
                result.duplex = Self.duplex(config)
            }
        }
        let wifiCount = types.values.filter { $0 == "Wi-Fi" }.count
        if wifiStates.contains(true) { result.wifi.connected = true }
        else if wifiStates.count == wifiCount, wifiCount > 0 { result.wifi.connected = false }
        result.localIP = Self.localAddress(to: address)
        return result
    }

    /// UDP connect selects the route's source address without sending a packet.
    static func localAddress(to destination: String) -> String? {
        var hints = addrinfo()
        hints.ai_flags = AI_NUMERICHOST
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_DGRAM
        var address: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(destination, "445", &hints, &address) == 0, let address else { return nil }
        defer { freeaddrinfo(address) }
        let fd = socket(address.pointee.ai_family, SOCK_DGRAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        guard connect(fd, address.pointee.ai_addr, address.pointee.ai_addrlen) == 0 else { return nil }
        var local = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let status = withUnsafeMutablePointer(to: &local) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress -> Int32 in
                guard getsockname(fd, socketAddress, &length) == 0 else { return -1 }
                return getnameinfo(socketAddress, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            }
        }
        return status == 0 ? String(cString: host) : nil
    }

    static func activeState(_ text: String) -> Bool? {
        DiagnosticParsing.capture(#"status:\s*(active|inactive)\b"#, in: text).map { $0[0].lowercased() == "active" }
    }
    static func mtu(_ text: String) -> Int? {
        DiagnosticParsing.capture(#"\bmtu\s+(\d+)\b"#, in: text)?.first.flatMap(Int.init)
    }
    static func duplex(_ text: String) -> String? {
        guard activeState(text) == true else { return nil }
        let lower = text.lowercased()
        if lower.contains("full-duplex") { return "Full" }
        if lower.contains("half-duplex") { return "Half" }
        return nil
    }

    static func linkSpeed(_ text: String) -> Double? {
        guard text.contains("status: active"),
              let values = DiagnosticParsing.capture(#"media:.*?\((\d+(?:\.\d+)?)(G)?base"#, in: text), let number = Double(values[0]) else { return nil }
        return number * (values[1].isEmpty ? 1 : 1000)
    }
}
