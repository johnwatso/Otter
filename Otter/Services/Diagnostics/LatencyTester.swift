import Darwin
import Foundation

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
/// happens first and is not timed. A plain socket is used on purpose:
/// `NWConnection` spends tens of milliseconds on path setup before it reports
/// ready, which would swamp a sub-millisecond LAN round trip.
enum TCPLatencyProbe {
    /// Milliseconds to connect (the best of a few tries, to shed scheduling
    /// noise), or nil if the server did not answer in time.
    static func measure(url: URL, timeout: TimeInterval = 1) async -> Double? {
        guard let host = url.host(percentEncoded: false),
              let port = NetworkReachabilityService.reachabilityPort(for: url)
        else { return nil }

        var address = host
        if !NetworkShare.isIPAddress(host) {
            guard let resolved = await SystemHostResolver().resolveIPAddress(for: host) else { return nil }
            address = resolved
        }

        let target = address
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var best: Double?
                for _ in 0..<3 {
                    guard let sample = connectTime(address: target, port: port, timeout: timeout) else { break }
                    best = min(best ?? sample, sample)
                }
                continuation.resume(returning: best)
            }
        }
    }

    private static func connectTime(address: String, port: UInt16, timeout: TimeInterval) -> Double? {
        // A scoped IPv6 address ("fe80::1%en0") resolves fine here too.
        var hints = addrinfo(
            ai_flags: AI_NUMERICHOST | AI_NUMERICSERV, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil
        )
        var results: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(address, String(port), &hints, &results) == 0, let info = results else { return nil }
        defer { freeaddrinfo(results) }

        let descriptor = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }

        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else { return nil }
        var noSigPipe: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        let start = ContinuousClock.now
        if connect(descriptor, info.pointee.ai_addr, info.pointee.ai_addrlen) != 0 {
            guard errno == EINPROGRESS else { return nil }
            var poller = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
            guard poll(&poller, 1, Int32(timeout * 1000)) > 0 else { return nil }
            var socketError: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0,
                  socketError == 0
            else { return nil }
        }
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.seconds) * 1000
            + Double(elapsed.components.attoseconds) / 1e15
    }
}
