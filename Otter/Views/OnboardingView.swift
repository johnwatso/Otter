import AppKit
import SwiftUI

struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var discovery: SMBDiscoveryService
    @EnvironmentObject private var loginItemService: LoginItemService
    @EnvironmentObject private var notificationService: NotificationService

    let onAddManually: () -> Void

    @State private var step = 0
    @State private var mountedShares: [MountedShareSuggestion] = []
    @State private var isRefreshingMountedShares = false
    @State private var importedPaths = Set<String>()
    @State private var pendingFinderServer: DiscoveredSMBServer?
    @State private var mountPathsBeforeOpeningFinder = Set<String>()
    @State private var finderImportMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case 0:
                    welcomePage
                case 1:
                    presencePage
                case 2:
                    findSharesPage
                default:
                    finishPage
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack {
                if step == 0 {
                    Button("Skip Setup") {
                        finish(requestNotificationPermission: false)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                } else {
                    Button {
                        step -= 1
                    } label: {
                        Label("Back", systemImage: "chevron.left")
                    }
                    .tahoeSecondaryActionButton()
                }

                Spacer()

                if step < 3 {
                    Button {
                        switch step {
                        case 0:
                            step = 1
                        case 1:
                            step = 2
                            beginDiscovery()
                        default:
                            refreshMountedShares(
                                autoImportFromFinder: true,
                                advanceToFinish: true
                            )
                        }
                    } label: {
                        Label(step == 0 ? "Get Started" : "Continue", systemImage: "chevron.right")
                    }
                    .tahoePrimaryActionButton()
                    .keyboardShortcut(.defaultAction)
                    .disabled(step == 2 && isRefreshingMountedShares)
                } else {
                    Button {
                        finish(requestNotificationPermission: true)
                    } label: {
                        Label(settings.shares.isEmpty ? "Finish Without a Share" : "Finish", systemImage: "checkmark")
                    }
                    .tahoePrimaryActionButton()
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(18)
        }
        .frame(width: 620, height: 540)
        .onAppear {
            appModel.onboardingDidBegin()
        }
        .onDisappear {
            discovery.stop()
            appModel.onboardingDidEnd()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard step == 2, pendingFinderServer != nil else { return }
            refreshMountedShares(autoImportFromFinder: true)
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
        }
        .padding(36)
    }

    private var presencePage: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Where should Otter live?")
                    .font(.title2.bold())
                Text("Choose how you want to reach Otter after setup. You can change this later in Preferences.")
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 10) {
                ForEach(AppPresenceMode.allCases) { mode in
                    presenceChoice(mode)
                }
            }

            Label("Otter stays visible in both the Dock and menu bar until onboarding is finished.", systemImage: "info.circle")
                .font(.callout)
                .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(34)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var findSharesPage: some View {
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
                                Button(pendingFinderServer?.id == server.id ? "Open Again" : "Open in Finder") {
                                    openInFinder(server)
                                }
                            }
                        }
                    }

                    if let finderImportMessage {
                        Label(finderImportMessage, systemImage: pendingFinderServer == nil ? "checkmark.circle.fill" : "arrow.up.forward.app")
                            .font(.caption)
                            .foregroundStyle(pendingFinderServer == nil ? .green : .secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text("Connect in Finder, then return to Otter. The newly mounted share will be added automatically.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(24)
    }

    private var finishPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Keep Otter ready")
                    .font(.title2.bold())
                Text("These defaults make reconnection automatic while keeping alerts under your control.")
                    .foregroundStyle(.secondary)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 14) {
                    Toggle("Start Otter at login", isOn: Binding(
                        get: { loginItemService.isEnabled },
                        set: { loginItemService.setEnabled($0) }
                    ))

                    Toggle("Notify me about connection changes and problems", isOn: Binding(
                        get: { settings.preferences.notificationsEnabled },
                        set: { enabled in
                            settings.updatePreferences { $0.notificationsEnabled = enabled }
                            if enabled {
                                Task { await notificationService.requestAuthorization() }
                            }
                        }
                    ))
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if settings.shares.isEmpty {
                Label("No shares were added. Go Back to add one, or finish and add one later.", systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            } else {
                Label("\(settings.shares.count) share\(settings.shares.count == 1 ? "" : "s") ready for Otter to monitor.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }

            Spacer()
        }
        .padding(34)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            loginItemService.refresh()
        }
    }

    private var discoveryMessage: String {
        if case let .failed(message) = discovery.state {
            return "Discovery unavailable: \(message)"
        }
        return "No SMB servers found yet."
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
    }

    private func refreshMountedShares(
        autoImportFromFinder: Bool = false,
        advanceToFinish: Bool = false
    ) {
        guard !isRefreshingMountedShares else { return }
        isRefreshingMountedShares = true
        Task {
            let suggestions = await Task.detached(priority: .userInitiated) {
                MountedShareSuggestion.discover()
            }.value
            mountedShares = suggestions

            if autoImportFromFinder {
                importFinderShares(from: suggestions)
            }

            isRefreshingMountedShares = false
            if advanceToFinish {
                step = 3
            }
        }
    }

    private func openInFinder(_ server: DiscoveredSMBServer) {
        guard let url = server.finderURL else { return }
        pendingFinderServer = server
        finderImportMessage = "Complete the connection in Finder, then return to Otter."

        Task {
            let currentSuggestions = await Task.detached(priority: .userInitiated) {
                MountedShareSuggestion.discover()
            }.value
            mountPathsBeforeOpeningFinder = Set(currentSuggestions.map(\.mountPath))
            NSWorkspace.shared.open(url)
        }
    }

    private func importFinderShares(from suggestions: [MountedShareSuggestion]) {
        guard let pendingFinderServer else { return }

        let candidates = MountedShareSuggestion.finderImportCandidates(
            in: suggestions,
            for: pendingFinderServer,
            excludingMountPaths: mountPathsBeforeOpeningFinder
        )
        guard !candidates.isEmpty else {
            finderImportMessage = "Finder has not mounted a new SMB share yet. Complete the connection and return here."
            return
        }

        let previousCount = settings.shares.count
        candidates.forEach(importSuggestion)
        let addedCount = settings.shares.count - previousCount

        self.pendingFinderServer = nil
        finderImportMessage = addedCount > 0
            ? "Added \(addedCount) share\(addedCount == 1 ? "" : "s") from Finder."
            : "The Finder share was already added."
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

    private func finish(requestNotificationPermission: Bool) {
        let shouldRequestNotifications = requestNotificationPermission
            && settings.preferences.notificationsEnabled
            && notificationService.canAskForAuthorization
        settings.completeOnboarding()
        dismiss()

        if shouldRequestNotifications {
            Task { await notificationService.requestAuthorization() }
        }
    }

    private func presenceChoice(_ mode: AppPresenceMode) -> some View {
        let isSelected = settings.preferences.appPresenceMode == mode

        return AppPresenceChoice(mode: mode, isSelected: isSelected) {
            settings.updatePreferences { $0.appPresenceMode = mode }
        }
    }
}

private struct AppPresenceChoice: View {
    let mode: AppPresenceMode
    let isSelected: Bool
    let action: () -> Void

    private var secondaryColor: Color {
        Color(nsColor: .secondaryLabelColor)
    }

    private var tertiaryColor: Color {
        Color(nsColor: .tertiaryLabelColor)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: mode.systemImage)
                    .font(.title2)
                    .foregroundStyle(isSelected ? Color.accentColor : secondaryColor)
                    .frame(width: 32)

                VStack(alignment: .leading, spacing: 3) {
                    Text(mode.title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(mode.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }

                Spacer()

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : tertiaryColor)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(choiceBackground)
            .overlay(choiceBorder)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(mode.title)
        .accessibilityHint(mode.detail)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
    }

    private var choiceBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(isSelected ? Color.accentColor.opacity(0.10) : secondaryColor.opacity(0.06))
    }

    private var choiceBorder: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(isSelected ? Color.accentColor.opacity(0.65) : secondaryColor.opacity(0.12))
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
