import Foundation
import NetFS

enum MountServiceError: LocalizedError {
    case invalidURL
    case passwordInURL
    case cancelled
    case authenticationFailed
    case serverUnreachable
    case netFSFailed(Int32)

    static func failure(status: Int32) -> MountServiceError {
        switch status {
        case ECANCELED:
            .cancelled
        case EAUTH, EACCES, EPERM:
            .authenticationFailed
        case ETIMEDOUT, EHOSTUNREACH, EHOSTDOWN, ENETUNREACH, ENOENT:
            .serverUnreachable
        default:
            .netFSFailed(status)
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "The network address is invalid."
        case .passwordInURL:
            "Remove the username or password from the URL and let macOS handle credentials."
        case .cancelled:
            "The connection was canceled."
        case .authenticationFailed:
            "macOS couldn't authenticate with the server. Connect once in Finder to save the credentials."
        case .serverUnreachable:
            "The server didn't respond."
        case let .netFSFailed(status):
            "macOS returned mount error \(status)."
        }
    }
}

actor MountService {
    // NetFSMountURLSync blocks until the mount finishes (or the user dismisses a
    // credentials dialog), so it runs on a dedicated queue instead of tying up a
    // Swift-concurrency cooperative thread.
    // Session-only aliases let diagnostics remount by IP without saving a new server.
    private var diagnosticMountAliases: [NetworkShare.ID: URL] = [:]
    private let mountQueue = DispatchQueue(label: "Otter.MountService")
    private let credentialStore: any CredentialStoring

    init(credentialStore: any CredentialStoring = KeychainCredentialStore()) {
        self.credentialStore = credentialStore
    }

    func isMounted(_ share: NetworkShare) -> Bool {
        mountedURL(for: share) != nil
    }

    func mountedURL(for share: NetworkShare) -> URL? {
        mountedVolumeURL(for: share)
    }

    @discardableResult
    func mount(_ share: NetworkShare, urlOverride: URL? = nil) async throws -> URL? {
        guard let url = urlOverride ?? share.url else {
            throw MountServiceError.invalidURL
        }

        if let urlOverride,
           let originalHost = share.url?.host(percentEncoded: false),
           let fallbackHost = urlOverride.host(percentEncoded: false),
           originalHost != fallbackHost {
            // macOS files an SMB password under whichever spelling of the
            // server name was used when it was saved, so the fallback address
            // looks for it under every alias of the configured host.
            if let savedHost = credentialStore.savedCredentialHost(matching: originalHost) {
                _ = credentialStore.syncCredentials(fromHost: savedHost, toHost: fallbackHost)
            }
        }

        if url.user(percentEncoded: false) != nil || url.password(percentEncoded: false) != nil {
            throw MountServiceError.passwordInURL
        }

        // NetFS used to report EEXIST for this case. On macOS 27 it can return
        // an unrelated address error instead, so do not ask it to mount an
        // address that is already represented by a mounted volume.
        if let mountedURL = mountedVolumeURL(matching: url) {
            if urlOverride != nil {
                diagnosticMountAliases[share.id] = url
            }
            return mountedURL
        }

        let result: (status: Int32, mountPaths: [String]) = await withCheckedContinuation { continuation in
            mountQueue.async {
                var mountPoints: Unmanaged<CFArray>?
                let status = NetFSMountURLSync(
                    url as CFURL,
                    nil,
                    nil,
                    nil,
                    nil,
                    nil,
                    &mountPoints
                )
                let mountPaths = mountPoints?.takeRetainedValue() as? [String] ?? []
                continuation.resume(returning: (status, mountPaths))
            }
        }

        // Re-read the mount table regardless of the status. Besides handling
        // EEXIST, this covers a race with Finder and macOS versions that return
        // a different error even though the requested volume is mounted.
        if let mountedURL = mountedVolumeURL(matching: url) {
            if urlOverride != nil {
                diagnosticMountAliases[share.id] = url
            }
            return mountedURL
        }

        guard result.status == noErr else {
            throw MountServiceError.failure(status: result.status)
        }

        if let mountPath = result.mountPaths.first {
            return URL(fileURLWithPath: mountPath, isDirectory: true)
        }

        return mountedVolumeURL(for: share)
    }

    func unmount(_ share: NetworkShare) async throws {
        guard let url = mountedVolumeURL(for: share) else { return }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            FileManager.default.unmountVolume(at: url, options: []) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func mountedVolumeURL(for share: NetworkShare) -> URL? {
        let expectedLocations = expectedShareLocations(for: share)

        return mountedVolumeURL(matching: expectedLocations)
    }

    private func mountedVolumeURL(matching url: URL) -> URL? {
        guard let location = NetworkShareLocation(url: url) else { return nil }
        return mountedVolumeURL(matching: [location])
    }

    private func mountedVolumeURL(matching expectedLocations: [NetworkShareLocation]) -> URL? {
        let fileManager = FileManager.default

        guard !expectedLocations.isEmpty else { return nil }

        guard let mountedVolumes = fileManager.mountedVolumeURLs(
            includingResourceValuesForKeys: Array(Self.mountedVolumeResourceKeys),
            options: []
        )
        else {
            return nil
        }

        return mountedVolumes.first { mountedURL in
            guard let resourceValues = try? mountedURL.resourceValues(forKeys: Self.mountedVolumeResourceKeys),
                  let remountURL = resourceValues.volumeURLForRemounting,
                  let mountedLocation = NetworkShareLocation(url: remountURL)
            else {
                return false
            }

            return expectedLocations.contains(mountedLocation)
        }
    }

    private func expectedShareLocations(for share: NetworkShare) -> [NetworkShareLocation] {
        var locations: [NetworkShareLocation] = []
        if let alias = diagnosticMountAliases[share.id], let location = NetworkShareLocation(url: alias) {
            locations.append(location)
        }

        if let location = NetworkShareLocation(url: share.url) {
            locations.append(location)
        }

        if let url = share.url {
            for cachedIPAddress in share.orderedCachedIPAddresses {
                guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { continue }
                components.host = NetworkShare.urlComponentsHost(forIPAddress: cachedIPAddress)
                if let location = NetworkShareLocation(url: components.url), !locations.contains(location) {
                    locations.append(location)
                }
            }
        }

        return locations
    }

    private static let mountedVolumeResourceKeys: Set<URLResourceKey> = [
        .volumeURLForRemountingKey
    ]
}

struct NetworkShareLocation: Equatable {
    let scheme: String
    let host: String
    let port: Int
    let sharePath: String

    init?(url: URL?) {
        guard let url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              NetworkShareProtocol(urlScheme: scheme) != nil,
              let host = components.host?.lowercased(),
              !host.isEmpty
        else {
            return nil
        }

        let pathParts = (components.path.removingPercentEncoding ?? components.path)
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { $0.lowercased() }

        guard !pathParts.isEmpty else { return nil }

        self.scheme = scheme
        // One server answers to several names: "nas", "nas.local" and the
        // Bonjour service form all reach the same machine. Identifying it by
        // the stripped name keeps a volume mounted through one spelling from
        // looking like a different share than the same volume mounted through
        // another.
        self.host = ServerAlias.identity(for: host) ?? host
        self.port = components.port ?? Self.defaultPort(for: scheme)
        // Network filesystems are mounted at their exported root. A deeper URL
        // path is normally a folder within that volume, so match its first path
        // component to avoid treating a subfolder as a separate disk.
        self.sharePath = pathParts[0]
    }

    private static func defaultPort(for scheme: String) -> Int {
        switch scheme {
        case "smb": 445
        case "nfs": 2049
        case "https", "webdavs": 443
        case "http", "webdav": 80
        default: 0
        }
    }
}

// Kept as a source-compatible name for the SMB discovery and test helpers.
typealias SMBShareLocation = NetworkShareLocation
