import XCTest
@testable import Otter

final class NetworkShareTests: XCTestCase {
    func testInferredShareNameFromURL() {
        XCTAssertEqual(NetworkShare.inferredShareName(from: "smb://server.local/Dawn"), "Dawn")
        XCTAssertEqual(NetworkShare.inferredShareName(from: "smb://server.local/media/Movies"), "Movies")
        XCTAssertEqual(NetworkShare.inferredShareName(from: "smb://server.local/My%20Share"), "My Share")
        XCTAssertNil(NetworkShare.inferredShareName(from: "smb://server.local"))
    }

    func testDefaultMountPathPrefersShareName() {
        XCTAssertEqual(
            NetworkShare.defaultMountPath(displayName: "Anything", urlString: "smb://server.local/Dawn"),
            "/Volumes/Dawn"
        )
        XCTAssertEqual(
            NetworkShare.defaultMountPath(displayName: "Backups", urlString: "smb://server.local"),
            "/Volumes/Backups"
        )
        XCTAssertEqual(
            NetworkShare.defaultMountPath(displayName: "  ", urlString: "smb://server.local"),
            "/Volumes/Share"
        )
    }

    func testNormalizedMountPathFallsBackForEmptyAndRootPaths() {
        for invalidPath in ["", "   ", "/", "/Volumes", "/Volumes/"] {
            XCTAssertEqual(
                NetworkShare.normalizedMountPath(invalidPath, displayName: "Dawn", urlString: "smb://server.local/Dawn"),
                "/Volumes/Dawn",
                "Path \"\(invalidPath)\" should fall back to the default"
            )
        }
    }

    func testNormalizedMountPathKeepsVolumesPaths() {
        XCTAssertEqual(
            NetworkShare.normalizedMountPath("/Volumes/Media", displayName: "Dawn", urlString: "smb://server.local/Dawn"),
            "/Volumes/Media"
        )
    }

    func testNormalizedMountPathMapsRelativeAndForeignPathsIntoVolumes() {
        XCTAssertEqual(
            NetworkShare.normalizedMountPath("Media", displayName: "Dawn", urlString: "smb://server.local/Dawn"),
            "/Volumes/Media"
        )
        XCTAssertEqual(
            NetworkShare.normalizedMountPath("/tmp/Media", displayName: "Dawn", urlString: "smb://server.local/Dawn"),
            "/Volumes/Media"
        )
    }

    func testDecodingDefaultsNewFieldsToFalse() throws {
        let json = """
        {
            "id": "00000000-0000-0000-0000-000000000001",
            "displayName": "Dawn",
            "urlString": "smb://server.local/Dawn",
            "mountPath": "/Volumes/Dawn",
            "keepMounted": true,
            "mountAtLaunch": true,
            "createdAt": 0,
            "updatedAt": 0
        }
        """

        let share = try JSONDecoder().decode(NetworkShare.self, from: Data(json.utf8))
        XCTAssertFalse(share.autoConnectWhenReachable)
        XCTAssertFalse(share.wakeOnLAN.isEnabled)
        XCTAssertEqual(share.wakeOnLAN.broadcastAddress, WakeOnLANConfiguration.defaultBroadcastAddress)
        XCTAssertEqual(share.wakeOnLAN.port, WakeOnLANConfiguration.defaultPort)
        XCTAssertFalse(share.rules.hasVPNRule)
        XCTAssertFalse(share.rules.hasWiFiNetworkRule)
    }

    func testIPAddressIdentification() {
        XCTAssertTrue(NetworkShare.isIPAddress("127.0.0.1"))
        XCTAssertTrue(NetworkShare.isIPAddress("192.168.1.1"))
        XCTAssertTrue(NetworkShare.isIPAddress("2001:0db8:85a3:0000:0000:8a2e:0370:7334"))
        XCTAssertTrue(NetworkShare.isIPAddress("::1"))

        XCTAssertFalse(NetworkShare.isIPAddress("localhost"))
        XCTAssertFalse(NetworkShare.isIPAddress("my-nas.local"))
        XCTAssertFalse(NetworkShare.isIPAddress("apple.com"))
    }

