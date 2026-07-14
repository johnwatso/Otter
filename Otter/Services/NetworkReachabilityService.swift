import CoreLocation
import CoreWLAN
import Darwin
import Foundation
import Network

@MainActor
final class NetworkReachabilityService: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var isOnline = true
    @Published private(set) var currentWiFiNetworkName: String?
    @Published private(set) var isVPNConnected = false
    @Published private(set) var currentIPv4Subnets: [String] = []
    @Published private(set) var activeVPNNames: [String] = []
    @Published private(set) var knownVPNNames: [String] = []
    @Published private(set) var hasUnidentifiedTunnel = false
    @Published private(set) var locationAuthorizationStatus: CLAuthorizationStatus = .notDetermined

    var currentVPNDisplayName: String {
        if !activeVPNNames.isEmpty {
            return activeVPNNames.joined(separator: ", ")
        }

        if hasUnidentifiedTunnel {
            return "Tunnel detected (not used for share rules)"
        }

        return "None"
    }

    var isVPNNameUnavailable: Bool {
        hasUnidentifiedTunnel
    }

    // macOS only exposes the Wi-Fi network name to apps with Location Services access.
    var wifiNameRequiresLocationPermission: Bool {
        currentWiFiNetworkName == nil && locationAuthorizationStatus != .authorizedAlways
    }

    var canRequestLocationAuthorization: Bool {
        locationAuthorizationStatus == .notDetermined
    }

    var onPathChange: (() -> Void)?
    private let pathMonitor = NWPathMonitor()
    private let pathQueue = DispatchQueue(label: "Otter.NetworkPathMonitor")
    private let reachabilityQueue = DispatchQueue(label: "Otter.ServerReachability")
    private let locationManager = CLLocationManager()
    private var hasStarted = false
    private var hasReceivedPathUpdate = false
    private var lastDetailsRefresh: Date?
    private var detailsRefreshTask: Task<Void, Never>?

    override init() {
        super.init()
        locationManager.delegate = self
        locationAuthorizationStatus = locationManager.authorizationStatus
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        refreshNetworkDetails()

        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                await self?.handlePathUpdate(path)
            }
        }
        pathMonitor.start(queue: pathQueue)
    }

    func canReachServer(for url: URL, timeout: TimeInterval = 3) async -> Bool {
        guard isOnline, let host = url.host(percentEncoded: false) else {
            return false
        }

        let reachableHost: String
        if url.scheme?.lowercased() == "smb",
           SystemHostResolver.bonjourServiceIdentity(for: host) != nil {
            guard let resolvedAddress = await SystemHostResolver().resolveIPAddress(for: host) else {
                return false
            }
            reachableHost = resolvedAddress
        } else {
            reachableHost = host
        }

        let port = NWEndpoint.Port(rawValue: UInt16(url.port ?? 445)) ?? NWEndpoint.Port(rawValue: 445)!
        let connection = NWConnection(host: NWEndpoint.Host(reachableHost), port: port, using: .tcp)

        return await withCheckedContinuation { continuation in
            let attempt = ReachabilityAttempt(connection: connection, continuation: continuation)

            connection.stateUpdateHandler = { @Sendable (state: NWConnection.State) in
                switch state {
                case .ready:
                    attempt.finish(true)
                case .failed, .waiting:
                    attempt.finish(false)
                case .cancelled, .setup, .preparing:
                    break
                @unknown default:
                    break
                }
            }

            connection.start(queue: reachabilityQueue)
            reachabilityQueue.asyncAfter(deadline: .now() + timeout) {
                attempt.finish(false)
            }
        }
    }

    func refreshCurrentWiFiNetworkName() {
        refreshNetworkDetails()
    }

    func requestLocationAuthorization() {
        guard canRequestLocationAuthorization else { return }
        locationManager.requestWhenInUseAuthorization()
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.locationAuthorizationStatus = status
            await self.refreshNetworkDetailsNow()
            self.onPathChange?()
        }
    }

    // Reading VPN details walks SystemConfiguration and the running-app list, so the
    // monitor uses this throttled variant when checking several shares in a row.
    func refreshNetworkDetailsIfStale(maxAge: TimeInterval = 2) async {
        if let lastDetailsRefresh, Date().timeIntervalSince(lastDetailsRefresh) < maxAge {
            return
        }

        await refreshNetworkDetailsNow()
    }

    // Fire-and-forget variant for UI callers (onAppear, refresh buttons) that
    // must not block the main thread while details are gathered.
    func refreshNetworkDetails() {
        Task {
            await refreshNetworkDetailsNow()
        }
    }

    func refreshNetworkDetailsNow() async {
        // Coalesce concurrent callers onto the in-flight gather.
        if let detailsRefreshTask {
            await detailsRefreshTask.value
            return
        }

        let task = Task<Void, Never> {
            // CoreWLAN and SystemConfiguration talk to system daemons over XPC
            // and can take seconds; gather off the main thread and publish.
            let snapshot = await Task.detached(priority: .utility) {
                Self.gatherNetworkDetails()
            }.value

            lastDetailsRefresh = Date()
            currentWiFiNetworkName = snapshot.currentWiFiNetworkName
            currentIPv4Subnets = snapshot.currentIPv4Subnets
            activeVPNNames = snapshot.activeVPNNames
            knownVPNNames = snapshot.knownVPNNames
            isVPNConnected = snapshot.isVPNConnected
            hasUnidentifiedTunnel = snapshot.hasUnidentifiedTunnel
        }

        detailsRefreshTask = task
        await task.value
        detailsRefreshTask = nil
    }

    private struct NetworkDetailsSnapshot: Sendable {
        var currentWiFiNetworkName: String?
        var currentIPv4Subnets: [String]
        var activeVPNNames: [String]
        var knownVPNNames: [String]
        var isVPNConnected: Bool
        var hasUnidentifiedTunnel: Bool
    }

    private nonisolated static func gatherNetworkDetails() -> NetworkDetailsSnapshot {
        let currentWiFiNetworkName = readCurrentWiFiNetworkName()
        let activeVPNInterfaceNames = activeVPNInterfaceNames()
        let connectedServiceNames = VPNServiceDiscovery.connectedVPNServiceNames()
        let hasActiveTunnel = !activeVPNInterfaceNames.isEmpty

        var names = Set(VPNServiceDiscovery.vpnServiceNames(for: activeVPNInterfaceNames))
        names.formUnion(connectedServiceNames)

        // Network Extension VPNs (Tailscale, WireGuard, ...) don't appear as
        // SystemConfiguration services, so fall back to naming them by the VPN
        // apps that are currently running while a tunnel interface is active.
        if hasActiveTunnel && names.isEmpty {
            names.formUnion(VPNServiceDiscovery.runningVPNAppNames())
        }

        let identity = VPNConnectionIdentity(
            hasActiveTunnel: hasActiveTunnel,
            identifiedNames: names
        )

        return NetworkDetailsSnapshot(
            currentWiFiNetworkName: currentWiFiNetworkName,
            currentIPv4Subnets: readCurrentIPv4Subnets(),
            activeVPNNames: identity.activeNames,
            knownVPNNames: VPNServiceDiscovery.readKnownVPNNames(including: identity.activeNames),
            isVPNConnected: identity.isConnected,
            hasUnidentifiedTunnel: identity.hasUnidentifiedTunnel
        )
    }

    private func handlePathUpdate(_ path: NWPath) async {
        let newOnlineState = path.status == .satisfied
        let changed = newOnlineState != isOnline
        let previousWiFiNetworkName = currentWiFiNetworkName
        let previousIPv4Subnets = currentIPv4Subnets
        let wasVPNConnected = isVPNConnected
        let hadUnidentifiedTunnel = hasUnidentifiedTunnel
        let previousVPNNames = activeVPNNames
        let previousKnownVPNNames = knownVPNNames
        isOnline = newOnlineState
        await refreshNetworkDetailsNow()

        let wifiNetworkChanged = previousWiFiNetworkName != currentWiFiNetworkName
        let subnetsChanged = previousIPv4Subnets != currentIPv4Subnets
        let vpnChanged = wasVPNConnected != isVPNConnected
            || hadUnidentifiedTunnel != hasUnidentifiedTunnel
            || previousVPNNames != activeVPNNames
            || previousKnownVPNNames != knownVPNNames
        let shouldNotify = changed || wifiNetworkChanged || subnetsChanged || vpnChanged || !hasReceivedPathUpdate
        hasReceivedPathUpdate = true

        if shouldNotify {
            onPathChange?()
        }
    }

    private nonisolated static func readCurrentWiFiNetworkName() -> String? {
        guard let networkName = CWWiFiClient.shared().interface()?.ssid(),
              !networkName.isEmpty
        else {
            return nil
        }

        return networkName
    }

    // The IPv4 networks (CIDR, e.g. "192.168.1.0/24") the Mac is currently on,
    // excluding loopback, link-local, and VPN tunnel interfaces. Used to
    // recognize the network a share was configured on.
    private nonisolated static func readCurrentIPv4Subnets() -> [String] {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let addresses else {
            return []
        }

        defer { freeifaddrs(addresses) }

        var subnets = Set<String>()
        var cursor: UnsafeMutablePointer<ifaddrs>? = addresses

        while let current = cursor {
            let interface = current.pointee
            cursor = interface.ifa_next

            let flags = Int32(interface.ifa_flags)
            guard (flags & IFF_UP) != 0,
                  (flags & IFF_RUNNING) != 0,
                  (flags & IFF_LOOPBACK) == 0,
                  !isVPNInterfaceName(String(cString: interface.ifa_name)),
                  let address = interface.ifa_addr,
                  Int32(address.pointee.sa_family) == AF_INET,
                  hasUsableIPv4Address(address),
                  let netmask = interface.ifa_netmask,
                  Int32(netmask.pointee.sa_family) == AF_INET
            else { continue }

            let ipAddress = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
            }
            let mask = netmask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
            }

            guard mask != 0 else { continue }

            let network = ipAddress & mask
            let dottedNetwork = [24, 16, 8, 0]
                .map { String((network >> $0) & 0xff) }
                .joined(separator: ".")
            subnets.insert("\(dottedNetwork)/\(mask.nonzeroBitCount)")
        }

        return subnets.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private nonisolated static func activeVPNInterfaceNames() -> [String] {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let addresses else {
            return []
        }

        defer { freeifaddrs(addresses) }

        var interfaceNames = Set<String>()
        var cursor: UnsafeMutablePointer<ifaddrs>? = addresses

        while let current = cursor {
            let address = current.pointee
            let flags = Int32(address.ifa_flags)
            let isUp = (flags & IFF_UP) != 0
            let isRunning = (flags & IFF_RUNNING) != 0
            let interfaceName = String(cString: address.ifa_name)

            if isUp,
               isRunning,
               isVPNInterfaceName(interfaceName),
               hasUsableTunnelAddress(address.ifa_addr) {
                interfaceNames.insert(interfaceName)
            }

            cursor = address.ifa_next
        }

        return interfaceNames.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private nonisolated static func isVPNInterfaceName(_ interfaceName: String) -> Bool {
        let normalizedInterfaceName = interfaceName.lowercased()
        let prefixes = ["utun", "ppp", "ipsec", "tap", "tun"]
        return prefixes.contains { normalizedInterfaceName.hasPrefix($0) }
    }

    private nonisolated static func hasUsableTunnelAddress(_ address: UnsafePointer<sockaddr>?) -> Bool {
        guard let address else { return false }

        switch Int32(address.pointee.sa_family) {
        case AF_INET:
            return hasUsableIPv4Address(address)
        case AF_INET6:
            return hasUsableIPv6Address(address)
        default:
            return false
        }
    }

    private nonisolated static func hasUsableIPv4Address(_ address: UnsafePointer<sockaddr>) -> Bool {
        let ipv4Address = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
            UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
        }

        let firstOctet = (ipv4Address >> 24) & 0xff
        let secondOctet = (ipv4Address >> 16) & 0xff

        if firstOctet == 0 || firstOctet == 127 {
            return false
        }

        if firstOctet == 169 && secondOctet == 254 {
            return false
        }

        return true
    }

    private nonisolated static func hasUsableIPv6Address(_ address: UnsafePointer<sockaddr>) -> Bool {
        let bytes = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { pointer in
            withUnsafeBytes(of: pointer.pointee.sin6_addr) { Array($0) }
        }

        let isUnspecified = bytes.allSatisfy { $0 == 0 }
        let isLoopback = bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1
        let isLinkLocal = bytes.count >= 2 && bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80
        let isMulticast = bytes.first == 0xff

        return !isUnspecified && !isLoopback && !isLinkLocal && !isMulticast
    }

}

private final class ReachabilityAttempt: @unchecked Sendable {
    private let connection: NWConnection
    private let continuation: CheckedContinuation<Bool, Never>
    private let lock = NSLock()
    private var didResume = false

    init(connection: NWConnection, continuation: CheckedContinuation<Bool, Never>) {
        self.connection = connection
        self.continuation = continuation
    }

    func finish(_ result: Bool) {
        lock.lock()
        guard !didResume else {
            lock.unlock()
            return
        }

        didResume = true
        lock.unlock()
        connection.cancel()
        continuation.resume(returning: result)
    }
}
