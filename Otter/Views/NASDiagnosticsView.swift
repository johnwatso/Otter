import AppKit
import Combine
import SwiftUI

struct NASDiagnosticsSection: View {
    let shares: [NetworkShare]
    var serverName: String?
    @State private var isPresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Diagnostics").font(.subheadline).fontWeight(.bold).foregroundStyle(.secondary)
            Text(shares.count > 1
                 ? "Check the network path, SMB connections, and performance of all \(shares.count) shares on this server."
                 : "Check the network path, SMB connection, and share performance.")
                .font(.caption).foregroundStyle(.secondary)
            Button { isPresented = true } label: {
                Label("Open Diagnostics", systemImage: "waveform.path.ecg")
            }
            .tahoeSecondaryActionButton()
            .disabled(shares.isEmpty)
        }
        .sheet(isPresented: $isPresented) { NASDiagnosticsView(shares: shares, title: serverName) }
    }
}

/// The diagnostics for every share in one sheet. Each share keeps its own
/// results while the user switches between them.
@MainActor
final class NASDiagnosticsSession: ObservableObject {
    let shares: [NetworkShare]
    @Published private(set) var runningAll = false
    private var models: [NetworkShare.ID: NASDiagnosticsViewModel] = [:]
    private var runAllTask: Task<Void, Never>?
    private var subscriptions: Set<AnyCancellable> = []

    init(shares: [NetworkShare], models provided: [NetworkShare.ID: NASDiagnosticsViewModel] = [:]) {
        self.shares = shares
        for share in shares {
            let model = provided[share.id] ?? NASDiagnosticsViewModel()
            models[share.id] = model
            // Busy state spans every share, so a change to one refreshes the sheet.
            model.objectWillChange
                .sink { [weak self] _ in self?.objectWillChange.send() }
                .store(in: &subscriptions)
        }
    }

    func model(for share: NetworkShare) -> NASDiagnosticsViewModel {
        models[share.id] ?? NASDiagnosticsViewModel()
    }

    /// Shares on one server travel the same network path, so an action on one
    /// share waits for work on any other to finish.
    var isBusy: Bool { runningAll || models.values.contains(where: \.isBusy) }
    var isCancellable: Bool { runningAll || models.values.contains { $0.running || $0.testing || $0.comparing } }
    var blocksDismissal: Bool { models.values.contains(where: \.blocksDismissal) }
    var hasResults: Bool { models.values.contains { $0.result != nil } }

    /// Checks each share in turn. Checking them concurrently would have their
    /// latency probes and SMB queries compete on the same path.
    func runAll(service: MountService) {
        guard !isBusy else { return }
        runningAll = true
        runAllTask = Task {
            for share in shares {
                guard !Task.isCancelled,
                      let task = model(for: share).run(share: share, service: service)
                else { break }
                await task.value
            }
            runningAll = false
            runAllTask = nil
        }
    }

    func serverReport() -> String {
        shares.compactMap { share in
            let shareModel = self.model(for: share)
            return shareModel.result.map { DiagnosticReportBuilder.build($0, comparison: shareModel.comparison) }
        }
        .joined(separator: "\n\n")
    }

    func cancel() {
        runAllTask?.cancel()
        models.values.forEach { $0.cancel() }
    }
}

@MainActor
final class NASDiagnosticsViewModel: ObservableObject {
    @Published var result: NASDiagnosticResult?
    @Published var status = "Ready to check this connection"
    @Published var running = false
    @Published var testing = false
    @Published var progress = 0.0
    @Published var performanceStatus = "Not tested"
    @Published var error: String?
    @Published var comparison: DiagnosticComparison?
    @Published var comparing = false
    @Published var restorationRequired = false
    @Published var restoring = false
    @Published var reconnecting = false
    private var task: Task<Void, Never>?

    var isBusy: Bool { running || testing || comparing || restoring || reconnecting }
    var blocksDismissal: Bool { testing || comparing || restoring || reconnecting }