    func testDNSResolutionUsesInjectedResolver() async {
        let resolved = await NetworkShare.resolveIPAddress(
            for: "server.local",
            using: StubHostResolver(result: "192.168.1.20")
        )
        XCTAssertEqual(resolved, "192.168.1.20")

        let invalid = await NetworkShare.resolveIPAddress(
            for: "missing.local",
            using: StubHostResolver(result: nil)
        )
        XCTAssertNil(invalid)
    }

    func testLegacyRuleActionFieldsRemainDecodable() throws {
        let legacyJSON = """
        {
            "wifiNetworkName": "Home",
            "wifiNetworkAction": "disconnect",
            "registeredSubnets": ["192.168.1.0/24"],
            "vpnRuleEnabled": true,
            "vpnName": "Work VPN",
            "vpnAction": "disconnect"
        }
        """

        let rules = try JSONDecoder().decode(ShareRules.self, from: Data(legacyJSON.utf8))

        XCTAssertEqual(rules.requiredWiFiNetworkName, "Home")
        XCTAssertEqual(rules.registeredSubnets, ["192.168.1.0/24"])
        XCTAssertEqual(rules.requiredVPNName, "Work VPN")
    }
}

final class WakeOnLANConfigurationTests: XCTestCase {
    func testMACAddressNormalizationAcceptsCommonFormats() {
        XCTAssertEqual(WakeOnLANConfiguration.normalizedMACAddress("aa:bb:cc:dd:ee:ff"), "AA:BB:CC:DD:EE:FF")
        XCTAssertEqual(WakeOnLANConfiguration.normalizedMACAddress("AA-BB-CC-DD-EE-FF"), "AA:BB:CC:DD:EE:FF")
        XCTAssertEqual(WakeOnLANConfiguration.normalizedMACAddress("aabb.ccdd.eeff"), "AA:BB:CC:DD:EE:FF")
        XCTAssertEqual(WakeOnLANConfiguration.normalizedMACAddress("aabbccddeeff"), "AA:BB:CC:DD:EE:FF")
    }

    func testMACAddressNormalizationRejectsInvalidValues() {
        XCTAssertNil(WakeOnLANConfiguration.normalizedMACAddress(""))
        XCTAssertNil(WakeOnLANConfiguration.normalizedMACAddress("AA:BB:CC:DD:EE"))
        XCTAssertNil(WakeOnLANConfiguration.normalizedMACAddress("AA:BB:CC:DD:EE:GG"))
        XCTAssertNil(WakeOnLANConfiguration.normalizedMACAddress("AA BB CC DD EE FF"))
    }

    func testWakeOnLANConfigurationNormalizesDefaults() {
        let configuration = WakeOnLANConfiguration(
            isEnabled: true,
            macAddress: "aa-bb-cc-dd-ee-ff",
            broadcastAddress: " ",
            port: 70_000
        )

        XCTAssertEqual(configuration.macAddress, "AA:BB:CC:DD:EE:FF")
        XCTAssertEqual(configuration.broadcastAddress, WakeOnLANConfiguration.defaultBroadcastAddress)
        XCTAssertEqual(configuration.port, 65_535)
    }
}

final class WakeOnLANServiceTests: XCTestCase {
    func testMagicPacketLayout() throws {
        let packet = try WakeOnLANService.magicPacket(macAddress: "01:23:45:67:89:AB")
        let macAddressBytes: [UInt8] = [0x01, 0x23, 0x45, 0x67, 0x89, 0xab]

        XCTAssertEqual(packet.count, 102)
        XCTAssertEqual(Array(packet.prefix(6)), Array(repeating: 0xff, count: 6))

        for offset in stride(from: 6, to: packet.count, by: macAddressBytes.count) {
            XCTAssertEqual(Array(packet[offset..<(offset + macAddressBytes.count)]), macAddressBytes)
        }
    }

