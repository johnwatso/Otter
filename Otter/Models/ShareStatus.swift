import SwiftUI

enum ShareStatus: Equatable {
    case connected
    case disconnected
    case waitingForNetwork
    case waitingForAllowedNetwork(String)
    case waitingForVPN(String)
    case waitingForAccess
    case waitingForServerOnVPN
    case paused(Date?)
    case wakePacketSent
    case reconnecting
    case failed(String)

    var label: String {
        switch self {
        case .connected:
            "Connected"
        case .disconnected:
            "Disconnected"
        case .waitingForNetwork:
            "Waiting for network"
        case .waitingForAllowedNetwork:
            "Waiting for connection"
        case .waitingForVPN:
            "Waiting for VPN"
        case .waitingForAccess:
            "Waiting for access"
        case .waitingForServerOnVPN:
            "Server unavailable"
        case .paused:
            "Paused"
        case .wakePacketSent:
            "Wake sent"
        case .reconnecting:
            "Reconnecting"
        case .failed:
            "Couldn't connect"
        }
    }

    var detail: String? {
        switch self {
        case let .waitingForAllowedNetwork(requirement):
            return "Connect to \(requirement) to mount this share."
        case let .waitingForVPN(name):
            return "Connect to “\(name)” to access this server."
        case .waitingForAccess:
            return "This server isn’t available on the current network or VPN. Otter will keep checking quietly."
        case .waitingForServerOnVPN:
            return "A VPN is connected, but the server isn’t responding. Check that the correct VPN is active."
        case let .paused(resumeAt):
            if let resumeAt {
                return "Automatic mounting resumes \(resumeAt.formatted(date: .abbreviated, time: .shortened))."
            }
            return "Automatic mounting is paused until you resume it."
        case .wakePacketSent:
            return "Otter sent a Wake-on-LAN packet."
        case let .failed(message):
            return message
        case .connected, .disconnected, .waitingForNetwork, .reconnecting:
            return nil
        }
    }

    var detailTitle: String {
        switch self {
        case .failed:
            "Last error"
        case .connected, .disconnected, .waitingForNetwork, .waitingForAllowedNetwork, .waitingForVPN, .waitingForAccess, .waitingForServerOnVPN, .paused, .wakePacketSent, .reconnecting:
            "Details"
        }
    }

    var systemImage: String {
        switch self {
        case .connected:
            "externaldrive.connected.to.line.below.fill"
        case .disconnected:
            "externaldrive.fill.badge.xmark"
        case .waitingForNetwork:
            "externaldrive.badge.questionmark"
        case .waitingForAllowedNetwork:
            "externaldrive.badge.minus"
        case .waitingForVPN:
            "lock.shield.fill"
        case .waitingForAccess:
            "externaldrive.badge.minus"
        case .waitingForServerOnVPN:
            "lock.shield.fill"
        case .paused:
            "pause.circle.fill"
        case .wakePacketSent:
            "externaldrive.badge.plus"
        case .reconnecting:
            "arrow.triangle.2.circlepath"
        case .failed:
            "externaldrive.badge.exclamationmark"
        }
    }

    // Circle-family symbol for compact colored status indicators.
    var circleSymbol: String {
        switch self {
        case .connected:
            "checkmark.circle.fill"
        case .disconnected:
            "minus.circle.fill"
        case .waitingForNetwork:
            "questionmark.circle.fill"
        case .waitingForAllowedNetwork:
            "pause.circle.fill"
        case .waitingForVPN:
            "exclamationmark.circle.fill"
        case .waitingForAccess:
            "pause.circle.fill"
        case .waitingForServerOnVPN:
            "exclamationmark.circle.fill"
        case .paused:
            "pause.circle.fill"
        case .wakePacketSent:
            "power.circle.fill"
        case .reconnecting:
            "arrow.triangle.2.circlepath.circle.fill"
        case .failed:
            "exclamationmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .connected:
            .green
        case .disconnected:
            .secondary
        case .waitingForNetwork:
            .orange
        case .waitingForAllowedNetwork:
            .secondary
        case .waitingForVPN:
            .orange
        case .waitingForAccess:
            .secondary
        case .waitingForServerOnVPN:
            .orange
        case .paused:
            .indigo
        case .wakePacketSent:
            .orange
        case .reconnecting:
            .blue
        case .failed:
            .red
        }
    }

    var needsAttention: Bool {
        switch self {
        case .failed, .waitingForNetwork, .waitingForVPN, .waitingForServerOnVPN:
            true
        case .connected, .disconnected, .waitingForAllowedNetwork, .waitingForAccess, .paused, .wakePacketSent, .reconnecting:
            false
        }
    }

    var offersVPNSettingsAction: Bool {
        switch self {
        case .waitingForVPN, .waitingForAccess, .waitingForServerOnVPN:
            true
        default:
            false
        }
    }
}