    @discardableResult
    func run(share: NetworkShare, service: MountService) -> Task<Void, Never>? {
        guard !running, !testing, !comparing, !restoring else { return nil }
        running = true
        result = nil
        comparison = nil
        error = nil
        status = "Checking connection…"
        performanceStatus = "Not tested"
        task = Task {
            await NASDiagnosticsService().run(share: share, mountService: service) { [weak self] result, status in
                self?.result = result
                self?.status = status
            }
            if Task.isCancelled { status = "Diagnostics cancelled — partial results" }
            running = false
            task = nil
        }
        return task
    }

    func test(gigabytes: Int) {
        guard !running, !testing, !comparing, !restoring, let mount = result?.mount, mount.mountPath != nil else { return }
        testing = true
        progress = 0
        error = nil
        result?.performance = nil
        performanceStatus = "Preparing temporary file…"
        task = Task {
            do {
                let performance = try await SharePerformanceTester().test(mount: mount, gigabytes: gigabytes) { [weak self] value, label in
                    self?.progress = value
                    self?.performanceStatus = label
                }
                result?.performance = performance
                performanceStatus = "Performance test complete"
            } catch is CancellationError {
                performanceStatus = "Performance test cancelled"
            } catch {
                self.error = error.localizedDescription
                performanceStatus = "Performance test could not finish"
            }
            testing = false
            task = nil
        }
    }

    func compare(kind: DiagnosticComparisonKind, share: NetworkShare, service: MountService, monitor: ShareMonitor) {
        guard !running, !testing, !comparing, !restoring, !restorationRequired, let before = result else { return }
        let target = kind == .ipAddress ? before.mount.resolvedIP.flatMap { NASDiagnosticsService.temporaryIPURL(share: share, address: $0) } : nil
        comparing = true
        comparison = nil
        error = nil
        task = Task {
            let outcome = await DiagnosticComparisonService.run(before: before, kind: kind, targetURL: target,
                reconnect: { url in await monitor.remountForMaintenance(share, diagnosticURL: url) },
                collect: {
                    var collected: NASDiagnosticResult?
                    await NASDiagnosticsService().run(share: share, mountService: service) { value, label in
                        collected = value
                        self.status = label
                    }
                    try Task.checkCancellation()
                    guard let collected else { throw CancellationError() }
                    return collected
                }, benchmark: { mount, size in
                    self.testing = true
                    self.progress = 0
                    defer { self.testing = false }
                    return try await SharePerformanceTester().test(mount: mount, gigabytes: size) { value, label in
                        self.progress = value
                        self.performanceStatus = label
                    }
                }, status: { self.status = $0 })
            comparison = outcome.comparison
            result = outcome.current ?? (outcome.error == nil ? before : nil)
            error = outcome.error
            restorationRequired = outcome.restorationRequired
            status = outcome.error == nil ? "Comparison complete" : "Comparison stopped"
            comparing = false
            task = nil
        }
    }

    func restore(share: NetworkShare, service: MountService, monitor: ShareMonitor) {
        guard !running, !testing, !comparing, !restoring else { return }
        restoring = true
        status = "Restoring the configured connection…"
        error = nil
        task = Task {
            let reconnected = await monitor.remountForMaintenance(share)
            if reconnected {
                await NASDiagnosticsService().run(share: share, mountService: service) { value, label in
                    self.result = value
                    self.status = label
                }
            }
            let restored = reconnected && result?.isComplete == true && result?.mount.mountPath != nil && result?.mount.connectedUsing == "Hostname"
            restorationRequired = !restored
            comparison?.originalConnectionRestored = restored
            if !restored { error = "The configured hostname connection could not be verified. Close files on the share and retry restoration. Your saved server address is unchanged." }
            restoring = false
            task = nil
        }
    }

    func cancel() {
        guard !restoring else { return }
        task?.cancel()
        if testing { performanceStatus = "Cancelling — waiting for current I/O and cleanup…" }
    }
}

