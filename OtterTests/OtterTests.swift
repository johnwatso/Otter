import AppKit
import XCTest
@testable import Otter

final class AppIconAssetTests: XCTestCase {
    func testAppIconRendersDifferentLightAndDarkAppearances() throws {
        let lightImage = try XCTUnwrap(AdaptiveOtterIcon.image(for: .light))
        let darkImage = try XCTUnwrap(AdaptiveOtterIcon.image(for: .dark))
        let lightData = try XCTUnwrap(lightImage.tiffRepresentation)
        let darkData = try XCTUnwrap(darkImage.tiffRepresentation)

        XCTAssertNotEqual(lightData, darkData)
    }
}

final class NetworkShareTests: XCTestCase {
    func testMountedSuggestionMatchesBonjourDiscoveryIdentity() {
        let suggestion = MountedShareSuggestion(
            displayName: "Media",
            urlString: "smb://Living%20Room%20NAS._smb._tcp.local/Media",
            mountPath: "/Volumes/Media"
        )
        let matchingServer = DiscoveredSMBServer(name: "Living Room NAS", domain: "local.")
        let otherServer = DiscoveredSMBServer(name: "Archive NAS", domain: "local.")

        XCTAssertTrue(suggestion.matches(server: matchingServer))
        XCTAssertFalse(suggestion.matches(server: otherServer))
    }

    func testFinderImportCandidatesPreferTheSelectedBonjourServer() {
        let selectedServer = DiscoveredSMBServer(name: "Living Room NAS", domain: "local.")
        let selectedShare = MountedShareSuggestion(
            displayName: "Media",
            urlString: "smb://Living%20Room%20NAS._smb._tcp.local/Media",
            mountPath: "/Volumes/Media"
        )
        let unrelatedShare = MountedShareSuggestion(
            displayName: "Archive",
            urlString: "smb://archive.local/Archive",
            mountPath: "/Volumes/Archive"
        )

        let candidates = MountedShareSuggestion.finderImportCandidates(
            in: [unrelatedShare, selectedShare],
            for: selectedServer,
            excludingMountPaths: [unrelatedShare.mountPath]
        )

        XCTAssertEqual(candidates, [selectedShare])
    }

    func testInferredShareNameFromURL() {
        XCTAssertEqual(NetworkShare.inferredShareName(from: "smb://server.local/Dawn"), "Dawn")
        XCTAssertEqual(NetworkShare.inferredShareName(from: "smb://server.local/media/Movies"), "Movies")
        XCTAssertEqual(NetworkShare.inferredShareName(from: "smb://server.local/My%20Share"), "My Share")
        XCTAssertNil(NetworkShare.inferredShareName(from: "smb://server.local"))
    }

