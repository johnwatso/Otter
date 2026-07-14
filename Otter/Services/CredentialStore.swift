import Foundation
import Security

protocol CredentialStoring: Sendable {
    func hasCredentials(for host: String) -> Bool
    func syncCredentials(fromHost: String, toHost: String) -> Bool
    func removeFallbackCredentials(for host: String)
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

    private func fallbackLabel(for host: String) -> String {
        "Otter SMB fallback: \(host)"
    }
}
