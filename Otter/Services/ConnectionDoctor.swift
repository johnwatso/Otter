import Foundation

enum DiagnosticStepStatus: String, Sendable {
    case passed
    case warning
    case failed
    case information
}

struct ConnectionDiagnosticStep: Identifiable, Equatable, Sendable {
    let id = UUID()
    let title: String
    let detail: String
    let status: DiagnosticStepStatus
}

struct ConnectionDiagnosticReport: Equatable, Sendable {
    let generatedAt: Date
    let steps: [ConnectionDiagnosticStep]
    let hasRepairableItems: Bool

    init(
        generatedAt: Date,
        steps: [ConnectionDiagnosticStep],
        hasRepairableItems: Bool = false
    ) {
        self.generatedAt = generatedAt
        self.steps = steps
        self.hasRepairableItems = hasRepairableItems
    }

    var hasFailures: Bool {
        steps.contains { $0.status == .failed }
    }

    var redactedText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
        var lines = [
            "Otter Connection Doctor",
            "Generated: \(generatedAt.formatted(date: .abbreviated, time: .standard))",
            "Otter: \(version) (\(build))",
            "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "Share and network identifiers: redacted",
            ""
        ]

        for step in steps {
            lines.append("[\(step.status.rawValue.uppercased())] \(step.title): \(step.detail)")
        }
        return lines.joined(separator: "\n")
    }
}

@MainActor
final class ConnectionDoctor {
    private let settings: SettingsStore
    private let mountService: any MountServicing
    private let mountHealthService: any MountHealthChecking
    private let networkService: any NetworkReachabilityProviding
    private let monitor: ShareMonitor
    private let hostResolver: any HostResolving

    init(
        settings: SettingsStore,
        mountService: any MountServicing,
        mountHealthService: any MountHealthChecking,
        networkService: any NetworkReachabilityProviding,
        monitor: ShareMonitor,
        hostResolver: any HostResolving = SystemHostResolver()
    ) {
        self.settings = settings
        self.mountService = mountService
        self.mountHealthService = mountHealthService
        self.networkService = networkService
        self.monitor = monitor
        self.hostResolver = hostResolver
    }