    func testIPv4BroadcastValidation() {
        XCTAssertTrue(WakeOnLANService.isValidIPv4Address("255.255.255.255"))
        XCTAssertTrue(WakeOnLANService.isValidIPv4Address("192.168.1.255"))
        XCTAssertFalse(WakeOnLANService.isValidIPv4Address("example.local"))
        XCTAssertFalse(WakeOnLANService.isValidIPv4Address("999.999.999.999"))
    }
}

final class ShareRulesEvaluationTests: XCTestCase {
    func testNoRulesAllowsConnectionWithoutForcingMount() {
        let evaluation = ShareRules().evaluate(
            currentWiFiNetworkName: "Home",
            isVPNConnected: false,
            activeVPNNames: []
        )

        XCTAssertEqual(evaluation, .noRules)
    }

    func testWiFiConnectRuleMatchesCaseInsensitively() {
        let rules = ShareRules(wifiNetworkName: "home")

        let matching = rules.evaluate(currentWiFiNetworkName: "Home", isVPNConnected: false, activeVPNNames: [])
        XCTAssertTrue(matching.allowsConnection)
        XCTAssertTrue(matching.shouldAttemptMount)

        let blocked = rules.evaluate(currentWiFiNetworkName: "Coffee Shop", isVPNConnected: false, activeVPNNames: [])
        XCTAssertFalse(blocked.allowsConnection)
        XCTAssertTrue(blocked.shouldDisconnectMountedShare)
        XCTAssertEqual(blocked.blockedStatus, .waitingForAllowedNetwork("the registered network or VPN"))
    }

    func testRegisteredSubnetRuleMatchesRegisteredSubnet() {
        let rules = ShareRules(registeredSubnets: ["192.168.50.0/24"])

        // Same subnet, regardless of Wi-Fi vs Ethernet -> succeeds
        let onHomeSubnet = rules.evaluate(
            currentWiFiNetworkName: nil,
            isVPNConnected: false,
            activeVPNNames: [],
            currentIPv4Subnets: ["192.168.50.0/24"]
        )
        XCTAssertTrue(onHomeSubnet.allowsConnection)
        XCTAssertTrue(onHomeSubnet.shouldAttemptMount)

        // Different wired network -> blocked, unlike the legacy Ethernet fallback
        let onForeignSubnet = rules.evaluate(
            currentWiFiNetworkName: nil,
            isVPNConnected: false,
            activeVPNNames: [],
            currentIPv4Subnets: ["10.0.0.0/24"]
        )
        XCTAssertFalse(onForeignSubnet.allowsConnection)
        XCTAssertTrue(onForeignSubnet.shouldDisconnectMountedShare)

        // VPN still counts as an allowed connection path
        let onVPNElsewhere = rules.evaluate(
            currentWiFiNetworkName: nil,
            isVPNConnected: true,
            activeVPNNames: [],
            currentIPv4Subnets: ["10.0.0.0/24"]
        )
        XCTAssertTrue(onVPNElsewhere.allowsConnection)
    }

    func testSubnetAndWiFiNameEachMatchIndependently() {
        let rules = ShareRules(wifiNetworkName: "Home", registeredSubnets: ["192.168.50.0/24"])

        // Registered subnet matches even when the SSID differs (renamed
        // network) or is unreadable without Location Services access.
        let renamedWiFi = rules.evaluate(
            currentWiFiNetworkName: "New Network Name",
            isVPNConnected: false,
            activeVPNNames: [],
            currentIPv4Subnets: ["192.168.50.0/24"]
        )
        XCTAssertTrue(renamedWiFi.allowsConnection)

        // The Wi-Fi name still matches on its own if the subnet changed.
        let newSubnet = rules.evaluate(
            currentWiFiNetworkName: "Home",
            isVPNConnected: false,
            activeVPNNames: [],
            currentIPv4Subnets: ["192.168.86.0/24"]
        )
        XCTAssertTrue(newSubnet.allowsConnection)
    }

