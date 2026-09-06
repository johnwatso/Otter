import Foundation

struct MountDiagnostic: Sendable {
    var protocolName: String
    var server: String
    var shareName: String
    var mountPath: String?
    var resolvedIP: String?
    var connectedUsing: String = "Unavailable"
}

struct NetworkDiagnostic: Sendable {
    var interface: String?
    var type: String?
    var localIP: String?
    var linkMbps: Double?
    var target: String?
    var targetIsSessionAddress = false
    var fasterEthernetAvailable = false
    var availableEthernetMbps: Double?
    var mtu: Int?
    var duplex: String?
    var wifi = WiFiDiagnostic()
    var interfaceLinkMbps: [String: Double] = [:]
    var interfaceTypes: [String: String] = [:]
    var speedText: String { linkMbps.map { $0 >= 1000 ? String(format: "%.2g Gb/s", $0 / 1000) : String(format: "%.0f Mb/s", $0) } ?? "Unavailable" }
}

struct SMBChannelDiagnostic: Sendable {
    var interface: String?
    var serverIP: String?
    var state: String
    var linkMbps: Double?
    var isActive: Bool { state.lowercased() == "session active" }
}

struct SMBDiagnostic: Sendable {
    var dialect: String?
    var signing: Bool?
    var encryption: Bool?
    var multichannel: Bool?
    var channels: [SMBChannelDiagnostic]?
    var wifiParticipating = false
    var sessionStartedAt: Date?
    var clientLinkMbps: [String: Double] = [:]
    var activeChannels: [SMBChannelDiagnostic]? { channels?.filter(\.isActive) }
    var activeChannelCount: Int? { activeChannels?.count }
    var channelSummary: String {
        guard let count = activeChannelCount else { return "Channels unavailable" }
        return "\(count) active channel\(count == 1 ? "" : "s")"
    }
    /// RSS channels sharing one NIC cannot multiply its physical bandwidth.
    /// Unknown NIC capacity is conservatively capped at its fastest channel.
    var effectiveBandwidthMbps: Double? {
        guard let activeChannels, !activeChannels.isEmpty,
              activeChannels.allSatisfy({ $0.interface != nil && ($0.linkMbps ?? 0) > 0 && ($0.linkMbps?.isFinite == true) }) else { return nil }
        return Dictionary(grouping: activeChannels, by: { $0.interface! }).reduce(0) { total, group in
            let speeds = group.value.compactMap(\.linkMbps)
            let capacity = clientLinkMbps[group.key] ?? speeds.max()!
            return total + min(speeds.reduce(0, +), capacity)
        }
    }
    var multichannelText: String {
        guard let multichannel else { return "Unavailable" }
        return multichannel ? "Yes" : "No"
    }
}

struct LatencyDiagnostic: Sendable {
    var minimum: Double?
    var average: Double?
    var maximum: Double?
    var loss: Double?
}

struct PerformanceDiagnostic: Sendable {
    var writeMBps: Double
    var readMBps: Double
    var bytes: Int64
    var cacheBypass: Bool
    var duration: TimeInterval?
    var writeSamples: [ThroughputSample] = []
    var readSamples: [ThroughputSample] = []
    var write: ThroughputDiagnostic { .init(averageMBps: writeMBps, samples: writeSamples) }
    var read: ThroughputDiagnostic { .init(averageMBps: readMBps, samples: readSamples) }
    var sizeText: String { String(format: "%.1f GB", Double(bytes) / 1_000_000_000) }
}