    func run(for share: NetworkShare, attemptMount: Bool) async -> ConnectionDiagnosticReport {
        var steps: [ConnectionDiagnosticStep] = []
        await networkService.refreshNetworkDetailsIfStale(maxAge: 0)

        guard let url = share.url,
              url.scheme?.lowercased() == "smb",
              url.host(percentEncoded: false) != nil
        else {
            steps.append(.init(
                title: "Share configuration",
                detail: "The SMB address is invalid.",
                status: .failed
            ))
            return ConnectionDiagnosticReport(generatedAt: Date(), steps: steps)
        }

        if url.user(percentEncoded: false) != nil || url.password(percentEncoded: false) != nil {
            steps.append(.init(
                title: "Share configuration",
                detail: "The address contains a username or password. Remove it and use macOS Keychain.",
                status: .failed
            ))
        } else {
            steps.append(.init(
                title: "Share configuration",
                detail: "The SMB address and mount location are valid.",
                status: .passed
            ))
        }

        let effectivePauseState = settings.effectivePauseState(for: share)
        if let pauseState = effectivePauseState {
            let detail = pauseState.resumeAt == nil
                ? "Automatic mounting is paused until resumed."
                : "Automatic mounting is temporarily paused."
            steps.append(.init(title: "Automatic mounting", detail: detail, status: .warning))
        } else {
            steps.append(.init(title: "Automatic mounting", detail: "No pause is active.", status: .passed))
        }

        steps.append(.init(
            title: "Network path",
            detail: networkService.isOnline ? "macOS reports an active network path." : "No active network path is available.",
            status: networkService.isOnline ? .passed : .failed
        ))

        var ruleEvaluation = share.rules.evaluate(
            currentWiFiNetworkName: networkService.currentWiFiNetworkName,
            isVPNConnected: networkService.isVPNConnected,
            activeVPNNames: networkService.activeVPNNames,
            currentIPv4Subnets: networkService.currentIPv4Subnets
        )

        if attemptMount,
           !ruleEvaluation.allowsConnection,
           effectivePauseState == nil,
           networkService.isOnline,
           share.rules.hasVPNRule,
           share.rules.requiredVPNName != nil {
            await monitor.retry(share)
            await networkService.refreshNetworkDetailsNow()
            ruleEvaluation = share.rules.evaluate(
                currentWiFiNetworkName: networkService.currentWiFiNetworkName,
                isVPNConnected: networkService.isVPNConnected,
                activeVPNNames: networkService.activeVPNNames,
                currentIPv4Subnets: networkService.currentIPv4Subnets
            )
        }
        let directNetworkEvaluation = share.rules.evaluate(
            currentWiFiNetworkName: networkService.currentWiFiNetworkName,
            isVPNConnected: false,
            activeVPNNames: [],
            currentIPv4Subnets: networkService.currentIPv4Subnets
        )
        let connectionConditionsDetail: String
        if ruleEvaluation.allowsConnection,
           share.rules.hasVPNRule,
           networkService.isVPNConnected,
           !directNetworkEvaluation.allowsConnection {
            let selectedName = share.rules.requiredVPNName
            let selectedVPNIsIdentified = !networkService.hasUnidentifiedTunnel && (selectedName.map { requiredName in
                networkService.activeVPNNames.contains {
                    $0.localizedCaseInsensitiveCompare(requiredName) == .orderedSame
                }
            } ?? false)

            if selectedVPNIsIdentified {
                connectionConditionsDetail = "The selected VPN is connected. Otter will verify access by checking the server."
            } else if networkService.hasUnidentifiedTunnel {
                connectionConditionsDetail = "A VPN tunnel is active, but macOS did not expose its profile name to Otter. Otter will verify access by checking the server."
            } else {
                connectionConditionsDetail = "A different VPN is connected. Otter’s background monitor checks this server without treating an unavailable server as a connection error."
            }
        } else if ruleEvaluation.allowsConnection {
            connectionConditionsDetail = "The current network satisfies this share's conditions."
        } else if case let .waitingForVPN(name) = monitor.status(for: share) {
            connectionConditionsDetail = "Connect to “\(name)” to satisfy this share's VPN condition."
        } else {
            connectionConditionsDetail = "The current network does not satisfy this share's conditions."
        }

        steps.append(.init(
            title: "Connection conditions",
            detail: connectionConditionsDetail,
            status: ruleEvaluation.allowsConnection ? .passed : .warning
        ))
        let configurationCanBeRepaired = url.user(percentEncoded: false) == nil
            && url.password(percentEncoded: false) == nil
        let canSafelyAttemptRepair = configurationCanBeRepaired
            && effectivePauseState == nil
            && networkService.isOnline
            && (ruleEvaluation.allowsConnection
                || (share.rules.hasVPNRule && share.rules.requiredVPNName != nil))

        let originalHost = url.host(percentEncoded: false) ?? ""
        let hasCredentials = settings.hasCredentials(for: originalHost)
            || share.cachedIPAddress.map(settings.hasCredentials(for:)) == true
        steps.append(.init(
            title: "Keychain credentials",
            detail: hasCredentials
                ? "A matching macOS Keychain credential is available."
                : "No matching credential was found. Connect once in Finder and save the password.",
            status: hasCredentials ? .passed : .warning
        ))

        let resolvedIPAddresses = NetworkShare.isIPAddress(originalHost)
            ? []
            : await NetworkShare.resolveIPAddresses(for: originalHost, using: hostResolver)
        let resolvedIPAddress = resolvedIPAddresses.first
        let cacheUpdate: CachedIPAddressUpdate
        if !resolvedIPAddresses.isEmpty, !networkService.isVPNConnected {
            cacheUpdate = settings.recordResolvedIPAddresses(resolvedIPAddresses, for: share.id)
        } else {
            // A VPN may resolve the hostname to a tunnel-only address. Keep the
            // learned LAN fallback intact until the local network is observed.
            cacheUpdate = .ignored
        }
        let observedShare = settings.share(id: share.id) ?? share

        var reachableURL = url
        var reachable = await networkService.canReachServer(for: url, timeout: 3)
        var usedFallbackAddress = false
        if !reachable,
           networkService.isVPNConnected,
           let cachedIPAddress = observedShare.cachedIPAddress,
           !NetworkShare.isIPAddress(originalHost),
           var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.host = cachedIPAddress
            if let fallbackURL = components.url,
               await networkService.canReachServer(for: fallbackURL, timeout: 3) {
                reachable = true
                reachableURL = fallbackURL
                usedFallbackAddress = true
            }
        }