/// Diagnostics for one share, or for every share on a server in one sheet: a
/// single run checks each share, and an overview switches between results.
struct NASDiagnosticsView: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var session: NASDiagnosticsSession
    @State private var selectedShareID: NetworkShare.ID?
    @State private var copiedServerReport = false
    private let title: String?

    @MainActor
    init(shares: [NetworkShare], title: String? = nil) {
        self.title = title
        _session = StateObject(wrappedValue: NASDiagnosticsSession(shares: shares))
        _selectedShareID = State(initialValue: shares.first?.id)
    }

    @MainActor
    init(share: NetworkShare, model: NASDiagnosticsViewModel? = nil) {
        title = nil
        _session = StateObject(wrappedValue: NASDiagnosticsSession(shares: [share], models: model.map { [share.id: $0] } ?? [:]))
        _selectedShareID = State(initialValue: share.id)
    }

    private var shares: [NetworkShare] { session.shares }
    private var coversServer: Bool { shares.count > 1 }
    private var selectedShare: NetworkShare? { shares.first { $0.id == selectedShareID } ?? shares.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading) {
                    Text("NAS Diagnostics").font(.title2.bold())
                    Text(subtitle).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                    .disabled(session.blocksDismissal)
            }
            if coversServer { shareOverview }
            if let share = selectedShare {
                NASShareDiagnosticsPanel(share: share, model: session.model(for: share), busy: session.isBusy)
                    .id(share.id)
            }
            HStack {
                Button(coversServer ? "Run Diagnostics on All Shares" : "Run Diagnostics") {
                    copiedServerReport = false
                    session.runAll(service: appModel.mountService)
                }
                .tahoePrimaryActionButton().disabled(session.isBusy)
                if session.isCancellable { Button("Cancel") { session.cancel() }.tahoeSecondaryActionButton() }
                Spacer()
                if coversServer {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(session.serverReport(), forType: .string)
                        copiedServerReport = true
                    } label: {
                        Label(copiedServerReport ? "Copied" : "Copy Server Report", systemImage: copiedServerReport ? "checkmark" : "doc.on.doc")
                    }
                    .tahoeSecondaryActionButton()
                    .disabled(!session.hasResults)
                }
            }
        }
        .padding(20)
        .frame(width: 620)
        .frame(minHeight: 420, idealHeight: 680, maxHeight: 680)
        .interactiveDismissDisabled(session.blocksDismissal)
        .background(Color(NSColor.windowBackgroundColor))
        .onDisappear { session.cancel() }
    }

    private var subtitle: String {
        guard coversServer else { return shares.first?.displayName ?? "" }
        return "\(title ?? shares.first?.serverDisplayName ?? "Server") · \(shares.count) shares"
    }

    private var shareOverview: some View {
        VStack(spacing: 2) {
            ForEach(shares) { share in
                let model = session.model(for: share)
                let isSelected = share.id == selectedShare?.id
                Button { selectedShareID = share.id } label: {
                    HStack(spacing: 8) {
                        Text(share.displayName)
                            .font(.subheadline.weight(isSelected ? .semibold : .regular))
                        Spacer()
                        if model.isBusy { ProgressView().controlSize(.mini) }
                        Text(model.running ? "Checking…" : (model.result?.health.state.rawValue ?? "Not checked"))
                            .font(.subheadline)
                            .foregroundStyle(model.running ? Color.secondary : (model.result?.health.state.color ?? Color.secondary))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private extension ConnectionHealthState {
    var color: Color {
        switch self {
        case .good: .green
        case .incomplete: .secondary
        case .needsAttention, .potentialBottleneck: .orange
        }
    }
}

private struct NASShareDiagnosticsPanel: View {
    let share: NetworkShare
    @ObservedObject var model: NASDiagnosticsViewModel
    /// True while diagnostics for any share on the server are working.
    let busy: Bool
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var monitor: ShareMonitor
    @State private var gigabytes = 1
    @State private var showPerformanceConfirmation = false
    @State private var copied = false
    @State private var pendingComparison: DiagnosticComparisonKind?
    @State private var confirmComparison = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        if model.running || model.comparing || model.restoring { ProgressView().controlSize(.small) }
                        Text(model.status).font(.subheadline).foregroundStyle(.secondary)
                    }
                    if let result = model.result {
                        summary(result)
                        DisclosureGroup("Show Details") { details(result).padding(.top, 8) }
                        Divider()
                        performance(result)
                        Divider()
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Findings").font(.headline)
                            ForEach(result.detailedFindings) { finding in
                                Label(finding.message, systemImage: finding.severity == .good ? "checkmark.circle" : (finding.severity == .warning ? "exclamationmark.triangle" : "info.circle"))
                                    .foregroundStyle(finding.severity == .warning ? Color.orange : (finding.severity == .good ? Color.green : Color.secondary))
                                    .font(.callout).textSelection(.enabled)
                            }
                            if result.findings.isEmpty {
                                Text("No obvious issues found in the available measurements. This does not rule out NAS storage or session limitations.").foregroundStyle(.secondary)
                            }
                        }
                        Divider()
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Troubleshooting")
                                .font(.headline)

                            LazyVGrid(
                                columns: [
                                    GridItem(.flexible(), spacing: 10),
                                    GridItem(.flexible(), spacing: 10)
                                ],
                                alignment: .leading,
                                spacing: 10
                            ) {
                                troubleshootingButton("Reconnect Share", systemImage: "arrow.clockwise") {
                                    reconnect()
                                }
                                .disabled(busy)

                                troubleshootingButton("Compare After Reconnect", systemImage: "arrow.left.arrow.right") {
                                    pendingComparison = .reconnect
                                    confirmComparison = true
                                }
                                .disabled(busy || !result.isComplete || result.mount.mountPath == nil || model.restorationRequired)

                                if result.mount.connectedUsing == "Hostname", let address = result.mount.resolvedIP,
                                   NASDiagnosticsService.temporaryIPURL(share: share, address: address) != nil {
                                    troubleshootingButton("Compare Using IP Address", systemImage: "network") {
                                        pendingComparison = .ipAddress
                                        confirmComparison = true
                                    }
                                    .disabled(busy || !result.isComplete || model.restorationRequired)
                                }

                                troubleshootingButton(
                                    copied ? "Copied" : "Copy Diagnostic Report",
                                    systemImage: copied ? "checkmark" : "doc.on.doc"
                                ) {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(DiagnosticReportBuilder.build(result, comparison: model.comparison), forType: .string)
                                    copied = true
                                }
                            }

                            if result.mount.connectedUsing == "Hostname", let address = result.mount.resolvedIP,
                               NASDiagnosticsService.temporaryIPURL(share: share, address: address) != nil {
                                Label("Direct-IP comparison uses \(address) temporarily, then restores the configured connection.", systemImage: "info.circle")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text("Reports include server names and local IP addresses. Review before sharing.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Run a short check to understand this share’s connection. Performance testing is optional and starts separately.").foregroundStyle(.secondary)
                    }
                    if let comparison = model.comparison { comparisonView(comparison) }
                    if model.restorationRequired {
                        Button {
                            model.restore(share: share, service: appModel.mountService, monitor: monitor)
                        } label: {
                            Label("Restore Configured Connection", systemImage: "arrow.uturn.backward")
                        }
                        .tahoeSecondaryActionButton()
                        .disabled(busy)
                    }
                    if let error = model.error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onChange(of: model.running) { _, running in
            if running { copied = false }
        }
        .alert("Test Share Performance?", isPresented: $showPerformanceConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Start Test") { model.test(gigabytes: gigabytes) }
        } message: {
            Text("Otter will write and read a \(gigabytes) GB temporary file in its own unique folder on this share, then remove it. This uses network and storage bandwidth. NAS caching can affect the results.")
        }
        .alert(pendingComparison?.rawValue ?? "Compare Connection", isPresented: $confirmComparison) {
            Button("Cancel", role: .cancel) { }
            Button("Start Comparison") {
                if let kind = pendingComparison { copied = false; model.compare(kind: kind, share: share, service: appModel.mountService, monitor: monitor) }
            }
        } message: {
            Text("Otter will safely reconnect this share and repeat diagnostics. " + (model.result?.performance.map { "It will also repeat the \($0.sizeText) temporary-file performance test and remove the file. " } ?? "No performance test will run because the baseline was not tested. ") + (pendingComparison == .ipAddress ? "The configured hostname connection will be restored when finished, including after cancellation." : "Open files may prevent reconnecting."))
        }
    }

    private func comparisonView(_ comparison: DiagnosticComparison) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(comparison.kind.rawValue).font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                GridRow { Text("Measurement"); Text(comparison.kind == .ipAddress ? "Hostname" : "Before"); Text(comparison.kind == .ipAddress ? "IP" : "After") }.fontWeight(.semibold)
                ForEach(comparison.rows) { row in GridRow { Text(row.label); Text(row.before); Text(row.after) } }
            }.font(.subheadline)
            ForEach(comparison.interpretations, id: \.self) { Text($0).font(.callout).foregroundStyle(.secondary) }
            if let restored = comparison.originalConnectionRestored { Text(restored ? "Configured connection restored." : "Configured connection needs restoration.").font(.caption) }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(DiagnosticReportBuilder.build(comparison.after, comparison: comparison), forType: .string)
            } label: {
                Label("Copy Comparison Report", systemImage: "doc.on.doc")
            }
            .tahoeSecondaryActionButton()
        }.textSelection(.enabled)
    }

    private func summary(_ r: NASDiagnosticResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Connection Health").font(.headline)
            Text(r.health.state.rawValue).font(.title3.weight(.semibold))
                .foregroundStyle(r.health.state.color)
            Text(r.health.explanation).font(.callout).foregroundStyle(.secondary)
            DetailRow(label: "Network", value: "\(r.network.type ?? "Unavailable") · \(r.network.speedText)")
            if r.mount.protocolName == "SMB" {
                DetailRow(label: "SMB", value: "\(r.smb?.dialect ?? "Unavailable") · \(r.smb?.channelSummary ?? "Channels unavailable")")
            }
            DetailRow(label: "Latency", value: diagnosticNumber(r.latency?.average, suffix: " ms"))
        }
    }

    private func details(_ r: NASDiagnosticResult) -> some View {
        VStack(spacing: 7) {
            DetailRow(label: "Status", value: r.mount.mountPath == nil ? "Not mounted" : "Connected")
            DetailRow(label: "Protocol", value: r.mount.protocolName)
            DetailRow(label: "Server", value: r.mount.server)
            DetailRow(label: "Resolved IP", value: r.mount.resolvedIP ?? "Unavailable")
            DetailRow(label: "Connected using", value: r.mount.connectedUsing)
            DetailRow(label: "Share", value: r.mount.shareName)
            DetailRow(label: "Mount point", value: r.mount.mountPath ?? "Not mounted")
            DetailRow(label: "Route target", value: r.network.target ?? "Unavailable")
            DetailRow(label: "Interface", value: r.network.interface ?? "Unavailable")
            DetailRow(label: "Local IP", value: r.network.localIP ?? "Unavailable")
            DetailRow(label: "MTU", value: r.network.mtu.map(String.init) ?? "Unavailable")
            DetailRow(label: "Duplex", value: r.network.duplex ?? "Unavailable")
            DetailRow(label: "Wi-Fi", value: r.network.wifi.text)
            if let smb = r.smb {
                DetailRow(label: "Multichannel enabled", value: smb.multichannelText)
                DetailRow(label: "Effective SMB bandwidth", value: diagnosticSpeed(smb.effectiveBandwidthMbps))
                DetailRow(label: "Session age", value: diagnosticDuration(r.sessionAge))
                DetailRow(label: "Signing", value: diagnosticFlag(smb.signing))
                DetailRow(label: "Encryption", value: diagnosticFlag(smb.encryption))
                DetailRow(label: "Active channels", value: smb.channels.map { String($0.filter(\.isActive).count) } ?? "Unavailable")
                ForEach(Array((smb.channels ?? []).enumerated()), id: \.offset) { index, channel in
                    DetailRow(label: "Channel \(index + 1)", value: "\(channel.interface ?? "Unavailable") · \(channel.serverIP ?? "Unavailable") · \(channel.state) · \(diagnosticNumber(channel.linkMbps, suffix: " Mb/s"))")
                }
            }
            DetailRow(label: "Most recent wake", value: r.lastWakeAt?.formatted(date: .abbreviated, time: .shortened) ?? "Unavailable")
            if r.sessionPredatesWake == true {
                Text("SMB session predates the most recent system wake. This is context, not evidence of a fault.").font(.caption).foregroundStyle(.secondary)
            }
            if let p = r.performance {
                DetailRow(label: "Test size", value: p.sizeText)
                DetailRow(label: "Duration", value: diagnosticDuration(p.duration))
                throughputDetails("Read", p.read, expected: r.expectedMaxMBps)
                throughputDetails("Write", p.write, expected: r.expectedMaxMBps)
            }
            DetailRow(label: "Minimum latency", value: diagnosticNumber(r.latency?.minimum, suffix: " ms"))
            DetailRow(label: "Maximum latency", value: diagnosticNumber(r.latency?.maximum, suffix: " ms"))
            DetailRow(label: "Packet loss", value: diagnosticNumber(r.latency?.loss, suffix: "%"))
        }.textSelection(.enabled)
    }

    private func performance(_ r: NASDiagnosticResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Share Performance").font(.headline)
            if let p = r.performance {
                DetailRow(label: "Expected maximum", value: DiagnosticReportBuilder.expectedText(r.expectedMaxMBps))
                DetailRow(label: "Write", value: diagnosticNumber(p.writeMBps, suffix: " MB/s") + " · " + diagnosticPercent(p.write.utilisation(expected: r.expectedMaxMBps)) + " utilisation")
                DetailRow(label: "Read", value: diagnosticNumber(p.readMBps, suffix: " MB/s") + " · " + diagnosticPercent(p.read.utilisation(expected: r.expectedMaxMBps)) + " utilisation")
                Text(p.cacheBypass ? "Client cache bypass requested. NAS caches may still influence results." : "Client cache bypass is unavailable; cached data may inflate results.")
                    .font(.caption).foregroundStyle(.secondary)
            } else { Text(model.performanceStatus).font(.callout).foregroundStyle(.secondary) }
            if model.testing { Text(model.performanceStatus).font(.caption); ProgressView(value: model.progress) }
            HStack {
                Picker("Test size", selection: $gigabytes) {
                    ForEach(1...5, id: \.self) { Text("\($0) GB").tag($0) }
                }.frame(width: 180).disabled(busy)
                Button("Test Share Performance") { showPerformanceConfirmation = true }
                    .tahoeSecondaryActionButton().disabled(busy || r.mount.mountPath == nil)
            }
            Text("Creates a temporary file on the share and removes it when finished. Cancellation waits for any pending network I/O before cleanup.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func throughputDetails(_ label: String, _ t: ThroughputDiagnostic, expected: Double?) -> some View {
        VStack(spacing: 7) {
            DetailRow(label: "\(label) average", value: diagnosticNumber(t.averageMBps, suffix: " MB/s"))
            DetailRow(label: "\(label) utilisation", value: diagnosticPercent(t.utilisation(expected: expected)))
            DetailRow(label: "\(label) minimum", value: diagnosticNumber(t.minimumMBps, suffix: " MB/s"))
            DetailRow(label: "\(label) maximum", value: diagnosticNumber(t.maximumMBps, suffix: " MB/s"))
            DetailRow(label: "\(label) variation", value: diagnosticPercent(t.variation.map { $0 * 100 }))
        }
    }

    private func troubleshootingButton(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)
        }
        .tahoeSecondaryActionButton()
    }

    private func reconnect(url: URL? = nil) {
        model.reconnecting = true
        Task {
            let success = await monitor.remountForMaintenance(share, diagnosticURL: url)
            model.reconnecting = false
            if success {
                model.run(share: share, service: appModel.mountService)
            }
            else { model.error = "The share is busy or another connection check is running. Close open files or wait briefly, then try again." }
        }
    }
}
