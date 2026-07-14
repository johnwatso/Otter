import SwiftUI

enum ShareStatus: Equatable {
    case connected
    case disconnected
    case waitingForNetwork
    case waitingForAllowedNetwork(String)
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
        case .connected, .disconnected, .waitingForNetwork, .waitingForAllowedNetwork, .wakePacketSent, .reconnecting:
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
        case .connected, .disconnected, .waitingForAllowedNetwork, .wakePacketSent, .reconnecting:
            false
        }
    }
}