        let nameResolutionStep: ConnectionDiagnosticStep
        if NetworkShare.isIPAddress(originalHost) {
            nameResolutionStep = .init(
                title: "Name resolution",
                detail: "The share already uses an IP address.",
                status: .information
            )
        } else if resolvedIPAddress != nil {
            nameResolutionStep = .init(
                title: "Name resolution",
                detail: SystemHostResolver.bonjourServiceIdentity(for: originalHost) == nil
                    ? "The server name resolved successfully."
                    : "The Bonjour SMB service resolved to its host and network address.",
                status: .passed
            )
        } else if usedFallbackAddress {
            nameResolutionStep = .init(
                title: "Name resolution",
                detail: "Direct name resolution failed, but the cached VPN fallback address is reachable.",
                status: .warning
            )
        } else if reachable {
            nameResolutionStep = .init(
                title: "Name resolution",
                detail: "Direct DNS lookup returned no address, but macOS can still reach the SMB service, likely through Bonjour or an existing connection.",
                status: .information
            )
        } else {
            nameResolutionStep = .init(
                title: "Name resolution",
                detail: "The server name could not be resolved.",
                status: .failed
            )
        }
        steps.append(nameResolutionStep)

        if !NetworkShare.isIPAddress(originalHost) {
            let recentChangeCount = observedShare.recentIPAddressChangeCount()
            let stabilityStep: ConnectionDiagnosticStep
            if recentChangeCount >= NetworkShare.ipAddressInstabilityThreshold {
                stabilityStep = .init(
                    title: "LAN address stability",
                    detail: "Otter observed the LAN address change \(recentChangeCount) times in the last 30 days. The hostname remains primary; consider a DHCP reservation if reconnects become unreliable.",
                    status: .warning
                )
            } else if cacheUpdate.didChangeAddress {
                stabilityStep = .init(
                    title: "LAN address stability",
                    detail: "The LAN address changed once recently. Otter updated its fallback cache and kept the hostname as the primary address.",
                    status: .information
                )
            } else if resolvedIPAddress != nil, !networkService.isVPNConnected {
                stabilityStep = .init(
                    title: "LAN address stability",
                    detail: "Otter learned the current LAN address and cached it as a fallback. The hostname remains primary.",
                    status: .passed
                )
            } else if networkService.isVPNConnected, resolvedIPAddress != nil {
                stabilityStep = .init(
                    title: "LAN address stability",
                    detail: "The hostname resolved over VPN. Otter left the LAN fallback cache unchanged.",
                    status: .information
                )
            } else if observedShare.cachedIPAddress != nil {
                stabilityStep = .init(
                    title: "LAN address stability",
                    detail: "Otter retained the previously learned LAN address as a fallback. The hostname remains primary.",
                    status: .information
                )
            } else {
                stabilityStep = .init(
                    title: "LAN address stability",
                    detail: "Otter could not learn a LAN address during this check.",
                    status: .warning
                )
            }
            steps.append(stabilityStep)
        }

        steps.append(.init(
            title: "SMB reachability",
            detail: reachable
                ? "The server accepted a connection on the SMB port."
                : "The server did not answer on the SMB port within three seconds.",
            status: reachable ? .passed : .failed
        ))

