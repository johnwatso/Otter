import Foundation
import Network

struct LatencyTester {
    func test(address: String) async -> LatencyDiagnostic? {
        guard NetworkShare.isIPAddress(address) else { return nil }
        let ipv6 = address.contains(":")
        // ping's own deadline complements the subprocess timeout. ICMP may be blocked.
        let text = await DiagnosticCommandRunner().run(ipv6 ? "/sbin/ping6" : "/sbin/ping",
            ipv6 ? ["-n", "-c", "4", address] : ["-n", "-c", "4", "-W", "1000", address], timeout: 7, acceptedExitCodes: [0, 2])
        return text.map(Self.parse)
    }
    static func parse(_ text: String) -> LatencyDiagnostic {
        let values = DiagnosticParsing.capture(#"(?:round-trip|rtt).*?=\s*([\d.]+)/([\d.]+)/([\d.]+)/"#, in: text)
        let loss = DiagnosticParsing.capture(#"([\d.]+)% packet loss"#, in: text)?.first.flatMap(Double.init)
        return LatencyDiagnostic(minimum: values.flatMap { Double($0[0]) }, average: values.flatMap { Double($0[1]) }, maximum: values.flatMap { Double($0[2]) }, loss: loss)
    }
}

/// Round-trip time to a share's server, measured as the time to open a TCP
/// connection to its port. That is what `ping` reports, give or take a
/// handshake, so the number can be compared with it directly. Name resolution
/// happens first and is not timed.
enum TCPLatencyProbe {
    /// Milliseconds to connect, or nil if the server did not answer in time.
    static func measure(url: URL, timeout: TimeInterval = 1) async -> Double? {
        guard let host = url.host(percentEncoded: false),
              let rawPort = NetworkReachabilityService.reachabilityPort(for: url),
              let port = NWEndpoint.Port(rawValue: rawPort)
        else { return nil }

        var address = host
        if !NetworkShare.isIPAddress(host) {
            guard let resolved = await SystemHostResolver().resolveIPAddress(for: host) else { return nil }
            address = resolved
        }

        let queue = DispatchQueue(label: "Otter.TCPLatencyProbe", qos: .utility)
        let connection = NWConnection(host: NWEndpoint.Host(address), port: port, using: .tcp)

        return await withCheckedContinuation { continuation in
            let attempt = Attempt(connection: connection, continuation: continuation)
            let start = ContinuousClock.now

            connection.stateUpdateHandler = { @Sendable state in
                switch state {
                case .ready:
                    let elapsed = ContinuousClock.now - start
                    attempt.finish(
                        Double(elapsed.components.seconds) * 1000
                            + Double(elapsed.components.attoseconds) / 1e15
                    )
                case .failed, .waiting:
                    attempt.finish(nil)
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { attempt.finish(nil) }
        }
    }

    private final class Attempt: @unchecked Sendable {
        private let connection: NWConnection
        private let continuation: CheckedContinuation<Double?, Never>
        private let lock = NSLock()
        private var didResume = false

        init(connection: NWConnection, continuation: CheckedContinuation<Double?, Never>) {
            self.connection = connection
            self.continuation = continuation
        }

        func finish(_ result: Double?) {
            lock.lock()
            guard !didResume else { lock.unlock(); return }
            didResume = true
            lock.unlock()
            connection.cancel()
            continuation.resume(returning: result)
        }
    }
}
