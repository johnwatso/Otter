import AppKit
import SwiftUI

struct ConnectionDoctorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var settings: SettingsStore

    let share: NetworkShare

    @State private var report: ConnectionDiagnosticReport?
    @State private var repairStep: ConnectionDiagnosticStep?
    @State private var isRunning = false
    @State private var didCopy = false
    @State private var isShowingAdvanced = false

    private var currentShare: NetworkShare {
        settings.share(id: share.id) ?? share
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Diagnose")
                        .font(.title2.weight(.semibold))
                    Text(summaryText)
                        .font(.subheadline)
                        .foregroundStyle(summaryColor)
                }
                Spacer()
                if isRunning {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            Divider()

            if let report {
                List {
                    if let repairStep {
                        Section("Repair") {
                            diagnosticRow(repairStep)
                        }
                    }

                    Section("Checks") {
                        ForEach(report.steps) { step in
                            diagnosticRow(step)
                        }
                    }
                }
                .listStyle(.inset)
                .frame(maxHeight: .infinity)
            } else if isRunning {
                VStack(spacing: 12) {
                    ProgressView()
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

            Divider()

            HStack(spacing: 12) {
                Menu {
                    Button {
                        copyReport()
                    } label: {
                        Label(didCopy ? "Copied" : "Copy Report", systemImage: "doc.on.doc")
                    }
                    .disabled(report == nil)

                    Button {
                        runDoctor()
                    } label: {
                        Label("Run Again", systemImage: "arrow.clockwise")
                    }
                    .disabled(isRunning)

                    Divider()

                    Button {
                        isShowingAdvanced = true
                    } label: {
                        Label("Advanced Diagnostics…", systemImage: "waveform.path.ecg")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More")

                Spacer()

                if report?.hasRepairableItems == true {
                    Button("Repair") {
                        attemptRepair()
                    }
                    .tahoeSecondaryActionButton()
                    .disabled(isRunning)
                    .help("Reset retries and safely reconnect the share")
                }

                Button("Done") {
                    dismiss()
                }
                .tahoePrimaryActionButton()
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 520, height: 520)
        .task {
            await runDoctorNow()
        }
        .sheet(isPresented: $isShowingAdvanced) {
            NASDiagnosticsView(
                shares: NetworkShareServerGroup.diagnosticShares(containing: currentShare, in: settings.shares),
                title: nil
            )
        }
    }

    private var summaryText: String {
        guard let report else { return isRunning ? "Checking \(currentShare.displayName)…" : currentShare.displayName }
        let problems = report.steps.filter { $0.status == .failed || $0.status == .warning }.count
        if problems == 0 { return "Everything looks good" }
        return problems == 1 ? "1 thing needs attention" : "\(problems) things need attention"
    }

    private var summaryColor: Color {
        guard let report else { return .secondary }
        if report.steps.contains(where: { $0.status == .failed }) { return .red }
        if report.steps.contains(where: { $0.status == .warning }) { return .orange }
        return .green
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
        report = await appModel.connectionDoctor.run(for: currentShare, attemptMount: false)
        isRunning = false
    }

    @MainActor
    private func attemptRepairNow() async {
        guard !isRunning else { return }
        isRunning = true
        didCopy = false
        repairStep = await appModel.connectionDoctor.attemptRepair(for: currentShare)
        report = await appModel.connectionDoctor.run(for: currentShare, attemptMount: false)
        isRunning = false
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

    private func diagnosticRow(_ step: ConnectionDiagnosticStep) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: step.status.symbol)
                .foregroundStyle(step.status.color)
                .frame(width: 18)
                .accessibilityLabel(step.status.accessibilityName)

            VStack(alignment: .leading, spacing: 2) {
                Text(step.title)
                    .font(.body.weight(.semibold))
                Text(step.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}

private extension DiagnosticStepStatus {
    var accessibilityName: String {
        switch self {
        case .passed: "Passed"
        case .warning: "Warning"
        case .failed: "Failed"
        case .information: "Information"
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
