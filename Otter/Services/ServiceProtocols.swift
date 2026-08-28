import Foundation

protocol MountServicing: Sendable {
    func mountedURL(for share: NetworkShare) async -> URL?
    func mount(_ share: NetworkShare, urlOverride: URL?) async throws -> URL?
    func unmount(_ share: NetworkShare) async throws
}

protocol WakeOnLANServicing: Sendable {
    func sendWakePacket(using configuration: WakeOnLANConfiguration) async throws
}

protocol VPNConnecting: Sendable {
    func connect(named serviceName: String, timeout: TimeInterval) async throws
}

extension VPNConnecting {
    func connect(named serviceName: String) async throws {
        try await connect(named: serviceName, timeout: 30)
    }
}

enum MountHealthResult: Equatable, Sendable {
    case healthy
    case unresponsive
    case unavailable(String)
}

protocol MountHealthChecking: Sendable {
    func checkMount(at url: URL, timeout: TimeInterval) async -> MountHealthResult
    func checkPolicy(at url: URL, policy: ShareHealthCheckConfiguration, timeout: TimeInterval) async -> MountHealthResult
    func unmountForRecovery(at url: URL, timeout: TimeInterval) async -> Bool
}

extension MountHealthChecking {
    // Test doubles and third-party implementations retain the original health
    // contract. The system implementation adds the richer capacity, writability
    // and sentinel checks.
    func checkPolicy(at url: URL, policy: ShareHealthCheckConfiguration, timeout: TimeInterval) async -> MountHealthResult {
        await checkMount(at: url, timeout: timeout)
    }
}

@MainActor
protocol NetworkReachabilityProviding: AnyObject {
    var isOnline: Bool { get }
    var currentWiFiNetworkName: String? { get }
    var isVPNConnected: Bool { get }
    var currentIPv4Subnets: [String] { get }
    var activeVPNNames: [String] { get }
    var hasUnidentifiedTunnel: Bool { get }
    var onPathChange: (() -> Void)? { get set }

    func canReachServer(for url: URL, timeout: TimeInterval) async -> Bool
    func refreshNetworkDetailsIfStale(maxAge: TimeInterval) async
    func refreshNetworkDetailsNow() async
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
    /// - Parameter isRequestedAttempt: whether this status came out of a
    ///   connection the user asked for (or the single automatic attempt a
    ///   Connect Once share makes). Modes that stay quiet in the background
    ///   still report problems from those attempts.
    func notifyStatusChange(
        for share: NetworkShare,
        previous: ShareStatus,
        current: ShareStatus,
        isRequestedAttempt: Bool
    )
}

@MainActor
protocol DetectedShareNotifying: AnyObject {
    func notifyDetectedShare(_ suggestion: MountedShareSuggestion)
    func withdrawDetectedShareNotification(for suggestion: MountedShareSuggestion)
}

extension MountService: MountServicing {}
extension WakeOnLANService: WakeOnLANServicing {}
extension MountHealthService: MountHealthChecking {}
extension NetworkReachabilityService: NetworkReachabilityProviding {}
extension NotificationService: ShareNotificationProviding {}
extension NotificationService: DetectedShareNotifying {}
