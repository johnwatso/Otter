import Foundation
import NetFS

enum MountServiceError: LocalizedError {
    case invalidURL
    case passwordInURL
    case netFSFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "The network address is invalid."
        case .passwordInURL:
            "Remove the username or password from the URL and let macOS handle credentials."
        case let .netFSFailed(status):
            "macOS returned mount error \(status)."
        }
    }
}

actor MountService {
    func isMounted(_ share: NetworkShare) -> Bool {
        mountedURL(for: share) != nil
    }

    func mountedURL(for share: NetworkShare) -> URL? {
        mountedVolumeURL(for: share)
    }

    func mount(_ share: NetworkShare) throws {
        guard let url = share.url else {
            throw MountServiceError.invalidURL
        }

        if url.user(percentEncoded: false) != nil || url.password(percentEncoded: false) != nil {
            throw MountServiceError.passwordInURL
        }

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
        mountPoints?.release()

        guard status == noErr else {
            throw MountServiceError.netFSFailed(status)
        }
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
        let normalizedPath = normalizedMountPath(share.mountPath)
        let shareLocation = SMBShareLocation(url: share.url)

        guard let mountedVolumes = fileManager.mountedVolumeURLs(
            includingResourceValuesForKeys: Array(Self.mountedVolumeResourceKeys),
            options: []
        )
        else {
            return nil
        }

        return mountedVolumes.first { mountedURL in
            if normalizedMountPath(mountedURL.path) == normalizedPath {
                return true
            }

            guard let shareLocation,
                  let resourceValues = try? mountedURL.resourceValues(forKeys: Self.mountedVolumeResourceKeys),
                  let remountURL = resourceValues.volumeURLForRemounting,
                  let mountedLocation = SMBShareLocation(url: remountURL)
            else {
                return false
            }

            return mountedLocation == shareLocation
        }
    }

    private func normalizedMountPath(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }

    private static let mountedVolumeResourceKeys: Set<URLResourceKey> = [
        .volumeURLForRemountingKey
    ]
}

private struct SMBShareLocation: Equatable {
    let host: String
    let port: Int?
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
        self.port = components.port
        self.sharePath = pathParts.joined(separator: "/")
    }
}
