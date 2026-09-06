import Foundation

struct SMBInspector {
    func inspect(mountPath: String) async -> SMBDiagnostic {
        let runner = DiagnosticCommandRunner()
        if let json = await runner.run("/usr/bin/smbutil", ["statshares", "-m", mountPath, "-f", "JSON"]),
           let data = json.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data),
           let attributes = DiagnosticParsing.dictionaries(object).first(where: { $0["SMB_VERSION"] != nil }) {
            return Self.parseAttributes(attributes)
        }
        guard !Task.isCancelled else { return SMBDiagnostic() }
        return Self.parseText(await runner.run("/usr/bin/smbutil", ["statshares", "-m", mountPath]) ?? "")
    }

    static func parseAttributes(_ values: [String: Any]) -> SMBDiagnostic {
        let cipher = values["SMB_CURR_ENCRYPT_ALGORITHM"] as? String
        var encryption = DiagnosticParsing.bool(values["ENCRYPTION_ON"])
        if values["SMB_CURR_ENCRYPT_ALGORITHM"] is NSNull { encryption = false }
        if let cipher {
            if cipher.uppercased().contains("AES") { encryption = true }
            else if cipher.uppercased() == "OFF" { encryption = false }
        }
        // Encryption support/requirement and signing support are not active state.
        return SMBDiagnostic(dialect: (values["SMB_VERSION"] as? String)?.replacingOccurrences(of: "_", with: " "),
                             signing: DiagnosticParsing.bool(values["SIGNING_ON"]), encryption: encryption)
    }

    static func parseText(_ text: String) -> SMBDiagnostic {
        var attributes: [String: Any] = [:]
        for line in text.components(separatedBy: .newlines) {
            if let fields = DiagnosticParsing.capture(#"^\s*(SMB_VERSION|SIGNING_ON|ENCRYPTION_ON|SMB_CURR_ENCRYPT_ALGORITHM)\s+(.+?)\s*$"#, in: line) {
                attributes[fields[0].uppercased()] = fields[1]
            }
        }
        return parseAttributes(attributes)
    }
}
