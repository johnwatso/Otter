import AppKit
import SwiftUI

private enum ActivityEventFilter: String, CaseIterable, Identifiable {
    case all = "All Events"
    case connections = "Connections"
    case problems = "Warnings & Errors"

    var id: String { rawValue }

    func includes(_ kind: ShareEventKind) -> Bool {
        switch self {
        case .all: true
        case .connections: kind.isConnectionEvent
        case .problems: kind.severity != .info
        }
    }
}

private struct ActivityDayGroup: Identifiable {
    let day: Date
    let events: [ShareEvent]
    var id: Date { day }
}

// Newest first. A server log combines matching events across shares in a
// short burst. Other scopes retain the existing adjacent per-share runs.
struct ActivityEventRun: Identifiable {
    let events: [ShareEvent]
    var id: ShareEvent.ID { events[0].id }

    static func runs(
        from events: [ShareEvent],
        serverIdentities: [NetworkShare.ID: String]? = nil
    ) -> [ActivityEventRun] {
        var result: [[ShareEvent]] = []
        for event in events {
            if let serverIdentities {
                var matchingIndex: Int?
                if let server = serverIdentities[event.shareID] {
                    for index in result.indices.reversed() {
                        let latest = result[index][0]
                        // Anchor the burst to its newest event so a long chain
                        // of events cannot merge separate incidents.
                        guard latest.date.timeIntervalSince(event.date) <= 30 else { break }
                        // Don't group across another transition for this share,
                        // or mistake two attempts on one share for one incident.
                        guard !result[index].contains(where: { $0.shareID == event.shareID }) else { break }
                        if serverIdentities[latest.shareID] == server,
                           latest.kind == event.kind,
                           latest.detail == event.detail {
                            matchingIndex = index
                            break
                        }
                    }
                }
                if let matchingIndex {
                    result[matchingIndex].append(event)
                } else {
                    result.append([event])
                }
            } else if let last = result.last?.first,
                      event.kind.isCollapsible,
                      last.shareID == event.shareID,
                      last.kind == event.kind,
                      last.detail == event.detail {
                result[result.count - 1].append(event)
            } else {
                result.append([event])
            }
        }
        return result.map(ActivityEventRun.init)
    }
}

private struct ActivitySummary {
    var mounts = 0
    var reconnects = 0
    var errors = 0
}