    func testRegisteredSubnetDoesNotTrustForeignEthernet() {
        let rules = ShareRules(wifiNetworkName: "Home", registeredSubnets: ["192.168.50.0/24"])

        // A wired connection on some other network must not count as home
        // once a subnet is registered.
        let foreignEthernet = rules.evaluate(
            currentWiFiNetworkName: nil,
            isVPNConnected: false,
            activeVPNNames: [],
            currentIPv4Subnets: ["10.20.30.0/24"]
        )
        XCTAssertFalse(foreignEthernet.allowsConnection)
    }

    func testNamedVPNRuleOnlyMatchesThatVPN() {
        let rules = ShareRules(vpnRuleEnabled: true, vpnName: "VPN A")

        let onVPNA = rules.evaluate(currentWiFiNetworkName: nil, isVPNConnected: true, activeVPNNames: ["VPN A"])
        XCTAssertTrue(onVPNA.allowsConnection)
        XCTAssertTrue(onVPNA.shouldAttemptMount)

        let onVPNB = rules.evaluate(currentWiFiNetworkName: nil, isVPNConnected: true, activeVPNNames: ["VPN B"])
        XCTAssertFalse(onVPNB.allowsConnection)

        // Regression: an active but unnamed VPN must not satisfy a named rule,
        // or rules for different VPNs become indistinguishable.
        let onUnnamedVPN = rules.evaluate(currentWiFiNetworkName: nil, isVPNConnected: true, activeVPNNames: [])
        XCTAssertFalse(onUnnamedVPN.allowsConnection)
    }

    func testAnyVPNRuleMatchesUnnamedVPN() {
        let rules = ShareRules(vpnRuleEnabled: true, vpnName: "")

        let connected = rules.evaluate(currentWiFiNetworkName: nil, isVPNConnected: true, activeVPNNames: [])
        XCTAssertTrue(connected.allowsConnection)
        XCTAssertTrue(connected.shouldAttemptMount)

        let disconnected = rules.evaluate(currentWiFiNetworkName: nil, isVPNConnected: false, activeVPNNames: [])
        XCTAssertFalse(disconnected.allowsConnection)
        XCTAssertEqual(disconnected.blockedStatus, .waitingForAllowedNetwork("a VPN"))
    }

    func testCombinedNetworkAndVPNRulesAllowEitherPath() {
        var rules = ShareRules(wifiNetworkName: "Home")
        rules.vpnRuleEnabled = true
        rules.vpnName = "Work VPN"

        // Wifi matches -> succeeds directly
        let wifiOnlyIsEnough = rules.evaluate(currentWiFiNetworkName: "Home", isVPNConnected: false, activeVPNNames: [])
        XCTAssertTrue(wifiOnlyIsEnough.allowsConnection)

        // Wired Ethernet -> succeeds directly (legacy share with no registered
        // subnet keeps the old any-Ethernet behavior)
        let ethernetOnlyIsEnough = rules.evaluate(currentWiFiNetworkName: nil, isVPNConnected: false, activeVPNNames: [])
        XCTAssertTrue(ethernetOnlyIsEnough.allowsConnection)

        // Unregistered Wi-Fi, no VPN -> blocked
        let foreignWifiNoVPN = rules.evaluate(currentWiFiNetworkName: "Coffee Shop", isVPNConnected: false, activeVPNNames: [])
        XCTAssertFalse(foreignWifiNoVPN.allowsConnection)
        XCTAssertEqual(foreignWifiNoVPN.blockedStatus, .waitingForAllowedNetwork("the registered network or VPN Work VPN"))

        // Unregistered Wi-Fi, correct VPN -> succeeds
        let foreignWifiWithVPN = rules.evaluate(currentWiFiNetworkName: "Coffee Shop", isVPNConnected: true, activeVPNNames: ["Work VPN"])
        XCTAssertTrue(foreignWifiWithVPN.allowsConnection)

        // Unregistered Wi-Fi, wrong VPN -> blocked
        let foreignWifiWithWrongVPN = rules.evaluate(currentWiFiNetworkName: "Coffee Shop", isVPNConnected: true, activeVPNNames: ["Other VPN"])
        XCTAssertFalse(foreignWifiWithWrongVPN.allowsConnection)
    }
}

