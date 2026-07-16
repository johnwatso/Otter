import SwiftUI

// Dense, flat activity list in the SwiftMiner event log style.
struct ActivityLogView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var eventLog: ShareEventLog
    @State private var shareFilter: NetworkShare.ID?
    private let includedShareIDs: Set<NetworkShare.ID>?
    private let includedSharesLabel: String?

    init(
        initialShareFilter: NetworkShare.ID? = nil,
        includedShareIDs: Set<NetworkShare.ID>? = nil,
        includedSharesLabel: String? = nil
    ) {
        _shareFilter = State(initialValue: initialShareFilter)
        self.includedShareIDs = includedShareIDs
        self.includedSharesLabel = includedSharesLabel
    }

    private var allShares: [NetworkShare] {
        appModel.screenshotDemoShares ?? settings.shares
    }

    private var visibleEvents: [ShareEvent] {
        let events = appModel.screenshotDemoEvents ?? eventLog.events(for: nil)
        if let resolvedFilter {
            return events.filter { $0.shareID == resolvedFilter }
        }
        if let includedShareIDs {
            return events.filter { includedShareIDs.contains($0.shareID) }
        }
        return events
    }

    // A filter pointing at a share that was removed falls back to All Shares.
    private var resolvedFilter: NetworkShare.ID? {
        guard let shareFilter,
              filterableShares.contains(where: { $0.id == shareFilter })
        else { return nil }
        return shareFilter
    }

    private var filterableShares: [NetworkShare] {
        guard let includedShareIDs else { return allShares }
        return allShares.filter { includedShareIDs.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Activity Log")
                    .font(.title3)
                    .fontWeight(.bold)

                Spacer()

                Picker("Share", selection: $shareFilter) {
                    Text(includedSharesLabel.map { "All on \($0)" } ?? "All Shares")
                        .tag(NetworkShare.ID?.none)

                    ForEach(filterableShares) { share in
                        Text(share.displayName).tag(Optional(share.id))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 170)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            if visibleEvents.isEmpty {
                ContentUnavailableView {
                    Label("No Activity", systemImage: "clock.arrow.circlepath")
                } description: {
                    Text("Mounts, drops, and failures will appear here as they happen.")
                }
                .frame(maxHeight: .infinity)
            } else {
                List(visibleEvents) { event in
                    ActivityLogRow(event: event, shareName: shareName(for: event.shareID))
                        .listRowInsets(EdgeInsets(top: 3, leading: 12, bottom: 3, trailing: 12))
                        .listRowSeparator(.visible, edges: .bottom)
                        .listRowSeparatorTint(.secondary.opacity(0.14))
                        .listRowBackground(Color.clear)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }

            Divider()

            HStack {
                Button {
                    eventLog.clear()
                } label: {
                    Label("Clear Log", systemImage: "trash")
                }
                .tahoeSecondaryActionButton()
                .disabled(appModel.screenshotDemoEvents != nil || eventLog.events(for: nil).isEmpty)

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Label("Done", systemImage: "checkmark")
                }
                .tahoePrimaryActionButton()
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 480, height: 440)
    }

    private func shareName(for shareID: NetworkShare.ID) -> String {
        allShares.first { $0.id == shareID }?.displayName ?? "Removed share"
    }
}

private struct ActivityLogRow: View {
    let event: ShareEvent
    let shareName: String

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: event.kind.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(event.kind.color)
                .frame(width: 16, alignment: .center)

            VStack(alignment: .leading, spacing: 1) {
                Text(event.kind.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(metadataText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(metadataText)
            }

            Spacer(minLength: 8)

            Text(timeLabel)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    private var metadataText: String {
        var parts = [shareName]
        if let detail = event.detail, !detail.isEmpty {
            parts.append(detail)
        }
        return parts.joined(separator: " • ")
    }

    private var timeLabel: String {
        if Calendar.current.isDateInToday(event.date) {
            return event.date.formatted(date: .omitted, time: .shortened)
        }
        return event.date.formatted(date: .abbreviated, time: .shortened)
    }
}

private extension ShareEventKind {
    var title: String {
        switch self {
        case .mounted:
            "Mounted"
        case .connectionLost:
            "Connection lost"
        case .disconnected:
            "Disconnected"
        case .blockedByRule:
            "Disconnected by network condition"
        case .mountFailed:
            "Mount failed"
        case .wakePacketSent:
            "Wake-on-LAN packet sent"
        case .unresponsiveDetected:
            "Mounted volume stopped responding"
        case .recoveryAttempted:
            "Recovery started"
        }
    }

    var symbol: String {
        switch self {
        case .mounted:
            "checkmark.circle.fill"
        case .connectionLost:
            "wifi.exclamationmark"
        case .disconnected:
            "eject.circle.fill"
        case .blockedByRule:
            "pause.circle.fill"
        case .mountFailed:
            "exclamationmark.triangle.fill"
        case .wakePacketSent:
            "power.circle.fill"
        case .unresponsiveDetected:
            "externaldrive.badge.exclamationmark"
        case .recoveryAttempted:
            "wrench.and.screwdriver.fill"
        }
    }

    var color: Color {
        switch self {
        case .mounted:
            .green
        case .connectionLost:
            .orange
        case .disconnected:
            .secondary
        case .blockedByRule:
            .indigo
        case .mountFailed:
            .red
        case .wakePacketSent:
            .blue
        case .unresponsiveDetected:
            .red
        case .recoveryAttempted:
            .blue
        }
    }
}
