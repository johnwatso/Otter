import Foundation
import LocalAuthentication
import Security

protocol CredentialStoring: Sendable {
    func hasCredentials(for host: String) -> Bool
    func syncCredentials(fromHost: String, toHost: String) -> Bool
    func removeFallbackCredentials(for host: String)
    func exportCredential(for host: String) -> PortableCredential?
    func importCredential(_ credential: PortableCredential) -> Bool
}

/// An SMB location remembered by macOS. This deliberately contains only the
/// routing information required to offer a connection; passwords and account
/// names never leave Keychain.
struct SavedSMBShare: Identifiable, Hashable, Sendable {
    let host: String
    let path: String
    let port: Int?

    var id: String {
        "\(host.lowercased())|\(port ?? 445)|\(path.lowercased())"
    }

    var displayName: String {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        return components.last.map(String.init) ?? host
    }

    var detail: String {
        var address = host
        if let port, port != 445 {
            address += ":\(port)"
        }
        return path.isEmpty ? address : "\(address)/\(path)"
    }

    /// Uses the saved share path when Keychain has one. Some Finder-created
    /// credentials only identify a server; mounting that URL lets macOS show
    /// its usual share picker instead.
    var connectionURL: URL? {
        guard !host.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "smb"
        components.host = host
        if let port, port != 445 {
            components.port = port
        }
        components.path = path.isEmpty ? "/" : "/\(path)"
        return components.url
    }

    var hasSharePath: Bool { !path.isEmpty }

    init?(host: String, path: String? = nil, port: Int? = nil) {
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPath = (path ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        guard !normalizedHost.isEmpty,
              !normalizedHost.contains("/"),
              !normalizedHost.contains("@"),
              port.map({ (1...65_535).contains($0) }) ?? true
        else {
            return nil
        }

        self.host = normalizedHost
        self.path = normalizedPath
        self.port = port
    }
}

/// Reads SMB item *attributes* from Keychain so setup can offer connections
/// that Finder has used before. The query never requests secret data or an
/// account name, and it will not display a Keychain authentication prompt.
struct KeychainSMBShareDiscoveryService: Sendable {
    func savedShares() -> [SavedSMBShare] {
        let authenticationContext = LAContext()
        authenticationContext.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrProtocol as String: kSecAttrProtocolSMB,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecUseAuthenticationContext as String: authenticationContext
        ]

        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let matches = result as? [[String: Any]]
        else {
            return []
        }

        return Array(Set(matches.compactMap { item -> SavedSMBShare? in
            guard let host = item[kSecAttrServer as String] as? String else { return nil }
            let path = item[kSecAttrPath as String] as? String
            let port = (item[kSecAttrPort as String] as? NSNumber)?.intValue
            return SavedSMBShare(host: host, path: path, port: port)
        }))
        .sorted {
            $0.detail.localizedStandardCompare($1.detail) == .orderedAscending
        }
    }
}

extension CredentialStoring {
    // Credentials are deliberately unavailable to generic stores and tests.
    // Only the system Keychain implementation can opt into protected backup.
    func exportCredential(for host: String) -> PortableCredential? { nil }
    func importCredential(_ credential: PortableCredential) -> Bool { false }
}

struct PortableCredential: Codable, Equatable {
    let host: String
    let account: String
    let passwordData: Data
}

struct KeychainCredentialStore: CredentialStoring {
    func hasCredentials(for host: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: host,
            kSecAttrProtocol as String: kSecAttrProtocolSMB,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }

    @discardableResult
    func syncCredentials(fromHost: String, toHost: String) -> Bool {
        guard !fromHost.isEmpty, !toHost.isEmpty, fromHost != toHost else { return false }

        // Never add another account for the destination. Without a username in
        // the share URL, macOS would have no deterministic way to choose it.
        if hasCredentials(for: toHost) {
            return true
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: fromHost,
            kSecAttrProtocol as String: kSecAttrProtocolSMB,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let matches = result as? [[String: Any]],
              matches.count == 1,
              let item = matches.first,
              let account = item[kSecAttrAccount as String] as? String,
              let passwordData = item[kSecValueData as String] as? Data
        else {
            return false
        }

        var newItem: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: toHost,
            kSecAttrProtocol as String: kSecAttrProtocolSMB,
            kSecAttrAccount as String: account,
            kSecValueData as String: passwordData,
            kSecAttrLabel as String: fallbackLabel(for: toHost)
        ]

        // Preserve the source item's scope and accessibility instead of
        // weakening the protection on the copied fallback entry.
        for attribute in [kSecAttrAuthenticationType, kSecAttrPath, kSecAttrPort, kSecAttrAccessible] {
            if let value = item[attribute as String] {
                newItem[attribute as String] = value
            }
        }

        return SecItemAdd(newItem as CFDictionary, nil) == errSecSuccess
    }

    func removeFallbackCredentials(for host: String) {
        guard !host.isEmpty else { return }

        // Include the original label used by early releases so those entries
        // are cleaned up when their share or cached IP is removed.
        let labels = [fallbackLabel(for: host), "Otter: \(host)"]
        for label in labels {
            let query: [String: Any] = [
                kSecClass as String: kSecClassInternetPassword,
                kSecAttrServer as String: host,
                kSecAttrProtocol as String: kSecAttrProtocolSMB,
                kSecAttrLabel as String: label
            ]
            SecItemDelete(query as CFDictionary)
        }
    }

    func exportCredential(for host: String) -> PortableCredential? {
        guard !host.isEmpty else { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: host,
            kSecAttrProtocol as String: kSecAttrProtocolSMB,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let matches = result as? [[String: Any]],
              matches.count == 1,
              let account = matches[0][kSecAttrAccount as String] as? String,
              let passwordData = matches[0][kSecValueData as String] as? Data
        else { return nil }
        return PortableCredential(host: host, account: account, passwordData: passwordData)
    }

    func importCredential(_ credential: PortableCredential) -> Bool {
        guard !credential.host.isEmpty, !credential.account.isEmpty else { return false }
        let identity: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: credential.host,
            kSecAttrProtocol as String: kSecAttrProtocolSMB,
            kSecAttrAccount as String: credential.account
        ]
        let attributes: [String: Any] = [kSecValueData as String: credential.passwordData]
        let updateStatus = SecItemUpdate(identity as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else { return false }
        var item = identity
        item[kSecValueData as String] = credential.passwordData
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    private func fallbackLabel(for host: String) -> String {
        "Otter SMB fallback: \(host)"
    }
}