        var hasRepairableItems = false
        if let mountedURL = await mountService.mountedURL(for: share) {
            let health = await mountHealthService.checkMount(at: mountedURL, timeout: 3)
            switch health {
            case .healthy:
                steps.append(.init(title: "Mounted volume", detail: "The mounted volume responds to filesystem access.", status: .passed))
            case .unresponsive:
                steps.append(.init(title: "Mounted volume", detail: "The mounted volume did not respond within three seconds.", status: .failed))
                hasRepairableItems = canSafelyAttemptRepair
            case let .unavailable(message):
                steps.append(.init(title: "Mounted volume", detail: message, status: .warning))
            }
        } else if attemptMount && reachable && ruleEvaluation.allowsConnection {
            do {
                let overrideURL = reachableURL == url ? nil : reachableURL
                if try await mountService.mount(share, urlOverride: overrideURL) != nil {
                    steps.append(.init(title: "Mount attempt", detail: "macOS mounted the share successfully.", status: .passed))
                    await monitor.evaluate(share, reason: .volumeChanged)
                } else {
                    steps.append(.init(title: "Mount attempt", detail: "macOS returned success, but the mounted volume was not found.", status: .failed))
                }
            } catch {
                steps.append(.init(title: "Mount attempt", detail: error.localizedDescription, status: .failed))
            }
        } else {
            steps.append(.init(
                title: "Mounted volume",
                detail: attemptMount ? "A mount was not attempted because an earlier requirement failed." : "The share is not currently mounted.",
                status: attemptMount ? .warning : .information
            ))

            if !attemptMount {
                let statusSuggestsConnectionShouldExist: Bool
                switch monitor.status(for: share) {
                case .connected, .waitingForNetwork, .waitingForServerOnVPN, .wakePacketSent, .reconnecting, .failed:
                    statusSuggestsConnectionShouldExist = true
                case .disconnected, .waitingForAllowedNetwork, .waitingForVPN, .waitingForAccess, .paused:
                    statusSuggestsConnectionShouldExist = false
                }
                let shareExpectsConnection = share.keepMounted
                    || (share.autoConnectWhenReachable && reachable)
                    || statusSuggestsConnectionShouldExist
                hasRepairableItems = canSafelyAttemptRepair && shareExpectsConnection
            }
        }

        let runtimeState = monitor.runtimeState(for: share)
        if let lastCheckedAt = runtimeState.lastCheckedAt {
            let retryDetail = runtimeState.nextRetryDate.map {
                " Next automatic retry: \($0.formatted(date: .omitted, time: .shortened))."
            } ?? ""
            steps.append(.init(
                title: "Otter monitor",
                detail: "Last checked \(lastCheckedAt.formatted(date: .omitted, time: .standard)).\(retryDetail)",
                status: .information
            ))
        }