final class VPNConnectionIdentityTests: XCTestCase {
    func testUnidentifiedTunnelDoesNotCountAsVPN() {
        let identity = VPNConnectionIdentity(hasActiveTunnel: true, identifiedNames: [])

        XCTAssertFalse(identity.isConnected)
        XCTAssertTrue(identity.hasUnidentifiedTunnel)
        XCTAssertTrue(identity.activeNames.isEmpty)
    }

    func testIdentifiedVPNCountsAsConnectedAndSortsNames() {
        let identity = VPNConnectionIdentity(
            hasActiveTunnel: true,
            identifiedNames: ["Work VPN", "Personal VPN"]
        )

        XCTAssertTrue(identity.isConnected)
        XCTAssertFalse(identity.hasUnidentifiedTunnel)
        XCTAssertEqual(identity.activeNames, ["Personal VPN", "Work VPN"])
    }
}

final class RetryBackoffTests: XCTestCase {
    func testBackoffProgressionAndClamping() {
        XCTAssertEqual(RetryBackoff.delay(afterFailures: 0), 10)
        XCTAssertEqual(RetryBackoff.delay(afterFailures: 1), 10)
        XCTAssertEqual(RetryBackoff.delay(afterFailures: 2), 30)
        XCTAssertEqual(RetryBackoff.delay(afterFailures: 3), 120)
        XCTAssertEqual(RetryBackoff.delay(afterFailures: 4), 300)
        XCTAssertEqual(RetryBackoff.delay(afterFailures: 100), 300)
    }

    func testBackoffWithJitter() {
        for failures in 0...10 {
            let baseDelay = RetryBackoff.delay(afterFailures: failures)
            let maxJitter = min(baseDelay * 0.1, 30.0)
            
            for _ in 0..<100 {
                let delayWithJitter = RetryBackoff.delayWithJitter(afterFailures: failures)
                XCTAssertGreaterThanOrEqual(delayWithJitter, baseDelay - maxJitter)
                XCTAssertLessThanOrEqual(delayWithJitter, baseDelay + maxJitter)
                XCTAssertGreaterThanOrEqual(delayWithJitter, 1.0)
            }
        }
    }

    func testAutomaticRetryBudgetIsBounded() {
        XCTAssertTrue(RetryBackoff.shouldRetry(afterFailures: 0))
        XCTAssertTrue(RetryBackoff.shouldRetry(afterFailures: RetryBackoff.maxAutomaticAttempts - 1))
        XCTAssertFalse(RetryBackoff.shouldRetry(afterFailures: RetryBackoff.maxAutomaticAttempts))
        XCTAssertFalse(RetryBackoff.shouldRetry(afterFailures: RetryBackoff.maxAutomaticAttempts + 1))
    }
}

final class ShareMonitorRetryTests: XCTestCase {
    @MainActor
    func testUnreachableServerConsumesRetryBudgetAndSchedulesBackoff() async {
        let suiteName = "OtterTests.ShareMonitorRetryTests"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let settings = SettingsStore(defaults: defaults, credentialStore: RecordingCredentialStore())
        let share = NetworkShare(
            displayName: "Media",
            urlString: "smb://server.local/Media",
            mountPath: "/Volumes/Media"
        )
        settings.addShare(share)
        let network = StubNetworkReachability(isOnline: true, isReachable: false)
        let monitor = ShareMonitor(
            settings: settings,
            mountService: StubMountService(),
            wakeOnLANService: StubWakeOnLANService(),
            networkService: network,
            notificationService: RecordingNotificationService(),
            eventLog: ShareEventLog(defaults: defaults),
            defaults: defaults
        )

        let beforeEvaluation = Date()
        await monitor.evaluate(share, reason: .timer)
        let state = monitor.runtimeState(for: share)

        XCTAssertEqual(state.failureCount, 1)
        XCTAssertEqual(state.status, .waitingForNetwork)
        XCTAssertNotNil(state.nextRetryDate)
        XCTAssertGreaterThanOrEqual(state.nextRetryDate ?? .distantPast, beforeEvaluation.addingTimeInterval(9))
        XCTAssertLessThanOrEqual(state.nextRetryDate ?? .distantFuture, Date().addingTimeInterval(11))
    }

