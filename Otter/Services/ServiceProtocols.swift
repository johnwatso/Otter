import Foundation

protocol MountServicing: Sendable {
    func mountedURL(for share: NetworkShare) async -> URL?
    func mount(_ share: NetworkShare, urlOverride: URL?) async throws -> URL?
    func unmount(_ share: NetworkShare) async throws
}

protocol WakeOnLANServicing: Sendable {
    func sendWakePacket(using configuration: WakeOnLANConfiguration) async throws
}

enum MountHealthResult: Equatable, Sendable {
    case healthy
    case unresponsive
    case unavailable(String)
}

protocol MountHealthChecking: Sendable {
    func checkMount(at url: URL, timeout: TimeInterval) async -> MountHealthResult
    func unmountForRecovery(at url: URL, timeout: TimeInterval) async -> Bool
}

@MainActor
protocol NetworkReachabilityProviding: AnyObject {
    var isOnline: Bool { get }
    var currentWiFiNetworkName: String? { get }
    var isVPNConnected: Bool { get }
    var currentIPv4Subnets: [String] { get }
    var activeVPNNames: [String] { get }
    var onPathChange: (() -> Void)? { get set }

    func canReachServer(for url: URL, timeout: TimeInterval) async -> Bool
    func refreshNetworkDetailsIfStale(maxAge: TimeInterval) async
}

extension NetworkReachabilityProviding {
    func canReachServer(for url: URL) async -> Bool {
        await canReachServer(for: url, timeout: 3)
    }

    func refreshNetworkDetailsIfStale() async {
        await refreshNetworkDetailsIfStale(maxAge: 2)
    }
}

@MainActor
protocol ShareNotificationProviding: AnyObject {
    func notifyStatusChange(for share: NetworkShare, previous: ShareStatus, current: ShareStatus)
}

extension MountService: MountServicing {}
extension WakeOnLANService: WakeOnLANServicing {}
extension MountHealthService: MountHealthChecking {}
extension NetworkReachabilityService: NetworkReachabilityProviding {}
extension NotificationService: ShareNotificationProviding {}
