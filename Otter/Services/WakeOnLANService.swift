import Darwin
import Foundation

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
