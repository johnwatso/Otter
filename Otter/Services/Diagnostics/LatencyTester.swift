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
