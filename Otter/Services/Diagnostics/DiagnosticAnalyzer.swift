import Foundation

enum DiagnosticAnalyzer {
    static func findings(_ result: NASDiagnosticResult) -> [String] { detailedFindings(result).map(\.message) }

    static func health(_ r: NASDiagnosticResult) -> ConnectionHealthSummary {
        guard r.isComplete, r.mount.mountPath != nil, r.network.interface != nil,
              r.mount.protocolName != "SMB" || (r.smb?.dialect != nil && (r.smb?.activeChannelCount ?? 0) > 0) else {
            return .init(state: .incomplete, explanation: "Some connection measurements are missing or still running. Available results are shown below.")
        }
        if (r.latency?.loss ?? 0) >= 25 || r.detailedFindings.contains(where: { $0.id.hasSuffix("-low") || $0.id.hasSuffix("-below-gigabit") }) {
            return .init(state: .needsAttention, explanation: "Some measurements warrant a closer look. Review the findings before drawing conclusions about the cause.")
        }
        if r.detailedFindings.contains(where: { $0.severity == .warning }) {
            return .init(state: .potentialBottleneck, explanation: "The measurements suggest a possible performance limitation. The findings identify what is worth investigating.")
        }
        guard let p = r.performance, let expected = r.expectedMaxMBps, r.latency?.average != nil else {
            return .init(state: .incomplete, explanation: "Available connection checks show no clear fault. A performance test and link measurements are needed to assess throughput.")
        }
        if max(p.readMBps, p.writeMBps) > expected * 1.15 {
            return .init(state: .incomplete, explanation: "Measured throughput exceeds the estimated link capacity. Caching or incomplete link information may affect this comparison.")
        }
        return .init(state: .good, explanation: "Performance is within a plausible range for the active \(diagnosticSpeed(r.smb?.effectiveBandwidthMbps ?? r.network.linkMbps)) connection. No clear problem was found in the available measurements.")
    }

