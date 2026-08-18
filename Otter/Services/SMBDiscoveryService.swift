import Foundation
import Network
import NetFS

struct DiscoveredSMBServer: Identifiable, Hashable, Sendable {
    let name: String
    let domain: String

    var id: String { "\(name)|\(domain)" }

    var hostName: String {
        let trimmedDomain = domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if name.lowercased().hasSuffix(".\(trimmedDomain.lowercased())") {
            return name
        }
        return trimmedDomain.isEmpty ? name : "\(name).\(trimmedDomain)"
    }

    var finderURL: URL? {
        var components = URLComponents()
        components.scheme = "smb"
        components.host = hostName
        components.path = "/"
        return components.url
    }
}

enum SMBDiscoveryState: Equatable, Sendable {
    case idle
    case searching
    case ready
    case failed(String)
}

enum LocalNetworkAuthorizationStatus: Equatable, Sendable {
    case checking
    case allowed
    case denied
    case unknown

    var isAllowed: Bool {
        self == .allowed
    }
}

@MainActor
final class SMBDiscoveryService: ObservableObject {
    @Published private(set) var servers: [DiscoveredSMBServer] = []
    @Published private(set) var state: SMBDiscoveryState = .idle
    @Published private(set) var localNetworkAuthorizationStatus: LocalNetworkAuthorizationStatus = .unknown

    private var browser: NWBrowser?
    private var authorizationBrowser: NWBrowser?
    private let queue = DispatchQueue(label: "Otter.SMBDiscovery", qos: .utility)

    func start() {
        guard browser == nil else { return }

        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: "_smb._tcp", domain: nil), using: parameters)

        browser.stateUpdateHandler = { [weak self] newState in
            let state: SMBDiscoveryState
            switch newState {
            case .setup, .waiting:
                state = .searching
            case .ready:
                state = .ready
            case let .failed(error):
                state = .failed(error.localizedDescription)
            case .cancelled:
                state = .idle
            @unknown default:
                state = .searching
            }

            Task { @MainActor [weak self] in
                self?.state = state
            }
        }

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let discovered = results.compactMap { result -> DiscoveredSMBServer? in
                guard case let .service(name, _, domain, _) = result.endpoint else { return nil }
                return DiscoveredSMBServer(name: name, domain: domain)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

            Task { @MainActor [weak self] in
                self?.servers = discovered
            }
        }

        self.browser = browser
        state = .searching
        browser.start(queue: queue)
    }

    func restart() {
        stop()
        start()
    }

    /// Browsing for the declared SMB Bonjour service is the public Network
    /// framework mechanism that macOS uses to evaluate Local Network access.
    /// A policy-denied DNS-SD error means the switch in System Settings is off.
    func checkLocalNetworkAuthorization() {
        guard authorizationBrowser == nil else { return }

        localNetworkAuthorizationStatus = .checking

        let browser = NWBrowser(
            for: .bonjour(type: "_smb._tcp", domain: nil),
            using: .tcp
        )
        authorizationBrowser = browser

        browser.stateUpdateHandler = { [weak self, weak browser] state in
            let status: LocalNetworkAuthorizationStatus?
            switch state {
            case .ready:
                status = .allowed
            case let .failed(error):
                if case let .dns(code) = error, code == -65_570 {
                    status = .denied
                } else {
                    status = .unknown
                }
            case .cancelled, .setup, .waiting:
                status = nil
            @unknown default:
                status = .unknown
            }

            guard let status else { return }
            Task { @MainActor [weak self, weak browser] in
                self?.localNetworkAuthorizationStatus = status
                browser?.cancel()
                self?.authorizationBrowser = nil
            }
        }

        browser.start(queue: queue)
    }

    func stop() {
        browser?.cancel()
        browser = nil
        state = .idle
    }
}

actor SMBShareBrowserService {
    private let mountQueue = DispatchQueue(label: "Otter.SMBShareBrowser", qos: .userInitiated)

    func browse(_ server: DiscoveredSMBServer) async throws -> [MountedShareSuggestion] {
        guard let serverURL = server.finderURL else {
            throw MountServiceError.invalidURL
        }

        return try await browse(serverURL, matchingHost: server.hostName)
    }

    func browse(_ savedShare: SavedSMBShare) async throws -> [MountedShareSuggestion] {
        guard let connectionURL = savedShare.connectionURL else {
            throw MountServiceError.invalidURL
        }

        return try await browse(connectionURL, matchingHost: savedShare.host)
    }

    private func browse(_ serverURL: URL, matchingHost: String) async throws -> [MountedShareSuggestion] {

        let result: (status: Int32, mountPaths: [String]) = await withCheckedContinuation { continuation in
            mountQueue.async {
                var mountPoints: Unmanaged<CFArray>?
                let status = NetFSMountURLSync(
                    serverURL as CFURL,
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

        if result.status == ECANCELED {
            return []
        }
        guard result.status == noErr || result.status == EEXIST else {
            throw MountServiceError.failure(status: result.status)
        }

        let selectedShares = result.mountPaths.compactMap {
            try? MountedShareSuggestion.make(from: URL(fileURLWithPath: $0, isDirectory: true))
        }
        if !selectedShares.isEmpty {
            return selectedShares.sorted {
                $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            }
        }

        return MountedShareSuggestion.discover().filter { $0.matches(host: matchingHost) }
    }
}