        return ConnectionDiagnosticReport(
            generatedAt: Date(),
            steps: steps,
            hasRepairableItems: hasRepairableItems
        )
    }

    func attemptRepair(for share: NetworkShare) async -> ConnectionDiagnosticStep {
        let currentShare = settings.share(id: share.id) ?? share
        await networkService.refreshNetworkDetailsIfStale(maxAge: 0)

        guard let url = currentShare.url,
              url.scheme?.lowercased() == "smb",
              url.host(percentEncoded: false) != nil,
              url.user(percentEncoded: false) == nil,
              url.password(percentEncoded: false) == nil
        else {
            return .init(
                title: "Repair attempt",
                detail: "Otter did not make changes because the SMB address must be corrected manually.",
                status: .failed
            )
        }

        if settings.preferences.pauseState.isActive() {
            return .init(
                title: "Repair attempt",
                detail: "Otter is paused globally. Resume automatic mounting before repairing this share.",
                status: .warning
            )
        }

        guard networkService.isOnline else {
            return .init(
                title: "Repair attempt",
                detail: "No changes were made because macOS has no active network path.",
                status: .warning
            )
        }

        let ruleEvaluation = currentShare.rules.evaluate(
            currentWiFiNetworkName: networkService.currentWiFiNetworkName,
            isVPNConnected: networkService.isVPNConnected,
            activeVPNNames: networkService.activeVPNNames,
            currentIPv4Subnets: networkService.currentIPv4Subnets
        )
        if !ruleEvaluation.allowsConnection,
           currentShare.rules.hasVPNRule,
           currentShare.rules.requiredVPNName != nil {
            await monitor.retry(currentShare, resumeAutomaticMounting: true)
            return repairResult(
                status: monitor.status(for: currentShare),
                recoveredUnresponsiveMount: false
            )
        }

        guard ruleEvaluation.allowsConnection else {
            return .init(
                title: "Repair attempt",
                detail: "No changes were made because the current network does not satisfy this share's conditions.",
                status: .warning
            )
        }

        var recoveredUnresponsiveMount = false
        if let mountedURL = await mountService.mountedURL(for: currentShare) {
            switch await mountHealthService.checkMount(at: mountedURL, timeout: 3) {
            case .healthy:
                await monitor.evaluate(currentShare, reason: .volumeChanged)
                return .init(
                    title: "Repair attempt",
                    detail: "No repair was needed. The share is mounted and responds normally.",
                    status: .passed
                )
            case .unresponsive:
                guard await mountHealthService.unmountForRecovery(at: mountedURL, timeout: 10) else {
                    return .init(
                        title: "Repair attempt",
                        detail: "The volume is unresponsive and could not be safely unmounted. Otter did not force it.",
                        status: .failed
                    )
                }
                recoveredUnresponsiveMount = true
            case .unavailable:
                return .init(
                    title: "Repair attempt",
                    detail: "Otter could not safely determine the mounted volume's health, so no changes were made.",
                    status: .warning
                )
            }
        }

        await monitor.retry(currentShare, resumeAutomaticMounting: true)
        return repairResult(
            status: monitor.status(for: currentShare),
            recoveredUnresponsiveMount: recoveredUnresponsiveMount
        )
    }

    private func repairResult(
        status: ShareStatus,
        recoveredUnresponsiveMount: Bool
    ) -> ConnectionDiagnosticStep {
        let successDetail = recoveredUnresponsiveMount
            ? "Otter safely unmounted the unresponsive volume and mounted the share again."
            : "Otter reset the retry state and mounted the share successfully."

        switch status {
        case .connected:
            return .init(title: "Repair attempt", detail: successDetail, status: .passed)
        case .wakePacketSent:
            return .init(
                title: "Repair attempt",
                detail: "Otter sent a Wake-on-LAN packet and restarted automatic reconnect attempts.",
                status: .information
            )
        case .waitingForNetwork, .reconnecting:
            return .init(
                title: "Repair attempt",
                detail: "Otter reset the retry state and restarted automatic reconnect attempts.",
                status: .information
            )
        case .waitingForServerOnVPN:
            return .init(
                title: "Repair attempt",
                detail: "A VPN is connected, but the server isn’t responding. Check that the correct VPN is active.",
                status: .warning
            )
        case .waitingForAccess:
            return .init(
                title: "Repair attempt",
                detail: "This server isn’t available on the current network or VPN.",
                status: .warning
            )
        case .disconnected:
            return .init(
                title: "Repair attempt",
                detail: "The share is still disconnected. Otter restarted its automatic retry cycle.",
                status: .warning
            )
        case .waitingForAllowedNetwork:
            return .init(
                title: "Repair attempt",
                detail: "The current network does not satisfy this share's conditions.",
                status: .warning
            )
        case let .waitingForVPN(name):
            return .init(
                title: "Repair attempt",
                detail: "Connect to “\(name)” to access this server.",
                status: .warning
            )
        case .paused:
            return .init(
                title: "Repair attempt",
                detail: "Automatic mounting is still paused, so Otter did not reconnect the share.",
                status: .warning
            )
        case .failed:
            return .init(
                title: "Repair attempt",
                detail: "Otter could not reconnect the share. Review the refreshed checks for details.",
                status: .failed
            )
        }
    }
}
