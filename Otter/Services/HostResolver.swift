import Darwin
import Foundation

protocol HostResolving: Sendable {
    func resolveIPAddress(for hostname: String) async -> String?
}

struct SystemHostResolver: HostResolving {
    func resolveIPAddress(for hostname: String) async -> String? {
        await Task.detached(priority: .utility) { () -> String? in
            var result: UnsafeMutablePointer<addrinfo>?
            let status = getaddrinfo(hostname, nil, nil, &result)
            guard status == 0, let first = result else { return nil }
            defer { freeaddrinfo(result) }

            var hostnameBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let nameInfoStatus = getnameinfo(
                first.pointee.ai_addr,
                first.pointee.ai_addrlen,
                &hostnameBuffer,
                socklen_t(hostnameBuffer.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard nameInfoStatus == 0 else { return nil }
            return String(cString: hostnameBuffer)
        }.value
    }
}
