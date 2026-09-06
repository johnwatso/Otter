import Foundation
import Darwin

struct NASDiagnosticsService {
    func run(share: NetworkShare, mountService: MountService,
             update: @escaping @MainActor @Sendable (NASDiagnosticResult, String) -> Void) async {
        let mountedURL = await mountService.mountedURL(for: share)
        var mount = MountDiagnostic(protocolName: share.url?.scheme?.uppercased() ?? "Unavailable",
                                    server: share.host ?? "Unavailable",
                                    shareName: NetworkShare.inferredShareName(from: share.urlString) ?? "Unavailable")
        if let mountedURL {
            mount.mountPath = mountedURL.path
            // Read the actual mount source, never a credential-bearing raw URL.
            if let actual = Self.mountedSource(path: mountedURL.path) {
                mount.protocolName = actual.protocolName
                mount.server = actual.server
                mount.shareName = actual.shareName
                mount.connectedUsing = NetworkShare.isIPAddress(actual.server) ? "IP address" : "Hostname"
            }
        }
        var result = NASDiagnosticResult(mount: mount)
        result.lastWakeAt = Self.lastWakeDate()
        await update(result, "Checking SMB…")
        guard !Task.isCancelled else { return }
        if mount.protocolName == "SMB", let path = mount.mountPath {
            var smb = await SMBInspector().inspect(mountPath: path)
            smb = await SMBMultichannelInspector().inspect(mountPath: path, into: smb)
            let types = NetworkInterfaceInspector.interfaceTypes()
            smb.wifiParticipating = smb.wifiParticipating || (smb.channels ?? []).contains { $0.isActive && types[$0.interface ?? ""] == "Wi-Fi" }
            result.smb = smb
        }
        await update(result, "Checking network…")
        guard !Task.isCancelled else { return }
        let sessionAddress = result.smb?.channels?.first(where: { $0.isActive && $0.serverIP != nil })?.serverIP
        // Prefer the established session endpoint over DNS order on multihomed NASes.
        let addresses = await Self.resolve(mount.server)
        result.mount.resolvedIP = addresses.first
        if let target = sessionAddress ?? addresses.first {
            result.network = await NetworkInterfaceInspector().inspect(address: target, isSessionAddress: sessionAddress != nil)
            result.smb?.clientLinkMbps = result.network.interfaceLinkMbps
            Self.applyWiFiContext(to: &result)
            await update(result, "Checking latency…")
            guard !Task.isCancelled else { return }
            result.latency = await LatencyTester().test(address: target)
        }
        guard !Task.isCancelled else { return }
        result.generatedAt = Date()
        result.isComplete = true
        await update(result, "Diagnostics complete")
    }

    static func applyWiFiContext(to result: inout NASDiagnosticResult) {
        let active = result.smb?.activeChannels
        let types = result.network.interfaceTypes
        let wifiChannels = active?.filter { types[$0.interface ?? ""] == "Wi-Fi" }
        if let active, active.allSatisfy({ types[$0.interface ?? ""] != nil }) {
            result.network.wifi.usedForSMB = !(wifiChannels ?? []).isEmpty
        } else if result.mount.protocolName == "SMB", result.network.type == "Wi-Fi", result.network.targetIsSessionAddress {
            result.network.wifi.usedForSMB = true
        }
        result.network.wifi.participatingInMultichannel = !(wifiChannels ?? []).isEmpty && result.smb?.multichannel == true
        if result.network.wifi.usedForSMB == true {
            let speed = wifiChannels?.compactMap(\.linkMbps).max() ?? (result.network.type == "Wi-Fi" ? result.network.linkMbps : nil)
            if let speed, let ethernet = result.network.availableEthernetMbps {
                result.network.fasterEthernetAvailable = ethernet > speed
            }
        }
    }

    static func lastWakeDate(now: Date = Date()) -> Date? {
        var wake = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.waketime", &wake, &size, nil, 0) == 0, size == MemoryLayout<timeval>.size, wake.tv_sec > 0 else { return nil }
        let date = Date(timeIntervalSince1970: Double(wake.tv_sec) + Double(wake.tv_usec) / 1_000_000)
        return date <= now ? date : nil
    }

    static func resolve(_ host: String, using resolver: any HostResolving = SystemHostResolver(), timeout: TimeInterval = 5) async -> [String] {
        if NetworkShare.isIPAddress(host) { return [host] }
        let attempt = DiagnosticResolutionAttempt()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                attempt.install(continuation)
                Task {
                    guard !Task.isCancelled else { attempt.finish([]); return }
                    attempt.finish(await resolver.resolveIPAddresses(for: host))
                }
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(max(timeout, 0.01) * 1_000_000_000))
                    attempt.finish([])
                }
            }
        } onCancel: {
            attempt.finish([])
        }
    }

    static func temporaryIPURL(share: NetworkShare, address: String) -> URL? {
        guard NetworkShare.isIPAddress(address), let url = share.url, url.scheme == "smb",
              let host = share.host, !NetworkShare.isIPAddress(host),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        components.host = NetworkShare.urlComponentsHost(forIPAddress: address)
        return components.url
    }

    static func mountedSource(path: String) -> MountDiagnostic? {
        let count = getfsstat(nil, 0, MNT_NOWAIT)
        guard count > 0 else { return nil }
        let empty: statfs = statfs()
        var entries = Array(repeating: empty, count: Int(count) + 8)
        let byteCount = Int32(entries.count * MemoryLayout<statfs>.stride)
        let actualCount = entries.withUnsafeMutableBufferPointer { getfsstat($0.baseAddress, byteCount, MNT_NOWAIT) }
        guard actualCount > 0 else { return nil }
        for index in 0..<min(Int(actualCount), entries.count) {
            var entry = entries[index]
            let mountPath = withUnsafePointer(to: &entry.f_mntonname) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) } }
            guard mountPath == path else { continue }
            return diagnostic(for: entry, mountPath: mountPath)
        }
        return nil
    }

    static func diagnostic(for filesystem: statfs, mountPath: String) -> MountDiagnostic {
        var entry = filesystem
        let source = withUnsafePointer(to: &entry.f_mntfromname) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) } }
        let type = withUnsafePointer(to: &entry.f_fstypename) { $0.withMemoryRebound(to: CChar.self, capacity: 16) { String(cString: $0) } }
        if type == "smbfs", let url = URL(string: "smb:" + source), let host = url.host(percentEncoded: false) {
            return MountDiagnostic(protocolName: "SMB", server: host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")), shareName: url.pathComponents.dropFirst().first ?? "Unavailable", mountPath: mountPath)
        }
        if type == "nfs", let separator = source.range(of: ":/") {
            return MountDiagnostic(protocolName: "NFS", server: String(source[..<separator.lowerBound]).trimmingCharacters(in: CharacterSet(charactersIn: "[]")),
                           shareName: String(source[separator.upperBound...]), mountPath: mountPath)
        }
        return MountDiagnostic(protocolName: type.uppercased(), server: "Unavailable", shareName: "Unavailable", mountPath: mountPath)
    }
}

/// getaddrinfo cannot be interrupted. Release the diagnostic caller on timeout
/// or cancellation while the system resolver finishes independently.
private final class DiagnosticResolutionAttempt: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[String], Never>?
    private var result: [String]?

    func install(_ continuation: CheckedContinuation<[String], Never>) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(returning: result)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func finish(_ result: [String]) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: result)
    }
}
