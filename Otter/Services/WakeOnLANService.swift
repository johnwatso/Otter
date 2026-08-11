import Darwin
import Foundation

struct WakeOnLANDiscoveredConfiguration: Equatable, Sendable {
    let macAddress: String
    let broadcastAddress: String
    let port: Int
}

enum WakeOnLANConfigurationDiscoveryError: LocalizedError {
    case invalidShareURL
    case shareNotMounted
    case noLocalIPv4Address
    case macAddressUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidShareURL:
            "Enter a valid network share address first."
        case .shareNotMounted:
            "Mount this share, then try again. Otter can discover Wake-on-LAN settings only while the share is mounted."
        case .noLocalIPv4Address:
            "Otter couldn't find a local IPv4 address for this mounted share. Wake-on-LAN discovery is available only on the local network."
        case .macAddressUnavailable:
            "Otter couldn't read this server's MAC address from the local network. Confirm the share is mounted locally, then try again."
        }
    }
}

/// Discovers the information required for a Wake-on-LAN packet from a mounted,
/// local IPv4 share. SMB does not expose a server MAC address, so macOS's ARP
/// neighbour entry is the authoritative local source.
actor WakeOnLANConfigurationDiscoveryService {
    func discover(for shareURL: URL) async throws -> WakeOnLANDiscoveredConfiguration {
        guard NetworkShareLocation(url: shareURL) != nil else {
            throw WakeOnLANConfigurationDiscoveryError.invalidShareURL
        }

        let isMounted = await Task.detached(priority: .userInitiated) {
            Self.isMounted(shareURL: shareURL)
        }.value
        guard isMounted else {
            throw WakeOnLANConfigurationDiscoveryError.shareNotMounted
        }

        guard let host = shareURL.host(percentEncoded: false) else {
            throw WakeOnLANConfigurationDiscoveryError.invalidShareURL
        }

        let addresses: [String]
        if WakeOnLANService.isValidIPv4Address(host) {
            addresses = [host]
        } else {
            addresses = await NetworkShare.resolveIPAddresses(for: host)
                .filter(WakeOnLANService.isValidIPv4Address)
        }
        guard !addresses.isEmpty else {
            throw WakeOnLANConfigurationDiscoveryError.noLocalIPv4Address
        }

        for address in addresses {
            if let neighbour = await Task.detached(priority: .userInitiated, operation: {
                Self.arpNeighbour(for: address)
            }).value {
                return WakeOnLANDiscoveredConfiguration(
                    macAddress: neighbour.macAddress,
                    broadcastAddress: neighbour.interface.flatMap(Self.broadcastAddress(for:))
                        ?? WakeOnLANConfiguration.defaultBroadcastAddress,
                    port: WakeOnLANConfiguration.defaultPort
                )
            }
        }

        throw WakeOnLANConfigurationDiscoveryError.macAddressUnavailable
    }

    static func parseARPNeighbour(_ output: String) -> (macAddress: String, interface: String?)? {
        guard let macAddress = firstCapture(
            in: output,
            pattern: #"\bat\s+((?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2})\b"#
        ).flatMap(WakeOnLANConfiguration.normalizedMACAddress) else {
            return nil
        }

        let interface = firstCapture(in: output, pattern: #"\bon\s+([A-Za-z0-9._-]+)\b"#)
        return (macAddress, interface)
    }

    private static func isMounted(shareURL: URL) -> Bool {
        guard let requestedLocation = NetworkShareLocation(url: shareURL) else { return false }
        let keys: Set<URLResourceKey> = [.volumeURLKey, .volumeURLForRemountingKey]
        guard let volumeURLs = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: Array(keys),
            options: []
        ) else {
            return false
        }

        return volumeURLs.contains { volumeURL in
            guard let values = try? volumeURL.resourceValues(forKeys: keys) else { return false }
            let resolvedVolumeURL = values.volume ?? volumeURL
            let volumeValues = try? resolvedVolumeURL.resourceValues(forKeys: keys)
            let remountURL = values.volumeURLForRemounting ?? volumeValues?.volumeURLForRemounting

            return NetworkShareLocation(url: remountURL) == requestedLocation
        }
    }

    private static func arpNeighbour(for address: String) -> (macAddress: String, interface: String?)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/arp")
        process.arguments = ["-n", address]

        let output = Pipe()
        process.standardOutput = output
        process.standardError = output

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0 else { return nil }
        return parseARPNeighbour(String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    private static func broadcastAddress(for interface: String) -> String? {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let interfaces else { return nil }
        defer { freeifaddrs(interfaces) }

        var current: UnsafeMutablePointer<ifaddrs>? = interfaces
        while let entry = current {
            defer { current = entry.pointee.ifa_next }

            guard let name = entry.pointee.ifa_name,
                  String(cString: name) == interface,
                  let address = entry.pointee.ifa_addr,
                  let netmask = entry.pointee.ifa_netmask,
                  address.pointee.sa_family == UInt8(AF_INET),
                  netmask.pointee.sa_family == UInt8(AF_INET)
            else {
                continue
            }

            let ip = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { pointer in
                UInt32(bigEndian: pointer.pointee.sin_addr.s_addr)
            }
            let mask = netmask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { pointer in
                UInt32(bigEndian: pointer.pointee.sin_addr.s_addr)
            }
            var broadcast = in_addr(s_addr: (ip | ~mask).bigEndian)
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))

            guard inet_ntop(AF_INET, &broadcast, &buffer, socklen_t(buffer.count)) != nil else {
                return nil
            }
            return String(cString: buffer)
        }

        return nil
    }

    private static func firstCapture(in value: String, pattern: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                  in: value,
                  range: NSRange(value.startIndex..., in: value)
              ),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: value)
        else {
            return nil
        }
        return String(value[range])
    }
}