struct NASDiagnosticResult: Sendable {
    var mount: MountDiagnostic
    var network = NetworkDiagnostic()
    var smb: SMBDiagnostic?
    var latency: LatencyDiagnostic?
    var performance: PerformanceDiagnostic?
    var generatedAt = Date()
    var isComplete = false
    var lastWakeAt: Date?
    var sessionAge: TimeInterval? {
        smb?.sessionStartedAt.flatMap { $0 <= generatedAt ? generatedAt.timeIntervalSince($0) : nil }
    }
    var sessionPredatesWake: Bool? {
        guard let start = smb?.sessionStartedAt, let wake = lastWakeAt else { return nil }
        return start < wake
    }
    var expectedMaxMBps: Double? {
        let speed = mount.protocolName == "SMB" ? smb?.effectiveBandwidthMbps : network.linkMbps
        return speed.flatMap { $0 > 0 && $0.isFinite ? $0 / 8 * 0.944 : nil }
    }
    var health: ConnectionHealthSummary { DiagnosticAnalyzer.health(self) }
    var detailedFindings: [DiagnosticFinding] { DiagnosticAnalyzer.detailedFindings(self) }
    var findings: [String] { DiagnosticAnalyzer.findings(self) }
}

func diagnosticFlag(_ value: Bool?) -> String {
    value.map { $0 ? "Enabled" : "Disabled" } ?? "Unavailable"
}

func diagnosticNumber(_ value: Double?, suffix: String) -> String {
    value.map { String(format: "%.1f", $0) + suffix } ?? "Unavailable"
}

struct WiFiDiagnostic: Sendable {
    var connected: Bool?
    var usedForSMB: Bool?
    var participatingInMultichannel = false
    var text: String {
        guard let connected else { return "Unavailable" }
        guard connected else { return "Disconnected" }
        guard let usedForSMB else { return "Connected · SMB use unavailable" }
        if !usedForSMB { return "Connected · Not used for SMB" }
        return participatingInMultichannel ? "Connected · Participating in SMB Multichannel" : "Connected · Used for SMB"
    }
}

enum DiagnosticFindingSeverity: String, Sendable { case info, good, warning }
struct DiagnosticFinding: Sendable, Identifiable {
    var id: String
    var severity: DiagnosticFindingSeverity
    var message: String
}

enum ConnectionHealthState: String, Sendable {
    case good = "Good", needsAttention = "Needs Attention", potentialBottleneck = "Potential Bottleneck", incomplete = "Incomplete"
}
struct ConnectionHealthSummary: Sendable {
    var state: ConnectionHealthState
    var explanation: String
}

struct ThroughputSample: Sendable {
    var bytes: Int64
    var duration: TimeInterval
    var mbps: Double { Double(bytes) / 1_000_000 / duration }
}
struct ThroughputDiagnostic: Sendable {
    var averageMBps: Double
    var samples: [ThroughputSample]
    // Ignore a tiny trailing fragment when assessing consistency.
    var rates: [Double] { samples.filter { $0.duration >= 0.5 && $0.mbps.isFinite }.map(\.mbps) }
    var minimumMBps: Double? { rates.min() }
    var maximumMBps: Double? { rates.max() }
    var variation: Double? {
        let values = rates
        guard values.count >= 4 else { return nil }
        let mean = values.reduce(0, +) / Double(values.count)
        guard mean > 0 else { return nil }
        return sqrt(values.reduce(0) { $0 + pow($1 - mean, 2) } / Double(values.count)) / mean
    }
    var significantDrops: Int {
        let sorted = rates.sorted()
        guard sorted.count >= 4 else { return 0 }
        let median = sorted[sorted.count / 2]
        return sorted.filter { $0 < median * 0.5 }.count
    }
    var isInconsistent: Bool { rates.count >= 6 && ((variation ?? 0) > 0.5 || ((variation ?? 0) > 0.3 && significantDrops >= 2)) }
    func utilisation(expected: Double?) -> Double? {
        expected.flatMap { $0 > 0 && averageMBps.isFinite ? averageMBps / $0 * 100 : nil }
    }
}

/// Uses accumulated I/O time; one sample per ~750 ms, no per-block storage.
struct ThroughputSampler {
    private(set) var samples: [ThroughputSample] = []
    private var bytes: Int64 = 0
    private var duration = 0.0
    mutating func record(bytes: Int64, duration: TimeInterval) {
        self.bytes += bytes
        self.duration += duration
        if self.duration >= 0.75 { flush() }
    }
    mutating func flush() {
        guard duration > 0 else { return }
        samples.append(.init(bytes: bytes, duration: duration))
        bytes = 0
        duration = 0
    }
}

