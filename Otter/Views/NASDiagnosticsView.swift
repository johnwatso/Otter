import AppKit
import SwiftUI

struct NASDiagnosticsSection: View {
    let shares: [NetworkShare]
    @State private var selectedShare: NetworkShare?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Diagnostics").font(.subheadline).fontWeight(.bold).foregroundStyle(.secondary)
            Text("Check the network path, SMB connection, and share performance.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(shares) { share in
                Button { selectedShare = share } label: {
                    Label(shares.count > 1 ? "Diagnose \(share.displayName)" : "Open Diagnostics", systemImage: "waveform.path.ecg")
                }
                .tahoeSecondaryActionButton()
            }
        }
        .sheet(item: $selectedShare) { share in NASDiagnosticsView(share: share) }
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
    private var task: Task<Void, Never>?

    func run(share: NetworkShare, service: MountService) {
        guard !running, !testing, !comparing, !restoring else { return }
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

struct NASDiagnosticsView: View {
    let share: NetworkShare
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var monitor: ShareMonitor
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = NASDiagnosticsViewModel()
    @State private var gigabytes = 1
    @State private var showPerformanceConfirmation = false
    @State private var copied = false
    @State private var reconnecting = false
    @State private var pendingComparison: DiagnosticComparisonKind?
    @State private var confirmComparison = false

    @MainActor
    init(share: NetworkShare, model: NASDiagnosticsViewModel? = nil) {
        self.share = share
        _model = StateObject(wrappedValue: model ?? NASDiagnosticsViewModel())
    }

    private var busy: Bool { model.running || model.testing || model.comparing || model.restoring || reconnecting }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading) {
                    Text("NAS Diagnostics").font(.title2.bold())
                    Text(share.displayName).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                    .disabled(model.testing || model.comparing || model.restoring || reconnecting)
            }
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
            HStack {
                Button("Run Diagnostics") { copied = false; model.run(share: share, service: appModel.mountService) }
                    .tahoePrimaryActionButton().disabled(busy)
                if model.running || model.testing || model.comparing { Button("Cancel") { model.cancel() }.tahoeSecondaryActionButton() }
                Spacer()
            }
        }
        .padding(20)
        .frame(width: 620)
        .frame(minHeight: 420, idealHeight: 680, maxHeight: 680)
        .interactiveDismissDisabled(model.testing || model.comparing || model.restoring || reconnecting)
        .background(Color(NSColor.windowBackgroundColor))
        .onDisappear { model.cancel() }
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
                .foregroundStyle(r.health.state == .good ? Color.green : (r.health.state == .incomplete ? Color.secondary : Color.orange))
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
        reconnecting = true
        Task {
            let success = await monitor.remountForMaintenance(share, diagnosticURL: url)
            reconnecting = false
            if success {
                model.run(share: share, service: appModel.mountService)
            }
            else { model.error = "The share is busy or another connection check is running. Close open files or wait briefly, then try again." }
        }
    }
}