    @MainActor
    func testNetworkChangeResetsConsumedRetryBudget() async {
        let suiteName = "OtterTests.ShareMonitorRetryTests.Reset"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let settings = SettingsStore(defaults: defaults, credentialStore: RecordingCredentialStore())
        let share = NetworkShare(
            displayName: "Media",
            urlString: "smb://server.local/Media",
            mountPath: "/Volumes/Media"
        )
        settings.addShare(share)
        let monitor = ShareMonitor(
            settings: settings,
            mountService: StubMountService(),
            wakeOnLANService: StubWakeOnLANService(),
            networkService: StubNetworkReachability(isOnline: true, isReachable: false),
            notificationService: RecordingNotificationService(),
            eventLog: ShareEventLog(defaults: defaults),
            defaults: defaults
        )

        await monitor.evaluate(share, reason: .timer)
        XCTAssertEqual(monitor.runtimeState(for: share).failureCount, 1)

        await monitor.evaluate(share, reason: .networkChanged)
        XCTAssertEqual(monitor.runtimeState(for: share).failureCount, 1)
    }

    @MainActor
    func testTimerCannotRestartExhaustedRetriesButNetworkChangeCan() async {
        let suiteName = "OtterTests.ShareMonitorRetryTests.Exhaustion"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let settings = SettingsStore(defaults: defaults, credentialStore: RecordingCredentialStore())
        let share = NetworkShare(
            displayName: "Media",
            urlString: "smb://server.local/Media",
            mountPath: "/Volumes/Media"
        )
        settings.addShare(share)
        let network = StubNetworkReachability(isOnline: true, isReachable: false)
        var currentDate = Date()
        let monitor = ShareMonitor(
            settings: settings,
            mountService: StubMountService(),
            wakeOnLANService: StubWakeOnLANService(),
            networkService: network,
            notificationService: RecordingNotificationService(),
            eventLog: ShareEventLog(defaults: defaults),
            defaults: defaults,
            now: { currentDate }
        )

        for attempt in 1...RetryBackoff.maxAutomaticAttempts {
            await monitor.evaluate(share, reason: attempt == 1 ? .timer : .retry)
            XCTAssertEqual(monitor.runtimeState(for: share).failureCount, attempt)
            currentDate = currentDate.addingTimeInterval(1_000)
        }

        let exhaustedState = monitor.runtimeState(for: share)
        XCTAssertNil(exhaustedState.nextRetryDate)
        guard case let .failed(message) = exhaustedState.status else {
            return XCTFail("Expected the monitor to pause in a failed state")
        }
        XCTAssertTrue(message.contains("Automatic reconnect paused"))
        XCTAssertEqual(network.canReachCallCount, RetryBackoff.maxAutomaticAttempts)

        await monitor.evaluate(share, reason: .timer)
        XCTAssertEqual(network.canReachCallCount, RetryBackoff.maxAutomaticAttempts)
        XCTAssertEqual(monitor.runtimeState(for: share).failureCount, RetryBackoff.maxAutomaticAttempts)

        await monitor.evaluate(share, reason: .networkChanged)
        XCTAssertEqual(network.canReachCallCount, RetryBackoff.maxAutomaticAttempts + 1)
        XCTAssertEqual(monitor.runtimeState(for: share).failureCount, 1)
    }
}

