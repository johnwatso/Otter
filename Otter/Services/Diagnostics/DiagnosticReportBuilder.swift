import Foundation

enum DiagnosticReportBuilder {
    static func build(_ result: NASDiagnosticResult, comparison: DiagnosticComparison? = nil) -> String {
        let m = result.mount, n = result.network
        var lines = ["Otter Network Diagnostics", "Generated: \(result.generatedAt.ISO8601Format())",
                     "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)",
                     "Otter: \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unavailable")",
                     "", "Connection Health", result.health.state.rawValue, result.health.explanation,
                     "", "Server", "Address: \(m.server)", "Protocol: \(m.protocolName)", "Share: \(m.shareName)",
                     "Mount point: \(m.mountPath ?? "Not mounted")", "Connected using: \(m.connectedUsing)", "Resolved IP: \(m.resolvedIP ?? "Unavailable")",
                     "", "Network", "Interface: \(n.interface ?? "Unavailable")", "Type: \(n.type ?? "Unavailable")", "Local IP: \(n.localIP ?? "Unavailable")",
                     "Link speed: \(n.speedText)", "MTU: \(n.mtu.map(String.init) ?? "Unavailable")", "Duplex: \(n.duplex ?? "Unavailable")",
                     "Route target: \(n.target ?? "Unavailable")", "Verified SMB endpoint: \(n.targetIsSessionAddress ? "Yes" : "No")", "Wi-Fi: \(n.wifi.text)"]
        if let s = result.smb {
            lines += ["", "SMB", "Dialect: \(s.dialect ?? "Unavailable")", "Signing: \(diagnosticFlag(s.signing))", "Encryption: \(diagnosticFlag(s.encryption))",
                      "Multichannel Enabled: \(s.multichannelText)", "Active Channels: \(s.activeChannelCount.map(String.init) ?? "Unavailable")",
                      "Effective SMB Bandwidth: \(diagnosticSpeed(s.effectiveBandwidthMbps))", "Session Age: \(diagnosticDuration(result.sessionAge))"]
            for channel in s.channels ?? [] {
                lines.append("Channel: \(channel.interface ?? "Unavailable") · \(channel.serverIP ?? "Unavailable") · \(channel.state) · \(diagnosticNumber(channel.linkMbps, suffix: " Mb/s"))")
            }
        }
        lines += ["", "Sleep / Wake", "Most recent system wake: \(result.lastWakeAt?.ISO8601Format() ?? "Unavailable")"]
        if result.sessionPredatesWake == true { lines.append("SMB session predates the most recent system wake. This is context, not evidence of a fault.") }
        lines += ["", "Latency", "Average: \(diagnosticNumber(result.latency?.average, suffix: " ms"))", "Min: \(diagnosticNumber(result.latency?.minimum, suffix: " ms"))",
                  "Max: \(diagnosticNumber(result.latency?.maximum, suffix: " ms"))", "Loss: \(diagnosticNumber(result.latency?.loss, suffix: "%"))", "", "Performance",
                  "Expected Maximum: \(expectedText(result.expectedMaxMBps))"]
        if let p = result.performance {
            lines += ["Test Size: \(p.sizeText)", "Duration: \(diagnosticDuration(p.duration))"]
            lines += throughputLines("Write", p.write, expected: result.expectedMaxMBps)
            lines += throughputLines("Read", p.read, expected: result.expectedMaxMBps)
            lines += ["", "Client Cache Bypass: \(p.cacheBypass ? "Enabled" : "Unavailable")", "NAS caches may influence results."]
        } else { lines.append("Not tested") }
        lines += ["", "Findings"] + result.detailedFindings.map { "- [\($0.severity.rawValue)] \($0.message)" }
        if let comparison {
            lines += ["", comparison.kind.rawValue, "Before: \(comparison.before.generatedAt.ISO8601Format())", "After: \(comparison.after.generatedAt.ISO8601Format())",
                      "Before address: \(comparison.before.mount.server)", "After address: \(comparison.after.mount.server)",
                      "Before test size: \(comparison.before.performance?.sizeText ?? "Not tested")", "After test size: \(comparison.after.performance?.sizeText ?? "Not tested")"]
            lines += comparison.rows.map { "\($0.label): \($0.before) → \($0.after)" }
            lines += comparison.interpretations
            if let restored = comparison.originalConnectionRestored { lines.append("Configured connection restored: \(restored ? "Yes" : "No — retry restoration")") }
        }
        // Only allowlisted model fields: no raw URLs, tool output, credentials, or errors.
        return lines.joined(separator: "\n")
    }
    static func expectedText(_ value: Double?) -> String {
        value.map { String(format: "~%.0f MB/s", $0) } ?? "Unavailable"
    }
    private static func throughputLines(_ label: String, _ t: ThroughputDiagnostic, expected: Double?) -> [String] {
        ["", label, "Average: \(diagnosticNumber(t.averageMBps, suffix: " MB/s"))", "Minimum: \(diagnosticNumber(t.minimumMBps, suffix: " MB/s"))",
         "Maximum: \(diagnosticNumber(t.maximumMBps, suffix: " MB/s"))", "Utilisation: \(diagnosticPercent(t.utilisation(expected: expected)))",
         "Variation: \(diagnosticPercent(t.variation.map { $0 * 100 }))", "Significant drops: \(t.rates.count >= 6 ? String(t.significantDrops) : "Unavailable — short sample")"]
    }
}