enum WakeOnLANServiceError: LocalizedError {
    case invalidMACAddress
    case invalidBroadcastAddress
    case socketFailed(String)
    case socketOptionFailed(String)
    case sendFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidMACAddress:
            "The Wake-on-LAN MAC address is invalid."
        case .invalidBroadcastAddress:
            "The Wake-on-LAN broadcast address is invalid."
        case let .socketFailed(message):
            "Couldn't create a Wake-on-LAN socket: \(message)."
        case let .socketOptionFailed(message):
            "Couldn't enable Wake-on-LAN broadcast: \(message)."
        case let .sendFailed(message):
            "Couldn't send the Wake-on-LAN packet: \(message)."
        }
    }
}

actor WakeOnLANService {
    func sendWakePacket(using configuration: WakeOnLANConfiguration) async throws {
        let macAddress = configuration.macAddress
        let broadcastAddress = configuration.broadcastAddress
        let port = configuration.port
        let packet = try Self.magicPacket(macAddress: macAddress)

        try await Task.detached(priority: .utility) {
            try Self.send(packet: packet, broadcastAddress: broadcastAddress, port: port)
        }.value
    }

    static func magicPacket(macAddress: String) throws -> Data {
        guard let macAddressBytes = WakeOnLANConfiguration.macAddressBytes(from: macAddress) else {
            throw WakeOnLANServiceError.invalidMACAddress
        }

        var packet = Data(repeating: 0xff, count: 6)
        for _ in 0..<16 {
            packet.append(contentsOf: macAddressBytes)
        }

        return packet
    }

    static func isValidIPv4Address(_ value: String) -> Bool {
        var address = in_addr()
        return value.withCString { inet_pton(AF_INET, $0, &address) } == 1
    }

    private nonisolated static func send(packet: Data, broadcastAddress: String, port: Int) throws {
        guard isValidIPv4Address(broadcastAddress) else {
            throw WakeOnLANServiceError.invalidBroadcastAddress
        }

        let socketDescriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard socketDescriptor >= 0 else {
            throw WakeOnLANServiceError.socketFailed(lastErrnoDescription())
        }
        defer { close(socketDescriptor) }

        var broadcastEnabled: Int32 = 1
        guard setsockopt(
            socketDescriptor,
            SOL_SOCKET,
            SO_BROADCAST,
            &broadcastEnabled,
            socklen_t(MemoryLayout.size(ofValue: broadcastEnabled))
        ) == 0 else {
            throw WakeOnLANServiceError.socketOptionFailed(lastErrnoDescription())
        }

        var destination = sockaddr_in()
        destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        destination.sin_family = sa_family_t(AF_INET)
        destination.sin_port = in_port_t(port).bigEndian

        let conversionResult = broadcastAddress.withCString {
            inet_pton(AF_INET, $0, &destination.sin_addr)
        }
        guard conversionResult == 1 else {
            throw WakeOnLANServiceError.invalidBroadcastAddress
        }

        let sentByteCount = packet.withUnsafeBytes { buffer -> ssize_t in
            guard let baseAddress = buffer.baseAddress else { return -1 }

            return withUnsafePointer(to: &destination) { destinationPointer in
                destinationPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddressPointer in
                    sendto(
                        socketDescriptor,
                        baseAddress,
                        buffer.count,
                        0,
                        socketAddressPointer,
                        socklen_t(MemoryLayout<sockaddr_in>.size)
                    )
                }
            }
        }

        guard sentByteCount == packet.count else {
            throw WakeOnLANServiceError.sendFailed(lastErrnoDescription())
        }
    }

    private nonisolated static func lastErrnoDescription() -> String {
        String(cString: strerror(errno))
    }
}
