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
        let rules = ShareRules(wifiNetworkName: "home", wifiNetworkAction: .connect)

        let matching = rules.evaluate(currentWiFiNetworkName: "Home", isVPNConnected: false, activeVPNNames: [])
        XCTAssertTrue(matching.allowsConnection)
        XCTAssertTrue(matching.shouldAttemptMount)

        let blocked = rules.evaluate(currentWiFiNetworkName: "Coffee Shop", isVPNConnected: false, activeVPNNames: [])
        XCTAssertFalse(blocked.allowsConnection)
        XCTAssertTrue(blocked.shouldDisconnectMountedShare)
        XCTAssertEqual(blocked.blockedStatus, .waitingForAllowedNetwork("Wi-Fi home"))
    }

    func testWiFiDisconnectRulePausesShareOnMatchingNetwork() {
        let rules = ShareRules(wifiNetworkName: "Public", wifiNetworkAction: .disconnect)

        let paused = rules.evaluate(currentWiFiNetworkName: "Public", isVPNConnected: false, activeVPNNames: [])
        XCTAssertFalse(paused.allowsConnection)
        XCTAssertEqual(paused.blockedStatus, .pausedByRule("Wi-Fi Public"))

        let allowed = rules.evaluate(currentWiFiNetworkName: "Home", isVPNConnected: false, activeVPNNames: [])
        XCTAssertTrue(allowed.allowsConnection)
        XCTAssertFalse(allowed.shouldAttemptMount)
    }

    func testNamedVPNRuleOnlyMatchesThatVPN() {
        let rules = ShareRules(vpnRuleEnabled: true, vpnName: "VPN A", vpnAction: .connect)

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
        let rules = ShareRules(vpnRuleEnabled: true, vpnName: "", vpnAction: .connect)

        let connected = rules.evaluate(currentWiFiNetworkName: nil, isVPNConnected: true, activeVPNNames: [])
        XCTAssertTrue(connected.allowsConnection)
        XCTAssertTrue(connected.shouldAttemptMount)

        let disconnected = rules.evaluate(currentWiFiNetworkName: nil, isVPNConnected: false, activeVPNNames: [])
        XCTAssertFalse(disconnected.allowsConnection)
        XCTAssertEqual(disconnected.blockedStatus, .waitingForAllowedNetwork("a VPN"))
    }

    func testCombinedRulesRequireBothToPass() {
        var rules = ShareRules(wifiNetworkName: "Home", wifiNetworkAction: .connect)
        rules.vpnRuleEnabled = true
        rules.vpnName = "Work VPN"
        rules.vpnAction = .disconnect

        let wifiOnlyOK = rules.evaluate(currentWiFiNetworkName: "Home", isVPNConnected: false, activeVPNNames: [])
        XCTAssertTrue(wifiOnlyOK.allowsConnection)

        let vpnBlocks = rules.evaluate(currentWiFiNetworkName: "Home", isVPNConnected: true, activeVPNNames: ["Work VPN"])
        XCTAssertFalse(vpnBlocks.allowsConnection)
        XCTAssertEqual(vpnBlocks.blockedStatus, .pausedByRule("VPN Work VPN"))
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
