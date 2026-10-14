import AppKit
import SwiftUI

struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var networkService: NetworkReachabilityService
    @EnvironmentObject private var discovery: SMBDiscoveryService
    @EnvironmentObject private var loginItemService: LoginItemService
    @EnvironmentObject private var notificationService: NotificationService

    let onAddManually: () -> Void

    @State private var step = 0
    @State private var mountedShares: [MountedShareSuggestion] = []
    @State private var isRefreshingMountedShares = false
    @State private var savedSMBShares: [SavedSMBShare] = []
    @State private var isRefreshingSavedSMBShares = false
    @State private var importedPaths = Set<String>()
    @State private var shareBrowserMessage: String?
    @State private var browsingServerID: DiscoveredSMBServer.ID?
    @State private var browsingSavedShareID: SavedSMBShare.ID?
    var body: some View {
        VStack(spacing: 0) {
            Group {
                if step == 0 {
                    welcomePage
                } else {
                    findSharesPage
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack {
                if step == 0 {
                    Button("Skip Setup") {
                        finish()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                } else {
                    Button {
                        step -= 1
                    } label: {
                        Label("Back", systemImage: "chevron.left")
                    }
                    .onboardingSecondaryActionButton()
                }

                Spacer()

                if step == 0 {
                    Button {
                        step = 1
                        beginDiscovery()
                    } label: {
                        Text("Get Started")
                    }
                    .onboardingPrimaryActionButton()
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button {
                        finish()
                    } label: {
                        Text(settings.shares.isEmpty ? "Finish Without a Share" : "Finish")
                    }
                    .onboardingPrimaryActionButton()
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 620, height: 620)
        .onAppear {
            appModel.onboardingDidBegin()
        }
        .onDisappear {
            discovery.stop()
            appModel.onboardingDidEnd()
        }
    }

    private var welcomePage: some View {
        VStack(spacing: 18) {
            AdaptiveOtterIcon()
                .frame(width: 94, height: 94)

            VStack(spacing: 8) {
                Text("Welcome to Otter")
                    .font(.largeTitle.bold())
                Text("Keep your SMB shares connected after sleep, network changes, VPN reconnects, and server restarts.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 470)
            }

            HStack(spacing: 24) {
                onboardingFeature("bolt.heart", "Quietly monitors")
                onboardingFeature("key.fill", "Uses Keychain")
                onboardingFeature("lock.shield", "Respects network rules")
            }
            .padding(.top, 8)

            VStack(spacing: 0) {
                onboardingToggleRow("Start Otter at login", isOn: Binding(
                    get: { loginItemService.isEnabled },
                    set: { loginItemService.setEnabled($0) }
                ))

                Divider()

                onboardingToggleRow("Notify me about connection changes and problems", isOn: Binding(
                    get: { settings.preferences.notificationsEnabled },
                    set: { enabled in
                        settings.updatePreferences { $0.notificationsEnabled = enabled }
                    }
                ))
            }
            .padding(.horizontal, 14)
            .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
            .padding(.top, 10)
            .frame(maxWidth: 420)
        }
        .padding(36)
        .onAppear {
            loginItemService.refresh()
        }
    }

    private var findSharesPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Add your shares")
                    .font(.title2.bold())
                Text("Import a share already mounted in Finder, or open a nearby SMB server and connect once so macOS can save its credentials.")
                    .foregroundStyle(.secondary)
            }

            GroupBox("Mounted SMB shares") {
                VStack(spacing: 8) {
                    if isRefreshingMountedShares {
                        ProgressView("Looking for mounted shares…")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if mountedShares.isEmpty {
                        Text("No mounted SMB shares found.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ForEach(mountedShares) { suggestion in
                            HStack {
                                Label(suggestion.displayName, systemImage: "externaldrive.fill")
                                Spacer()
                                if importedPaths.contains(suggestion.mountPath)
                                    || settings.isDuplicateShare(urlString: suggestion.urlString) {
                                    Label("Added", systemImage: "checkmark")
                                        .foregroundStyle(.green)
                                } else {
                                    Button("Add") {
                                        importSuggestion(suggestion)
                                    }
                                }
                            }
                        }
                    }

                    HStack {
                        Button {
                            refreshMountedShares()
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        .tahoeCompactActionButton()

                        Button {
                            settings.completeOnboarding()
                            dismiss()
                            onAddManually()
                        } label: {
                            Label("Enter Address Manually", systemImage: "keyboard")
                        }
                        .tahoeCompactActionButton()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            GroupBox("Saved SMB connections") {
                VStack(spacing: 8) {
                    if isRefreshingSavedSMBShares {
                        ProgressView("Checking Keychain…")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if savedSMBShares.isEmpty {
                        Text("No saved SMB connections found in Keychain.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ForEach(savedSMBShares) { savedShare in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Label(savedShare.displayName, systemImage: "key.fill")
                                    Text(savedShare.detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button {
                                    browseShares(using: savedShare)
                                } label: {
                                    if browsingSavedShareID == savedShare.id {
                                        ProgressView()
                                            .controlSize(.small)
                                    } else {
                                        Text(savedShare.hasSharePath ? "Mount" : "Browse Shares…")
                                    }
                                }
                                .disabled(browsingServerID != nil || browsingSavedShareID != nil)
                            }
                        }
                    }

                    Button {
                        refreshSavedSMBShares()
                    } label: {
                        Label("Refresh Saved Connections", systemImage: "key.viewfinder")
                    }
                    .tahoeCompactActionButton()
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Text("Otter reads only saved server and share addresses. It checks reachability only after you choose one; passwords and usernames stay in Keychain.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            GroupBox("Nearby SMB servers") {
                VStack(spacing: 8) {
                    if discovery.servers.isEmpty {
                        HStack {
                            if discovery.state == .searching {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Searching the local network…")
                            } else {
                                Text(discoveryMessage)
                            }
                            Spacer()
                        }
                        .foregroundStyle(.secondary)
                    } else {
                        ForEach(discovery.servers) { server in
                            HStack {
                                Label(server.name, systemImage: "server.rack")
                                Spacer()
                                Button {
                                    browseShares(on: server)
                                } label: {
                                    if browsingServerID == server.id {
                                        ProgressView()
                                            .controlSize(.small)
                                    } else {
                                        Text("Browse Shares\u{2026}")
                                    }
                                }
                                .disabled(browsingServerID != nil || browsingSavedShareID != nil)
                            }
                        }
                    }

                    if let shareBrowserMessage {
                        Label(shareBrowserMessage, systemImage: "info.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text("macOS will show the server's shares and handle sign-in. Save the password to Keychain when prompted.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(24)
    }

    private var discoveryMessage: String {
        if case let .failed(message) = discovery.state {
            return "Discovery unavailable: \(message)"
        }
        return "No SMB servers found yet."
    }

    private func onboardingToggleRow(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            Text(title)
            Spacer(minLength: 8)
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .padding(.vertical, 10)
    }

    private func onboardingFeature(_ symbol: String, _ title: String) -> some View {
        VStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.blue)
            Text(title)
                .font(.caption.weight(.medium))
        }
        .frame(width: 120)
    }

    private func beginDiscovery() {
        discovery.start()
        refreshMountedShares()
        refreshSavedSMBShares()
    }

    private func refreshMountedShares() {
        guard !isRefreshingMountedShares else { return }
        isRefreshingMountedShares = true
        Task {
            let suggestions = await Task.detached(priority: .userInitiated) {
                MountedShareSuggestion.discover()
            }.value
            mountedShares = suggestions

            isRefreshingMountedShares = false
        }
    }

    private func refreshSavedSMBShares() {
        guard !isRefreshingSavedSMBShares else { return }
        isRefreshingSavedSMBShares = true
        let keychainDiscovery = appModel.keychainShareDiscoveryService
        Task {
            savedSMBShares = await Task.detached(priority: .userInitiated) {
                keychainDiscovery.savedShares()
            }.value
            isRefreshingSavedSMBShares = false
        }
    }

    private func browseShares(on server: DiscoveredSMBServer) {
        guard browsingServerID == nil, browsingSavedShareID == nil else { return }
        browsingServerID = server.id
        shareBrowserMessage = nil

        Task {
            do {
                let suggestions = try await appModel.shareBrowserService.browse(server)
                guard !suggestions.isEmpty else {
                    shareBrowserMessage = "No share was selected."
                    browsingServerID = nil
                    return
                }

                let existing = Set(mountedShares)
                mountedShares = existing.union(suggestions).sorted {
                    $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
                }
                let previousCount = settings.shares.count
                suggestions.forEach(importSuggestion)
                let addedCount = settings.shares.count - previousCount
                shareBrowserMessage = addedCount > 0
                    ? "Added \(String.counted(addedCount, "share"))."
                    : "The selected share was already added."
            } catch {
                shareBrowserMessage = "Couldn't browse this server: \(error.localizedDescription)"
            }
            browsingServerID = nil
        }
    }

    private func browseShares(using savedShare: SavedSMBShare) {
        guard browsingServerID == nil, browsingSavedShareID == nil else { return }
        browsingSavedShareID = savedShare.id
        shareBrowserMessage = nil

        Task {
            do {
                guard let url = savedShare.connectionURL else {
                    shareBrowserMessage = "This saved connection has an invalid network address."
                    browsingSavedShareID = nil
                    return
                }
                guard await networkService.canReachServer(for: url, timeout: 2) else {
                    shareBrowserMessage = "\(savedShare.displayName) is not reachable on the current network, so Otter didn't try to mount it."
                    browsingSavedShareID = nil
                    return
                }
                let suggestions = try await appModel.shareBrowserService.browse(savedShare)
                guard !suggestions.isEmpty else {
                    shareBrowserMessage = "No share was selected."
                    browsingSavedShareID = nil
                    return
                }

                let existing = Set(mountedShares)
                mountedShares = existing.union(suggestions).sorted {
                    $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
                }
                let previousCount = settings.shares.count
                suggestions.forEach(importSuggestion)
                let addedCount = settings.shares.count - previousCount
                shareBrowserMessage = addedCount > 0
                    ? "Added \(String.counted(addedCount, "share")) from Keychain."
                    : "The selected share was already added."
            } catch {
                shareBrowserMessage = "Couldn't connect using this saved connection: \(error.localizedDescription)"
            }
            browsingSavedShareID = nil
        }
    }

    private func importSuggestion(_ suggestion: MountedShareSuggestion) {
        guard !settings.isDuplicateShare(urlString: suggestion.urlString) else { return }
        settings.addShare(NetworkShare(
            displayName: suggestion.displayName,
            urlString: suggestion.urlString,
            mountPath: suggestion.mountPath
        ))
        importedPaths.insert(suggestion.mountPath)
    }

    private func finish() {
        settings.completeOnboarding()
        if settings.preferences.notificationsEnabled {
            Task { await notificationService.requestAuthorization() }
        }
        dismiss()
    }

}

private extension View {
    @ViewBuilder
    func onboardingPrimaryActionButton() -> some View {
        if #available(macOS 26.0, *) {
            self
                .font(.body.weight(.semibold))
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.roundedRectangle(radius: 11))
                .controlSize(.large)
                .frame(minWidth: 132)
        } else {
            self
                .font(.body.weight(.semibold))
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.roundedRectangle(radius: 11))
                .controlSize(.large)
                .frame(minWidth: 132)
        }
    }

    @ViewBuilder
    func onboardingSecondaryActionButton() -> some View {
        if #available(macOS 26.0, *) {
            self
                .font(.body.weight(.medium))
                .buttonStyle(.glass)
                .buttonBorderShape(.roundedRectangle(radius: 11))
                .controlSize(.large)
        } else {
            self
                .font(.body.weight(.medium))
                .buttonStyle(.bordered)
                .buttonBorderShape(.roundedRectangle(radius: 11))
                .controlSize(.large)
        }
    }
}

struct AdaptiveOtterIcon: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Image(nsImage: Self.image(for: colorScheme) ?? NSApplication.shared.applicationIconImage)
            .resizable()
            .scaledToFit()
            .id(colorScheme)
    }

    static func image(for colorScheme: ColorScheme, bundle: Bundle = .main) -> NSImage? {
        let resourceName = colorScheme == .dark ? "otter-icon-dark" : "otter-icon-light"
        guard let url = bundle.url(forResource: resourceName, withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }
}
