import Foundation

protocol WebUIProbing: Sendable {
    func responds(at url: URL) async -> Bool
}

/// A small, fixed set of web ports, checked only while viewing a server.
/// A listening TCP socket alone isn't enough: require HTTP or an HTTPS
/// certificate response, including the self-signed certificates common on NASes.
struct WebUIDiscoveryService: Sendable {
    var resolver: any HostResolving = SystemHostResolver()
    var probe: any WebUIProbing = WebUIHTTPProbe()

    static func candidates(for address: String) -> [URL] {
        let host = address.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard NetworkShare.isIPAddress(host) else { return [] }
        return [("https", 443), ("https", 5001), ("https", 8443),
                ("http", 80), ("http", 5000), ("http", 8080)].compactMap { scheme, port in
            var components = URLComponents()
            components.scheme = scheme
            components.host = host.contains(":") ? "[\(host)]" : host
            components.port = (port == 443 || port == 80) ? nil : port
            components.path = "/"
            return components.url
        }
    }

    func discover(host: String) async -> URL? {
        let addresses: [String]
        let unbracketedHost = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if NetworkShare.isIPAddress(unbracketedHost) {
            addresses = [unbracketedHost]
        } else {
            // Resolve afresh instead of probing a cached address that could now
            // belong to another device. The resolver also handles SMB Bonjour names.
            addresses = await resolver.resolveIPAddresses(for: host)
        }
        guard !Task.isCancelled else { return nil }
        // Bound traffic even when DNS returns many addresses. Prefer the
        // resolver's order, then HTTPS, regardless of response timing.
        let candidates = addresses.prefix(2).flatMap { Self.candidates(for: $0) }
        return await withTaskGroup(of: (Int, Bool).self) { group in
            for (index, url) in candidates.enumerated() {
                group.addTask { (index, await probe.responds(at: url)) }
            }
            var found: Int?
            for await (index, responds) in group where responds {
                found = min(found ?? index, index)
            }
            guard !Task.isCancelled, let found else { return nil }
            return candidates[found]
        }
    }
}

struct WebUIHTTPProbe: WebUIProbing {
    func responds(at url: URL) async -> Bool {
        await responds(at: url, configuration: .ephemeral)
    }

    func responds(at url: URL, configuration: URLSessionConfiguration) async -> Bool {
        guard !Task.isCancelled else { return false }
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 3
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration, delegate: WebUIProbeDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "HEAD"
        do {
            let (_, response) = try await session.data(for: request)
            // Login challenges, redirects and method-not-allowed responses all
            // establish that a web server exists; no page body is needed.
            return response is HTTPURLResponse && !Task.isCancelled
        } catch {
            guard !Task.isCancelled, url.scheme == "https",
                  let error = error as? URLError else { return false }
            switch error.code {
            case .serverCertificateUntrusted, .serverCertificateHasBadDate,
                 .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
                // Detect the endpoint without accepting its certificate. The
                // user's browser retains its normal certificate checks.
                return true
            default:
                return false
            }
        }
    }
}

private final class WebUIProbeDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        // A local redirect already proves the endpoint exists. Don't probe an
        // unrelated destination or let a redirect determine the saved URL.
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        // No stored credentials or authentication prompts during discovery.
        completionHandler((challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust)
            ? .performDefaultHandling : .rejectProtectionSpace, nil)
    }
}