final class MountIdentityTests: XCTestCase {
    func testSMBIdentityIgnoresFoldersBelowTheShareAndNormalizesDefaultPort() {
        let configured = SMBShareLocation(url: URL(string: "smb://server.local:445/Media/Movies"))
        let mounted = SMBShareLocation(url: URL(string: "smb://SERVER.local/Media"))

        XCTAssertEqual(configured, mounted)
    }

    func testDifferentSharesOnTheSameServerHaveDifferentIdentities() {
        let media = SMBShareLocation(url: URL(string: "smb://server.local/Media"))
        let backups = SMBShareLocation(url: URL(string: "smb://server.local/Backups"))

        XCTAssertNotEqual(media, backups)
    }
}

final class ProblemNotificationTrackerTests: XCTestCase {
    func testRecoveryClearsSuppressionEvenWithoutARecoveryNotification() {
        let shareID = UUID()
        var tracker = ProblemNotificationTracker()

        XCTAssertTrue(tracker.beginProblemDelivery(for: shareID))
        XCTAssertFalse(tracker.beginProblemDelivery(for: shareID))

        tracker.resolveIfNeeded(shareID: shareID, status: .connected)

        XCTAssertTrue(tracker.beginProblemDelivery(for: shareID))
    }

    func testFailedDeliveryCanBeRetried() {
        let shareID = UUID()
        var tracker = ProblemNotificationTracker()

        XCTAssertTrue(tracker.beginProblemDelivery(for: shareID))
        tracker.problemDeliveryFailed(for: shareID)

        XCTAssertTrue(tracker.beginProblemDelivery(for: shareID))
    }
}

final class SettingsStoreTests: XCTestCase {
    @MainActor
    func testIsDuplicateShareMatchesIdenticalAddresses() {
        let defaults = UserDefaults(suiteName: "OtterTests.SettingsStoreTests")!
        defaults.removePersistentDomain(forName: "OtterTests.SettingsStoreTests")
        
        let store = SettingsStore(defaults: defaults)
        let share = NetworkShare(
            displayName: "Test Share",
            urlString: "smb://server.local/share",
            mountPath: "/Volumes/share"
        )
        store.addShare(share)
        
        // Exact duplicate
        XCTAssertTrue(store.isDuplicateShare(urlString: "smb://server.local/share"))
        // Case insensitive host/scheme
        XCTAssertTrue(store.isDuplicateShare(urlString: "SMB://SERVER.LOCAL/share"))
        // Missing smb:// prefix (normalized automatically)
        XCTAssertTrue(store.isDuplicateShare(urlString: "server.local/share"))
        XCTAssertTrue(store.isDuplicateShare(urlString: "//server.local/share"))
        
        // Non-duplicate URL
        XCTAssertFalse(store.isDuplicateShare(urlString: "smb://server.local/other"))
        
        // Excluding current share ID
        XCTAssertFalse(store.isDuplicateShare(urlString: "smb://server.local/share", excluding: share.id))
    }

    @MainActor
    func testRemovingLastShareForCachedIPRemovesFallbackCredential() {
        let defaults = UserDefaults(suiteName: "OtterTests.SettingsStoreTests.Credentials")!
        defaults.removePersistentDomain(forName: "OtterTests.SettingsStoreTests.Credentials")
        let credentialStore = RecordingCredentialStore()
        let store = SettingsStore(defaults: defaults, credentialStore: credentialStore)
        let share = NetworkShare(
            displayName: "Media",
            urlString: "smb://server.local/Media",
            mountPath: "/Volumes/Media",
            cachedIPAddress: "192.168.1.20"
        )
        store.addShare(share)

        store.removeShare(id: share.id)

        XCTAssertEqual(credentialStore.removedHosts, ["192.168.1.20"])
    }

