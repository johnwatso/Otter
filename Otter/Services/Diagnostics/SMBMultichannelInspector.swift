import Foundation

struct SMBMultichannelInspector {
    func inspect(mountPath: String, into smb: SMBDiagnostic) async -> SMBDiagnostic {
        let runner = DiagnosticCommandRunner()
        if let text = await runner.run("/usr/bin/smbutil", ["multichannel", "-m", mountPath, "-f", "JSON"]),
           let parsed = Self.parseJSON(text, mountPath: mountPath, into: smb) { return parsed }
        guard !Task.isCancelled else { return smb }
        return Self.parseText(await runner.run("/usr/bin/smbutil", ["multichannel", "-m", mountPath]) ?? "", into: smb)
    }

    static func parseJSON(_ text: String, mountPath: String, into initial: SMBDiagnostic) -> SMBDiagnostic? {
        guard let data = text.data(using: .utf8), let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let session = root[mountPath] as? [String: Any] else { return nil }
        var result = initial
        result.multichannel = DiagnosticParsing.bool((session["session_info"] as? [String: Any])?["mc_on"])
        result.sessionStartedAt = Self.sessionDate((session["session_info"] as? [String: Any])?["session_setup_time"] as? String)
        if let channels = session["multi_channel_status"] as? [String: Any] {
            let parsed = channels.values.compactMap { value -> SMBChannelDiagnostic? in
                guard let channel = value as? [String: Any], let state = channel["state"] as? String else { return nil }
                let speed = channel["link_speed"].flatMap { Double(String(describing: $0)) }.map { $0 / 1_000_000 }
                let address = channel["server_inet"] as? String
                return SMBChannelDiagnostic(interface: channel["client_interface"] as? String,
                                            serverIP: address.flatMap { NetworkShare.isIPAddress($0) ? $0 : nil }, state: state, linkMbps: speed)
            }
            if parsed.count == channels.count { result.channels = parsed.sorted { ($0.interface ?? "") < ($1.interface ?? "") } }
        }
        return result
    }

    static func parseText(_ text: String, into initial: SMBDiagnostic) -> SMBDiagnostic {
        var result = initial
        result.multichannel = DiagnosticParsing.capture(#"Multichannel ON:\s*(yes|no)"#, in: text).flatMap { DiagnosticParsing.bool($0[0]) }
        result.sessionStartedAt = DiagnosticParsing.capture(#"Info:.*?Setup Time:\s*(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})"#, in: text).flatMap { Self.sessionDate($0[0]) }
        var channels: [SMBChannelDiagnostic] = []
        for line in text.components(separatedBy: .newlines) {
            if let fields = DiagnosticParsing.capture(#"\b(en\d+|bridge\d+|utun\d+)\s+\(([^)]+)\).*\[([^]]+)\]\s+(\S+)\s+\d+\s+([\d.]+)\s+([GMK]?)b"#, in: line) {
                let multiplier: Double = fields[5].uppercased() == "G" ? 1000 : (fields[5].uppercased() == "M" ? 1 : 0.001)
                let state = fields[2].trimmingCharacters(in: .whitespaces)
                channels.append(.init(interface: fields[0], serverIP: NetworkShare.isIPAddress(fields[3]) ? fields[3] : nil,
                                      state: state, linkMbps: Double(fields[4]).map { $0 * multiplier }))
                if state == "session active", fields[1].lowercased().contains("wi-fi") { result.wifiParticipating = true }
            }
        }
        if !channels.isEmpty { result.channels = channels }
        return result
    }

    static func sessionDate(_ text: String?, now: Date = Date(), timeZone: TimeZone = .current) -> Date? {
        guard let text else { return nil }
        // Apple's session_info timestamp is local time without a zone.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.isLenient = false
        guard let date = formatter.date(from: text), formatter.string(from: date) == text,
              date.timeIntervalSince1970 > 0, date <= now else { return nil }
        // Ambiguous repeated local time at a DST transition is not reliable.
        if formatter.string(from: date.addingTimeInterval(3600)) == text || formatter.string(from: date.addingTimeInterval(-3600)) == text { return nil }
        return date
    }
}
