import Darwin
import Foundation
import dnssd

protocol HostResolving: Sendable {
    func resolveIPAddresses(for hostname: String) async -> [String]
}

extension HostResolving {
    func resolveIPAddress(for hostname: String) async -> String? {
        await resolveIPAddresses(for: hostname).first
    }
}

struct BonjourServiceIdentity: Equatable, Sendable {
    let name: String
    let type: String
    let domain: String
}

struct SystemHostResolver: HostResolving {
    private static let resolutionQueue = DispatchQueue(label: "Otter.HostResolver", qos: .utility)

    func resolveIPAddresses(for hostname: String) async -> [String] {
        let addressableHostname: String
        if let service = Self.bonjourServiceIdentity(for: hostname) {
            guard let resolvedHost = await Self.resolveBonjourService(service, timeout: 3) else {
                return []
            }
            addressableHostname = resolvedHost
        } else {
            addressableHostname = hostname
        }

        return await Task.detached(priority: .utility) {
            Self.numericIPAddresses(for: addressableHostname)
        }.value
    }

    // Mounted SMB volumes are commonly identified by macOS as a DNS-SD service,
    // e.g. "Living Room NAS._smb._tcp.local". That value must first be resolved
    // to its target host before ordinary address lookup can find the LAN IP.
    static func bonjourServiceIdentity(for hostname: String) -> BonjourServiceIdentity? {
        let marker = "._smb._tcp."
        guard let markerRange = hostname.range(of: marker, options: [.caseInsensitive]),
              markerRange.lowerBound != hostname.startIndex
        else { return nil }

        let name = String(hostname[..<markerRange.lowerBound])
        var domain = String(hostname[markerRange.upperBound...])
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !name.isEmpty, !domain.isEmpty else { return nil }
        domain.append(".")

        return BonjourServiceIdentity(name: name, type: "_smb._tcp.", domain: domain)
    }

    private static func resolveBonjourService(
        _ service: BonjourServiceIdentity,
        timeout: TimeInterval
    ) async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let attempt = BonjourResolutionAttempt(continuation: continuation)

            resolutionQueue.async {
                var serviceRef: DNSServiceRef?
                let context = Unmanaged.passUnretained(attempt).toOpaque()
                let status = DNSServiceResolve(
                    &serviceRef,
                    0,
                    UInt32(kDNSServiceInterfaceIndexAny),
                    service.name,
                    service.type,
                    service.domain,
                    bonjourResolutionCallback,
                    context
                )

                guard status == kDNSServiceErr_NoError, let serviceRef else {
                    attempt.finish(nil)
                    return
                }

                attempt.serviceRef = serviceRef
                Self.resolutionQueue.asyncAfter(deadline: .now() + max(timeout, 0.1)) {
                    attempt.finish(nil)
                }

                guard DNSServiceSetDispatchQueue(serviceRef, Self.resolutionQueue) == kDNSServiceErr_NoError else {
                    attempt.finish(nil)
                    return
                }
            }
        }
    }

    private static func numericIPAddresses(for hostname: String) -> [String] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP

        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(hostname, nil, &hints, &result)
        guard status == 0, let first = result else { return [] }
        defer { freeaddrinfo(result) }

        var ipv4Addresses: [String] = []
        var ipv6Addresses: [String] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first

        while let current = cursor {
            defer { cursor = current.pointee.ai_next }
            guard let address = current.pointee.ai_addr else { continue }

            var hostnameBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let nameInfoStatus = getnameinfo(
                address,
                current.pointee.ai_addrlen,
                &hostnameBuffer,
                socklen_t(hostnameBuffer.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard nameInfoStatus == 0 else { continue }

            let addressString = String(cString: hostnameBuffer)
            if current.pointee.ai_family == AF_INET {
                if !ipv4Addresses.contains(addressString) {
                    ipv4Addresses.append(addressString)
                }
            } else if current.pointee.ai_family == AF_INET6,
                      !ipv6Addresses.contains(addressString) {
                ipv6Addresses.append(addressString)
            }
        }

        // IPv4 is the most useful fallback for typical LAN SMB shares. Return
        // every result so callers can retain an existing address when a
        // multi-homed server merely changes DNS result order.
        return ipv4Addresses + ipv6Addresses
    }
}

private let bonjourResolutionCallback: DNSServiceResolveReply = {
    _, _, _, errorCode, _, hostTarget, _, _, _, context in
    guard let context else { return }
    let attempt = Unmanaged<BonjourResolutionAttempt>.fromOpaque(context).takeUnretainedValue()

    guard errorCode == kDNSServiceErr_NoError, let hostTarget else {
        attempt.finish(nil)
        return
    }
    attempt.finish(String(cString: hostTarget))
}

private final class BonjourResolutionAttempt: @unchecked Sendable {
    var serviceRef: DNSServiceRef?
    private var continuation: CheckedContinuation<String?, Never>?

    init(continuation: CheckedContinuation<String?, Never>) {
        self.continuation = continuation
    }

    // All access is serialized on SystemHostResolver.resolutionQueue.
    func finish(_ hostname: String?) {
        guard let continuation else { return }
        self.continuation = nil
        if let serviceRef {
            DNSServiceRefDeallocate(serviceRef)
            self.serviceRef = nil
        }
        continuation.resume(returning: hostname)
    }
}