    @MainActor
    func testSharedFallbackCredentialSurvivesUntilLastShareIsRemoved() {
        let defaults = UserDefaults(suiteName: "OtterTests.SettingsStoreTests.SharedCredentials")!
        defaults.removePersistentDomain(forName: "OtterTests.SettingsStoreTests.SharedCredentials")
        let credentialStore = RecordingCredentialStore()
        let store = SettingsStore(defaults: defaults, credentialStore: credentialStore)
        let first = NetworkShare(
            displayName: "Media",
            urlString: "smb://server.local/Media",
            mountPath: "/Volumes/Media",
            cachedIPAddress: "192.168.1.20"
        )
        let second = NetworkShare(
            displayName: "Backups",
            urlString: "smb://server.local/Backups",
            mountPath: "/Volumes/Backups",
            cachedIPAddress: "192.168.1.20"
        )
        store.addShare(first)
        store.addShare(second)

        store.removeShare(id: first.id)
        XCTAssertTrue(credentialStore.removedHosts.isEmpty)

        store.removeShare(id: second.id)
        XCTAssertEqual(credentialStore.removedHosts, ["192.168.1.20"])
    }
}

final class AppPreferencesTests: XCTestCase {
    func testFallbackIntervalIsClamped() {
        XCTAssertEqual(AppPreferences(fallbackCheckInterval: 1).fallbackCheckInterval, 15)
        XCTAssertEqual(AppPreferences(fallbackCheckInterval: 60).fallbackCheckInterval, 60)
        XCTAssertEqual(AppPreferences(fallbackCheckInterval: 100_000).fallbackCheckInterval, 3600)
    }

    func testLegacyDockIconKeyMigratesToPresenceMode() throws {
        let legacyJSON = """
        {"fallbackCheckInterval": 60, "showDockIconWhenPreferencesOpen": false}
        """

        let preferences = try JSONDecoder().decode(AppPreferences.self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(preferences.appPresenceMode, .menuBarOnly)

        let legacyEnabledJSON = """
        {"fallbackCheckInterval": 60, "showDockIconWhenPreferencesOpen": true}
        """

        let enabledPreferences = try JSONDecoder().decode(AppPreferences.self, from: Data(legacyEnabledJSON.utf8))
        XCTAssertEqual(enabledPreferences.appPresenceMode, .dockWhilePreferencesOpen)
    }
}

private struct StubHostResolver: HostResolving {
    let result: String?

    func resolveIPAddress(for hostname: String) async -> String? {
        result
    }
}

private final class RecordingCredentialStore: CredentialStoring, @unchecked Sendable {
    var removedHosts: [String] = []

    func hasCredentials(for host: String) -> Bool {
        false
    }

    func syncCredentials(fromHost: String, toHost: String) -> Bool {
        false
    }

    func removeFallbackCredentials(for host: String) {
        removedHosts.append(host)
    }
}

private actor StubMountService: MountServicing {
    func mountedURL(for share: NetworkShare) async -> URL? {
        nil
    }

    func mount(_ share: NetworkShare, urlOverride: URL?) async throws -> URL? {
        nil
    }

    func unmount(_ share: NetworkShare) async throws {}
}

private actor StubWakeOnLANService: WakeOnLANServicing {
    func sendWakePacket(using configuration: WakeOnLANConfiguration) async throws {}
}

@MainActor
private final class StubNetworkReachability: NetworkReachabilityProviding {
    let isOnline: Bool
    let currentWiFiNetworkName: String? = nil
    let isVPNConnected = false
    let currentIPv4Subnets: [String] = []
    let activeVPNNames: [String] = []
    var onPathChange: (() -> Void)?
    let isReachable: Bool
    private(set) var canReachCallCount = 0

    init(isOnline: Bool, isReachable: Bool) {
        self.isOnline = isOnline
        self.isReachable = isReachable
    }

    func canReachServer(for url: URL, timeout: TimeInterval) async -> Bool {
        canReachCallCount += 1
        return isReachable
    }

    func refreshNetworkDetailsIfStale(maxAge: TimeInterval) async {}
}

@MainActor
private final class RecordingNotificationService: ShareNotificationProviding {
    private(set) var transitions: [(previous: ShareStatus, current: ShareStatus)] = []

    func notifyStatusChange(for share: NetworkShare, previous: ShareStatus, current: ShareStatus) {
        transitions.append((previous, current))
    }
}