    func testSharesOnTheSameServerAreGroupedForPresentation() {
        let media = NetworkShare(
            displayName: "Media",
            urlString: "smb://HomeNAS.local/Media",
            mountPath: "/Volumes/Media"
        )
        let backups = NetworkShare(
            displayName: "Backups",
            urlString: "smb://homenas/Backups",
            mountPath: "/Volumes/Backups"
        )
        let archive = NetworkShare(
            displayName: "Archive",
            urlString: "smb://archive.example.com/Archive",
            mountPath: "/Volumes/Archive"
        )

        let groups = NetworkShareServerGroup.make(from: [media, archive, backups])

        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].serverName, "HomeNAS")
        XCTAssertEqual(groups[0].shares.map(\.displayName), ["Media", "Backups"])
        XCTAssertTrue(groups[0].isGrouped)
        XCTAssertEqual(groups[1].shares, [archive])
        XCTAssertFalse(groups[1].isGrouped)
    }

    func testBonjourServerDisplayNameOmitsServiceSuffix() {
        let share = NetworkShare(
            displayName: "Media",
            urlString: "smb://Living%20Room%20NAS._smb._tcp.local/Media",
            mountPath: "/Volumes/Media"
        )

        XCTAssertEqual(share.serverDisplayName, "Living Room NAS")
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
        XCTAssertEqual(share.pauseState, .inactive)
        XCTAssertFalse(share.wakeOnLAN.isEnabled)
        XCTAssertEqual(share.wakeOnLAN.broadcastAddress, WakeOnLANConfiguration.defaultBroadcastAddress)
        XCTAssertEqual(share.wakeOnLAN.port, WakeOnLANConfiguration.defaultPort)
        XCTAssertFalse(share.rules.hasVPNRule)
        XCTAssertFalse(share.rules.hasWiFiNetworkRule)
        XCTAssertTrue(share.ipAddressChangeObservations.isEmpty)
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

    func testBonjourSMBServiceIdentityIsParsedBeforeAddressLookup() {
        XCTAssertEqual(
            SystemHostResolver.bonjourServiceIdentity(for: "Living Room NAS._smb._tcp.local"),
            BonjourServiceIdentity(name: "Living Room NAS", type: "_smb._tcp.", domain: "local.")
        )
        XCTAssertNil(SystemHostResolver.bonjourServiceIdentity(for: "living-room-nas.local"))
    }

    func testResolvedIPAddressCacheKeepsHostnameAndTracksInstability() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        var share = NetworkShare(
            displayName: "Media",
            urlString: "smb://server.local/Media",
            mountPath: "/Volumes/Media"
        )

        XCTAssertEqual(
            share.recordResolvedIPAddress("192.168.1.20", observedAt: now.addingTimeInterval(-300)),
            .initial
        )
        XCTAssertEqual(
            share.recordResolvedIPAddress("192.168.1.20", observedAt: now.addingTimeInterval(-200)),
            .unchanged
        )
        XCTAssertEqual(
            share.recordResolvedIPAddress("192.168.1.21", observedAt: now.addingTimeInterval(-100)),
            .changed(recentChangeCount: 1)
        )
        XCTAssertEqual(
            share.recordResolvedIPAddress("192.168.1.22", observedAt: now),
            .changed(recentChangeCount: 2)
        )

        XCTAssertEqual(share.host, "server.local")
        XCTAssertEqual(share.cachedIPAddress, "192.168.1.22")
        XCTAssertEqual(share.recentIPAddressChangeCount(at: now), 2)
        XCTAssertTrue(share.hasUnstableIPAddress(at: now))
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

    func testEditorDraftPreservesPauseState() {
        let resumeAt = Date().addingTimeInterval(3_600)
        let share = NetworkShare(
            displayName: "Media",
            urlString: "smb://server.local/Media",
            mountPath: "/Volumes/Media",
            pauseState: .paused(until: resumeAt)
        )

        XCTAssertEqual(DraftShare(share: share).pauseState, .paused(until: resumeAt))
    }

    func testEditorDraftKeepsNetworkAndVPNConnectionPathsIndependent() {
        let networkOnlyShare = NetworkShare(
            displayName: "Media",
            urlString: "smb://server.local/Media",
            mountPath: "/Volumes/Media",
            rules: ShareRules(wifiNetworkName: "Home")
        )
        let networkDraft = DraftShare(share: networkOnlyShare)

        XCTAssertTrue(networkDraft.limitsToRegisteredNetwork)
        XCTAssertFalse(networkDraft.usesVPNRule)
        XCTAssertTrue(networkDraft.rules.hasNetworkRule)
        XCTAssertFalse(networkDraft.rules.hasVPNRule)

        let vpnOnlyShare = NetworkShare(
            displayName: "Media",
            urlString: "smb://server.local/Media",
            mountPath: "/Volumes/Media",
            rules: ShareRules(vpnRuleEnabled: true, vpnName: "Work VPN")
        )
        let vpnDraft = DraftShare(share: vpnOnlyShare)

        XCTAssertFalse(vpnDraft.limitsToRegisteredNetwork)
        XCTAssertTrue(vpnDraft.usesVPNRule)
        XCTAssertEqual(vpnDraft.rules.requiredVPNName, "Work VPN")
    }

    func testEditorDraftRetiresLegacyUnnamedVPNRule() {
        let legacyShare = NetworkShare(
            displayName: "Media",
            urlString: "smb://server.local/Media",
            mountPath: "/Volumes/Media",
            rules: ShareRules(
                wifiNetworkName: "Home",
                vpnRuleEnabled: true,
                vpnName: ""
            )
        )

        let draft = DraftShare(share: legacyShare)

        XCTAssertTrue(draft.limitsToRegisteredNetwork)
        XCTAssertFalse(draft.usesVPNRule)
        XCTAssertTrue(draft.rules.hasNetworkRule)
        XCTAssertFalse(draft.rules.hasVPNRule)
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
        XCTAssertEqual(blocked.blockedStatus, .waitingForAllowedNetwork("the registered network"))
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

        // An arbitrary active VPN cannot bypass a registered-network rule.
        let onVPNElsewhere = rules.evaluate(
            currentWiFiNetworkName: nil,
            isVPNConnected: true,
            activeVPNNames: [],
            currentIPv4Subnets: ["10.0.0.0/24"]
        )
        XCTAssertFalse(onVPNElsewhere.allowsConnection)
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

    func testConfiguredVPNPathAcceptsIdentifiedAndUnidentifiedTunnels() {
        let rules = ShareRules(vpnRuleEnabled: true, vpnName: "VPN A")

        let onVPNA = rules.evaluate(currentWiFiNetworkName: nil, isVPNConnected: true, activeVPNNames: ["VPN A"])
        XCTAssertTrue(onVPNA.allowsConnection)
        XCTAssertTrue(onVPNA.shouldAttemptMount)

        let onVPNB = rules.evaluate(currentWiFiNetworkName: nil, isVPNConnected: true, activeVPNNames: ["VPN B"])
        XCTAssertTrue(onVPNB.allowsConnection)

        // App-managed Network Extensions such as WireGuard can expose a live
        // tunnel without exposing their profile name to Otter.
        let onUnnamedVPN = rules.evaluate(currentWiFiNetworkName: nil, isVPNConnected: true, activeVPNNames: [])
        XCTAssertTrue(onUnnamedVPN.allowsConnection)

        let disconnected = rules.evaluate(currentWiFiNetworkName: nil, isVPNConnected: false, activeVPNNames: [])
        XCTAssertFalse(disconnected.allowsConnection)
        XCTAssertEqual(disconnected.blockedStatus, .waitingForVPN("VPN A"))
    }

    func testUnnamedVPNRuleNeverMatchesAnArbitraryTunnel() {
        let rules = ShareRules(vpnRuleEnabled: true, vpnName: "")

        let connected = rules.evaluate(currentWiFiNetworkName: nil, isVPNConnected: true, activeVPNNames: [])
        XCTAssertFalse(connected.allowsConnection)
        XCTAssertFalse(connected.shouldAttemptMount)
        XCTAssertEqual(
            connected.blockedStatus,
            .waitingForAllowedNetwork("a VPN selected in this share’s settings")
        )

        let disconnected = rules.evaluate(currentWiFiNetworkName: nil, isVPNConnected: false, activeVPNNames: [])
        XCTAssertFalse(disconnected.allowsConnection)
        XCTAssertEqual(
            disconnected.blockedStatus,
            .waitingForAllowedNetwork("a VPN selected in this share’s settings")
        )
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
        XCTAssertEqual(foreignWifiNoVPN.blockedStatus, .waitingForAllowedNetwork("the registered network or VPN “Work VPN”"))

        // Unregistered Wi-Fi, correct VPN -> succeeds
        let foreignWifiWithVPN = rules.evaluate(currentWiFiNetworkName: "Coffee Shop", isVPNConnected: true, activeVPNNames: ["Work VPN"])
        XCTAssertTrue(foreignWifiWithVPN.allowsConnection)

        // Otter cannot identify another app's profile reliably. A live tunnel
        // triggers the server check; an unusable VPN fails at reachability.
        let foreignWifiWithWrongVPN = rules.evaluate(currentWiFiNetworkName: "Coffee Shop", isVPNConnected: true, activeVPNNames: ["Other VPN"])
        XCTAssertTrue(foreignWifiWithWrongVPN.allowsConnection)
    }
}

final class VPNConnectionIdentityTests: XCTestCase {
    func testWaitingForVPNStatusUsesDirectRecoveryWording() {
        let status = ShareStatus.waitingForVPN("Tunnel to Work")

        XCTAssertEqual(status.label, "Waiting for VPN")
        XCTAssertEqual(status.detail, "Connect to “Tunnel to Work” to access this server.")
        XCTAssertTrue(status.needsAttention)
    }

    func testAppManagedVPNFailureExplainsTheMacOSLimitation() {
        let message = SystemVPNConnectionError.notControllable("Work VPN").localizedDescription

        XCTAssertTrue(message.contains("does not allow Otter to start"))
        XCTAssertTrue(message.contains("managed by another VPN app"))
        XCTAssertTrue(message.contains("Connect it manually"))
    }

    func testUnidentifiedTunnelCountsAsConnectedWithoutInventingAName() {
        let identity = VPNConnectionIdentity(hasActiveTunnel: true, identifiedNames: [])

        XCTAssertTrue(identity.isConnected)
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

    func testProviderNameDoesNotPretendToIdentifyTheActiveProfile() {
        let identity = VPNConnectionIdentity(
            hasActiveTunnel: true,
            identifiedNames: ["WireGuard"],
            hasIdentifiedProfile: false
        )

        XCTAssertTrue(identity.isConnected)
        XCTAssertTrue(identity.hasUnidentifiedTunnel)
        XCTAssertEqual(identity.activeNames, ["WireGuard"])
    }

    func testSystemReportedVPNNameCountsAsConnectedDuringInterfaceRefresh() {
        let identity = VPNConnectionIdentity(
            hasActiveTunnel: false,
            identifiedNames: ["Work VPN"]
        )

        XCTAssertTrue(identity.isConnected)
        XCTAssertFalse(identity.hasUnidentifiedTunnel)
        XCTAssertEqual(identity.activeNames, ["Work VPN"])
    }

    func testVPNVerificationAcceptsAnActiveTunnelBeforeServerCheck() {
        let connected = VPNVerificationResult.connected("Tunnel to Work")
        let different = VPNVerificationResult.differentVPN(
            required: "Tunnel to Work",
            active: ["Personal VPN"]
        )
        let unidentified = VPNVerificationResult.unidentifiedTunnel("Tunnel to Work")

        XCTAssertTrue(connected.isVerified)
        XCTAssertTrue(different.isVerified)
        XCTAssertTrue(unidentified.isVerified)
        XCTAssertTrue(connected.message.contains("will check the server"))
        XCTAssertTrue(different.message.contains("will check the server"))
        XCTAssertTrue(unidentified.message.contains("will check the server"))
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
    func testPausedShareDoesNotReachOrMountAutomatically() async {
        let suiteName = "OtterTests.ShareMonitorRetryTests.Paused"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let settings = SettingsStore(defaults: defaults, credentialStore: RecordingCredentialStore())
        let resumeAt = Date().addingTimeInterval(3_600)
        let share = NetworkShare(
            displayName: "Media",
            urlString: "smb://server.local/Media",
            mountPath: "/Volumes/Media",
            pauseState: .paused(until: resumeAt)
        )
        settings.addShare(share)
        let network = StubNetworkReachability(isOnline: true, isReachable: true)
        let mountService = StubMountService()
        let monitor = ShareMonitor(
            settings: settings,
            mountService: mountService,
            wakeOnLANService: StubWakeOnLANService(),
            networkService: network,
            notificationService: RecordingNotificationService(),
            eventLog: ShareEventLog(defaults: defaults),
            defaults: defaults
        )

        await monitor.evaluate(share, reason: .timer)
        let mountCallCount = await mountService.mountCallCount

        XCTAssertEqual(monitor.status(for: share), .paused(resumeAt))
        XCTAssertEqual(network.canReachCallCount, 0)
        XCTAssertEqual(mountCallCount, 0)
        XCTAssertTrue(settings.share(id: share.id)?.keepMounted == true)
    }

    @MainActor
    func testDisconnectPausesWithoutDisablingAutomaticMounting() async {
        let suiteName = "OtterTests.ShareMonitorRetryTests.Disconnect"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let settings = SettingsStore(defaults: defaults, credentialStore: RecordingCredentialStore())
        let share = NetworkShare(
            displayName: "Media",
            urlString: "smb://server.local/Media",
            mountPath: "/Volumes/Media",
            keepMounted: true
        )
        settings.addShare(share)
        let monitor = ShareMonitor(
            settings: settings,
            mountService: StubMountService(),
            wakeOnLANService: StubWakeOnLANService(),
            networkService: StubNetworkReachability(isOnline: true, isReachable: true),
            notificationService: RecordingNotificationService(),
            eventLog: ShareEventLog(defaults: defaults),
            defaults: defaults
        )

        await monitor.disconnect(share)

        XCTAssertEqual(monitor.status(for: share), .paused(nil))
        XCTAssertEqual(settings.share(id: share.id)?.pauseState, .paused())
        XCTAssertTrue(settings.share(id: share.id)?.keepMounted == true)
    }

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

    @MainActor
    func testNamedVPNConnectsBeforeMountingShare() async {
        let suiteName = "OtterTests.ShareMonitorRetryTests.VPNSuccess"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let settings = SettingsStore(defaults: defaults, credentialStore: RecordingCredentialStore())
        let share = NetworkShare(
            displayName: "Media",
            urlString: "smb://server.local/Media",
            mountPath: "/Volumes/Media",
            rules: ShareRules(vpnRuleEnabled: true, vpnName: "Work VPN")
        )
        settings.addShare(share)
        let network = StubNetworkReachability(
            isOnline: true,
            isReachable: true,
            vpnNameToActivateOnRefresh: "Work VPN"
        )
        let vpnConnectionService = StubVPNConnectionService()
        let mountedURL = URL(fileURLWithPath: "/Volumes/Media", isDirectory: true)
        let mountService = StubMountService(mountResult: mountedURL)
        let monitor = ShareMonitor(
            settings: settings,
            mountService: mountService,
            wakeOnLANService: StubWakeOnLANService(),
            vpnConnectionService: vpnConnectionService,
            networkService: network,
            notificationService: RecordingNotificationService(),
            eventLog: ShareEventLog(defaults: defaults),
            defaults: defaults
        )

        await monitor.evaluate(share, reason: .timer)

        let vpnConnectionNames = await vpnConnectionService.connectionNames
        let mountCallCount = await mountService.mountCallCount
        XCTAssertEqual(vpnConnectionNames, ["Work VPN"])
        XCTAssertEqual(mountCallCount, 1)
        XCTAssertEqual(monitor.status(for: share), .connected)
    }

    @MainActor
    func testActiveUnidentifiedTunnelTriggersServerCheckAndMount() async {
        let suiteName = "OtterTests.ShareMonitorRetryTests.UnidentifiedVPN"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let settings = SettingsStore(defaults: defaults, credentialStore: RecordingCredentialStore())
        let share = NetworkShare(
            displayName: "Media",
            urlString: "smb://server.local/Media",
            mountPath: "/Volumes/Media",
            rules: ShareRules(vpnRuleEnabled: true, vpnName: "Tunnel to Work")
        )
        settings.addShare(share)
        let network = StubNetworkReachability(
            isOnline: true,
            isReachable: true,
            isVPNConnected: true,
            activeVPNNames: []
        )
        let vpnConnectionService = StubVPNConnectionService()
        let mountService = StubMountService(
            mountResult: URL(fileURLWithPath: "/Volumes/Media", isDirectory: true)
        )
        let monitor = ShareMonitor(
            settings: settings,
            mountService: mountService,
            wakeOnLANService: StubWakeOnLANService(),
            vpnConnectionService: vpnConnectionService,
            networkService: network,
            notificationService: RecordingNotificationService(),
            eventLog: ShareEventLog(defaults: defaults),
            defaults: defaults
        )

        await monitor.evaluate(share, reason: .timer)

        let vpnConnectionNames = await vpnConnectionService.connectionNames
        let mountCallCount = await mountService.mountCallCount
        XCTAssertTrue(vpnConnectionNames.isEmpty)
        XCTAssertEqual(network.canReachCallCount, 1)
        XCTAssertEqual(mountCallCount, 1)
        XCTAssertEqual(monitor.status(for: share), .connected)
    }

    @MainActor
    func testUnreachableServerOverDifferentVPNWaitsQuietly() async {
        let suiteName = "OtterTests.ShareMonitorRetryTests.WrongVPN"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let settings = SettingsStore(defaults: defaults, credentialStore: RecordingCredentialStore())
        let share = NetworkShare(
            displayName: "Media",
            urlString: "smb://server.local/Media",
            mountPath: "/Volumes/Media",
            rules: ShareRules(vpnRuleEnabled: true, vpnName: "Tunnel to Work")
        )
        settings.addShare(share)
        let network = StubNetworkReachability(
            isOnline: true,
            isReachable: false,
            isVPNConnected: true,
            activeVPNNames: ["Other VPN"]
        )
        let vpnConnectionService = StubVPNConnectionService()
        let mountService = StubMountService(
            mountResult: URL(fileURLWithPath: "/Volumes/Media", isDirectory: true)
        )
        let monitor = ShareMonitor(
            settings: settings,
            mountService: mountService,
            wakeOnLANService: StubWakeOnLANService(),
            vpnConnectionService: vpnConnectionService,
            networkService: network,
            notificationService: RecordingNotificationService(),
            eventLog: ShareEventLog(defaults: defaults),
            defaults: defaults
        )

        await monitor.evaluate(share, reason: .timer)

        let vpnConnectionNames = await vpnConnectionService.connectionNames
        let mountCallCount = await mountService.mountCallCount
        XCTAssertTrue(vpnConnectionNames.isEmpty)
        XCTAssertEqual(mountCallCount, 0)
        XCTAssertEqual(monitor.status(for: share), .waitingForAccess)
        XCTAssertFalse(monitor.status(for: share).needsAttention)
        XCTAssertEqual(monitor.runtimeState(for: share).failureCount, 0)
        XCTAssertNil(monitor.runtimeState(for: share).nextRetryDate)

        await monitor.evaluate(share, reason: .timer)

        XCTAssertEqual(network.canReachCallCount, 2)
        XCTAssertEqual(monitor.runtimeState(for: share).failureCount, 0)
        XCTAssertEqual(monitor.status(for: share), .waitingForAccess)
    }

    @MainActor
    func testUnreachableServerOverConfirmedVPNRemainsAProblem() async {
        let suiteName = "OtterTests.ShareMonitorRetryTests.ConfirmedVPNUnavailable"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let settings = SettingsStore(defaults: defaults, credentialStore: RecordingCredentialStore())
        let share = NetworkShare(
            displayName: "Media",
            urlString: "smb://server.local/Media",
            mountPath: "/Volumes/Media",
            rules: ShareRules(vpnRuleEnabled: true, vpnName: "Tunnel to Work")
        )
        settings.addShare(share)
        let network = StubNetworkReachability(
            isOnline: true,
            isReachable: false,
            isVPNConnected: true,
            activeVPNNames: ["Tunnel to Work"]
        )
        let monitor = ShareMonitor(
            settings: settings,
            mountService: StubMountService(),
            wakeOnLANService: StubWakeOnLANService(),
            networkService: network,
            notificationService: RecordingNotificationService(),
            eventLog: ShareEventLog(defaults: defaults),
            defaults: defaults
        )

        await monitor.evaluate(share, reason: .timer)

        XCTAssertEqual(monitor.status(for: share), .waitingForServerOnVPN)
        XCTAssertTrue(monitor.status(for: share).needsAttention)
        XCTAssertEqual(monitor.runtimeState(for: share).failureCount, 1)
        XCTAssertNotNil(monitor.runtimeState(for: share).nextRetryDate)
    }

    @MainActor
    func testManualAttemptOverDifferentVPNReportsTheFailure() async {
        let suiteName = "OtterTests.ShareMonitorRetryTests.ManualWrongVPN"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let settings = SettingsStore(defaults: defaults, credentialStore: RecordingCredentialStore())
        let share = NetworkShare(
            displayName: "Media",
            urlString: "smb://server.local/Media",
            mountPath: "/Volumes/Media",
            rules: ShareRules(vpnRuleEnabled: true, vpnName: "Tunnel to Work")
        )
        settings.addShare(share)
        let network = StubNetworkReachability(
            isOnline: true,
            isReachable: false,
            isVPNConnected: true,
            activeVPNNames: ["Other VPN"]
        )
        let monitor = ShareMonitor(
            settings: settings,
            mountService: StubMountService(),
            wakeOnLANService: StubWakeOnLANService(),
            networkService: network,
            notificationService: RecordingNotificationService(),
            eventLog: ShareEventLog(defaults: defaults),
            defaults: defaults
        )

        await monitor.evaluate(share, reason: .manual, force: true)

        XCTAssertEqual(monitor.status(for: share), .waitingForServerOnVPN)
        XCTAssertTrue(monitor.status(for: share).needsAttention)
    }

    @MainActor
    func testUnnamedVPNRuleDoesNotConnectOrMount() async {
        let suiteName = "OtterTests.ShareMonitorRetryTests.UnnamedVPN"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let settings = SettingsStore(defaults: defaults, credentialStore: RecordingCredentialStore())
        let share = NetworkShare(
            displayName: "Media",
            urlString: "smb://server.local/Media",
            mountPath: "/Volumes/Media",
            rules: ShareRules(vpnRuleEnabled: true)
        )
        settings.addShare(share)
        let vpnConnectionService = StubVPNConnectionService()
        let mountService = StubMountService(mountResult: URL(fileURLWithPath: "/Volumes/Media"))
        let monitor = ShareMonitor(
            settings: settings,
            mountService: mountService,
            wakeOnLANService: StubWakeOnLANService(),
            vpnConnectionService: vpnConnectionService,
            networkService: StubNetworkReachability(isOnline: true, isReachable: true),
            notificationService: RecordingNotificationService(),
            eventLog: ShareEventLog(defaults: defaults),
            defaults: defaults
        )

        await monitor.evaluate(share, reason: .timer)

        let vpnConnectionNames = await vpnConnectionService.connectionNames
        let mountCallCount = await mountService.mountCallCount
        XCTAssertTrue(vpnConnectionNames.isEmpty)
        XCTAssertEqual(mountCallCount, 0)
        XCTAssertEqual(
            monitor.status(for: share),
            .waitingForAllowedNetwork("a VPN selected in this share’s settings")
        )
    }

    @MainActor
    func testUnavailableNamedVPNFailsWithoutMounting() async {
        let suiteName = "OtterTests.ShareMonitorRetryTests.VPNUnavailable"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let settings = SettingsStore(defaults: defaults, credentialStore: RecordingCredentialStore())
        let share = NetworkShare(
            displayName: "Media",
            urlString: "smb://server.local/Media",
            mountPath: "/Volumes/Media",
            rules: ShareRules(vpnRuleEnabled: true, vpnName: "Missing VPN")
        )
        settings.addShare(share)
        let vpnConnectionService = StubVPNConnectionService(
            error: .serviceNotFound("Missing VPN")
        )
        let mountService = StubMountService(mountResult: URL(fileURLWithPath: "/Volumes/Media"))
        let monitor = ShareMonitor(
            settings: settings,
            mountService: mountService,
            wakeOnLANService: StubWakeOnLANService(),
            vpnConnectionService: vpnConnectionService,
            networkService: StubNetworkReachability(isOnline: true, isReachable: true),
            notificationService: RecordingNotificationService(),
            eventLog: ShareEventLog(defaults: defaults),
            defaults: defaults
        )

        await monitor.evaluate(share, reason: .timer)

        let mountCallCount = await mountService.mountCallCount
        guard case let .failed(message) = monitor.status(for: share) else {
            return XCTFail("Expected a VPN connection failure")
        }
        XCTAssertTrue(message.contains("System Settings"))
        XCTAssertEqual(mountCallCount, 0)
    }

    @MainActor
    func testAppManagedVPNWaitsForTheUserWithoutFailingTheShare() async {
        let suiteName = "OtterTests.ShareMonitorRetryTests.AppManagedVPN"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let settings = SettingsStore(defaults: defaults, credentialStore: RecordingCredentialStore())
        let share = NetworkShare(
            displayName: "Media",
            urlString: "smb://server.local/Media",
            mountPath: "/Volumes/Media",
            rules: ShareRules(vpnRuleEnabled: true, vpnName: "Tunnel to Work")
        )
        settings.addShare(share)
        let vpnConnectionService = StubVPNConnectionService(
            error: .notControllable("Tunnel to Work")
        )
        let mountService = StubMountService(mountResult: URL(fileURLWithPath: "/Volumes/Media"))
        let monitor = ShareMonitor(
            settings: settings,
            mountService: mountService,
            wakeOnLANService: StubWakeOnLANService(),
            vpnConnectionService: vpnConnectionService,
            networkService: StubNetworkReachability(isOnline: true, isReachable: true),
            notificationService: RecordingNotificationService(),
            eventLog: ShareEventLog(defaults: defaults),
            defaults: defaults
        )

        await monitor.evaluate(share, reason: .timer)

        let mountCallCount = await mountService.mountCallCount
        XCTAssertEqual(monitor.status(for: share), .waitingForVPN("Tunnel to Work"))
        XCTAssertEqual(monitor.runtimeState(for: share).failureCount, 0)
        XCTAssertNil(monitor.runtimeState(for: share).nextRetryDate)
        XCTAssertEqual(mountCallCount, 0)
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

final class MountHealthServiceTests: XCTestCase {
    func testProbeReportsLocalDirectoryAsHealthy() async {
        let result = await MountHealthService().checkMount(
            at: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
            timeout: 1
        )

        XCTAssertEqual(result, .healthy)
    }

    func testRecoveryRefusesPathsOutsideVolumes() async {
        let recovered = await MountHealthService().unmountForRecovery(
            at: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
            timeout: 1
        )

        XCTAssertFalse(recovered)
    }
}

final class ConnectionDoctorTests: XCTestCase {
    @MainActor
    func testReadinessCheckAttemptsAndReportsSuccessfulMount() async {
        let suiteName = "OtterTests.ConnectionDoctorTests.Readiness"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let settings = SettingsStore(defaults: defaults, credentialStore: RecordingCredentialStore())
        let share = NetworkShare(
            displayName: "Media",
            urlString: "smb://server.local/Media",
            mountPath: "/Volumes/Media"
        )
        settings.addShare(share)
        let mountedURL = URL(fileURLWithPath: "/Volumes/Media", isDirectory: true)
        let mountService = StubMountService(mountResult: mountedURL)
        let network = StubNetworkReachability(isOnline: true, isReachable: true)
        let monitor = makeMonitor(
            settings: settings,
            mountService: mountService,
            network: network,
            defaults: defaults
        )
        let doctor = ConnectionDoctor(
            settings: settings,
            mountService: mountService,
            mountHealthService: StubMountHealthService(),
            networkService: network,
            monitor: monitor,
            hostResolver: StubHostResolver(result: "192.168.1.20")
        )

        let report = await doctor.run(for: share, attemptMount: true)
        let mountCallCount = await mountService.mountCallCount
        let mountStep = report.steps.first { $0.title == "Mount attempt" }

        XCTAssertGreaterThanOrEqual(mountCallCount, 1)
        XCTAssertEqual(mountStep?.status, .passed)
        XCTAssertFalse(report.hasFailures)
    }

    @MainActor
    func testUnidentifiedVPNTunnelPassesConditionsBeforeServerCheck() async {
        let suiteName = "OtterTests.ConnectionDoctorTests.UnidentifiedVPN"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let settings = SettingsStore(defaults: defaults, credentialStore: RecordingCredentialStore())
        let share = NetworkShare(
            displayName: "Media",
            urlString: "smb://192.0.2.10/Media",
            mountPath: "/Volumes/Media",
            rules: ShareRules(vpnRuleEnabled: true, vpnName: "Tunnel to Work")
        )
        settings.addShare(share)
        let mountService = StubMountService()
        let network = StubNetworkReachability(
            isOnline: true,
            isReachable: true,
            isVPNConnected: true,
            activeVPNNames: []
        )
        let monitor = makeMonitor(
            settings: settings,
            mountService: mountService,
            network: network,
            defaults: defaults
        )
        let doctor = ConnectionDoctor(
            settings: settings,
            mountService: mountService,
            mountHealthService: StubMountHealthService(),
            networkService: network,
            monitor: monitor,
            hostResolver: StubHostResolver(result: nil)
        )

        let report = await doctor.run(for: share, attemptMount: false)
        let conditions = report.steps.first { $0.title == "Connection conditions" }
        let reachability = report.steps.first { $0.title == "SMB reachability" }

        XCTAssertEqual(conditions?.status, .passed)
        XCTAssertTrue(conditions?.detail.contains("did not expose its profile name") == true)
        XCTAssertEqual(reachability?.status, .passed)
    }

    @MainActor
    func testSuccessfulResolutionCachesFallbackWithoutReplacingHostname() async {
        let suiteName = "OtterTests.ConnectionDoctorTests.AddressCache"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let settings = SettingsStore(defaults: defaults, credentialStore: RecordingCredentialStore())
        let share = NetworkShare(
            displayName: "Media",
            urlString: "smb://server.local/Media",
            mountPath: "/Volumes/Media"
        )
        settings.addShare(share)
        let mountedURL = URL(fileURLWithPath: "/Volumes/Media", isDirectory: true)
        let mountService = StubMountService(mountedURL: mountedURL)
        let network = StubNetworkReachability(isOnline: true, isReachable: true)
        let monitor = makeMonitor(
            settings: settings,
            mountService: mountService,
            network: network,
            defaults: defaults
        )
        let doctor = ConnectionDoctor(
            settings: settings,
            mountService: mountService,
            mountHealthService: StubMountHealthService(result: .healthy),
            networkService: network,
            monitor: monitor,
            hostResolver: StubHostResolver(result: "192.168.1.20")
        )

        let report = await doctor.run(for: share, attemptMount: false)
        let stability = report.steps.first { $0.title == "LAN address stability" }

        XCTAssertEqual(settings.share(id: share.id)?.host, "server.local")
        XCTAssertEqual(settings.share(id: share.id)?.cachedIPAddress, "192.168.1.20")
        XCTAssertEqual(stability?.status, .passed)
        XCTAssertTrue(stability?.detail.contains("hostname remains primary") == true)
    }

    @MainActor
    func testRepeatedLANAddressChangesProduceWarning() async {
        let suiteName = "OtterTests.ConnectionDoctorTests.AddressChanges"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let settings = SettingsStore(defaults: defaults, credentialStore: RecordingCredentialStore())
        let now = Date()
        let share = NetworkShare(
            displayName: "Media",
            urlString: "smb://server.local/Media",
            mountPath: "/Volumes/Media",
            cachedIPAddress: "192.168.1.22",
            ipAddressChangeObservations: [
                IPAddressChangeObservation(
                    previousAddress: "192.168.1.20",
                    currentAddress: "192.168.1.21",
                    observedAt: now.addingTimeInterval(-2 * 24 * 60 * 60)
                ),
                IPAddressChangeObservation(
                    previousAddress: "192.168.1.21",
                    currentAddress: "192.168.1.22",
                    observedAt: now.addingTimeInterval(-24 * 60 * 60)
                )
            ]
        )
        settings.addShare(share)
        let mountedURL = URL(fileURLWithPath: "/Volumes/Media", isDirectory: true)
        let mountService = StubMountService(mountedURL: mountedURL)
        let network = StubNetworkReachability(isOnline: true, isReachable: true)
        let monitor = makeMonitor(
            settings: settings,
            mountService: mountService,
            network: network,
            defaults: defaults
        )
        let doctor = ConnectionDoctor(
            settings: settings,
            mountService: mountService,
            mountHealthService: StubMountHealthService(result: .healthy),
            networkService: network,
            monitor: monitor,
            hostResolver: StubHostResolver(result: "192.168.1.22")
        )

        let report = await doctor.run(for: share, attemptMount: false)
        let stability = report.steps.first { $0.title == "LAN address stability" }

        XCTAssertEqual(stability?.status, .warning)
        XCTAssertTrue(stability?.detail.contains("2 times") == true)
        XCTAssertEqual(settings.share(id: share.id)?.urlString, "smb://server.local/Media")
        XCTAssertFalse(report.hasRepairableItems)
    }

    @MainActor
    func testMissingExpectedShareOffersRepair() async {
        let suiteName = "OtterTests.ConnectionDoctorTests.RepairAvailability.Missing"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let settings = SettingsStore(defaults: defaults, credentialStore: RecordingCredentialStore())
        let share = NetworkShare(
            displayName: "Media",
            urlString: "smb://server.local/Media",
            mountPath: "/Volumes/Media",
            keepMounted: true
        )
        settings.addShare(share)
        let mountService = StubMountService()
        let network = StubNetworkReachability(isOnline: true, isReachable: true)
        let monitor = makeMonitor(
            settings: settings,
            mountService: mountService,
            network: network,
            defaults: defaults
        )
        let doctor = ConnectionDoctor(
            settings: settings,
            mountService: mountService,
            mountHealthService: StubMountHealthService(),
            networkService: network,
            monitor: monitor,
            hostResolver: StubHostResolver(result: "192.168.1.20")
        )

        let report = await doctor.run(for: share, attemptMount: false)

        XCTAssertTrue(report.hasRepairableItems)
    }

    @MainActor
    func testOfflineShareDoesNotOfferUnavailableRepair() async {
        let suiteName = "OtterTests.ConnectionDoctorTests.RepairAvailability.Offline"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let settings = SettingsStore(defaults: defaults, credentialStore: RecordingCredentialStore())
        let share = NetworkShare(
            displayName: "Media",
            urlString: "smb://server.local/Media",
            mountPath: "/Volumes/Media"
        )
        settings.addShare(share)
        let mountService = StubMountService()
        let network = StubNetworkReachability(isOnline: false, isReachable: false)
        let monitor = makeMonitor(
            settings: settings,
            mountService: mountService,
            network: network,
            defaults: defaults
        )
        let doctor = ConnectionDoctor(
            settings: settings,
            mountService: mountService,
            mountHealthService: StubMountHealthService(),
            networkService: network,
            monitor: monitor,
            hostResolver: StubHostResolver(result: nil)
        )

        let report = await doctor.run(for: share, attemptMount: false)

        XCTAssertFalse(report.hasRepairableItems)
    }

    @MainActor
    func testUnresponsiveMountedShareOffersRepair() async {
        let suiteName = "OtterTests.ConnectionDoctorTests.RepairAvailability.Unresponsive"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let settings = SettingsStore(defaults: defaults, credentialStore: RecordingCredentialStore())
        let share = NetworkShare(
            displayName: "Media",
            urlString: "smb://server.local/Media",
            mountPath: "/Volumes/Media"
        )
        settings.addShare(share)
        let mountedURL = URL(fileURLWithPath: "/Volumes/Media", isDirectory: true)
        let mountService = StubMountService(mountedURL: mountedURL)
        let network = StubNetworkReachability(isOnline: true, isReachable: true)
        let monitor = makeMonitor(
            settings: settings,
            mountService: mountService,
            network: network,
            defaults: defaults
        )
        let doctor = ConnectionDoctor(
            settings: settings,
            mountService: mountService,
            mountHealthService: StubMountHealthService(result: .unresponsive),
            networkService: network,
            monitor: monitor,
            hostResolver: StubHostResolver(result: "192.168.1.20")
        )

        let report = await doctor.run(for: share, attemptMount: false)

        XCTAssertTrue(report.hasRepairableItems)
    }

    @MainActor
    func testReachableSMBServiceDowngradesDirectDNSFailureToInformation() async {
        let suiteName = "OtterTests.ConnectionDoctorTests.NameResolution"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let settings = SettingsStore(defaults: defaults, credentialStore: RecordingCredentialStore())
        let share = NetworkShare(
            displayName: "Media",
            urlString: "smb://bonjour-name.local/Media",
            mountPath: "/Volumes/Media"
        )
        settings.addShare(share)
        let mountService = StubMountService()
        let network = StubNetworkReachability(isOnline: true, isReachable: true)
        let monitor = makeMonitor(
            settings: settings,
            mountService: mountService,
            network: network,
            defaults: defaults
        )
        let doctor = ConnectionDoctor(
            settings: settings,
            mountService: mountService,
            mountHealthService: StubMountHealthService(),
            networkService: network,
            monitor: monitor,
            hostResolver: StubHostResolver(result: nil)
        )

        let report = await doctor.run(for: share, attemptMount: false)
        let nameResolution = report.steps.first { $0.title == "Name resolution" }

        XCTAssertEqual(nameResolution?.status, .information)
        XCTAssertTrue(nameResolution?.detail.contains("macOS can still reach") == true)
        XCTAssertFalse(report.hasFailures)
    }

    @MainActor
    func testRepairMountsAndResumesShareWithoutChangingKeepMountedPreference() async {
        let suiteName = "OtterTests.ConnectionDoctorTests.Repair"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let settings = SettingsStore(defaults: defaults, credentialStore: RecordingCredentialStore())
        let share = NetworkShare(
            displayName: "Media",
            urlString: "smb://server.local/Media",
            mountPath: "/Volumes/Media",
            keepMounted: false,
            pauseState: .paused()
        )
        settings.addShare(share)
        let mountedURL = URL(fileURLWithPath: "/Volumes/Media", isDirectory: true)
        let mountService = StubMountService(mountResult: mountedURL)
        let network = StubNetworkReachability(isOnline: true, isReachable: true)
        let monitor = makeMonitor(
            settings: settings,
            mountService: mountService,
            network: network,
            defaults: defaults
        )
        let doctor = ConnectionDoctor(
            settings: settings,
            mountService: mountService,
            mountHealthService: StubMountHealthService(),
            networkService: network,
            monitor: monitor
        )

        let result = await doctor.attemptRepair(for: share)
        let mountCallCount = await mountService.mountCallCount

        XCTAssertEqual(result.status, .passed)
        XCTAssertEqual(mountCallCount, 1)
        XCTAssertEqual(monitor.status(for: share), .connected)
        XCTAssertEqual(settings.share(id: share.id)?.pauseState, .inactive)
        XCTAssertFalse(settings.share(id: share.id)?.keepMounted == true)
    }

    @MainActor
    func testRepairDoesNotDisturbHealthyMountedShare() async {
        let suiteName = "OtterTests.ConnectionDoctorTests.Healthy"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let settings = SettingsStore(defaults: defaults, credentialStore: RecordingCredentialStore())
        let share = NetworkShare(
            displayName: "Media",
            urlString: "smb://server.local/Media",
            mountPath: "/Volumes/Media"
        )
        settings.addShare(share)
        let mountedURL = URL(fileURLWithPath: "/Volumes/Media", isDirectory: true)
        let mountService = StubMountService(mountedURL: mountedURL)
        let healthService = StubMountHealthService(result: .healthy)
        let network = StubNetworkReachability(isOnline: true, isReachable: true)
        let monitor = makeMonitor(
            settings: settings,
            mountService: mountService,
            network: network,
            defaults: defaults
        )
        let doctor = ConnectionDoctor(
            settings: settings,
            mountService: mountService,
            mountHealthService: healthService,
            networkService: network,
            monitor: monitor,
            hostResolver: StubHostResolver(result: "192.168.1.20")
        )

        let report = await doctor.run(for: share, attemptMount: false)
        let result = await doctor.attemptRepair(for: share)
        let mountCallCount = await mountService.mountCallCount
        let recoveryCallCount = await healthService.recoveryCallCount

        XCTAssertEqual(result.status, .passed)
        XCTAssertTrue(result.detail.contains("No repair was needed"))
        XCTAssertFalse(report.hasRepairableItems)
        XCTAssertEqual(mountCallCount, 0)
        XCTAssertEqual(recoveryCallCount, 0)
    }

    @MainActor
    func testRepairSafelyUnmountsAndReconnectsUnresponsiveShare() async {
        let suiteName = "OtterTests.ConnectionDoctorTests.Unresponsive"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let settings = SettingsStore(defaults: defaults, credentialStore: RecordingCredentialStore())
        let share = NetworkShare(
            displayName: "Media",
            urlString: "smb://server.local/Media",
            mountPath: "/Volumes/Media"
        )
        settings.addShare(share)
        let mountedURL = URL(fileURLWithPath: "/Volumes/Media", isDirectory: true)
        let mountService = StubMountService(
            mountedURL: mountedURL,
            mountResult: mountedURL,
            mountedURLReadsBeforeMissing: 1
        )
        let healthService = StubMountHealthService(result: .unresponsive, recoveryResult: true)
        let network = StubNetworkReachability(isOnline: true, isReachable: true)
        let monitor = makeMonitor(
            settings: settings,
            mountService: mountService,
            network: network,
            defaults: defaults
        )
        let doctor = ConnectionDoctor(
            settings: settings,
            mountService: mountService,
            mountHealthService: healthService,
            networkService: network,
            monitor: monitor
        )

        let result = await doctor.attemptRepair(for: share)
        let mountCallCount = await mountService.mountCallCount
        let recoveryCallCount = await healthService.recoveryCallCount

        XCTAssertEqual(result.status, .passed)
        XCTAssertTrue(result.detail.contains("safely unmounted"))
        XCTAssertEqual(recoveryCallCount, 1)
        XCTAssertEqual(mountCallCount, 1)
        XCTAssertEqual(monitor.status(for: share), .connected)
    }

    @MainActor
    func testRepairDoesNotOverrideGlobalPause() async {
        let suiteName = "OtterTests.ConnectionDoctorTests.GlobalPause"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let settings = SettingsStore(defaults: defaults, credentialStore: RecordingCredentialStore())
        let share = NetworkShare(
            displayName: "Media",
            urlString: "smb://server.local/Media",
            mountPath: "/Volumes/Media"
        )
        settings.addShare(share)
        settings.pauseAll(until: nil)
        let mountedURL = URL(fileURLWithPath: "/Volumes/Media", isDirectory: true)
        let mountService = StubMountService(mountResult: mountedURL)
        let network = StubNetworkReachability(isOnline: true, isReachable: true)
        let monitor = makeMonitor(
            settings: settings,
            mountService: mountService,
            network: network,
            defaults: defaults
        )
        let doctor = ConnectionDoctor(
            settings: settings,
            mountService: mountService,
            mountHealthService: StubMountHealthService(),
            networkService: network,
            monitor: monitor
        )

        let result = await doctor.attemptRepair(for: share)
        let mountCallCount = await mountService.mountCallCount

        XCTAssertEqual(result.status, .warning)
        XCTAssertTrue(result.detail.contains("paused globally"))
        XCTAssertEqual(mountCallCount, 0)
        XCTAssertTrue(settings.preferences.pauseState.isActive())
    }

    @MainActor
    func testCopiedReportOmitsShareAndServerIdentifiers() async {
        let suiteName = "OtterTests.ConnectionDoctorTests.Redaction"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let settings = SettingsStore(defaults: defaults, credentialStore: RecordingCredentialStore())
        let share = NetworkShare(
            displayName: "Secret Finance Share",
            urlString: "smb://192.0.2.99/Confidential",
            mountPath: "/Volumes/Confidential"
        )
        settings.addShare(share)
        let mountService = StubMountService()
        let network = StubNetworkReachability(isOnline: true, isReachable: false)
        let monitor = ShareMonitor(
            settings: settings,
            mountService: mountService,
            wakeOnLANService: StubWakeOnLANService(),
            networkService: network,
            notificationService: RecordingNotificationService(),
            eventLog: ShareEventLog(defaults: defaults),
            defaults: defaults
        )
        let doctor = ConnectionDoctor(
            settings: settings,
            mountService: mountService,
            mountHealthService: StubMountHealthService(),
            networkService: network,
            monitor: monitor
        )

        let report = await doctor.run(for: share, attemptMount: false).redactedText

        XCTAssertFalse(report.contains("Secret Finance Share"))
        XCTAssertFalse(report.contains("192.0.2.99"))
        XCTAssertFalse(report.contains("Confidential"))
        XCTAssertTrue(report.contains("Share and network identifiers: redacted"))
    }

    @MainActor
    private func makeMonitor(
        settings: SettingsStore,
        mountService: StubMountService,
        network: StubNetworkReachability,
        defaults: UserDefaults
    ) -> ShareMonitor {
        ShareMonitor(
            settings: settings,
            mountService: mountService,
            wakeOnLANService: StubWakeOnLANService(),
            networkService: network,
            notificationService: RecordingNotificationService(),
            eventLog: ShareEventLog(defaults: defaults),
            defaults: defaults
        )
    }
}

final class ProblemNotificationTrackerTests: XCTestCase {
    func testVPNRequirementDoesNotRepeatUntilItIsResolved() {
        let shareID = UUID()
        var tracker = ProblemNotificationTracker()

        XCTAssertTrue(tracker.beginProblemDelivery(for: shareID))
        tracker.resolveIfNeeded(shareID: shareID, status: .waitingForVPN("Tunnel to Work"))
        XCTAssertFalse(tracker.beginProblemDelivery(for: shareID))

        tracker.resolveIfNeeded(shareID: shareID, status: .connected)
        XCTAssertTrue(tracker.beginProblemDelivery(for: shareID))
    }

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
    func testAddedOnboardingSharePersistsImmediately() {
        let suiteName = "OtterTests.SettingsStoreTests.OnboardingPersistence"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let credentialStore = RecordingCredentialStore()
        let store = SettingsStore(defaults: defaults, credentialStore: credentialStore)
        let share = NetworkShare(
            displayName: "Media",
            urlString: "smb://server.local/Media",
            mountPath: "/Volumes/Media"
        )

        store.addShare(share)
        let reloadedStore = SettingsStore(defaults: defaults, credentialStore: credentialStore)

        XCTAssertEqual(reloadedStore.shares, [share])
    }

    @MainActor
    func testMultipleResolvedAddressesDoNotCreateFalseChangeHistoryWhenOrderChanges() {
        let suiteName = "OtterTests.SettingsStoreTests.MultiAddressCache"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let store = SettingsStore(defaults: defaults, credentialStore: RecordingCredentialStore())
        let share = NetworkShare(
            displayName: "Media",
            urlString: "smb://server.local/Media",
            mountPath: "/Volumes/Media"
        )
        store.addShare(share)

        XCTAssertEqual(
            store.recordResolvedIPAddresses(["192.168.1.20", "192.168.1.21"], for: share.id),
            .initial
        )
        XCTAssertEqual(
            store.recordResolvedIPAddresses(["192.168.1.21", "192.168.1.20"], for: share.id),
            .unchanged
        )
        XCTAssertEqual(store.share(id: share.id)?.cachedIPAddress, "192.168.1.20")
        XCTAssertTrue(store.share(id: share.id)?.ipAddressChangeObservations.isEmpty == true)
    }

    @MainActor
    func testChangingPrimaryHostnameClearsLearnedFallbackAndHistory() {
        let suiteName = "OtterTests.SettingsStoreTests.HostChange"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let store = SettingsStore(defaults: defaults, credentialStore: RecordingCredentialStore())
        var share = NetworkShare(
            displayName: "Media",
            urlString: "smb://old-server.local/Media",
            mountPath: "/Volumes/Media",
            cachedIPAddress: "192.168.1.20",
            ipAddressChangeObservations: [
                IPAddressChangeObservation(
                    previousAddress: "192.168.1.19",
                    currentAddress: "192.168.1.20",
                    observedAt: Date()
                )
            ]
        )
        store.addShare(share)

        share.urlString = "smb://new-server.local/Media"
        store.updateShare(share)

        XCTAssertEqual(store.share(id: share.id)?.host, "new-server.local")
        XCTAssertNil(store.share(id: share.id)?.cachedIPAddress)
        XCTAssertTrue(store.share(id: share.id)?.ipAddressChangeObservations.isEmpty == true)
    }

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

    @MainActor
    func testPausingDoesNotDisableKeepMountedPreference() {
        let suiteName = "OtterTests.SettingsStoreTests.Pause"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let store = SettingsStore(defaults: defaults, credentialStore: RecordingCredentialStore())
        let share = NetworkShare(
            displayName: "Media",
            urlString: "smb://server.local/Media",
            mountPath: "/Volumes/Media",
            keepMounted: true
        )
        store.addShare(share)

        store.pauseShare(id: share.id, until: nil)

        XCTAssertTrue(store.share(id: share.id)?.keepMounted == true)
        XCTAssertEqual(store.share(id: share.id)?.pauseState, .paused())
    }

    @MainActor
    func testConfigurationExportOmitsRuntimeAndPrivateState() throws {
        let suiteName = "OtterTests.SettingsStoreTests.Export"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let store = SettingsStore(defaults: defaults, credentialStore: RecordingCredentialStore())
        let share = NetworkShare(
            displayName: "Media",
            urlString: "smb://private-user:private-password@server.local/Media",
            mountPath: "/Volumes/Media",
            pauseState: .paused(until: Date().addingTimeInterval(3_600)),
            cachedIPAddress: "203.0.113.42",
            ipAddressChangeObservations: [
                IPAddressChangeObservation(
                    previousAddress: "203.0.113.41",
                    currentAddress: "203.0.113.42",
                    observedAt: Date()
                )
            ]
        )
        store.addShare(share)

        let data = try ConfigurationTransferService.encode(store.configurationArchive())
        let json = String(decoding: data, as: UTF8.self)
        let decoded = try ConfigurationTransferService.decode(data)

        XCTAssertEqual(decoded.shares.count, 1)
        XCTAssertEqual(decoded.shares[0].displayName, "Media")
        XCTAssertEqual(decoded.shares[0].urlString, "smb://server.local/Media")
        XCTAssertFalse(json.contains("cachedIPAddress"))
        XCTAssertFalse(json.contains("ipAddressChangeObservations"))
        XCTAssertFalse(json.contains("203.0.113.42"))
        XCTAssertFalse(json.contains("203.0.113.41"))
        XCTAssertFalse(json.contains("private-user"))
        XCTAssertFalse(json.contains("private-password"))
        XCTAssertFalse(json.contains("pauseState"))
        XCTAssertFalse(json.contains("hasCompletedOnboarding"))
        XCTAssertFalse(json.contains("notificationsEnabled"))

        let credentialedJSON = json.replacingOccurrences(
            of: "smb://server.local/Media",
            with: "smb://user:password@server.local/Media"
        )
        XCTAssertThrowsError(
            try ConfigurationTransferService.decode(Data(credentialedJSON.utf8))
        )
    }

    @MainActor
    func testConfigurationMergePreservesLocalRuntimeState() {
        let suiteName = "OtterTests.SettingsStoreTests.Import"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let store = SettingsStore(defaults: defaults, credentialStore: RecordingCredentialStore())
        let resumeAt = Date().addingTimeInterval(3_600)
        let existing = NetworkShare(
            displayName: "Old Name",
            urlString: "smb://server.local/Media",
            mountPath: "/Volumes/Media",
            pauseState: .paused(until: resumeAt),
            cachedIPAddress: "192.0.2.10",
            ipAddressChangeObservations: [
                IPAddressChangeObservation(
                    previousAddress: "192.0.2.9",
                    currentAddress: "192.0.2.10",
                    observedAt: Date()
                )
            ]
        )
        store.addShare(existing)
        let incoming = NetworkShare(
            displayName: "New Name",
            urlString: "smb://SERVER.local:445/Media/",
            mountPath: "/Volumes/Renamed Media",
            keepMounted: false
        )
        let archive = ConfigurationTransferService.archive(
            shares: [incoming],
            preferences: AppPreferences(fallbackCheckInterval: 120, recoverUnresponsiveMounts: true)
        )

        let result = store.importConfiguration(archive, strategy: .merge)
        let merged = store.shares[0]

        XCTAssertEqual(result, ConfigurationImportResult(added: 0, updated: 1, removed: 0))
        XCTAssertEqual(merged.id, existing.id)
        XCTAssertEqual(merged.displayName, "New Name")
        XCTAssertEqual(merged.cachedIPAddress, "192.0.2.10")
        XCTAssertEqual(merged.ipAddressChangeObservations, existing.ipAddressChangeObservations)
        XCTAssertEqual(merged.pauseState, .paused(until: resumeAt))
        XCTAssertFalse(merged.keepMounted)
        XCTAssertEqual(store.preferences.fallbackCheckInterval, 120)
        XCTAssertTrue(store.preferences.recoverUnresponsiveMounts)
    }

    @MainActor
    func testManagedConfigurationIsAuthoritativeButAllowsRuntimePause() throws {
        let suiteName = "OtterTests.SettingsStoreTests.Managed"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(
            try JSONEncoder().encode(
                AppPreferences(fallbackCheckInterval: 45, recoverUnresponsiveMounts: false)
            ),
            forKey: "preferences"
        )
        let managedShare = NetworkShare(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000123")!,
            displayName: "Managed Media",
            urlString: "smb://managed.example/Media",
            mountPath: "/Volumes/Media",
            keepMounted: true,
            rules: ShareRules(vpnRuleEnabled: true, vpnName: "Managed VPN")
        )
        let payload = ManagedConfigurationPayload(
            formatVersion: ManagedConfigurationPayload.currentFormatVersion,
            shares: [PortableShareConfiguration(share: managedShare)],
            monitoring: PortableMonitoringConfiguration(
                fallbackCheckInterval: 120,
                recoverUnresponsiveMounts: true
            )
        )
        let payloadData = try JSONEncoder().encode(payload)
        let payloadObject = try JSONSerialization.jsonObject(with: payloadData)
        defaults.set(payloadObject, forKey: ManagedConfigurationService.defaultsKey)

        let store = SettingsStore(defaults: defaults, credentialStore: RecordingCredentialStore())
        XCTAssertTrue(store.isManagedShare(id: managedShare.id))
        XCTAssertEqual(store.share(id: managedShare.id)?.displayName, "Managed Media")
        XCTAssertEqual(store.preferences.fallbackCheckInterval, 120)
        XCTAssertTrue(store.preferences.recoverUnresponsiveMounts)

        var editedShare = try XCTUnwrap(store.share(id: managedShare.id))
        editedShare.displayName = "User Override"
        editedShare.keepMounted = false
        store.updateShare(editedShare)
        store.updatePreferences {
            $0.fallbackCheckInterval = 15
            $0.recoverUnresponsiveMounts = false
        }
        store.pauseShare(id: managedShare.id, until: nil)
        store.removeShare(id: managedShare.id)

        let retainedShare = try XCTUnwrap(store.share(id: managedShare.id))
        XCTAssertEqual(retainedShare.displayName, "Managed Media")
        XCTAssertTrue(retainedShare.keepMounted)
        XCTAssertEqual(retainedShare.pauseState, .paused())
        XCTAssertEqual(store.preferences.fallbackCheckInterval, 120)
        XCTAssertTrue(store.preferences.recoverUnresponsiveMounts)

        defaults.removeObject(forKey: ManagedConfigurationService.defaultsKey)
        let storeAfterProfileRemoval = SettingsStore(
            defaults: defaults,
            credentialStore: RecordingCredentialStore()
        )
        XCTAssertNil(storeAfterProfileRemoval.share(id: managedShare.id))
        XCTAssertEqual(storeAfterProfileRemoval.preferences.fallbackCheckInterval, 45)
        XCTAssertFalse(storeAfterProfileRemoval.preferences.recoverUnresponsiveMounts)
    }
}

final class SupportPackageTests: XCTestCase {
    @MainActor
    func testSupportPackageOmitsIdentifyingAndSensitiveValues() throws {
        let appModel = AppModel(isRunningTests: true)
        let share = NetworkShare(
            displayName: "AcmeVault",
            urlString: "smb://needle-server.example/AcmeFiles",
            mountPath: "/Volumes/AcmeFiles",
            rules: ShareRules(
                wifiNetworkName: "Needle Wi-Fi",
                registeredSubnets: ["10.77.0.0/16"],
                vpnRuleEnabled: true,
                vpnName: "Needle VPN"
            ),
            cachedIPAddress: "203.0.113.77"
        )
        appModel.settings.addShare(share)
        appModel.eventLog.record(
            .mountFailed,
            for: share,
            detail: "NeedleEvent included a private server error"
        )

        let package = SupportPackageService.make(
            settings: appModel.settings,
            eventLog: appModel.eventLog,
            monitor: appModel.monitor,
            networkService: appModel.networkService,
            notificationService: appModel.notificationService,
            loginItemService: appModel.loginItemService
        )
        let data = try SupportPackageService.encode(package)
        let json = String(decoding: data, as: UTF8.self)

        XCTAssertEqual(package.shares.map(\.reference), ["Share 1"])
        XCTAssertEqual(package.events.map(\.shareReference), ["Share 1"])
        XCTAssertTrue(package.shares[0].usesNamedVPNRule)
        XCTAssertTrue(package.shares[0].usesRegisteredNetworkRule)
        XCTAssertFalse(json.contains("AcmeVault"))
        XCTAssertFalse(json.contains("AcmeFiles"))
        XCTAssertFalse(json.contains("needle-server"))
        XCTAssertFalse(json.contains("Needle Wi-Fi"))
        XCTAssertFalse(json.contains("Needle VPN"))
        XCTAssertFalse(json.contains("10.77.0.0/16"))
        XCTAssertFalse(json.contains("203.0.113.77"))
        XCTAssertFalse(json.contains("NeedleEvent"))
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
        XCTAssertEqual(enabledPreferences.appPresenceMode, .dockAndMenuBar)
    }

    func testLegacyPresenceModeNamesMigrateToDockAndMenuBar() throws {
        for legacyMode in ["dockWhilePreferencesOpen", "alwaysShowDockIcon"] {
            let json = """
            {"fallbackCheckInterval": 60, "appPresenceMode": "\(legacyMode)"}
            """

            let preferences = try JSONDecoder().decode(AppPreferences.self, from: Data(json.utf8))
            XCTAssertEqual(preferences.appPresenceMode, .dockAndMenuBar)
        }
    }

    func testPresenceModesControlDockAndMenuBarVisibility() {
        XCTAssertEqual(AppPresenceMode.allCases, [.dockAndMenuBar, .dockOnly, .menuBarOnly])

        XCTAssertTrue(AppPresenceMode.dockAndMenuBar.showsDockIcon)
        XCTAssertTrue(AppPresenceMode.dockAndMenuBar.showsMenuBarIcon)
        XCTAssertTrue(AppPresenceMode.dockOnly.showsDockIcon)
        XCTAssertFalse(AppPresenceMode.dockOnly.showsMenuBarIcon)
        XCTAssertFalse(AppPresenceMode.menuBarOnly.showsDockIcon)
        XCTAssertTrue(AppPresenceMode.menuBarOnly.showsMenuBarIcon)

        for mode in AppPresenceMode.allCases {
            XCTAssertTrue(mode.shouldShowDockIcon(duringOnboarding: true))
            XCTAssertTrue(mode.shouldShowMenuBarIcon(duringOnboarding: true))
        }
    }

    func testPauseStateExpiresAtItsResumeDate() {
        let now = Date(timeIntervalSince1970: 1_000)
        var pause = PauseState.paused(until: now.addingTimeInterval(60))

        XCTAssertTrue(pause.isActive(at: now))
        XCTAssertFalse(pause.isActive(at: now.addingTimeInterval(60)))

        pause.clearIfExpired(at: now.addingTimeInterval(60))
        XCTAssertEqual(pause, .inactive)
    }
}

private struct StubHostResolver: HostResolving {
    let result: String?

    func resolveIPAddresses(for hostname: String) async -> [String] {
        result.map { [$0] } ?? []
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
    private(set) var mountCallCount = 0
    private let mountedURLValue: URL?
    private let mountResult: URL?
    private let mountedURLReadsBeforeMissing: Int?
    private var mountedURLReadCount = 0

    init(
        mountedURL: URL? = nil,
        mountResult: URL? = nil,
        mountedURLReadsBeforeMissing: Int? = nil
    ) {
        self.mountedURLValue = mountedURL
        self.mountResult = mountResult
        self.mountedURLReadsBeforeMissing = mountedURLReadsBeforeMissing
    }

    func mountedURL(for share: NetworkShare) async -> URL? {
        defer { mountedURLReadCount += 1 }
        if let mountedURLReadsBeforeMissing,
           mountedURLReadCount >= mountedURLReadsBeforeMissing {
            return nil
        }
        return mountedURLValue
    }

    func mount(_ share: NetworkShare, urlOverride: URL?) async throws -> URL? {
        mountCallCount += 1
        return mountResult
    }

    func unmount(_ share: NetworkShare) async throws {}
}

private actor StubWakeOnLANService: WakeOnLANServicing {
    func sendWakePacket(using configuration: WakeOnLANConfiguration) async throws {}
}

private actor StubVPNConnectionService: VPNConnecting {
    private(set) var connectionNames: [String] = []
    private let error: SystemVPNConnectionError?

    init(error: SystemVPNConnectionError? = nil) {
        self.error = error
    }

    func connect(named serviceName: String, timeout: TimeInterval) async throws {
        connectionNames.append(serviceName)
        if let error {
            throw error
        }
    }
}

private actor StubMountHealthService: MountHealthChecking {
    private let result: MountHealthResult
    private let recoveryResult: Bool
    private(set) var recoveryCallCount = 0

    init(result: MountHealthResult = .healthy, recoveryResult: Bool = false) {
        self.result = result
        self.recoveryResult = recoveryResult
    }

    func checkMount(at url: URL, timeout: TimeInterval) async -> MountHealthResult {
        result
    }

    func unmountForRecovery(at url: URL, timeout: TimeInterval) async -> Bool {
        recoveryCallCount += 1
        return recoveryResult
    }
}

@MainActor
private final class StubNetworkReachability: NetworkReachabilityProviding {
    let isOnline: Bool
    let currentWiFiNetworkName: String?
    private(set) var isVPNConnected: Bool
    let currentIPv4Subnets: [String]
    private(set) var activeVPNNames: [String]
    private(set) var hasUnidentifiedTunnel: Bool
    var onPathChange: (() -> Void)?
    let isReachable: Bool
    private(set) var canReachCallCount = 0
    private let vpnNameToActivateOnRefresh: String?

    init(
        isOnline: Bool,
        isReachable: Bool,
        currentWiFiNetworkName: String? = nil,
        isVPNConnected: Bool = false,
        currentIPv4Subnets: [String] = [],
        activeVPNNames: [String] = [],
        hasUnidentifiedTunnel: Bool? = nil,
        vpnNameToActivateOnRefresh: String? = nil
    ) {
        self.isOnline = isOnline
        self.isReachable = isReachable
        self.currentWiFiNetworkName = currentWiFiNetworkName
        self.isVPNConnected = isVPNConnected
        self.currentIPv4Subnets = currentIPv4Subnets
        self.activeVPNNames = activeVPNNames
        self.hasUnidentifiedTunnel = hasUnidentifiedTunnel
            ?? (isVPNConnected && activeVPNNames.isEmpty)
        self.vpnNameToActivateOnRefresh = vpnNameToActivateOnRefresh
    }

    func canReachServer(for url: URL, timeout: TimeInterval) async -> Bool {
        canReachCallCount += 1
        return isReachable
    }

    func refreshNetworkDetailsIfStale(maxAge: TimeInterval) async {}

    func refreshNetworkDetailsNow() async {
        guard let vpnNameToActivateOnRefresh else { return }
        isVPNConnected = true
        activeVPNNames = [vpnNameToActivateOnRefresh]
        hasUnidentifiedTunnel = false
    }
}

@MainActor
private final class RecordingNotificationService: ShareNotificationProviding {
    private(set) var transitions: [(previous: ShareStatus, current: ShareStatus)] = []

    func notifyStatusChange(for share: NetworkShare, previous: ShareStatus, current: ShareStatus) {
        transitions.append((previous, current))
    }
}
