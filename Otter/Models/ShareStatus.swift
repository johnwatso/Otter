import SwiftUI

enum ShareStatus: Equatable {
    case connected
    case disconnected
    case waitingForNetwork
    case waitingForAllowedNetwork(String)
    case pausedByRule(String)
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
            "Waiting for network rule"
        case .pausedByRule:
            "Paused by rule"
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
        case let .pausedByRule(requirement):
            return "Rule disconnects this share while \(requirement) is active."
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
        case .connected, .disconnected, .waitingForNetwork, .waitingForAllowedNetwork, .pausedByRule, .wakePacketSent, .reconnecting:
            "Details"
        }
    }

    var systemImage: String {
        switch self {
        case .connected:
            "externaldrive.fill"
        case .disconnected:
            "externaldrive"
        case .waitingForNetwork:
            "wifi.exclamationmark"
        case .waitingForAllowedNetwork:
            "wifi.slash"
        case .pausedByRule:
            "pause.circle"
        case .wakePacketSent:
            "power.circle"
        case .reconnecting:
            "arrow.triangle.2.circlepath"
        case .failed:
            "exclamationmark.triangle.fill"
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
        case .waitingForAllowedNetwork, .pausedByRule:
            .secondary
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
        case .failed, .waitingForNetwork:
            true
        case .connected, .disconnected, .waitingForAllowedNetwork, .pausedByRule, .wakePacketSent, .reconnecting:
            false
        }
    }
}