    static func detailedFindings(_ r: NASDiagnosticResult) -> [DiagnosticFinding] {
        var findings: [DiagnosticFinding] = []
        func add(_ id: String, _ severity: DiagnosticFindingSeverity, _ message: String) {
            findings.append(.init(id: id, severity: severity, message: message))
        }
        if r.mount.mountPath == nil { add("unmounted", .info, "The share is not mounted. Connect it before checking SMB or testing performance.") }
        if let p = r.performance {
            if let expected = r.expectedMaxMBps {
                // A link ceiling is an upper bound, not an expectation. Only up to
                // about 1 Gb/s should a NAS be expected to saturate the network;
                // beyond it the disks normally set the pace, so falling short of
                // the ceiling is ordinary rather than a fault worth flagging.
                let link = r.smb?.effectiveBandwidthMbps ?? r.network.linkMbps
                let fasterThanGigabit = (link ?? 0) > 1200
                let gigabitEquivalent = 118.0
                for (label, measurement) in [("Read", p.read), ("Write", p.write)] {
                    let key = label.lowercased()
                    let utilisation = measurement.averageMBps / expected
                    if (0.85...1.15).contains(utilisation) {
                        add(key + "-good", .good, "\(label) performance is approximately \(diagnosticPercent(utilisation * 100)) of the expected practical maximum for the active connection.")
                    } else if utilisation > 1.15 {
                        add(key + "-cache", .info, "\(label) performance exceeds the estimated link capacity. Caching or incomplete channel information may be influencing the result.")
                    } else if utilisation < 0.5 {
                        if measurement.rates.count < 4 {
                            // Too few intervals to have measured anything: on a fast
                            // link a small test is mostly setup, cache and flush.
                            add(key + "-short-test", .info, "\(label) averaged \(diagnosticNumber(measurement.averageMBps, suffix: " MB/s")), below the \(diagnosticSpeed(link)) link ceiling, but the test was too short on a connection this fast to draw a conclusion from. Run a larger test for a usable figure.")
                        } else if !fasterThanGigabit {
                            add(key + "-low", .warning, "\(label) performance is well below the estimated link capacity. NAS storage, server load, or the session may be limiting throughput.")
                        } else if measurement.averageMBps < gigabitEquivalent {
                            add(key + "-below-gigabit", .warning, "\(label) performance is below what a 1 Gb/s connection would deliver, despite a \(diagnosticSpeed(link)) link. The SMB path, NAS storage, or server load is worth investigating.")
                        } else {
                            add(key + "-storage-bound", .info, "\(label) performance is below the \(diagnosticSpeed(link)) link ceiling. Above 1 Gb/s that is expected: NAS storage, not the network, usually sets the limit.")
                        }
                    }
                }
                if p.writeMBps < p.readMBps * 0.85 && p.writeMBps >= expected * 0.5 {
                    add("write-plausible", .info, "Write performance is lower than read performance but remains within a plausible range. Storage or server-side write behaviour may be the limiting factor.")
                }
            }
            if let speed = r.smb?.effectiveBandwidthMbps ?? r.network.linkMbps {
                if speed >= 2500, r.mount.protocolName == "SMB", p.writeMBps > 150, (90...120).contains(p.readMBps) {
                    add("smb-read-ceiling", .warning, "SMB read performance appears unusually close to a 1GbE ceiling despite a faster connection. Write performance exceeds 1GbE; the SMB read path and NAS storage are worth investigating.")
                } else if (950...1050).contains(speed), (90...115).contains(p.readMBps) || (90...115).contains(p.writeMBps) {
                    add("gigabit", .info, "The network link is currently operating at 1 Gb/s. Measured throughput appears consistent with that link speed.")
                }
            }
            for (label, measurement) in [("Read", p.read), ("Write", p.write)] where measurement.isInconsistent {
                add(label.lowercased() + "-inconsistent", .warning, measurement.significantDrops >= 2
                    ? "\(label) performance is inconsistent and experienced several significant drops during the test."
                    : "\(label) throughput varied substantially during the test. Storage activity, server load, or the network may be affecting consistency.")
            }
            if findings.contains(where: { $0.severity == .warning }), r.smb?.signing == true || r.smb?.encryption == true {
                add("security-context", .info, "SMB signing or encryption is enabled. These protect the connection and can add processing work; this test does not establish them as the cause of lower performance.")
            }
        }
        let active = r.smb?.activeChannels
        let wifiUsed = r.network.wifi.usedForSMB == true || r.smb?.wifiParticipating == true
        if wifiUsed, r.network.fasterEthernetAvailable {
            add("wifi-faster-ethernet", .warning, "SMB is currently using Wi-Fi even though a faster Ethernet interface is available. Check routing and active SMB channels.")
        } else if wifiUsed, let active, active.count > 1,
                  active.contains(where: { r.network.interfaceTypes[$0.interface ?? ""] == "Ethernet" }) {
            add("wifi-mixed", .info, "Wi-Fi is participating alongside Ethernet in SMB Multichannel. If performance is inconsistent, this mixed path is worth investigating.")
        }
        if let route = r.network.interface, let active, !active.isEmpty {
            let interfaces = Set(active.compactMap(\.interface))
            if !interfaces.contains(route), r.network.targetIsSessionAddress {
                add("route-mismatch", .info, "Active SMB channels use different interfaces from the current route to the NAS. An established session may retain an earlier path.")
            } else if r.network.type == "Ethernet", !wifiUsed,
                      active.allSatisfy({ r.network.interfaceTypes[$0.interface ?? ""] == "Ethernet" }) {
                add("expected-ethernet", .good, "The SMB session is using the expected Ethernet interface indicated by the current route.")
            }
        }
        if let channelSpeed = r.smb?.effectiveBandwidthMbps, let link = r.network.linkMbps, channelSpeed < link * 0.8 {
            add("channel-limit", .info, "Active SMB channel bandwidth is lower than the interface link speed. The session or server-side network path may impose a lower ceiling.")
        }
        if let average = r.latency?.average {
            if average <= 2, r.latency?.loss == 0 { add("latency-good", .good, "Network latency is excellent.") }
            else if average > 20 { add("latency-high", .warning, "Latency is higher than expected for a local wired network. Wi-Fi, VPNs, remote connections, or a busy NAS may explain this.") }
        } else { add("latency-unavailable", .info, "Latency is unavailable. The NAS may block ICMP probes.") }
        if (r.latency?.loss ?? 0) > 0 { add("loss", .info, "Some latency probes received no reply. Packet loss or ICMP filtering may be involved.") }
        if r.network.target != nil, !r.network.targetIsSessionAddress { add("route-unverified", .info, "Network details describe the route to a resolved address; the established session endpoint could not be verified.") }
        return findings
    }
}
