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
    func testSavedSMBShareBuildsAnEncodedConnectionURL() throws {
        let savedShare = try XCTUnwrap(
            SavedSMBShare(host: "  nas.local  ", path: "/Family Photos/", port: 445)
        )

        XCTAssertEqual(savedShare.displayName, "Family Photos")
        XCTAssertEqual(savedShare.detail, "nas.local/Family Photos")
        XCTAssertEqual(savedShare.connectionURL?.absoluteString, "smb://nas.local/Family%20Photos")
        XCTAssertTrue(savedShare.hasSharePath)
    }

    func testSavedSMBShareWithoutPathUsesServerRootForNativeSharePicker() throws {
        let savedShare = try XCTUnwrap(SavedSMBShare(host: "archive.local"))

        XCTAssertEqual(savedShare.displayName, "archive.local")
        XCTAssertEqual(savedShare.connectionURL?.absoluteString, "smb://archive.local/")
        XCTAssertFalse(savedShare.hasSharePath)
    }

    func testSavedSMBShareRejectsInvalidAddresses() {
        XCTAssertNil(SavedSMBShare(host: ""))
        XCTAssertNil(SavedSMBShare(host: "server.local/path"))
        XCTAssertNil(SavedSMBShare(host: "server.local", port: 70_000))
        // Port 0 is how Keychain records the default SMB port, so it is a
        // valid saved connection rather than an invalid address.
        XCTAssertNotNil(SavedSMBShare(host: "server.local", port: 0))
    }

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

    func testMountedSuggestionRecognizesTheSameShareAfterFinderRenamesItsMountPoint() {
        let original = MountedShareSuggestion(
            displayName: "Media",
            urlString: "smb://nas.local/Media",
            mountPath: "/Volumes/Media"
        )
        let remounted = MountedShareSuggestion(
            displayName: "Media-1",
            urlString: "smb://nas.local/Media/Movies",
            mountPath: "/Volumes/Media-1"
        )
        let differentShare = MountedShareSuggestion(
            displayName: "Backups",
            urlString: "smb://nas.local/Backups",
            mountPath: "/Volumes/Backups"
        )

        XCTAssertTrue(original.isSameShare(as: remounted))
        XCTAssertFalse(original.isSameShare(as: differentShare))
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

    func testRecognizesSupportedNetworkProtocols() {
        XCTAssertEqual(NetworkShareProtocol(urlScheme: "smb"), .smb)
        XCTAssertEqual(NetworkShareProtocol(urlScheme: "nfs"), .nfs)
        XCTAssertEqual(NetworkShareProtocol(urlScheme: "https"), .webdav)
        XCTAssertNil(NetworkShareProtocol(urlScheme: "ftp"))

        let nfsShare = NetworkShare(
            displayName: "Archive",
            urlString: "nfs://server.local/export/archive",
            mountPath: "/Volumes/Archive"
        )
        XCTAssertEqual(nfsShare.connectionProtocol, .nfs)
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
        XCTAssertEqual(groups[0].shareCountLabel, "2 shares")
        XCTAssertEqual(groups[1].shares, [archive])
        XCTAssertFalse(groups[1].isGrouped)
        XCTAssertEqual(groups[1].shareCountLabel, "1 share")
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
        XCTAssertEqual(share.connectionMode, .keepConnected)
        XCTAssertEqual(share.pauseState, .inactive)
        XCTAssertFalse(share.wakeOnLAN.isEnabled)
        XCTAssertEqual(share.wakeOnLAN.broadcastAddress, WakeOnLANConfiguration.defaultBroadcastAddress)
        XCTAssertEqual(share.wakeOnLAN.port, WakeOnLANConfiguration.defaultPort)
        XCTAssertFalse(share.rules.hasVPNRule)
        XCTAssertFalse(share.rules.hasWiFiNetworkRule)
        XCTAssertTrue(share.prefersIPv4)
        XCTAssertTrue(share.cachedIPAddresses.isEmpty)
        XCTAssertTrue(share.ipAddressChangeObservations.isEmpty)
    }

    func testLegacySingleAddressMigratesIntoDualStackCache() throws {
        let json = """
        {
            "id": "00000000-0000-0000-0000-000000000001",
            "displayName": "Dawn",
            "urlString": "smb://server.local/Dawn",
            "mountPath": "/Volumes/Dawn",
            "keepMounted": true,
            "mountAtLaunch": true,
            "cachedIPAddress": "192.168.1.20",
            "createdAt": 0,
            "updatedAt": 0
        }
        """

        let share = try JSONDecoder().decode(NetworkShare.self, from: Data(json.utf8))

        XCTAssertTrue(share.prefersIPv4)
        XCTAssertEqual(share.cachedIPAddresses, ["192.168.1.20"])
        XCTAssertEqual(share.cachedIPAddress, "192.168.1.20")
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

    func testDualStackCacheDefaultsToIPv4AndCanPreferIPv6() {
        var share = NetworkShare(
            displayName: "Media",
            urlString: "smb://server.local/Media",
            mountPath: "/Volumes/Media",
            cachedIPAddresses: ["fd00::20", "192.168.1.20"]
        )

        XCTAssertEqual(share.orderedCachedIPAddresses, ["192.168.1.20", "fd00::20"])
        XCTAssertEqual(share.cachedIPAddress, "192.168.1.20")

        share.prefersIPv4 = false
        XCTAssertEqual(share.orderedCachedIPAddresses, ["fd00::20", "192.168.1.20"])
        XCTAssertEqual(share.cachedIPAddress, "fd00::20")
    }

    func testScopedIPv6AddressIsRecognized() {
        XCTAssertTrue(NetworkShare.isIPv6Address("fe80::1%en0"))
        XCTAssertFalse(NetworkShare.isIPv4Address("fe80::1%en0"))
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
        XCTAssertTrue(rules.connectVPNAutomatically)
    }

    func testVPNRuleDecodesManualConnectionPreference() throws {
        let json = """
        {
            "vpnRuleEnabled": true,
            "vpnName": "Work VPN",
            "connectVPNAutomatically": false
        }
        """

        let rules = try JSONDecoder().decode(ShareRules.self, from: Data(json.utf8))

        XCTAssertTrue(rules.hasVPNRule)
        XCTAssertFalse(rules.connectVPNAutomatically)
        XCTAssertFalse(rules.shouldConnectVPNAutomatically)
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

    func testEditorDraftRetiresNetworkRestrictionsWhilePreservingVPNRules() {
        let networkOnlyShare = NetworkShare(
            displayName: "Media",
            urlString: "smb://server.local/Media",
            mountPath: "/Volumes/Media",
            connectionMode: .adaptive,
            rules: ShareRules(wifiNetworkName: "Home")
        )
        let networkDraft = DraftShare(share: networkOnlyShare)

        XCTAssertFalse(networkDraft.usesVPNRule)
        XCTAssertFalse(networkDraft.rules.hasNetworkRule)
        XCTAssertFalse(networkDraft.rules.hasVPNRule)

        let vpnOnlyShare = NetworkShare(
            displayName: "Media",
            urlString: "smb://server.local/Media",
            mountPath: "/Volumes/Media",
            connectionMode: .adaptive,
            rules: ShareRules(
                vpnRuleEnabled: true,
                vpnName: "Work VPN",
                connectVPNAutomatically: false
            )
        )
        let vpnDraft = DraftShare(share: vpnOnlyShare)

        XCTAssertTrue(vpnDraft.usesVPNRule)
        XCTAssertFalse(vpnDraft.connectVPNAutomatically)
        XCTAssertEqual(vpnDraft.rules.requiredVPNName, "Work VPN")
        XCTAssertFalse(vpnDraft.rules.shouldConnectVPNAutomatically)
    }

    func testEditorDraftRetiresLegacyUnnamedVPNRule() {
        let legacyShare = NetworkShare(
            displayName: "Media",
            urlString: "smb://server.local/Media",
            mountPath: "/Volumes/Media",
            connectionMode: .adaptive,
            rules: ShareRules(
                wifiNetworkName: "Home",
                vpnRuleEnabled: true,
                vpnName: ""
            )
        )

        let draft = DraftShare(share: legacyShare)

        XCTAssertFalse(draft.usesVPNRule)
        XCTAssertFalse(draft.rules.hasNetworkRule)
        XCTAssertFalse(draft.rules.hasVPNRule)
    }

    func testEditorDraftDefaultsToKeepConnectedAndHidesRemoteAccessForIt() {
        var draft = DraftShare(share: nil)

        XCTAssertEqual(draft.connectionMode, .keepConnected)
        XCTAssertFalse(draft.showsRemoteAccess)

        for mode in [ConnectionMode.adaptive, .manual, .connectOnce] {
            draft.connectionMode = mode
            XCTAssertTrue(draft.showsRemoteAccess, "\(mode) configures its route")
        }
    }

    func testEditorDraftKeepsVPNConfigurationWhileKeepConnectedHidesIt() {
        let share = NetworkShare(
            displayName: "Media",
            urlString: "smb://server.local/Media",
            mountPath: "/Volumes/Media",
            connectionMode: .adaptive,
            rules: ShareRules(vpnRuleEnabled: true, vpnName: "Work VPN")
        )
        var draft = DraftShare(share: share)

        draft.connectionMode = .keepConnected

        XCTAssertFalse(draft.showsRemoteAccess)
        XCTAssertTrue(draft.usesVPNRule)
        XCTAssertEqual(draft.rules.requiredVPNName, "Work VPN")
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

    func testWakeOnLANDiscoveryParsesMACAddressAndInterfaceFromARPOutput() {
        let output = "? (192.168.1.25) at aa:bb:cc:dd:ee:ff on en0 ifscope [ethernet]"

        let neighbour = WakeOnLANConfigurationDiscoveryService.parseARPNeighbour(output)

        XCTAssertEqual(neighbour?.macAddress, "AA:BB:CC:DD:EE:FF")
        XCTAssertEqual(neighbour?.interface, "en0")
    }

    func testWakeOnLANDiscoveryRejectsIncompleteARPEntry() {
        XCTAssertNil(WakeOnLANConfigurationDiscoveryService.parseARPNeighbour("? (192.168.1.25) at (incomplete) on en0"))
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

    func testUnexpectedDisconnectRecoveryStaysFastAndClampsAtThirtySeconds() {
        XCTAssertEqual(UnexpectedDisconnectRetryPolicy.delay(afterFailures: 0), 2)
        XCTAssertEqual(UnexpectedDisconnectRetryPolicy.delay(afterFailures: 1), 2)
        XCTAssertEqual(UnexpectedDisconnectRetryPolicy.delay(afterFailures: 2), 5)
        XCTAssertEqual(UnexpectedDisconnectRetryPolicy.delay(afterFailures: 3), 10)
        XCTAssertEqual(UnexpectedDisconnectRetryPolicy.delay(afterFailures: 4), 15)
        XCTAssertEqual(UnexpectedDisconnectRetryPolicy.delay(afterFailures: 5), 30)
        XCTAssertEqual(UnexpectedDisconnectRetryPolicy.delay(afterFailures: 100), 30)
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
        XCTAssertTrue(settings.share(id: share.id)?.connectionMode == .keepConnected)
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
            connectionMode: .keepConnected
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
        XCTAssertTrue(settings.share(id: share.id)?.connectionMode == .keepConnected)
    }

    @MainActor
    func testDisconnectingManualShareDoesNotCreateAutomaticMountingPause() async {
        let suiteName = "OtterTests.ShareMonitorRetryTests.ManualDisconnect"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let settings = SettingsStore(defaults: defaults, credentialStore: RecordingCredentialStore())
        let share = NetworkShare(
            displayName: "Media",
            urlString: "smb://server.local/Media",
            mountPath: "/Volumes/Media",
            connectionMode: .manual
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

        XCTAssertEqual(monitor.status(for: share), .disconnected)
        XCTAssertEqual(settings.share(id: share.id)?.pauseState, .inactive)
        XCTAssertFalse(settings.isGloballyPaused)
    }

    @MainActor
    func testDisconnectingAllManualSharesDoesNotPauseGlobally() async {
        let suiteName = "OtterTests.ShareMonitorRetryTests.AllManualDisconnect"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let settings = SettingsStore(defaults: defaults, credentialStore: RecordingCredentialStore())
        let share = NetworkShare(
            displayName: "Media",
            urlString: "smb://server.local/Media",
            mountPath: "/Volumes/Media",
            connectionMode: .manual
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

        await monitor.disconnectAll()

        XCTAssertEqual(monitor.status(for: share), .disconnected)
        XCTAssertEqual(settings.share(id: share.id)?.pauseState, .inactive)
        XCTAssertFalse(settings.isGloballyPaused)
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
    func testUnexpectedUnmountRetriesQuicklyPastNormalBudgetUntilNetworkChanges() async {
        let suiteName = "OtterTests.ShareMonitorRetryTests.UnexpectedUnmount"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let settings = SettingsStore(defaults: defaults, credentialStore: RecordingCredentialStore())
        let share = NetworkShare(
            displayName: "Media",
            urlString: "smb://192.0.2.10/Media",
            mountPath: "/Volumes/Media",
            connectionMode: .keepConnected
        )
        settings.addShare(share)
        let mountedURL = URL(fileURLWithPath: "/Volumes/Media", isDirectory: true)
        let mountService = StubMountService(
            mountedURL: mountedURL,
            mountedURLReadsBeforeMissing: 1
        )
        let network = StubNetworkReachability(isOnline: true, isReachable: false)
        var currentDate = Date()
        let monitor = ShareMonitor(
            settings: settings,
            mountService: mountService,
            mountHealthService: StubMountHealthService(result: .healthy),
            wakeOnLANService: StubWakeOnLANService(),
            networkService: network,
            notificationService: RecordingNotificationService(),
            eventLog: ShareEventLog(defaults: defaults),
            defaults: defaults,
            now: { currentDate }
        )

        await monitor.evaluate(share, reason: .timer)
        XCTAssertEqual(monitor.status(for: share), .connected)

        await monitor.evaluate(share, reason: .volumeChanged)
        var state = monitor.runtimeState(for: share)
        XCTAssertEqual(state.failureCount, 1)
        XCTAssertGreaterThanOrEqual(state.nextRetryDate ?? .distantPast, currentDate.addingTimeInterval(1.8))
        XCTAssertLessThanOrEqual(state.nextRetryDate ?? .distantFuture, currentDate.addingTimeInterval(2.2))

        for expectedFailureCount in 2...(RetryBackoff.maxAutomaticAttempts + 2) {
            currentDate = currentDate.addingTimeInterval(1_000)
            await monitor.evaluate(share, reason: .retry)
            state = monitor.runtimeState(for: share)
            XCTAssertEqual(state.failureCount, expectedFailureCount)
            XCTAssertNotNil(state.nextRetryDate)
        }

        currentDate = currentDate.addingTimeInterval(1_000)
        await monitor.evaluate(share, reason: .networkChanged)
        state = monitor.runtimeState(for: share)
        XCTAssertEqual(state.failureCount, 1)
        XCTAssertGreaterThanOrEqual(state.nextRetryDate ?? .distantPast, currentDate.addingTimeInterval(9))
        XCTAssertLessThanOrEqual(state.nextRetryDate ?? .distantFuture, currentDate.addingTimeInterval(11))
    }

    @MainActor
    func testVPNFallbackTriesIPv4ThenIPv6AndMountsWithReachableAddress() async {
        let suiteName = "OtterTests.ShareMonitorRetryTests.DualStackFallback"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let settings = SettingsStore(defaults: defaults, credentialStore: RecordingCredentialStore())
        let share = NetworkShare(
            displayName: "Media",
            urlString: "smb://server.local/Media",
            mountPath: "/Volumes/Media",
            cachedIPAddresses: ["fd00::20", "192.168.1.20"]
        )
        settings.addShare(share)
        let mountedURL = URL(fileURLWithPath: "/Volumes/Media", isDirectory: true)
        let mountService = StubMountService(mountResult: mountedURL)
        let network = StubNetworkReachability(
            isOnline: true,
            isReachable: false,
            isVPNConnected: true,
            reachableHosts: ["fd00::20"]
        )
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
        let overrides = await mountService.mountURLOverrides

        XCTAssertEqual(network.reachedHosts, ["server.local", "192.168.1.20", "fd00::20"])
        XCTAssertEqual(overrides.first.flatMap { $0 }?.host(percentEncoded: false), "fd00::20")
        XCTAssertEqual(monitor.status(for: share), .connected)
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
            connectionMode: .adaptive,
            rules: ShareRules(
                vpnRuleEnabled: true,
                vpnName: "Work VPN",
                connectVPNAutomatically: true
            )
        )
        settings.addShare(share)
        let network = StubNetworkReachability(
            isOnline: true,
            isReachable: false,
            isReachableAfterVPNConnection: true,
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
            connectionMode: .adaptive,
            rules: ShareRules(
                vpnRuleEnabled: true,
                vpnName: "Tunnel to Work",
                connectVPNAutomatically: false
            )
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
    func testManualVPNModeWaitsWithoutStartingVPN() async {
        let suiteName = "OtterTests.ShareMonitorRetryTests.ManualVPNMode"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let settings = SettingsStore(defaults: defaults, credentialStore: RecordingCredentialStore())
        let share = NetworkShare(
            displayName: "Media",
            urlString: "smb://server.local/Media",
            mountPath: "/Volumes/Media",
            connectionMode: .adaptive,
            rules: ShareRules(
                vpnRuleEnabled: true,
                vpnName: "Tunnel to Work",
                connectVPNAutomatically: false
            )
        )
        settings.addShare(share)
        let vpnConnectionService = StubVPNConnectionService()
        let mountService = StubMountService(
            mountResult: URL(fileURLWithPath: "/Volumes/Media", isDirectory: true)
        )
        let monitor = ShareMonitor(
            settings: settings,
            mountService: mountService,
            wakeOnLANService: StubWakeOnLANService(),
            vpnConnectionService: vpnConnectionService,
            networkService: StubNetworkReachability(isOnline: true, isReachable: false),
            notificationService: RecordingNotificationService(),
            eventLog: ShareEventLog(defaults: defaults),
            defaults: defaults
        )

        await monitor.evaluate(share, reason: .timer)

        let vpnConnectionNames = await vpnConnectionService.connectionNames
        let mountCallCount = await mountService.mountCallCount
        XCTAssertTrue(vpnConnectionNames.isEmpty)
        XCTAssertEqual(mountCallCount, 0)
        XCTAssertEqual(monitor.status(for: share), .waitingForVPN("Tunnel to Work"))
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
            connectionMode: .adaptive,
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
            connectionMode: .adaptive,
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
            connectionMode: .adaptive,
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
            connectionMode: .adaptive,
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
            connectionMode: .adaptive,
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
            networkService: StubNetworkReachability(isOnline: true, isReachable: false),
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
            connectionMode: .adaptive,
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
            networkService: StubNetworkReachability(isOnline: true, isReachable: false),
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
            connectionMode: .adaptive,
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
            connectionMode: .keepConnected
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
            connectionMode: .manual,
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
        XCTAssertFalse(settings.share(id: share.id)?.connectionMode == .keepConnected)
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
            store.recordResolvedIPAddresses(["fd00::20", "192.168.1.20", "192.168.1.21"], for: share.id),
            .initial
        )
        XCTAssertEqual(
            store.recordResolvedIPAddresses(["192.168.1.21", "fd00::20", "192.168.1.20"], for: share.id),
            .unchanged
        )
        XCTAssertEqual(store.share(id: share.id)?.cachedIPAddress, "192.168.1.20")
        XCTAssertEqual(
            store.share(id: share.id)?.orderedCachedIPAddresses,
            ["192.168.1.20", "192.168.1.21", "fd00::20"]
        )
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
            connectionMode: .keepConnected
        )
        store.addShare(share)

        store.pauseShare(id: share.id, until: nil)

        XCTAssertTrue(store.share(id: share.id)?.connectionMode == .keepConnected)
        XCTAssertEqual(store.share(id: share.id)?.pauseState, .paused())
    }

    @MainActor
    func testManualShareIgnoresAutomaticMountingPauses() {
        let suiteName = "OtterTests.SettingsStoreTests.ManualPause"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let store = SettingsStore(defaults: defaults, credentialStore: RecordingCredentialStore())
        let share = NetworkShare(
            displayName: "Media",
            urlString: "smb://server.local/Media",
            mountPath: "/Volumes/Media",
            connectionMode: .manual,
            pauseState: .paused()
        )
        store.addShare(share)
        store.pauseAll(until: nil)

        XCTAssertNil(store.effectivePauseState(for: share))
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
            prefersIPv4: false,
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
        XCTAssertFalse(decoded.shares[0].prefersIPv4)
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

    func testProtectedConfigurationBackupRoundTripsCredentials() throws {
        let share = NetworkShare(
            displayName: "Archive",
            urlString: "nfs://server.local/exports/archive",
            mountPath: "/Volumes/Archive",
            healthCheck: ShareHealthCheckConfiguration(
                requiresWritableVolume: true,
                sentinelRelativePath: ".otter-health"
            )
        )
        let archive = ConfigurationTransferService.archive(
            shares: [share], preferences: AppPreferences()
        )
        let credentials = [PortableCredential(host: "server.local", account: "otter", passwordData: Data("secret".utf8))]

        let data = try ConfigurationTransferService.encodeProtectedBackup(
            archive, credentials: credentials, password: "correct horse battery staple"
        )
        let restored = try ConfigurationTransferService.decodeProtectedBackup(
            data, password: "correct horse battery staple"
        )

        XCTAssertEqual(restored.archive.shares.first?.urlString, share.urlString)
        XCTAssertEqual(restored.archive.shares.first?.healthCheck, share.healthCheck)
        XCTAssertEqual(restored.credentials, credentials)
        XCTAssertThrowsError(try ConfigurationTransferService.decodeProtectedBackup(data, password: "wrong"))
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
            connectionMode: .manual
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
        XCTAssertEqual(merged.connectionMode, .manual)
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
            connectionMode: .keepConnected,
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
        editedShare.connectionMode = .manual
        store.updateShare(editedShare)
        store.updatePreferences {
            $0.fallbackCheckInterval = 15
            $0.recoverUnresponsiveMounts = false
        }
        store.pauseShare(id: managedShare.id, until: nil)
        store.removeShare(id: managedShare.id)

        let retainedShare = try XCTUnwrap(store.share(id: managedShare.id))
        XCTAssertEqual(retainedShare.displayName, "Managed Media")
        XCTAssertEqual(retainedShare.connectionMode, .keepConnected)
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
            connectionMode: .adaptive,
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
        XCTAssertTrue(package.shares[0].startsVPNAutomatically)
        XCTAssertTrue(package.shares[0].usesRegisteredNetworkRule)
        XCTAssertFalse(json.contains("AcmeVault"))
        XCTAssertFalse(json.contains("AcmeFiles"))
        XCTAssertFalse(json.contains("needle-server"))
        XCTAssertFalse(json.contains("Needle Wi-Fi"))
        XCTAssertFalse(json.contains("Needle VPN"))
        XCTAssertFalse(json.contains("10.77.0.0/16"))
        XCTAssertFalse(json.contains("203.0.113.77"))
        XCTAssertFalse(json.contains("NeedleEvent"))

        let exportData = try SupportDiagnosticsExporter.makeData(
            settings: appModel.settings,
            eventLog: appModel.eventLog,
            monitor: appModel.monitor,
            networkService: appModel.networkService,
            notificationService: appModel.notificationService,
            loginItemService: appModel.loginItemService
        )
        let exportedJSON = String(decoding: exportData, as: UTF8.self)
        XCTAssertFalse(exportedJSON.contains("needle-server"))
        XCTAssertFalse(exportedJSON.contains("NeedleEvent"))
    }

    @MainActor
    func testSupportExportFilenameUsesUTCAndTheSupportExtension() {
        let date = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(
            SupportDiagnosticsExporter.defaultFilename(for: date),
            "Otter-support-1970-01-01-000000.ottersupport"
        )
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

        XCTAssertTrue(AppPresenceMode.menuBarOnly.shouldShowDockIcon(
            duringOnboarding: false,
            duringShareEditing: true
        ))
        XCTAssertTrue(AppPresenceMode.menuBarOnly.shouldShowDockIcon(
            duringOnboarding: false,
            duringPreferencesOpen: true
        ))
        XCTAssertTrue(AppPresenceMode.menuBarOnly.shouldShowDockIcon(
            duringOnboarding: false,
            duringSharesWindowOpen: true
        ))
        XCTAssertFalse(AppPresenceMode.menuBarOnly.shouldShowDockIcon(duringOnboarding: false))
    }

    func testAutoUpdateInstallPreferencesRoundTripAndClamp() throws {
        var preferences = AppPreferences()
        XCTAssertEqual(preferences.autoUpdateInstallPolicy, .whenIdle)
        XCTAssertEqual(preferences.autoUpdateInstallHour, 3)

        preferences.autoUpdateInstallPolicy = .scheduled
        preferences.autoUpdateInstallHour = 22

        let data = try JSONEncoder().encode(preferences)
        let decoded = try JSONDecoder().decode(AppPreferences.self, from: data)
        XCTAssertEqual(decoded.autoUpdateInstallPolicy, .scheduled)
        XCTAssertEqual(decoded.autoUpdateInstallHour, 22)

        // Out-of-range hours are clamped rather than rejected.
        XCTAssertEqual(AppPreferences(autoUpdateInstallHour: 99).autoUpdateInstallHour, 23)
        XCTAssertEqual(AppPreferences(autoUpdateInstallHour: -4).autoUpdateInstallHour, 0)
    }

    func testAutoUpdateInstallPreferencesDefaultForOlderConfigurations() throws {
        let json = """
        { "fallbackCheckInterval": 60 }
        """

        let preferences = try JSONDecoder().decode(AppPreferences.self, from: Data(json.utf8))
        XCTAssertEqual(preferences.autoUpdateInstallPolicy, .whenIdle)
        XCTAssertEqual(preferences.autoUpdateInstallHour, 3)
        XCTAssertFalse(preferences.alwaysShowServerName)
    }

    func testAlwaysShowServerNamePreferenceRoundTrips() throws {
        var preferences = AppPreferences()
        XCTAssertFalse(preferences.alwaysShowServerName)

        preferences.alwaysShowServerName = true
        let data = try JSONEncoder().encode(preferences)
        let decoded = try JSONDecoder().decode(AppPreferences.self, from: data)

        XCTAssertTrue(decoded.alwaysShowServerName)
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
    let results: [String]

    init(result: String?) {
        results = result.map { [$0] } ?? []
    }

    init(results: [String]) {
        self.results = results
    }

    func resolveIPAddresses(for hostname: String) async -> [String] {
        results
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
    private(set) var mountURLOverrides: [URL?] = []
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
        mountURLOverrides.append(urlOverride)
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
    private(set) var reachedHosts: [String] = []
    private let reachableHosts: Set<String>?
    private let isReachableAfterVPNConnection: Bool?
    private let vpnNameToActivateOnRefresh: String?

    init(
        isOnline: Bool,
        isReachable: Bool,
        currentWiFiNetworkName: String? = nil,
        isVPNConnected: Bool = false,
        currentIPv4Subnets: [String] = [],
        activeVPNNames: [String] = [],
        hasUnidentifiedTunnel: Bool? = nil,
        isReachableAfterVPNConnection: Bool? = nil,
        vpnNameToActivateOnRefresh: String? = nil,
        reachableHosts: Set<String>? = nil
    ) {
        self.isOnline = isOnline
        self.isReachable = isReachable
        self.currentWiFiNetworkName = currentWiFiNetworkName
        self.isVPNConnected = isVPNConnected
        self.currentIPv4Subnets = currentIPv4Subnets
        self.activeVPNNames = activeVPNNames
        self.hasUnidentifiedTunnel = hasUnidentifiedTunnel
            ?? (isVPNConnected && activeVPNNames.isEmpty)
        self.isReachableAfterVPNConnection = isReachableAfterVPNConnection
        self.vpnNameToActivateOnRefresh = vpnNameToActivateOnRefresh
        self.reachableHosts = reachableHosts
    }

    func canReachServer(for url: URL, timeout: TimeInterval) async -> Bool {
        canReachCallCount += 1
        let host = url.host(percentEncoded: false) ?? ""
        reachedHosts.append(host)
        if isVPNConnected, let isReachableAfterVPNConnection {
            return isReachableAfterVPNConnection
        }
        return reachableHosts?.contains(host) ?? isReachable
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
    private(set) var requestedAttemptFlags: [Bool] = []

    func notifyStatusChange(
        for share: NetworkShare,
        previous: ShareStatus,
        current: ShareStatus,
        isRequestedAttempt: Bool
    ) {
        transitions.append((previous, current))
        requestedAttemptFlags.append(isRequestedAttempt)
    }
}

final class NewShareDetectionTests: XCTestCase {
    @MainActor
    private func makeSettings(_ name: String) -> (SettingsStore, UserDefaults) {
        let suiteName = "OtterTests.NewShareDetection.\(name)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let settings = SettingsStore(defaults: defaults, credentialStore: RecordingCredentialStore())
        settings.completeOnboarding()
        return (settings, defaults)
    }

    private func suggestion(
        _ name: String = "Media",
        urlString: String = "smb://homenas.local/Media",
        mountPath: String = "/Volumes/Media"
    ) -> MountedShareSuggestion {
        MountedShareSuggestion(displayName: name, urlString: urlString, mountPath: mountPath)
    }

    @MainActor
    func testVolumesMountedBeforeOtterStartedAreNotOffered() async {
        let (settings, defaults) = makeSettings("Baseline")
        let notifier = RecordingDetectedShareNotifier()
        let source = SuggestionSource([suggestion()])
        let detector = NewShareDetectionService(
            settings: settings,
            notificationService: notifier,
            defaults: defaults,
            workspaceNotificationCenter: NotificationCenter(),
            discoverShares: { await source.current() }
        )

        await detector.scan(announcing: false)
        await detector.scan(announcing: true)

        XCTAssertTrue(detector.pendingSuggestions.isEmpty)
        XCTAssertTrue(notifier.notified.isEmpty)
    }

    @MainActor
    func testShareMountedWhileRunningIsOfferedOnce() async {
        let (settings, defaults) = makeSettings("Offer")
        let notifier = RecordingDetectedShareNotifier()
        let source = SuggestionSource([])
        let detector = NewShareDetectionService(
            settings: settings,
            notificationService: notifier,
            defaults: defaults,
            workspaceNotificationCenter: NotificationCenter(),
            discoverShares: { await source.current() }
        )

        await detector.scan(announcing: false)
        await source.set([suggestion()])
        await detector.scan(announcing: true)
        await detector.scan(announcing: true)

        XCTAssertEqual(detector.pendingSuggestions.map(\.displayName), ["Media"])
        XCTAssertEqual(notifier.notified.count, 1)
    }

    @MainActor
    func testConfiguredShareIsNotOffered() async {
        let (settings, defaults) = makeSettings("Configured")
        settings.addShare(NetworkShare(
            displayName: "Media",
            // The same share reached through a Bonjour identity and a deeper path.
            urlString: "smb://HomeNAS.local/media/Movies",
            mountPath: "/Volumes/Media"
        ))
        let notifier = RecordingDetectedShareNotifier()
        let source = SuggestionSource([])
        let detector = NewShareDetectionService(
            settings: settings,
            notificationService: notifier,
            defaults: defaults,
            workspaceNotificationCenter: NotificationCenter(),
            discoverShares: { await source.current() }
        )

        await detector.scan(announcing: false)
        await source.set([suggestion()])
        await detector.scan(announcing: true)

        XCTAssertTrue(detector.pendingSuggestions.isEmpty)
        XCTAssertTrue(notifier.notified.isEmpty)
    }

    @MainActor
    func testIgnoredShareIsNotOfferedAgainAfterRemounting() async {
        let (settings, defaults) = makeSettings("Ignored")
        let notifier = RecordingDetectedShareNotifier()
        let source = SuggestionSource([])
        let detector = NewShareDetectionService(
            settings: settings,
            notificationService: notifier,
            defaults: defaults,
            workspaceNotificationCenter: NotificationCenter(),
            discoverShares: { await source.current() }
        )

        await detector.scan(announcing: false)
        await source.set([suggestion()])
        await detector.scan(announcing: true)
        detector.ignore(suggestion())

        // Unmount, then mount the same share again.
        await source.set([])
        await detector.scan(announcing: false)
        await source.set([suggestion(mountPath: "/Volumes/Media-1")])
        await detector.scan(announcing: true)

        XCTAssertTrue(detector.pendingSuggestions.isEmpty)
        XCTAssertEqual(notifier.notified.count, 1)
        XCTAssertEqual(notifier.withdrawn.count, 1)
        XCTAssertEqual(detector.ignoredShareCount, 1)

        detector.resetIgnoredShares()
        XCTAssertEqual(detector.ignoredShareCount, 0)
    }

    @MainActor
    func testDismissedShareIsOfferedAgainAfterRemounting() async {
        let (settings, defaults) = makeSettings("Dismissed")
        let notifier = RecordingDetectedShareNotifier()
        let source = SuggestionSource([])
        let detector = NewShareDetectionService(
            settings: settings,
            notificationService: notifier,
            defaults: defaults,
            workspaceNotificationCenter: NotificationCenter(),
            discoverShares: { await source.current() }
        )

        await detector.scan(announcing: false)
        await source.set([suggestion()])
        await detector.scan(announcing: true)
        detector.dismiss(suggestion())

        await source.set([])
        await detector.scan(announcing: false)
        await source.set([suggestion()])
        await detector.scan(announcing: true)

        XCTAssertEqual(detector.pendingSuggestions.count, 1)
        XCTAssertEqual(notifier.notified.count, 2)
    }

    @MainActor
    func testDisabledDetectionStaysQuietWithoutBuildingABacklog() async {
        let (settings, defaults) = makeSettings("Disabled")
        settings.updatePreferences { $0.detectNewShares = false }
        let notifier = RecordingDetectedShareNotifier()
        let source = SuggestionSource([])
        let detector = NewShareDetectionService(
            settings: settings,
            notificationService: notifier,
            defaults: defaults,
            workspaceNotificationCenter: NotificationCenter(),
            discoverShares: { await source.current() }
        )

        await detector.scan(announcing: false)
        await source.set([suggestion()])
        await detector.scan(announcing: true)

        XCTAssertTrue(detector.pendingSuggestions.isEmpty)
        XCTAssertTrue(notifier.notified.isEmpty)

        // Re-enabling doesn't announce shares that were mounted while off.
        settings.updatePreferences { $0.detectNewShares = true }
        await detector.scan(announcing: true)

        XCTAssertTrue(detector.pendingSuggestions.isEmpty)
        XCTAssertTrue(notifier.notified.isEmpty)
    }

    @MainActor
    func testDetectionWaitsUntilOnboardingIsComplete() async {
        let suiteName = "OtterTests.NewShareDetection.Onboarding"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let settings = SettingsStore(defaults: defaults, credentialStore: RecordingCredentialStore())
        let notifier = RecordingDetectedShareNotifier()
        let source = SuggestionSource([])
        let detector = NewShareDetectionService(
            settings: settings,
            notificationService: notifier,
            defaults: defaults,
            workspaceNotificationCenter: NotificationCenter(),
            discoverShares: { await source.current() }
        )

        await detector.scan(announcing: false)
        await source.set([suggestion()])
        await detector.scan(announcing: true)

        XCTAssertTrue(notifier.notified.isEmpty)
    }

    @MainActor
    func testManagingAnOfferAddsTheShareAndClearsTheOffer() async {
        let (settings, defaults) = makeSettings("Manage")
        let notifier = RecordingDetectedShareNotifier()
        let source = SuggestionSource([])
        let detector = NewShareDetectionService(
            settings: settings,
            notificationService: notifier,
            defaults: defaults,
            workspaceNotificationCenter: NotificationCenter(),
            discoverShares: { await source.current() }
        )

        await detector.scan(announcing: false)
        await source.set([suggestion()])
        await detector.scan(announcing: true)

        let added = detector.manage(suggestion())

        XCTAssertNotNil(added)
        XCTAssertEqual(settings.shares.map(\.urlString), ["smb://homenas.local/Media"])
        XCTAssertTrue(settings.shares.first?.connectionMode == .keepConnected)
        XCTAssertTrue(detector.pendingSuggestions.isEmpty)
        XCTAssertEqual(notifier.withdrawn.count, 1)
    }

    @MainActor
    func testSuppressedScanRecordsMountsWithoutOffering() async {
        let (settings, defaults) = makeSettings("Suppressed")
        let notifier = RecordingDetectedShareNotifier()
        let source = SuggestionSource([])
        let detector = NewShareDetectionService(
            settings: settings,
            notificationService: notifier,
            defaults: defaults,
            workspaceNotificationCenter: NotificationCenter(),
            discoverShares: { await source.current() }
        )

        await detector.scan(announcing: false)
        detector.isSuppressed = true
        await source.set([suggestion()])
        await detector.scan(announcing: true)

        XCTAssertTrue(notifier.notified.isEmpty)

        detector.isSuppressed = false
        await detector.scan(announcing: true)

        XCTAssertTrue(notifier.notified.isEmpty)
    }

    // Volume events arrive in bursts and are coalesced into one scan. An
    // unmount landing on top of a mount must not swallow the offer.
    @MainActor
    func testMountFollowedByAnUnmountStillOffersTheNewShare() async throws {
        let (settings, defaults) = makeSettings("Coalesced")
        let notifier = RecordingDetectedShareNotifier()
        let source = SuggestionSource([])
        let workspaceCenter = NotificationCenter()
        let detector = NewShareDetectionService(
            settings: settings,
            notificationService: notifier,
            defaults: defaults,
            workspaceNotificationCenter: workspaceCenter,
            scanDelay: 0.05,
            discoverShares: { await source.current() }
        )

        detector.start()
        await detector.scan(announcing: false)

        // The scan start() schedules must have run before the share appears,
        // otherwise it records the share as one that was mounted all along.
        try await poll { await source.readCount >= 2 }

        await source.set([suggestion()])
        workspaceCenter.post(name: NSWorkspace.didMountNotification, object: nil)
        workspaceCenter.post(name: NSWorkspace.didUnmountNotification, object: nil)
        try await poll { !notifier.notified.isEmpty }

        XCTAssertEqual(detector.pendingSuggestions.map(\.displayName), ["Media"])
        XCTAssertEqual(notifier.notified.count, 1)
    }

    // Waits for a debounced scan to land without pinning the test to a fixed
    // deadline. Returns early as soon as the condition holds.
    private func poll(
        timeout: TimeInterval = 5,
        until isSatisfied: () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await isSatisfied() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    func testPreferencesDefaultDetectionOnForExistingInstallations() throws {
        let legacyPreferences = Data(#"{"fallbackCheckInterval":60}"#.utf8)
        let decoded = try JSONDecoder().decode(AppPreferences.self, from: legacyPreferences)

        XCTAssertTrue(decoded.detectNewShares)

        let roundTripped = try JSONDecoder().decode(
            AppPreferences.self,
            from: try JSONEncoder().encode(AppPreferences(detectNewShares: false))
        )
        XCTAssertFalse(roundTripped.detectNewShares)
    }
}

private actor SuggestionSource {
    private var suggestions: [MountedShareSuggestion]
    private(set) var readCount = 0

    init(_ suggestions: [MountedShareSuggestion]) {
        self.suggestions = suggestions
    }

    func set(_ suggestions: [MountedShareSuggestion]) {
        self.suggestions = suggestions
    }

    func current() -> [MountedShareSuggestion] {
        readCount += 1
        return suggestions
    }
}

@MainActor
private final class RecordingDetectedShareNotifier: DetectedShareNotifying {
    private(set) var notified: [MountedShareSuggestion] = []
    private(set) var withdrawn: [MountedShareSuggestion] = []

    func notifyDetectedShare(_ suggestion: MountedShareSuggestion) {
        notified.append(suggestion)
    }

    func withdrawDetectedShareNotification(for suggestion: MountedShareSuggestion) {
        withdrawn.append(suggestion)
    }
}

final class ConnectionModePersistenceTests: XCTestCase {
    private func legacyShareJSON(
        keepMounted: Bool,
        mountAtLaunch: Bool,
        autoConnectWhenReachable: Bool,
        rules: String = ""
    ) -> Data {
        let json = """
        {
            "id": "00000000-0000-0000-0000-000000000001",
            "displayName": "Dawn",
            "urlString": "smb://server.local/Dawn",
            "mountPath": "/Volumes/Dawn",
            "keepMounted": \(keepMounted),
            "mountAtLaunch": \(mountAtLaunch),
            "autoConnectWhenReachable": \(autoConnectWhenReachable),
            \(rules)
            "createdAt": 0,
            "updatedAt": 0
        }
        """
        return Data(json.utf8)
    }

    func testEveryModeSurvivesASaveAndReload() throws {
        for mode in ConnectionMode.allCases {
            let share = NetworkShare(
                displayName: "Media",
                urlString: "smb://server.local/Media",
                mountPath: "/Volumes/Media",
                connectionMode: mode,
                rules: ShareRules(vpnRuleEnabled: true, vpnName: "Work VPN")
            )

            let reloaded = try JSONDecoder().decode(
                NetworkShare.self,
                from: try JSONEncoder().encode(share)
            )

            XCTAssertEqual(reloaded.connectionMode, mode)
            // The VPN selection is configuration, not a mode detail: it comes
            // back untouched even for the mode that hides it.
            XCTAssertEqual(reloaded.rules.requiredVPNName, "Work VPN")
        }
    }

    func testExistingKeepConnectedSharesStayKeepConnected() throws {
        let share = try JSONDecoder().decode(
            NetworkShare.self,
            from: legacyShareJSON(keepMounted: true, mountAtLaunch: true, autoConnectWhenReachable: false)
        )

        XCTAssertEqual(share.connectionMode, .keepConnected)
    }

    func testExistingKeepConnectedShareThatDependedOnAVPNBecomesAdaptive() throws {
        let share = try JSONDecoder().decode(
            NetworkShare.self,
            from: legacyShareJSON(
                keepMounted: true,
                mountAtLaunch: true,
                autoConnectWhenReachable: false,
                rules: """
                "rules": { "vpnRuleEnabled": true, "vpnName": "Work VPN" },
                """
            )
        )

        // Keep Connected is not location aware, so a share that was reaching
        // its server over a VPN keeps that route by becoming Adaptive.
        XCTAssertEqual(share.connectionMode, .adaptive)
        XCTAssertEqual(share.rules.requiredVPNName, "Work VPN")
    }

    func testExistingConnectWhenAvailableSharesBecomeAdaptive() throws {
        let share = try JSONDecoder().decode(
            NetworkShare.self,
            from: legacyShareJSON(keepMounted: false, mountAtLaunch: false, autoConnectWhenReachable: true)
        )

        XCTAssertEqual(share.connectionMode, .adaptive)
    }

    func testExistingManualSharesStayManual() throws {
        let share = try JSONDecoder().decode(
            NetworkShare.self,
            from: legacyShareJSON(keepMounted: false, mountAtLaunch: false, autoConnectWhenReachable: false)
        )

        XCTAssertEqual(share.connectionMode, .manual)
    }

    func testExistingManualShareThatMountedAtLaunchBecomesConnectOnce() throws {
        let share = try JSONDecoder().decode(
            NetworkShare.self,
            from: legacyShareJSON(keepMounted: false, mountAtLaunch: true, autoConnectWhenReachable: false)
        )

        XCTAssertEqual(share.connectionMode, .connectOnce)
    }

    func testSavedSharesStillCarryTheLegacySwitchesForOlderBuilds() throws {
        let share = NetworkShare(
            displayName: "Media",
            urlString: "smb://server.local/Media",
            mountPath: "/Volumes/Media",
            connectionMode: .connectOnce
        )

        let encoded = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(share)
        ) as? [String: Any]

        XCTAssertEqual(encoded?["connectionMode"] as? String, "connectOnce")
        XCTAssertEqual(encoded?["keepMounted"] as? Bool, false)
        XCTAssertEqual(encoded?["mountAtLaunch"] as? Bool, true)
        XCTAssertEqual(encoded?["autoConnectWhenReachable"] as? Bool, false)
    }

    func testTransferredConfigurationsMigrateAndRoundTripTheMode() throws {
        let legacyPayload = """
        {
            "id": "00000000-0000-0000-0000-000000000009",
            "displayName": "Media",
            "urlString": "smb://server.local/Media",
            "mountPath": "/Volumes/Media",
            "keepMounted": false,
            "mountAtLaunch": false,
            "autoConnectWhenReachable": true,
            "wakeOnLAN": { "isEnabled": false, "macAddress": "", "broadcastAddress": "255.255.255.255", "port": 9 },
            "rules": { "vpnRuleEnabled": true, "vpnName": "Work VPN" },
            "healthCheck": { "isEnabled": true, "requiresWritableVolume": false, "sentinelRelativePath": "" }
        }
        """
        let migrated = try JSONDecoder().decode(
            PortableShareConfiguration.self,
            from: Data(legacyPayload.utf8)
        )

        XCTAssertEqual(migrated.connectionMode, .adaptive)
        XCTAssertEqual(migrated.makeNetworkShare().connectionMode, .adaptive)

        let reencoded = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(migrated)
        ) as? [String: Any]
        XCTAssertEqual(reencoded?["connectionMode"] as? String, "adaptive")
        XCTAssertEqual(reencoded?["keepMounted"] as? Bool, true)
    }
}

final class ConnectionModeBehaviorTests: XCTestCase {
    @MainActor
    private func makeMonitor(
        _ name: String,
        share: NetworkShare,
        network: StubNetworkReachability,
        mountService: StubMountService,
        vpnConnectionService: StubVPNConnectionService = StubVPNConnectionService()
    ) -> (ShareMonitor, SettingsStore, RecordingNotificationService) {
        let notifier = RecordingNotificationService()
        let suiteName = "OtterTests.ConnectionMode.\(name)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let settings = SettingsStore(defaults: defaults, credentialStore: RecordingCredentialStore())
        settings.addShare(share)
        let monitor = ShareMonitor(
            settings: settings,
            mountService: mountService,
            wakeOnLANService: StubWakeOnLANService(),
            vpnConnectionService: vpnConnectionService,
            networkService: network,
            notificationService: notifier,
            eventLog: ShareEventLog(defaults: defaults),
            defaults: defaults
        )
        return (monitor, settings, notifier)
    }

    private func share(
        _ mode: ConnectionMode,
        rules: ShareRules = ShareRules()
    ) -> NetworkShare {
        NetworkShare(
            displayName: "Media",
            urlString: "smb://server.local/Media",
            mountPath: "/Volumes/Media",
            connectionMode: mode,
            rules: rules
        )
    }

    // MARK: - Keep Connected

    @MainActor
    func testKeepConnectedMountsWithoutConsultingASavedVPN() async {
        let vpnShare = share(
            .keepConnected,
            rules: ShareRules(vpnRuleEnabled: true, vpnName: "Work VPN", connectVPNAutomatically: true)
        )
        let mountService = StubMountService(mountResult: URL(fileURLWithPath: "/Volumes/Media", isDirectory: true))
        let vpnConnectionService = StubVPNConnectionService()
        let (monitor, settings, _) = makeMonitor(
            "KeepConnectedIgnoresVPN",
            share: vpnShare,
            network: StubNetworkReachability(isOnline: true, isReachable: true),
            mountService: mountService,
            vpnConnectionService: vpnConnectionService
        )

        await monitor.evaluate(vpnShare, reason: .timer)

        let vpnConnectionNames = await vpnConnectionService.connectionNames
        XCTAssertEqual(monitor.status(for: vpnShare), .connected)
        XCTAssertTrue(vpnConnectionNames.isEmpty)
        // Hidden, not deleted: switching back to Adaptive must find the VPN.
        XCTAssertEqual(settings.share(id: vpnShare.id)?.rules.requiredVPNName, "Work VPN")
    }

    @MainActor
    func testKeepConnectedKeepsRetryingWhenTheServerGoesAway() async {
        let keepConnected = share(.keepConnected)
        let (monitor, _, _) = makeMonitor(
            "KeepConnectedRetries",
            share: keepConnected,
            network: StubNetworkReachability(isOnline: true, isReachable: false),
            mountService: StubMountService()
        )

        await monitor.evaluate(keepConnected, reason: .timer)
        let state = monitor.runtimeState(for: keepConnected)

        XCTAssertEqual(state.status, .waitingForNetwork)
        XCTAssertEqual(state.failureCount, 1)
        XCTAssertNotNil(state.nextRetryDate)
    }

    // MARK: - Adaptive

    @MainActor
    func testAdaptiveBringsUpTheVPNBeforeMountingAwayFromTheLocalNetwork() async {
        let adaptive = share(
            .adaptive,
            rules: ShareRules(vpnRuleEnabled: true, vpnName: "Work VPN", connectVPNAutomatically: true)
        )
        let mountService = StubMountService(mountResult: URL(fileURLWithPath: "/Volumes/Media", isDirectory: true))
        let vpnConnectionService = StubVPNConnectionService()
        let (monitor, _, _) = makeMonitor(
            "AdaptiveConnectsVPN",
            share: adaptive,
            network: StubNetworkReachability(
                isOnline: true,
                isReachable: false,
                isReachableAfterVPNConnection: true,
                vpnNameToActivateOnRefresh: "Work VPN"
            ),
            mountService: mountService,
            vpnConnectionService: vpnConnectionService
        )

        await monitor.evaluate(adaptive, reason: .timer)

        let vpnConnectionNames = await vpnConnectionService.connectionNames
        let mountCallCount = await mountService.mountCallCount
        XCTAssertEqual(vpnConnectionNames, ["Work VPN"])
        XCTAssertEqual(mountCallCount, 1)
        XCTAssertEqual(monitor.status(for: adaptive), .connected)
    }

    @MainActor
    func testAdaptiveKeepsTryingWhenItCannotEstablishTheConnection() async {
        let adaptive = share(.adaptive)
        let (monitor, _, _) = makeMonitor(
            "AdaptiveRetries",
            share: adaptive,
            network: StubNetworkReachability(isOnline: true, isReachable: false),
            mountService: StubMountService()
        )

        await monitor.evaluate(adaptive, reason: .timer)
        let state = monitor.runtimeState(for: adaptive)

        XCTAssertEqual(state.status, .waitingForNetwork)
        XCTAssertNotNil(state.nextRetryDate)
    }

    // MARK: - Manual

    @MainActor
    func testManualStaysQuietAndDoesNotStartAVPNInTheBackground() async {
        let manual = share(
            .manual,
            rules: ShareRules(vpnRuleEnabled: true, vpnName: "Work VPN", connectVPNAutomatically: true)
        )
        let mountService = StubMountService()
        let vpnConnectionService = StubVPNConnectionService()
        let (monitor, _, notifier) = makeMonitor(
            "ManualQuiet",
            share: manual,
            network: StubNetworkReachability(isOnline: true, isReachable: true),
            mountService: mountService,
            vpnConnectionService: vpnConnectionService
        )

        for reason in [MonitorReason.launch, .timer, .networkChanged, .volumeChanged] {
            await monitor.evaluate(manual, reason: reason)
        }

        let vpnConnectionNames = await vpnConnectionService.connectionNames
        let mountCallCount = await mountService.mountCallCount
        let state = monitor.runtimeState(for: manual)

        XCTAssertEqual(mountCallCount, 0)
        XCTAssertTrue(vpnConnectionNames.isEmpty)
        // Not "waiting for VPN": nothing is expected of this share right now.
        XCTAssertEqual(state.status, .disconnected)
        XCTAssertNil(state.nextRetryDate)
        XCTAssertFalse(notifier.transitions.contains { $0.current.needsAttention })
    }

    @MainActor
    func testManualConnectsOnRequestAndReportsThatAttemptsFailure() async {
        let manual = share(.manual)
        let (monitor, settings, notifier) = makeMonitor(
            "ManualRequested",
            share: manual,
            network: StubNetworkReachability(isOnline: true, isReachable: false),
            mountService: StubMountService()
        )

        await monitor.mount(manual)
        let state = monitor.runtimeState(for: manual)

        guard case .failed = state.status else {
            return XCTFail("A requested connection should report its failure, got \(state.status)")
        }
        // Reported once, not turned into a background retry loop.
        XCTAssertNil(state.nextRetryDate)
        XCTAssertEqual(state.failureCount, 0)
        XCTAssertTrue(notifier.requestedAttemptFlags.allSatisfy { $0 })
        // Connecting on demand is not a reconfiguration.
        XCTAssertEqual(settings.share(id: manual.id)?.connectionMode, .manual)
    }

    @MainActor
    func testManualStartsTheVPNWhenTheUserAsksToConnect() async {
        let manual = share(
            .manual,
            rules: ShareRules(vpnRuleEnabled: true, vpnName: "Work VPN", connectVPNAutomatically: true)
        )
        let mountService = StubMountService(mountResult: URL(fileURLWithPath: "/Volumes/Media", isDirectory: true))
        let vpnConnectionService = StubVPNConnectionService()
        let (monitor, _, _) = makeMonitor(
            "ManualStartsVPN",
            share: manual,
            network: StubNetworkReachability(
                isOnline: true,
                isReachable: false,
                isReachableAfterVPNConnection: true,
                vpnNameToActivateOnRefresh: "Work VPN"
            ),
            mountService: mountService,
            vpnConnectionService: vpnConnectionService
        )

        await monitor.mount(manual)

        let vpnConnectionNames = await vpnConnectionService.connectionNames
        XCTAssertEqual(vpnConnectionNames, ["Work VPN"])
        XCTAssertEqual(monitor.status(for: manual), .connected)
    }

    @MainActor
    func testManualUsesTheLocalServerWithoutStartingTheConfiguredVPN() async {
        let manual = share(
            .manual,
            rules: ShareRules(vpnRuleEnabled: true, vpnName: "Work VPN", connectVPNAutomatically: true)
        )
        let mountService = StubMountService(mountResult: URL(fileURLWithPath: "/Volumes/Media", isDirectory: true))
        let vpnConnectionService = StubVPNConnectionService()
        let network = StubNetworkReachability(isOnline: true, isReachable: true)
        let (monitor, _, _) = makeMonitor(
            "ManualPrefersLocalNetwork",
            share: manual,
            network: network,
            mountService: mountService,
            vpnConnectionService: vpnConnectionService
        )

        await monitor.mount(manual)

        let vpnConnectionNames = await vpnConnectionService.connectionNames
        let mountCallCount = await mountService.mountCallCount
        XCTAssertTrue(vpnConnectionNames.isEmpty)
        XCTAssertEqual(network.canReachCallCount, 1)
        XCTAssertEqual(mountCallCount, 1)
        XCTAssertEqual(monitor.status(for: manual), .connected)
    }

    // MARK: - Connect Once

    @MainActor
    func testConnectOnceMountsAtLaunchThenStopsMaintainingTheShare() async {
        let connectOnce = share(.connectOnce)
        let mountService = StubMountService(mountResult: URL(fileURLWithPath: "/Volumes/Media", isDirectory: true))
        let (monitor, _, notifier) = makeMonitor(
            "ConnectOnceLaunch",
            share: connectOnce,
            network: StubNetworkReachability(isOnline: true, isReachable: true),
            mountService: mountService
        )

        await monitor.evaluate(connectOnce, reason: .launch)
        XCTAssertEqual(monitor.status(for: connectOnce), .connected)

        // The volume disappears; the stub keeps reporting nothing mounted.
        await monitor.evaluate(connectOnce, reason: .volumeChanged)
        await monitor.evaluate(connectOnce, reason: .timer)

        let mountCallCount = await mountService.mountCallCount
        let state = monitor.runtimeState(for: connectOnce)

        XCTAssertEqual(mountCallCount, 1, "Connect Once must not become Keep Connected")
        XCTAssertEqual(state.status, .disconnected)
        XCTAssertNil(state.nextRetryDate)
        XCTAssertFalse(notifier.transitions.contains { $0.current.needsAttention })
    }

    @MainActor
    func testConnectOnceDoesNotRetryAfterItsSingleAttemptFails() async {
        let connectOnce = share(.connectOnce)
        let network = StubNetworkReachability(isOnline: true, isReachable: false)
        let (monitor, _, notifier) = makeMonitor(
            "ConnectOnceFails",
            share: connectOnce,
            network: network,
            mountService: StubMountService()
        )

        await monitor.evaluate(connectOnce, reason: .launch)
        let launchState = monitor.runtimeState(for: connectOnce)
        let reachChecksAfterLaunch = network.canReachCallCount

        guard case .failed = launchState.status else {
            return XCTFail("The one attempt should be surfaced, got \(launchState.status)")
        }
        XCTAssertNil(launchState.nextRetryDate)
        // The failure belongs to the attempt Otter was asked to make.
        XCTAssertTrue(notifier.requestedAttemptFlags.allSatisfy { $0 })

        await monitor.evaluate(connectOnce, reason: .timer)
        // The reported failure survives an ordinary tick.
        if case .failed = monitor.runtimeState(for: connectOnce).status {} else {
            XCTFail("The failure should stay visible between triggers")
        }

        await monitor.evaluate(connectOnce, reason: .networkChanged)

        XCTAssertEqual(network.canReachCallCount, reachChecksAfterLaunch, "No persistent retrying")
        XCTAssertEqual(monitor.runtimeState(for: connectOnce).status, .disconnected)
    }

    @MainActor
    func testConnectOnceUsesTheConfiguredVPNForItsOneAttempt() async {
        let connectOnce = share(
            .connectOnce,
            rules: ShareRules(vpnRuleEnabled: true, vpnName: "Work VPN", connectVPNAutomatically: true)
        )
        let mountService = StubMountService(mountResult: URL(fileURLWithPath: "/Volumes/Media", isDirectory: true))
        let vpnConnectionService = StubVPNConnectionService()
        let (monitor, _, _) = makeMonitor(
            "ConnectOnceVPN",
            share: connectOnce,
            network: StubNetworkReachability(
                isOnline: true,
                isReachable: false,
                isReachableAfterVPNConnection: true,
                vpnNameToActivateOnRefresh: "Work VPN"
            ),
            mountService: mountService,
            vpnConnectionService: vpnConnectionService
        )

        await monitor.evaluate(connectOnce, reason: .launch)

        let vpnConnectionNames = await vpnConnectionService.connectionNames
        XCTAssertEqual(vpnConnectionNames, ["Work VPN"])
        XCTAssertEqual(monitor.status(for: connectOnce), .connected)
    }

    // MARK: - Modes are the user's choice

    @MainActor
    func testConnectingEverythingDoesNotRewriteConnectionModes() async {
        let manual = share(.manual)
        let mountService = StubMountService(mountResult: URL(fileURLWithPath: "/Volumes/Media", isDirectory: true))
        let (monitor, settings, _) = makeMonitor(
            "MountAllKeepsModes",
            share: manual,
            network: StubNetworkReachability(isOnline: true, isReachable: true),
            mountService: mountService
        )

        await monitor.mountAll()

        let mountCallCount = await mountService.mountCallCount
        XCTAssertEqual(mountCallCount, 1)
        XCTAssertEqual(monitor.status(for: manual), .connected)
        XCTAssertEqual(settings.share(id: manual.id)?.connectionMode, .manual)
    }

    func testOnlyThePersistentModesComplainAboutUnexpectedOutages() {
        XCTAssertTrue(ConnectionMode.keepConnected.reportsUnexpectedProblems)
        XCTAssertTrue(ConnectionMode.adaptive.reportsUnexpectedProblems)
        XCTAssertFalse(ConnectionMode.manual.reportsUnexpectedProblems)
        XCTAssertFalse(ConnectionMode.connectOnce.reportsUnexpectedProblems)

        XCTAssertFalse(ConnectionMode.keepConnected.usesRemoteAccess)
        XCTAssertTrue(ConnectionMode.adaptive.usesRemoteAccess)
        XCTAssertTrue(ConnectionMode.manual.usesRemoteAccess)
        XCTAssertTrue(ConnectionMode.connectOnce.usesRemoteAccess)
    }
}

final class ServerAliasTests: XCTestCase {
    func testDotLocalHostResolvesToTheBrowsedName() {
        XCTAssertEqual(ServerAlias.canonicalHost(for: "RoonieNAS-Pro.local"), "roonienas-pro")
    }

    func testBonjourServiceHostResolvesToTheBrowsedName() {
        XCTAssertEqual(ServerAlias.canonicalHost(for: "Living Room NAS._smb._tcp.local"), "living room nas")
    }

    func testAdvertisedSpellingIsPreferredOverTheStrippedName() {
        XCTAssertEqual(
            ServerAlias.canonicalHost(for: "RoonieNAS-Pro.local", advertisedNames: ["RoonieNAS-Pro"]),
            "RoonieNAS-Pro"
        )
    }

    func testHostThatIsAlreadyTheBrowsedNameIsNotAnAlias() {
        XCTAssertNil(ServerAlias.canonicalHost(for: "RoonieNAS-Pro"))
        XCTAssertNil(ServerAlias.canonicalHost(for: "RoonieNAS-Pro", advertisedNames: ["RoonieNAS-Pro"]))
    }

    func testOrdinaryDNSNamesAndIPAddressesAreLeftAlone() {
        XCTAssertNil(ServerAlias.canonicalHost(for: "nas.example.com"))
        XCTAssertNil(ServerAlias.canonicalHost(for: "192.168.1.20"))
        XCTAssertNil(ServerAlias.canonicalHost(for: "fe80::1"))
    }

    func testIdentityCollapsesEveryAliasFormOfOneServer() {
        let identities = ["nas", "NAS.local", "nas._smb._tcp.local.", "NAS."].map(ServerAlias.identity)
        XCTAssertEqual(Set(identities.compactMap { $0 }), ["nas"])
    }

    func testURLKeepsEverythingButTheHost() {
        let share = NetworkShare(
            displayName: "Media",
            urlString: "smb://nas.local:4450/Media",
            mountPath: "/Volumes/Media"
        )

        XCTAssertEqual(ServerAlias.urlString(for: share, replacingHostWith: "nas"), "smb://nas:4450/Media")
    }
}

final class SavedSMBShareKeychainTests: XCTestCase {
    func testKeychainDefaultPortIsAcceptedRatherThanDiscarded() throws {
        // macOS writes port 0 for an ordinary SMB connection, so this is the
        // shape of essentially every credential Finder saves.
        let savedShare = try XCTUnwrap(
            SavedSMBShare(host: "roonienas-pro", path: "Vault", port: 0)
        )

        XCTAssertNil(savedShare.port)
        XCTAssertEqual(savedShare.displayName, "Vault")
        XCTAssertEqual(savedShare.connectionURL?.absoluteString, "smb://roonienas-pro/Vault")
    }

    func testServerOnlyCredentialSavedUnderItsBonjourNameOffersTheSharePicker() throws {
        let savedShare = try XCTUnwrap(
            SavedSMBShare(host: "RoonieNAS-Pro._smb._tcp.local", path: nil, port: 0)
        )

        XCTAssertFalse(savedShare.hasSharePath)
        XCTAssertEqual(savedShare.connectionURL?.absoluteString, "smb://RoonieNAS-Pro._smb._tcp.local/")
    }

    func testGenuinelyInvalidPortIsStillRejected() {
        XCTAssertNil(SavedSMBShare(host: "nas.local", path: "Vault", port: 70_000))
        XCTAssertNil(SavedSMBShare(host: "nas.local", path: "Vault", port: -1))
        XCTAssertEqual(SavedSMBShare(host: "nas.local", path: "Vault", port: 4_450)?.port, 4_450)
    }
}

final class ServerAliasCredentialTests: XCTestCase {
    func testCandidatesCoverEverySpellingMacOSFilesAnSMBPasswordUnder() {
        let candidates = ServerAlias.credentialHostCandidates(for: "RoonieNAS-Pro.local")

        // The keychain matches a server name exactly, so the spelling the user
        // typed has to survive alongside the lowercased forms.
        XCTAssertTrue(candidates.contains("RoonieNAS-Pro.local"))
        XCTAssertTrue(candidates.contains("RoonieNAS-Pro"))
        XCTAssertTrue(candidates.contains("RoonieNAS-Pro._smb._tcp.local"))
        XCTAssertTrue(candidates.contains("roonienas-pro"))
        XCTAssertEqual(candidates.count, Set(candidates).count)
    }

    func testCandidatesForABonjourServiceNameIncludeThePlainAddress() {
        let candidates = ServerAlias.credentialHostCandidates(for: "RoonieNAS-Pro._smb._tcp.local")

        XCTAssertTrue(candidates.contains("RoonieNAS-Pro"))
        XCTAssertTrue(candidates.contains("RoonieNAS-Pro.local"))
    }

    func testOrdinaryDNSNamesAndIPAddressesHaveNoAliasSpellings() {
        XCTAssertEqual(ServerAlias.credentialHostCandidates(for: "nas.example.com"), ["nas.example.com"])
        XCTAssertEqual(ServerAlias.credentialHostCandidates(for: "10.11.1.241"), ["10.11.1.241"])
    }

    func testLookupFindsAPasswordSavedUnderTheBonjourSpelling() {
        // The share is addressed by the plain name while macOS filed the
        // password under the Bonjour service name — the case that made Otter
        // report "no keychain credentials" for a server that had them.
        let store = AliasCredentialStore(hosts: ["RoonieNAS-Pro._smb._tcp.local"])

        XCTAssertTrue(store.hasCredentials(forAnyAliasOf: "RoonieNAS-Pro"))
        XCTAssertTrue(store.hasCredentials(forAnyAliasOf: "RoonieNAS-Pro.local"))
        XCTAssertEqual(
            store.savedCredentialHost(matching: "RoonieNAS-Pro"),
            "RoonieNAS-Pro._smb._tcp.local"
        )
        XCTAssertFalse(store.hasCredentials(forAnyAliasOf: "OtherNAS"))
    }

    func testDisplayNameKeepsCapitalization() {
        XCTAssertEqual(ServerAlias.displayName(for: "RoonieNAS-Pro.local"), "RoonieNAS-Pro")
        XCTAssertEqual(ServerAlias.displayName(for: "RoonieNAS-Pro._smb._tcp.local"), "RoonieNAS-Pro")
    }
}

final class ShareDeduplicationTests: XCTestCase {
    @MainActor
    private func makeSettings(_ name: String) -> (SettingsStore, UserDefaults) {
        let suiteName = "OtterTests.ShareDeduplication.\(name)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let settings = SettingsStore(defaults: defaults, credentialStore: RecordingCredentialStore())
        settings.completeOnboarding()
        return (settings, defaults)
    }

    @MainActor
    private func makeMonitor(
        settings: SettingsStore,
        defaults: UserDefaults,
        eventLog: ShareEventLog,
        mountedURL: URL?
    ) -> ShareMonitor {
        ShareMonitor(
            settings: settings,
            mountService: StubMountService(mountedURL: mountedURL, mountResult: mountedURL),
            wakeOnLANService: StubWakeOnLANService(),
            networkService: StubNetworkReachability(isOnline: true, isReachable: true),
            notificationService: RecordingNotificationService(),
            eventLog: eventLog,
            defaults: defaults
        )
    }

    func testVolumesMountedThroughAnAliasOrCachedAddressMatchTheSameShare() {
        let share = NetworkShare(
            displayName: "Vault",
            urlString: "smb://nas.local/Vault",
            mountPath: "/Volumes/Vault",
            cachedIPAddresses: ["10.11.1.241"]
        )
        let volumes = [
            MountedShareSuggestion(displayName: "Vault", urlString: "smb://nas.local/Vault", mountPath: "/Volumes/Vault"),
            MountedShareSuggestion(displayName: "Vault", urlString: "smb://10.11.1.241/Vault", mountPath: "/Volumes/Vault-1"),
            MountedShareSuggestion(displayName: "Vault", urlString: "smb://nas/Vault", mountPath: "/Volumes/Vault-2"),
            MountedShareSuggestion(displayName: "Repo", urlString: "smb://nas.local/Repo", mountPath: "/Volumes/Repo")
        ]

        let matches = ShareDeduplicationService.volumes(volumes, matching: share)

        XCTAssertEqual(matches.map(\.mountPath), ["/Volumes/Vault", "/Volumes/Vault-1", "/Volumes/Vault-2"])
        XCTAssertEqual(
            ShareDeduplicationService.preferredVolume(among: matches, for: share)?.mountPath,
            "/Volumes/Vault"
        )
    }

    func testPreferredVolumeFallsBackToTheNameMacOSDidNotRename() {
        let share = NetworkShare(
            displayName: "Vault",
            urlString: "smb://nas.local/Vault",
            mountPath: "/Volumes/Vault-1",
            cachedIPAddresses: ["10.11.1.241"]
        )
        let matches = [
            MountedShareSuggestion(displayName: "Vault", urlString: "smb://10.11.1.241/Vault", mountPath: "/Volumes/Vault-1"),
            MountedShareSuggestion(displayName: "Vault", urlString: "smb://nas/Vault", mountPath: "/Volumes/Vault")
        ]

        XCTAssertEqual(
            ShareDeduplicationService.preferredVolume(among: matches, for: share)?.mountPath,
            "/Volumes/Vault"
        )
    }

    @MainActor
    func testConnectedAliasShareIsReconnectedThroughTheBrowsedName() async {
        let (settings, defaults) = makeSettings("Canonical")
        let share = NetworkShare(
            displayName: "Vault",
            urlString: "smb://nas.local/Vault",
            mountPath: "/Volumes/Vault"
        )
        settings.addShare(share)

        let eventLog = ShareEventLog(defaults: defaults)
        let mountedURL = URL(fileURLWithPath: "/Volumes/Vault", isDirectory: true)
        let monitor = makeMonitor(settings: settings, defaults: defaults, eventLog: eventLog, mountedURL: mountedURL)
        await monitor.evaluate(share, reason: .manual, force: true)
        XCTAssertEqual(monitor.status(for: share), .connected)

        let service = ShareDeduplicationService(
            settings: settings,
            monitor: monitor,
            eventLog: eventLog,
            credentialStore: RecordingCredentialStore(),
            resolver: StubHostResolver(result: "10.11.1.241"),
            advertisedServerNames: { ["RoonieNAS-Pro"] },
            discoverVolumes: { [] },
            unmountVolume: { _ in true },
            workspaceNotificationCenter: NotificationCenter(),
            scanDelay: 0
        )

        await service.scan()

        XCTAssertEqual(settings.share(id: share.id)?.urlString, "smb://nas/Vault")
        XCTAssertEqual(monitor.status(for: share), .connected)
        XCTAssertEqual(eventLog.events(for: share.id).first?.kind, .duplicateResolved)
        XCTAssertEqual(service.recentResolutions.count, 1)

        // The rewritten address is already the browsed name, so a second pass
        // has nothing left to do.
        await service.scan()
        XCTAssertEqual(service.recentResolutions.count, 1)
    }

    @MainActor
    func testAliasIsLeftAloneWhenTheBrowsedNameLeadsSomewhereElse() async {
        let (settings, defaults) = makeSettings("DifferentServer")
        let share = NetworkShare(
            displayName: "Vault",
            urlString: "smb://nas.local/Vault",
            mountPath: "/Volumes/Vault"
        )
        settings.addShare(share)

        let eventLog = ShareEventLog(defaults: defaults)
        let mountedURL = URL(fileURLWithPath: "/Volumes/Vault", isDirectory: true)
        let monitor = makeMonitor(settings: settings, defaults: defaults, eventLog: eventLog, mountedURL: mountedURL)
        await monitor.evaluate(share, reason: .manual, force: true)

        let service = ShareDeduplicationService(
            settings: settings,
            monitor: monitor,
            eventLog: eventLog,
            credentialStore: RecordingCredentialStore(),
            resolver: HostMapResolver(["nas.local": ["10.11.1.241"], "nas": ["10.11.1.99"]]),
            discoverVolumes: { [] },
            unmountVolume: { _ in true },
            workspaceNotificationCenter: NotificationCenter(),
            scanDelay: 0
        )

        await service.scan()

        XCTAssertEqual(settings.share(id: share.id)?.urlString, "smb://nas.local/Vault")
        XCTAssertTrue(service.recentResolutions.isEmpty)
    }

    @MainActor
    func testDisconnectedShareIsNotReconnectedJustToChangeItsAddress() async {
        let (settings, defaults) = makeSettings("Disconnected")
        let share = NetworkShare(
            displayName: "Vault",
            urlString: "smb://nas.local/Vault",
            mountPath: "/Volumes/Vault"
        )
        settings.addShare(share)

        let eventLog = ShareEventLog(defaults: defaults)
        let monitor = makeMonitor(settings: settings, defaults: defaults, eventLog: eventLog, mountedURL: nil)
        let service = ShareDeduplicationService(
            settings: settings,
            monitor: monitor,
            eventLog: eventLog,
            credentialStore: RecordingCredentialStore(),
            resolver: StubHostResolver(result: "10.11.1.241"),
            discoverVolumes: { [] },
            unmountVolume: { _ in true },
            workspaceNotificationCenter: NotificationCenter(),
            scanDelay: 0
        )

        await service.scan()

        XCTAssertEqual(settings.share(id: share.id)?.urlString, "smb://nas.local/Vault")
        XCTAssertTrue(service.recentResolutions.isEmpty)
    }

    @MainActor
    func testSecondCopyOfAMountedShareIsUnmounted() async {
        let (settings, defaults) = makeSettings("RedundantVolume")
        let share = NetworkShare(
            displayName: "Vault",
            urlString: "smb://nas.local/Vault",
            mountPath: "/Volumes/Vault",
            cachedIPAddresses: ["10.11.1.241"]
        )
        settings.addShare(share)

        let eventLog = ShareEventLog(defaults: defaults)
        let monitor = makeMonitor(settings: settings, defaults: defaults, eventLog: eventLog, mountedURL: nil)
        let unmounted = UnmountRecorder()
        let service = ShareDeduplicationService(
            settings: settings,
            monitor: monitor,
            eventLog: eventLog,
            credentialStore: RecordingCredentialStore(),
            resolver: StubHostResolver(result: "10.11.1.241"),
            discoverVolumes: {
                [
                    MountedShareSuggestion(displayName: "Vault", urlString: "smb://nas.local/Vault", mountPath: "/Volumes/Vault"),
                    MountedShareSuggestion(displayName: "Vault", urlString: "smb://10.11.1.241/Vault", mountPath: "/Volumes/Vault-1")
                ]
            },
            unmountVolume: { url in await unmounted.record(url) },
            workspaceNotificationCenter: NotificationCenter(),
            scanDelay: 0
        )

        await service.scan()

        let paths = await unmounted.paths
        XCTAssertEqual(paths, ["/Volumes/Vault-1"])
        XCTAssertEqual(settings.share(id: share.id)?.mountPath, "/Volumes/Vault")
        XCTAssertEqual(eventLog.events(for: share.id).first?.kind, .duplicateResolved)
    }

    @MainActor
    func testNothingHappensWhileDeduplicationIsTurnedOff() async {
        let (settings, defaults) = makeSettings("Disabled")
        settings.updatePreferences { $0.deduplicateConnections = false }
        let share = NetworkShare(
            displayName: "Vault",
            urlString: "smb://nas.local/Vault",
            mountPath: "/Volumes/Vault"
        )
        settings.addShare(share)

        let eventLog = ShareEventLog(defaults: defaults)
        let mountedURL = URL(fileURLWithPath: "/Volumes/Vault", isDirectory: true)
        let monitor = makeMonitor(settings: settings, defaults: defaults, eventLog: eventLog, mountedURL: mountedURL)
        await monitor.evaluate(share, reason: .manual, force: true)

        let unmounted = UnmountRecorder()
        let service = ShareDeduplicationService(
            settings: settings,
            monitor: monitor,
            eventLog: eventLog,
            credentialStore: RecordingCredentialStore(),
            resolver: StubHostResolver(result: "10.11.1.241"),
            discoverVolumes: {
                [
                    MountedShareSuggestion(displayName: "Vault", urlString: "smb://nas.local/Vault", mountPath: "/Volumes/Vault"),
                    MountedShareSuggestion(displayName: "Vault", urlString: "smb://10.11.1.241/Vault", mountPath: "/Volumes/Vault-1")
                ]
            },
            unmountVolume: { url in await unmounted.record(url) },
            workspaceNotificationCenter: NotificationCenter(),
            scanDelay: 0
        )

        await service.scan()

        let paths = await unmounted.paths
        XCTAssertTrue(paths.isEmpty)
        XCTAssertEqual(settings.share(id: share.id)?.urlString, "smb://nas.local/Vault")
    }
}

extension ShareDeduplicationTests {
    @MainActor
    func testSavedPasswordIsCarriedOverFromTheBonjourSpelling() async {
        let (settings, defaults) = makeSettings("CredentialCarry")
        let share = NetworkShare(
            displayName: "Vault",
            urlString: "smb://RoonieNAS-Pro.local/Vault",
            mountPath: "/Volumes/Vault"
        )
        settings.addShare(share)

        let eventLog = ShareEventLog(defaults: defaults)
        let mountedURL = URL(fileURLWithPath: "/Volumes/Vault", isDirectory: true)
        let monitor = makeMonitor(settings: settings, defaults: defaults, eventLog: eventLog, mountedURL: mountedURL)
        await monitor.evaluate(share, reason: .manual, force: true)

        // Exactly how macOS files a password saved through Finder.
        let credentials = AliasCredentialStore(hosts: ["RoonieNAS-Pro._smb._tcp.local"])
        let service = ShareDeduplicationService(
            settings: settings,
            monitor: monitor,
            eventLog: eventLog,
            credentialStore: credentials,
            resolver: StubHostResolver(result: "10.11.1.241"),
            advertisedServerNames: { ["RoonieNAS-Pro"] },
            discoverVolumes: { [] },
            unmountVolume: { _ in true },
            workspaceNotificationCenter: NotificationCenter(),
            scanDelay: 0
        )

        await service.scan()

        XCTAssertEqual(settings.share(id: share.id)?.urlString, "smb://RoonieNAS-Pro/Vault")
        XCTAssertEqual(credentials.syncedPairs.map(\.to), ["RoonieNAS-Pro"])
        XCTAssertEqual(credentials.syncedPairs.map(\.from), ["RoonieNAS-Pro._smb._tcp.local"])
    }

    @MainActor
    func testShareIsLeftAloneWhenItsPasswordCannotFollowTheNewAddress() async {
        let (settings, defaults) = makeSettings("CredentialStuck")
        let share = NetworkShare(
            displayName: "Vault",
            urlString: "smb://RoonieNAS-Pro.local/Vault",
            mountPath: "/Volumes/Vault"
        )
        settings.addShare(share)

        let eventLog = ShareEventLog(defaults: defaults)
        let mountedURL = URL(fileURLWithPath: "/Volumes/Vault", isDirectory: true)
        let monitor = makeMonitor(settings: settings, defaults: defaults, eventLog: eventLog, mountedURL: mountedURL)
        await monitor.evaluate(share, reason: .manual, force: true)

        let credentials = AliasCredentialStore(
            hosts: ["RoonieNAS-Pro._smb._tcp.local"],
            allowsSync: false
        )
        let service = ShareDeduplicationService(
            settings: settings,
            monitor: monitor,
            eventLog: eventLog,
            credentialStore: credentials,
            resolver: StubHostResolver(result: "10.11.1.241"),
            discoverVolumes: { [] },
            unmountVolume: { _ in true },
            workspaceNotificationCenter: NotificationCenter(),
            scanDelay: 0
        )

        await service.scan()

        // Reconnecting would have put a password prompt in front of the user.
        XCTAssertEqual(settings.share(id: share.id)?.urlString, "smb://RoonieNAS-Pro.local/Vault")
        XCTAssertTrue(service.recentResolutions.isEmpty)
        XCTAssertEqual(monitor.status(for: share), .connected)
    }
}

private final class AliasCredentialStore: CredentialStoring, @unchecked Sendable {
    private var hosts: Set<String>
    private let allowsSync: Bool
    private(set) var syncedPairs: [(from: String, to: String)] = []

    init(hosts: Set<String>, allowsSync: Bool = true) {
        self.hosts = hosts
        self.allowsSync = allowsSync
    }

    // Case-sensitive, exactly like the keychain.
    func hasCredentials(for host: String) -> Bool {
        hosts.contains(host)
    }

    func syncCredentials(fromHost: String, toHost: String) -> Bool {
        guard allowsSync, hosts.contains(fromHost) else { return false }
        syncedPairs.append((from: fromHost, to: toHost))
        hosts.insert(toHost)
        return true
    }

    func removeFallbackCredentials(for host: String) {
        hosts.remove(host)
    }
}

private struct HostMapResolver: HostResolving {
    private let addressesByHost: [String: [String]]

    init(_ addressesByHost: [String: [String]]) {
        self.addressesByHost = addressesByHost
    }

    func resolveIPAddresses(for hostname: String) async -> [String] {
        addressesByHost[hostname.lowercased()] ?? []
    }
}

private actor UnmountRecorder {
    private(set) var paths: [String] = []

    func record(_ url: URL) -> Bool {
        paths.append(url.standardizedFileURL.path)
        return true
    }
}
