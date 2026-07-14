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

    private var currentShare: NetworkShare {
        settings.share(id: share.id) ?? share
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "stethoscope")
                    .font(.title2)
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Connection Doctor")
                        .font(.title3.bold())
                    Text(currentShare.displayName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isRunning {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(16)

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
            } else {
                ContentUnavailableView {
                    Label("Ready to Check", systemImage: "stethoscope")
                } description: {
                    Text("Otter will check the network, conditions, credentials, SMB reachability, and mounted-volume health.")
                }
            }

            Divider()

            VStack(spacing: 12) {
                HStack {
                    Button {
                        copyReport()
                    } label: {
                        Label(didCopy ? "Copied" : "Copy Report", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                    }
                    .tahoeSecondaryActionButton()
                    .disabled(report == nil)
                    .help("Copy redacted diagnostics")

                    Button {
                        runDoctor()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .tahoeSecondaryActionButton()
                    .disabled(isRunning)
                    .help("Run diagnostics again")

                    Spacer()

                    if report?.hasRepairableItems == true {
                        Button {
                            attemptRepair()
                        } label: {
                            Label("Attempt Repair", systemImage: "wrench.and.screwdriver")
                        }
                        .tahoeSecondaryActionButton()
                        .disabled(isRunning)
                        .help("Reset retries and safely reconnect the share")
                    }

                    Button {
                        dismiss()
                    } label: {
                        Label("Done", systemImage: "checkmark")
                    }
                    .tahoePrimaryActionButton()
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
        }
        .frame(width: 560, height: 540)
        .task {
            await runDoctorNow()
        }
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

            VStack(alignment: .leading, spacing: 2) {
                Text(step.title)
                    .font(.system(size: 13, weight: .semibold))
                Text(step.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 3)
    }
}

private extension DiagnosticStepStatus {
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
