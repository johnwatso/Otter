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
            _ = credentialStore.syncCredentials(fromHost: originalHost, toHost: fallbackHost)
        }

        if url.user(percentEncoded: false) != nil || url.password(percentEncoded: false) != nil {
            throw MountServiceError.passwordInURL
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

        if result.status == EEXIST {
            return mountedVolumeURL(for: share)
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
        let fileManager = FileManager.default
        let expectedLocations = expectedShareLocations(for: share)

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
                  let mountedLocation = SMBShareLocation(url: remountURL)
            else {
                return false
            }

            return expectedLocations.contains(mountedLocation)
        }
    }

    private func expectedShareLocations(for share: NetworkShare) -> [SMBShareLocation] {
        var locations: [SMBShareLocation] = []

        if let location = SMBShareLocation(url: share.url) {
            locations.append(location)
        }

        if let cachedIPAddress = share.cachedIPAddress,
           let url = share.url,
           var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.host = cachedIPAddress
            if let location = SMBShareLocation(url: components.url), !locations.contains(location) {
                locations.append(location)
            }
        }

        return locations
    }

    private static let mountedVolumeResourceKeys: Set<URLResourceKey> = [
        .volumeURLForRemountingKey
    ]
}

struct SMBShareLocation: Equatable {
    let host: String
    let port: Int
    let sharePath: String

    init?(url: URL?) {
        guard let url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "smb",
              let host = components.host?.lowercased(),
              !host.isEmpty
        else {
            return nil
        }

        let pathParts = (components.path.removingPercentEncoding ?? components.path)
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { $0.lowercased() }

        guard !pathParts.isEmpty else { return nil }

        self.host = host
        self.port = components.port ?? 445
        // SMB mounts are identified by server and share. A deeper URL path is a
        // folder within that share and should not change the mounted-volume identity.
        self.sharePath = pathParts[0]
    }
}