// Date-grouped activity list with a 24-hour summary and expandable rows.
struct ActivityLogView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var eventLog: ShareEventLog
    @State private var shareFilter: NetworkShare.ID?
    @State private var eventFilter: ActivityEventFilter = .all
    @State private var expandedIDs: Set<ShareEvent.ID> = []
    @State private var isConfirmingClear = false
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

    private var storedEvents: [ShareEvent] {
        appModel.screenshotDemoEvents ?? eventLog.events(for: nil)
    }

    // Events for the selected share(s), before the event-type filter.
    private var scopedEvents: [ShareEvent] {
        let events = storedEvents
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

    private var serverIdentities: [NetworkShare.ID: String]? {
        guard includedShareIDs != nil, resolvedFilter == nil else { return nil }
        return Dictionary(uniqueKeysWithValues: filterableShares.compactMap { share in
            share.serverIdentity.map { (share.id, $0) }
        })
    }

    private var summary: ActivitySummary {
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        var result = ActivitySummary()
        let recent = scopedEvents.filter { $0.date >= cutoff }
        let summaryEvents: [ShareEvent]
        if let serverIdentities {
            summaryEvents = dayGroups(from: recent).flatMap { group in
                ActivityEventRun.runs(from: group.events, serverIdentities: serverIdentities).map { $0.events[0] }
            }
        } else {
            summaryEvents = recent
        }
        for event in summaryEvents {
            if event.kind == .mounted { result.mounts += 1 }
            if event.kind == .reconnected { result.reconnects += 1 }
            if event.kind.severity == .error { result.errors += 1 }
        }
        return result
    }

    private func dayGroups(from events: [ShareEvent]) -> [ActivityDayGroup] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: events) { calendar.startOfDay(for: $0.date) }
        return grouped
            .map { ActivityDayGroup(day: $0.key, events: $0.value.sorted { $0.date > $1.date }) }
            .sorted { $0.day > $1.day }
    }

    var body: some View {
        let events = scopedEvents.filter { eventFilter.includes($0.kind) }
        // Group before filtering so hidden transitions still separate incidents.
        let groups = dayGroups(from: scopedEvents).filter { group in
            group.events.contains { eventFilter.includes($0.kind) }
        }

        VStack(spacing: 0) {
            header

            Divider()

            ActivitySummaryView(summary: summary)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 4)

            if scopedEvents.isEmpty {
                emptyState(
                    symbol: "clock",
                    title: "No activity yet",
                    message: "Connection events will appear here as Otter manages your shares."
                )
            } else if events.isEmpty {
                emptyState(
                    symbol: "line.3.horizontal.decrease.circle",
                    title: "No matching events",
                    message: "Try selecting a different event filter."
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(groups) { group in
                            ActivityDateSection(
                                group: group,
                                eventFilter: eventFilter,
                                showsShareName: resolvedFilter == nil,
                                serverIdentities: serverIdentities,
                                shareLookup: share(for:),
                                expandedIDs: $expandedIDs
                            )
                        }
                    }
                    .padding(16)
                }
            }

            Divider()

            HStack {
                Spacer()
                Menu {
                    Button("Export Log…", systemImage: "square.and.arrow.up") { exportLog() }
                        .disabled(scopedEvents.isEmpty)
                    Divider()
                    Button("Clear Log…", systemImage: "trash", role: .destructive) { isConfirmingClear = true }
                        .disabled(appModel.screenshotDemoEvents != nil || eventLog.events(for: nil).isEmpty)
                } label: {
                    Image(systemName: "arrow.up.page.on.clipboard")
                }
                .menuIndicator(.hidden)
                .tahoeSecondaryMenu()
                .fixedSize()
                .help("Export or clear the log")
                .accessibilityLabel("Log actions")
                Button("Done") { dismiss() }
                    .tahoePrimaryActionButton()
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(minWidth: 620, idealWidth: 680, maxWidth: 720, minHeight: 480, idealHeight: 700, maxHeight: 750)
        .confirmationDialog("Clear the activity log?", isPresented: $isConfirmingClear, titleVisibility: .visible) {
            Button("Clear Log", role: .destructive) { eventLog.clear() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This removes the recorded history for every share. It can't be undone.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Activity Log")
                        .font(.title3.weight(.bold))
                    Text(resolvedFilter == nil
                         ? includedSharesLabel.map { "Connection history and events for \($0)." }
                            ?? "Connection history and events for your shares."
                         : "Connection history and events for this share.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

            }

            HStack(spacing: 10) {
                Picker("Share", selection: $shareFilter) {
                    Text(includedSharesLabel.map { "All on \($0)" } ?? "All Shares")
                        .tag(NetworkShare.ID?.none)
                    ForEach(filterableShares) { share in
                        Text(share.displayName).tag(Optional(share.id))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .accessibilityLabel("Share")

                Picker("Events", selection: $eventFilter) {
                    ForEach(ActivityEventFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .accessibilityLabel("Event filter")

                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private func emptyState(symbol: String, title: String, message: String) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(message)
        }
        .frame(maxHeight: .infinity)
    }

    private func share(for id: NetworkShare.ID) -> NetworkShare? {
        allShares.first { $0.id == id }
    }

    private func exportLog() {
        struct Entry: Encodable {
            let date: Date
            let share: String
            let server: String?
            let event: String
            let detail: String?
        }
        let entries = scopedEvents.map { event in
            let share = share(for: event.shareID)
            return Entry(
                date: event.date,
                share: share?.displayName ?? "Removed share",
                server: share?.host,
                event: event.kind.rawValue,
                detail: event.detail
            )
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(entries) else { return }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Otter Activity Log.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? data.write(to: url, options: .atomic)
    }
}

private struct ActivitySummaryView: View {
    let summary: ActivitySummary

    var body: some View {
        HStack(spacing: 0) {
            Text("Last 24 hours")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 4)

            metric(symbol: "checkmark.circle.fill", color: .green, value: summary.mounts, label: "Mounts")
            separator
            metric(symbol: "arrow.triangle.2.circlepath", color: .blue, value: summary.reconnects, label: "Reconnects")
            separator
            metric(symbol: "xmark.circle.fill", color: .red, value: summary.errors, label: "Errors")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator.opacity(0.6)))
        .accessibilityElement(children: .combine)
    }

    private var separator: some View {
        Divider().frame(height: 28)
    }

    private func metric(symbol: String, color: Color, value: Int, label: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text("\(value)").font(.headline.monospacedDigit())
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct ActivityDateSection: View {
    let group: ActivityDayGroup
    let eventFilter: ActivityEventFilter
    let showsShareName: Bool
    let serverIdentities: [NetworkShare.ID: String]?
    let shareLookup: (NetworkShare.ID) -> NetworkShare?
    @Binding var expandedIDs: Set<ShareEvent.ID>

    private var runs: [ActivityEventRun] {
        ActivityEventRun.runs(from: group.events, serverIdentities: serverIdentities)
            .filter { eventFilter.includes($0.events[0].kind) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ForEach(Array(runs.enumerated()), id: \.element.id) { index, run in
                if index > 0 {
                    Divider().padding(.leading, 44)
                }
                ActivityEventRow(
                    events: run.events,
                    shareLookup: shareLookup,
                    showsShareName: showsShareName,
                    isExpanded: expandedIDs.contains(run.id),
                    toggle: { toggle(run.id) }
                )
            }
        }
        .background(.background.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator.opacity(0.6)))
    }

    private var header: some View {
        HStack(spacing: 6) {
            if let prefix = relativeName {
                Text(prefix).fontWeight(.semibold)
                Text(group.day.formatted(date: .long, time: .omitted)).foregroundStyle(.secondary)
            } else {
                Text(group.day.formatted(date: .long, time: .omitted)).fontWeight(.semibold)
            }
            Spacer()
        }
        .font(.subheadline)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(.quaternary.opacity(0.6))
        .accessibilityAddTraits(.isHeader)
    }

    private var relativeName: String? {
        let calendar = Calendar.current
        if calendar.isDateInToday(group.day) { return "Today" }
        if calendar.isDateInYesterday(group.day) { return "Yesterday" }
        return nil
    }

    private func toggle(_ id: ShareEvent.ID) {
        withAnimation(.easeInOut(duration: 0.2)) {
            if expandedIDs.contains(id) {
                expandedIDs.remove(id)
            } else {
                expandedIDs.insert(id)
            }
        }
    }
}

private struct ActivityEventRow: View {
    let events: [ShareEvent]
    let shareLookup: (NetworkShare.ID) -> NetworkShare?
    let showsShareName: Bool
    let isExpanded: Bool
    let toggle: () -> Void

    private var event: ShareEvent { events[0] }
    private var isRun: Bool { events.count > 1 }
    private var share: NetworkShare? { shareLookup(event.shareID) }
    private var shareIDs: [NetworkShare.ID] {
        var seen = Set<NetworkShare.ID>()
        return events.map(\.shareID).filter { seen.insert($0).inserted }
    }
    private var spansShares: Bool { shareIDs.count > 1 }

    private var title: String {
        if spansShares { return "\(event.kind.title) · \(String.counted(shareIDs.count, "share"))" }
        return isRun ? "\(event.kind.title) ×\(events.count)" : event.kind.title
    }

    private var timeLabel: String {
        let time = { (date: Date) in date.formatted(date: .omitted, time: .shortened) }
        guard let oldest = events.last, isRun else { return time(event.date) }
        let start = time(oldest.date)
        let end = time(event.date)
        return start == end ? end : "\(start) – \(end)"
    }

    private var shareName: String {
        shareIDs.map { shareLookup($0)?.displayName ?? "Removed share" }.joined(separator: ", ")
    }

    private var subtitle: String? {
        if let detail = event.detail, !detail.isEmpty { return detail }
        return showsShareName ? shareName : nil
    }

    var body: some View {
        VStack(spacing: 0) {
            Button(action: toggle) {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: event.kind.symbol)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(event.kind.color)
                        .frame(width: 20)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.primary)
                        if let subtitle {
                            Text(subtitle)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(isExpanded ? nil : 1)
                                .truncationMode(.tail)
                        }
                        if showsShareName, event.detail?.isEmpty == false {
                            Text(shareName)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Text(timeLabel)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint("Shows event details")
            .accessibilityAddTraits(.isButton)

            if isExpanded {
                details
                    .padding(.leading, 46)
                    .padding(.trailing, 14)
                    .padding(.bottom, 10)
                    .transition(.opacity)
            }
        }
    }

    private var accessibilityText: String {
        var text = "\(event.kind.severity.label)\(spansShares ? title : event.kind.title)"
        if spansShares {
            text += ", \(timeLabel)"
        } else if isRun {
            text += ", \(events.count) times, \(timeLabel)"
        } else {
            text += ", \(event.date.formatted(date: .abbreviated, time: .shortened))"
        }
        if showsShareName { text += ", \(shareName)" }
        if let detail = event.detail, !detail.isEmpty { text += ", \(detail)" }
        return text
    }

    private var details: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 6) {
            row(spansShares ? "Shares" : "Share", shareName)
            if let host = share?.host { row("Server", host) }
            if let detail = event.detail, !detail.isEmpty { row("Detail", detail) }
            if isRun {
                row("Times", events.map { event in
                    let time = event.date.formatted(date: .omitted, time: .standard)
                    guard spansShares else { return time }
                    let name = shareLookup(event.shareID)?.displayName ?? "Removed share"
                    return "\(name): \(time)"
                }.joined(separator: "\n"))
            } else {
                row("Time", event.date.formatted(date: .long, time: .shortened))
            }
        }
        .font(.subheadline)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .textSelection(.enabled)
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
            Text(value).fixedSize(horizontal: false, vertical: true)
        }
    }
}

enum ShareEventSeverity {
    case info, warning, error

    var label: String {
        switch self {
        case .info: ""
        case .warning: "Warning: "
        case .error: "Error: "
        }
    }
}

private extension ShareEventKind {
    var severity: ShareEventSeverity {
        switch self {
        case .mountFailed, .unresponsiveDetected:
            .error
        case .connectionLost, .healthCheckFailed, .credentialsRequired:
            .warning
        default:
            .info
        }
    }

    var isCollapsible: Bool {
        severity != .error && self != .credentialsRequired
    }

    var isConnectionEvent: Bool {
        switch self {
        case .mounted, .reconnected, .connectionLost, .disconnected, .blockedByRule, .duplicateResolved, .mountFailed:
            true
        default:
            false
        }
    }

    var title: String {
        switch self {
        case .mounted:
            "Mounted"
        case .reconnected:
            "Reconnected"
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
        case .healthCheckFailed:
            "Health check failed"
        case .credentialsRequired:
            "Credentials need attention"
        case .duplicateResolved:
            "Duplicate connection cleaned up"
        }
    }

    var symbol: String {
        switch self {
        case .mounted:
            "checkmark.circle.fill"
        case .reconnected:
            "arrow.triangle.2.circlepath"
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
        case .healthCheckFailed:
            "heart.text.square.fill"
        case .credentialsRequired:
            "key.fill"
        case .duplicateResolved:
            "rectangle.on.rectangle.slash"
        }
    }

    var color: Color {
        switch self {
        case .mounted:
            .green
        case .reconnected:
            .blue
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
        case .healthCheckFailed:
            .orange
        case .credentialsRequired:
            .orange
        case .duplicateResolved:
            .blue
        }
    }
}