func diagnosticSpeed(_ mbps: Double?) -> String {
    mbps.map { $0 >= 1000 ? String(format: "%.3g Gb/s", $0 / 1000) : String(format: "%.0f Mb/s", $0) } ?? "Unavailable"
}
func diagnosticDuration(_ seconds: TimeInterval?) -> String {
    guard let seconds, seconds >= 0, seconds.isFinite else { return "Unavailable" }
    let total = Int(min(seconds, Double(Int.max / 2)))
    if total >= 3600 { return "\(total / 3600)h \(total % 3600 / 60)m" }
    return String(format: "%dm %02ds", total / 60, total % 60)
}
func diagnosticPercent(_ value: Double?) -> String {
    value.map { String(format: "%.0f%%", $0) } ?? "Unavailable"
}

enum DiagnosticComparisonKind: String, Sendable {
    case reconnect = "Before / After Reconnect"
    case ipAddress = "Hostname vs IP"
}
struct DiagnosticComparison: Sendable {
    var kind: DiagnosticComparisonKind
    var before: NASDiagnosticResult
    var after: NASDiagnosticResult
    var originalConnectionRestored: Bool?
    var performanceComparable: Bool {
        guard let first = before.performance, let second = after.performance else { return false }
        return first.bytes == second.bytes && first.cacheBypass == second.cacheBypass
    }
    var interpretations: [String] {
        guard performanceComparable, let first = before.performance, let second = after.performance else {
            return ["No matched performance tests are available. Connection measurements can be compared, but throughput change is unavailable."]
        }
        var messages: [String] = []
        for (label, old, new) in [("Write", first.writeMBps, second.writeMBps), ("Read", first.readMBps, second.readMBps)] {
            guard old > 0, old.isFinite, new.isFinite else { continue }
            let change = (new / old - 1) * 100
            if abs(change) > 10 {
                messages.append("\(label) performance \(change > 0 ? "improved" : "decreased") by \(diagnosticPercent(abs(change))) \(kind == .reconnect ? "after reconnecting the SMB session" : "using the direct-IP connection").")
            }
        }
        if messages.isEmpty {
            messages.append(kind == .reconnect ? "No meaningful performance change was detected after reconnecting (10% threshold)." : "No meaningful difference was detected between hostname and direct-IP connections (10% threshold).")
        }
        messages.append("This is a single before/after comparison. NAS caches, storage activity, and session changes may influence the result; it does not isolate DNS as the cause.")
        return messages
    }
}

struct DiagnosticComparisonRow: Identifiable {
    var label: String
    var before: String
    var after: String
    var id: String { label }
}
extension DiagnosticComparison {
    var rows: [DiagnosticComparisonRow] {
        [
            .init(label: "Latency", before: diagnosticNumber(before.latency?.average, suffix: " ms"), after: diagnosticNumber(after.latency?.average, suffix: " ms")),
            .init(label: "SMB channels", before: before.smb?.activeChannelCount.map(String.init) ?? "Unavailable", after: after.smb?.activeChannelCount.map(String.init) ?? "Unavailable"),
            .init(label: "SMB bandwidth", before: diagnosticSpeed(before.smb?.effectiveBandwidthMbps), after: diagnosticSpeed(after.smb?.effectiveBandwidthMbps)),
            .init(label: "Write", before: diagnosticNumber(before.performance?.writeMBps, suffix: " MB/s"), after: diagnosticNumber(after.performance?.writeMBps, suffix: " MB/s")),
            .init(label: "Read", before: diagnosticNumber(before.performance?.readMBps, suffix: " MB/s"), after: diagnosticNumber(after.performance?.readMBps, suffix: " MB/s"))
        ]
    }
}
