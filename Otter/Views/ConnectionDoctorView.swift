import AppKit
import SwiftUI

struct ConnectionDoctorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var settings: SettingsStore

    let share: NetworkShare

    @StateObject private var performanceModel = NASDiagnosticsViewModel()
    @State private var report: ConnectionDiagnosticReport?
    @State private var repairStep: ConnectionDiagnosticStep?
    @State private var isRunning = false
    @State private var didCopy = false
    @State private var expandedCategories: Set<DiagnosticCategory> = []
    @State private var expandedDetails: Set<UUID> = []
    @State private var isPerformanceExpanded = false
    @State private var runDuration: TimeInterval?
    @State private var pendingPerformanceBytes: Int64?
    @State private var showPerformanceConfirmation = false
    @State private var didCopyDetailedReport = false

    private var currentShare: NetworkShare {
        settings.share(id: share.id) ?? share
    }

    private var displayedSteps: [ConnectionDiagnosticStep] {
        if let repairStep {
            return [repairStep] + (report?.steps ?? [])
        }
        return report?.steps ?? []
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            if let report {
                ScrollView {
                    VStack(spacing: 14) {
                        healthSummary(for: report)

                        ForEach(DiagnosticCategory.allCases) { category in
                            let steps = displayedSteps.filter { category.contains($0) }
                            if !steps.isEmpty {
                                categorySection(category, steps: steps)
                            }
                        }

                        performanceSection
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 18)
                }
                .scrollIndicators(.automatic)
            } else if isRunning {
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.regular)
                    Text("Checking the network, server and volume…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView {
                    Label("Ready to Check", systemImage: "stethoscope")
                } description: {
                    Text("Otter will check the network, connection conditions, server reachability, and mounted-volume health.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            footer
        }
        .frame(
            minWidth: 560,
            idealWidth: 620,
            maxWidth: .infinity,
            minHeight: 560,
            idealHeight: 700,
            maxHeight: .infinity
        )
        .background(.regularMaterial)
        .task {
            await runDoctorNow()
        }
        .interactiveDismissDisabled(performanceModel.blocksDismissal)
        .alert("Run Performance Test?", isPresented: $showPerformanceConfirmation) {
            Button("Cancel", role: .cancel) {
                pendingPerformanceBytes = nil
            }
            Button("Start Test") {
                runPerformanceTest()
            }
        } message: {
            Text(performanceConfirmationMessage)
        }
        .onDisappear {
            performanceModel.cancel()
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.quaternary)
                    .frame(width: 48, height: 48)

                Image(systemName: "externaldrive.fill")
                    .font(.system(size: 24, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                    .frame(width: 48, height: 48)

                if isConnected {
                    Circle()
                        .fill(.green)
                        .frame(width: 15, height: 15)
                        .overlay {
                            Circle().stroke(.background, lineWidth: 2)
                        }
                        .offset(x: 2, y: 2)
                        .accessibilityLabel("Connected")
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("DIAGNOSE")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .tracking(0.5)

                Text(currentShare.displayName)
                    .font(.title.weight(.semibold))
                    .lineLimit(1)

                Text(shareMetadata)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 16)

            if isRunning || performanceModel.isBusy {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Checking")
            }

            Menu {
                Button {
                    copyReport()
                } label: {
                    Label(didCopy ? "Copied" : "Copy Report", systemImage: "doc.on.doc")
                }
                .disabled(report == nil)

                if let result = performanceModel.result {
                    Button {
                        copyDetailedReport(result)
                    } label: {
                        Label(
                            didCopyDetailedReport ? "Detailed Report Copied" : "Copy Detailed Report…",
                            systemImage: "doc.on.doc"
                        )
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 24, height: 24)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
            .accessibilityLabel("More options")
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .padding(.bottom, 16)
    }

    private func healthSummary(for report: ConnectionDiagnosticReport) -> some View {
        let summary = HealthSummary(steps: report.steps)

        return HStack(spacing: 16) {
            Image(systemName: summary.symbol)
                .font(.system(size: 42, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(summary.color)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(summary.title)
                    .font(.title3.weight(.semibold))
                Text(summary.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(summary.color.opacity(0.09), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(summary.color.opacity(0.13), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }

    private func categorySection(
        _ category: DiagnosticCategory,
        steps: [ConnectionDiagnosticStep]
    ) -> some View {
        let isExpanded = expandedCategories.contains(category)

        return VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if isExpanded {
                        expandedCategories.remove(category)
                    } else {
                        expandedCategories.insert(category)
                    }
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: category.symbol)
                        .font(.system(size: 22, weight: .medium))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                        .frame(width: 28)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(category.title)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(category.summary(for: steps))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(category.title), \(category.summary(for: steps))")
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")

            if isExpanded {
                VStack(spacing: 0) {
                    ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                        if index > 0 {
                            Divider()
                                .padding(.leading, 50)
                        }
                        diagnosticRow(step)
                    }
                }
                .transition(.opacity)
            }
        }
        .background(.background.opacity(0.48), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.separator.opacity(0.42), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func diagnosticRow(_ step: ConnectionDiagnosticStep) -> some View {
        // Informational rows have nothing to say except their detail, so show it.
        let automaticallyShowsDetail = step.status != .passed
        let showsDetail = automaticallyShowsDetail || expandedDetails.contains(step.id)

        return Button {
            guard !automaticallyShowsDetail else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                if showsDetail {
                    expandedDetails.remove(step.id)
                } else {
                    expandedDetails.insert(step.id)
                }
            }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: step.status.symbol)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(step.status.color)
                    .frame(width: 20)
                    .accessibilityLabel(step.status.accessibilityName)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(step.title)
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if step.status != .information {
                            Text(step.status.label)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize()
                        }
                    }

                    if showsDetail {
                        Text(step.detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .transition(.opacity)
                    }
                }
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint(automaticallyShowsDetail ? "" : showsDetail ? "Collapse details" : "Show details")
    }

    private var performanceSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isPerformanceExpanded.toggle()
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "gauge.with.dots.needle.33percent")
                        .font(.system(size: 22, weight: .medium))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                        .frame(width: 28)

                    VStack(alignment: .leading, spacing: 1) {
                        Text("Performance")
                            .font(.body.weight(.semibold))
                        Text(performanceSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if performanceModel.isBusy {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Running performance diagnostics")
                    }

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isPerformanceExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Performance, \(performanceSummary)")
            .accessibilityValue(isPerformanceExpanded ? "Expanded" : "Collapsed")

            if isPerformanceExpanded {
                Divider()
                    .padding(.leading, 50)

                VStack(alignment: .leading, spacing: 12) {
                    if let result = performanceModel.result {
                        performanceResults(result)
                    } else {
                        Text("Measure real read and write performance using a temporary file on this share. Choose 1 GB for a quick measurement or 5 GB for steadier results on fast networks.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if performanceModel.testing {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(performanceModel.performanceStatus)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            ProgressView(value: performanceModel.progress)
                        }
                    } else if performanceModel.running {
                        Text(performanceModel.status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let error = performanceModel.error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(Color.warningText)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }

                    HStack(spacing: 10) {
                        Button("Run 1 GB Test") {
                            askToRunPerformanceTest(gigabytes: 1)
                        }
                        .tahoeSecondaryActionButton()
                        .disabled(isRunning || performanceModel.isBusy)

                        Button("Run 5 GB Test") {
                            askToRunPerformanceTest(gigabytes: 5)
                        }
                        .tahoeSecondaryActionButton()
                        .disabled(isRunning || performanceModel.isBusy)

                        if performanceModel.running || performanceModel.testing {
                            Button("Cancel") {
                                performanceModel.cancel()
                            }
                            .tahoeSecondaryActionButton()
                        }

                        Spacer()
                    }

                    Text("Tests create a temporary file in Otter’s own folder on the share and remove it when finished. NAS caching can affect results.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
                .transition(.opacity)
            }
        }
        .background(.background.opacity(0.48), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.separator.opacity(0.42), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private func performanceResults(_ result: NASDiagnosticResult) -> some View {
        if let performance = result.performance {
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 7) {
                GridRow {
                    Text("Write")
                        .foregroundStyle(.secondary)
                    Text(diagnosticNumber(performance.writeMBps, suffix: " MB/s"))
                        .fontWeight(.medium)
                    Text(diagnosticPercent(performance.write.utilisation(expected: result.expectedMaxMBps)) + " utilization")
                        .foregroundStyle(.secondary)
                }
                GridRow {
                    Text("Read")
                        .foregroundStyle(.secondary)
                    Text(diagnosticNumber(performance.readMBps, suffix: " MB/s"))
                        .fontWeight(.medium)
                    Text(diagnosticPercent(performance.read.utilisation(expected: result.expectedMaxMBps)) + " utilization")
                        .foregroundStyle(.secondary)
                }
                GridRow {
                    Text("Test")
                        .foregroundStyle(.secondary)
                    Text(performance.sizeText)
                    Text("")
                }
                GridRow {
                    Text("Expected")
                        .foregroundStyle(.secondary)
                    Text(DiagnosticReportBuilder.expectedText(result.expectedMaxMBps))
                    Text("")
                }
            }
            .font(.callout)

            ForEach(result.detailedFindings.filter { $0.severity != .good }) { finding in
                Label(
                    finding.message,
                    systemImage: finding.severity == .warning ? "exclamationmark.triangle.fill" : "info.circle.fill"
                )
                .font(.callout)
                .foregroundStyle(finding.severity == .warning ? Color.orange : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            DisclosureGroup("Technical Details") {
                technicalDetails(result)
                    .padding(.top, 10)
            }
            .font(.callout)
        } else if !performanceModel.isBusy {
            Text(performanceModel.performanceStatus)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func technicalDetails(_ result: NASDiagnosticResult) -> some View {
        VStack(spacing: 7) {
            DetailRow(label: "Status", value: result.mount.mountPath == nil ? "Not mounted" : "Connected")
            DetailRow(label: "Protocol", value: result.mount.protocolName)
            DetailRow(label: "Server", value: result.mount.server)
            DetailRow(label: "Share", value: result.mount.shareName)
            DetailRow(label: "Mount point", value: result.mount.mountPath ?? "Not mounted")
            DetailRow(label: "Connected using", value: result.mount.connectedUsing)
            DetailRow(label: "Resolved IP", value: result.mount.resolvedIP ?? "Unavailable")
            DetailRow(label: "Network", value: "\(result.network.type ?? "Unavailable") · \(result.network.speedText)")
            DetailRow(label: "Route target", value: result.network.target ?? "Unavailable")
            DetailRow(label: "Interface", value: result.network.interface ?? "Unavailable")
            DetailRow(label: "Local IP", value: result.network.localIP ?? "Unavailable")
            DetailRow(label: "MTU", value: result.network.mtu.map(String.init) ?? "Unavailable")
            DetailRow(label: "Duplex", value: result.network.duplex ?? "Unavailable")
            DetailRow(label: "Wi-Fi", value: result.network.wifi.text)

            if let smb = result.smb {
                DetailRow(label: "SMB dialect", value: smb.dialect ?? "Unavailable")
                DetailRow(label: "Multichannel enabled", value: smb.multichannelText)
                DetailRow(label: "Active channels", value: smb.channelSummary)
                DetailRow(label: "SMB bandwidth", value: diagnosticSpeed(smb.effectiveBandwidthMbps))
                DetailRow(label: "Session age", value: diagnosticDuration(result.sessionAge))
                DetailRow(label: "Signing", value: diagnosticFlag(smb.signing))
                DetailRow(label: "Encryption", value: diagnosticFlag(smb.encryption))

                ForEach(Array((smb.channels ?? []).enumerated()), id: \.offset) { index, channel in
                    DetailRow(
                        label: "Channel \(index + 1)",
                        value: "\(channel.interface ?? "Unavailable") · \(channel.serverIP ?? "Unavailable") · \(channel.state) · \(diagnosticNumber(channel.linkMbps, suffix: " Mb/s"))"
                    )
                }
            }

            DetailRow(
                label: "Most recent wake",
                value: result.lastWakeAt?.formatted(date: .abbreviated, time: .shortened) ?? "Unavailable"
            )

            if let performance = result.performance {
                DetailRow(label: "Test size", value: performance.sizeText)
                DetailRow(label: "Duration", value: diagnosticDuration(performance.duration))
                throughputTechnicalDetails("Write", performance.write, expected: result.expectedMaxMBps)
                throughputTechnicalDetails("Read", performance.read, expected: result.expectedMaxMBps)
            }

            DetailRow(label: "Minimum latency", value: diagnosticNumber(result.latency?.minimum, suffix: " ms"))
            DetailRow(label: "Average latency", value: diagnosticNumber(result.latency?.average, suffix: " ms"))
            DetailRow(label: "Maximum latency", value: diagnosticNumber(result.latency?.maximum, suffix: " ms"))
            DetailRow(label: "Packet loss", value: diagnosticNumber(result.latency?.loss, suffix: "%"))
        }
        .textSelection(.enabled)
    }

    private func throughputTechnicalDetails(
        _ label: String,
        _ throughput: ThroughputDiagnostic,
        expected: Double?
    ) -> some View {
        Group {
            DetailRow(label: "\(label) average", value: diagnosticNumber(throughput.averageMBps, suffix: " MB/s"))
            DetailRow(label: "\(label) utilization", value: diagnosticPercent(throughput.utilisation(expected: expected)))
            DetailRow(label: "\(label) minimum", value: diagnosticNumber(throughput.minimumMBps, suffix: " MB/s"))
            DetailRow(label: "\(label) maximum", value: diagnosticNumber(throughput.maximumMBps, suffix: " MB/s"))
            DetailRow(label: "\(label) variation", value: diagnosticPercent(throughput.variation.map { $0 * 100 }))
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            if let report {
                Image(systemName: "clock")
                    .font(.title3)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 3) {
                        Text("Checked")
                        Text(report.generatedAt, style: .relative)
                    }
                    .font(.callout)

                    if let runDuration {
                        Text("All checks completed in \(formattedDuration(runDuration)).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            if report?.hasRepairableItems == true {
                Button("Repair") {
                    attemptRepair()
                }
                .tahoeSecondaryActionButton()
                .disabled(isRunning || performanceModel.isBusy)
                .help("Reset retries and safely reconnect the share")
            }

            Button("Run Again") {
                runDoctor()
            }
            .tahoeSecondaryActionButton()
            .disabled(isRunning || performanceModel.isBusy)

            Button("Done") {
                dismiss()
            }
            .tahoePrimaryActionButton()
            .disabled(performanceModel.blocksDismissal)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(.bar)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    private var isConnected: Bool {
        appModel.monitor.status(for: currentShare) == .connected
    }

    private var shareMetadata: String {
        let server = currentShare.serverDisplayName(customNames: settings.preferences.serverNames)
        let connectionProtocol = NetworkShareProtocol(urlScheme: currentShare.url?.scheme)?.title ?? "Unknown protocol"
        let address = currentShare.host ?? "Unknown address"
        return [server, connectionProtocol, address].joined(separator: "  ·  ")
    }

    private var performanceSummary: String {
        if performanceModel.testing {
            return performanceModel.performanceStatus
        }
        if performanceModel.running {
            return performanceModel.status
        }
        if let performance = performanceModel.result?.performance {
            return "\(performance.sizeText) test complete"
        }
        return "Optional read and write test"
    }

    private var performanceConfirmationMessage: String {
        let size = pendingPerformanceBytes.map(performanceSizeText) ?? "selected"
        return "Otter will write and read a \(size) temporary file in its own unique folder on this share, then remove it. This uses network and storage bandwidth. NAS caching can affect the results."
    }

    private func performanceSizeText(_ bytes: Int64) -> String {
        String(format: "%.0f GB", Double(bytes) / 1_000_000_000)
    }

    private func askToRunPerformanceTest(gigabytes: Int64) {
        pendingPerformanceBytes = gigabytes * 1_000_000_000
        showPerformanceConfirmation = true
    }

    private func runPerformanceTest() {
        guard let bytes = pendingPerformanceBytes else { return }
        didCopyDetailedReport = false
        performanceModel.run(
            share: currentShare,
            service: appModel.mountService,
            performanceBytes: bytes
        )
        pendingPerformanceBytes = nil
    }

    private func copyDetailedReport(_ result: NASDiagnosticResult) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            DiagnosticReportBuilder.build(result, comparison: nil),
            forType: .string
        )
        didCopyDetailedReport = true
    }

    private func formattedDuration(_ duration: TimeInterval) -> String {
        let precision = duration < 10 ? 1 : 0
        return duration.formatted(.number.precision(.fractionLength(precision))) + " seconds"
    }

    private func runDoctor() {
        Task { await runDoctorNow(clearRepairResult: true) }
    }

    private func attemptRepair() {
        Task { await attemptRepairNow() }
    }

    @MainActor
    private func runDoctorNow(clearRepairResult: Bool = false) async {
        guard !isRunning else { return }
        isRunning = true
        didCopy = false
        if clearRepairResult {
            repairStep = nil
        }

        let startedAt = ContinuousClock.now
        let newReport = await appModel.connectionDoctor.run(for: currentShare, attemptMount: false)
        runDuration = interval(from: startedAt.duration(to: .now))
        report = newReport
        expandedDetails = []
        expandedCategories = Set(DiagnosticCategory.allCases.filter { category in
            newReport.steps.contains { category.contains($0) && $0.status.needsAttention }
        })
        isRunning = false
    }

    @MainActor
    private func attemptRepairNow() async {
        guard !isRunning else { return }
        isRunning = true
        didCopy = false
        repairStep = await appModel.connectionDoctor.attemptRepair(for: currentShare)

        let startedAt = ContinuousClock.now
        let newReport = await appModel.connectionDoctor.run(for: currentShare, attemptMount: false)
        runDuration = interval(from: startedAt.duration(to: .now))
        report = newReport
        expandedDetails = []
        expandedCategories = Set(DiagnosticCategory.allCases.filter { category in
            displayedSteps.contains { category.contains($0) && $0.status.needsAttention }
        })
        isRunning = false
    }

    private func interval(from duration: Duration) -> TimeInterval {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }

    private func copyReport() {
        guard let report else { return }
        let copiedReport: ConnectionDiagnosticReport
        if let repairStep {
            copiedReport = ConnectionDiagnosticReport(
                generatedAt: report.generatedAt,
                steps: [repairStep] + report.steps,
                hasRepairableItems: report.hasRepairableItems
            )
        } else {
            copiedReport = report
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copiedReport.redactedText, forType: .string)
        didCopy = true
    }
}

private enum DiagnosticCategory: String, CaseIterable, Identifiable {
    case configuration
    case network
    case connectivity

    var id: Self { self }

    var title: String {
        switch self {
        case .configuration: "Configuration"
        case .network: "Network"
        case .connectivity: "Connectivity"
        }
    }

    var symbol: String {
        switch self {
        case .configuration: "gearshape"
        case .network: "network"
        case .connectivity: "arrow.left.arrow.right"
        }
    }

    func contains(_ step: ConnectionDiagnosticStep) -> Bool {
        switch self {
        case .configuration:
            ["Share configuration", "Automatic mounting", "Keychain credentials"].contains(step.title)
        case .network:
            ["Network path", "Connection conditions", "Name resolution", "LAN address stability"].contains(step.title)
        case .connectivity:
            !DiagnosticCategory.configuration.contains(step) && !DiagnosticCategory.network.contains(step)
        }
    }

    func summary(for steps: [ConnectionDiagnosticStep]) -> String {
        let failures = steps.filter { $0.status == .failed }.count
        let warnings = steps.filter { $0.status == .warning }.count
        let information = steps.filter { $0.status == .information }.count

        if failures > 0 {
            let failureText = failures == 1 ? "1 failed" : "\(failures) failed"
            guard warnings > 0 else { return failures == 1 ? "1 check failed" : "\(failures) checks failed" }
            let warningText = warnings == 1 ? "1 needs attention" : "\(warnings) need attention"
            return "\(failureText) · \(warningText)"
        }
        if warnings > 0 {
            return warnings == 1 ? "1 check needs attention" : "\(warnings) checks need attention"
        }
        if information > 0 {
            let passed = steps.count - information
            return "\(passed) passed · \(information) informational"
        }
        return steps.count == 1 ? "1 check passed" : "\(steps.count) checks passed"
    }
}

private struct HealthSummary {
    let title: String
    let detail: String
    let symbol: String
    let color: Color

    init(steps: [ConnectionDiagnosticStep]) {
        let failures = steps.filter { $0.status == .failed }.count
        let warnings = steps.filter { $0.status == .warning }.count

        if failures > 0 {
            title = "Connection problems detected"
            let failureText = failures == 1 ? "1 diagnostic check failed" : "\(failures) diagnostic checks failed"
            let warningText = warnings == 0 ? "" : warnings == 1 ? " One more check needs attention." : " \(warnings) more checks need attention."
            detail = failureText + "." + warningText + " Review the details below."
            symbol = "xmark.circle.fill"
            color = .red
        } else if warnings > 0 {
            title = "Some checks need attention"
            detail = warnings == 1
                ? "1 diagnostic check needs attention. Review the details below."
                : "\(warnings) diagnostic checks need attention. Review the details below."
            symbol = "exclamationmark.triangle.fill"
            color = .orange
        } else {
            title = "Everything looks good"
            detail = "All \(steps.count) diagnostic checks completed without problems. Your share is configured correctly and ready to use."
            symbol = "checkmark.circle.fill"
            color = .green
        }
    }
}

private extension DiagnosticStepStatus {
    var needsAttention: Bool {
        self == .warning || self == .failed
    }

    var accessibilityName: String {
        switch self {
        case .passed: "Passed"
        case .warning: "Warning"
        case .failed: "Failed"
        case .information: "Information"
        }
    }

    var label: String {
        switch self {
        case .passed: "Passed"
        case .warning: "Warning"
        case .failed: "Failed"
        case .information: "Info"
        }
    }

    var symbol: String {
        switch self {
        case .passed:
            "checkmark.circle.fill"
        case .warning:
            "exclamationmark.triangle.fill"
        case .failed:
            "xmark.circle.fill"
        case .information:
            "info.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .passed:
            .green
        case .warning:
            .orange
        case .failed:
            .red
        case .information:
            .blue
        }
    }
}
