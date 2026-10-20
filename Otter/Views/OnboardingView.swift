import AppKit
import SwiftUI

struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var monitor: ShareMonitor
    @EnvironmentObject private var discovery: SMBDiscoveryService
    @EnvironmentObject private var networkService: NetworkReachabilityService
    @EnvironmentObject private var loginItemService: LoginItemService
    @EnvironmentObject private var notificationService: NotificationService

    /// Called with the connected share when the user finishes, so the main
    /// window can select it.
    private let onFinish: (NetworkShare?) -> Void

    private typealias Step = OnboardingStep

    private enum ConnectPanel {
        case discover, manual
    }

    @State private var step: Step
    @State private var panel: ConnectPanel?
    @State private var busyID: String?
    @State private var mountedShares: [MountedShareSuggestion] = []
    @State private var savedShares: [SavedSMBShare] = []
    @State private var address = ""
    @FocusState private var addressFocused: Bool
    @State private var connectionMessage: String?
    @State private var connectedShareID: NetworkShare.ID?

    init(initialStep: OnboardingStep = .welcome, onFinish: @escaping (NetworkShare?) -> Void = { _ in }) {
        _step = State(initialValue: initialStep)
        self.onFinish = onFinish
    }

    private var isConnecting: Bool { busyID != nil }

    private var readyMountedShares: [MountedShareSuggestion] {
        mountedShares.filter { !settings.isDuplicateShare(urlString: $0.urlString) }
    }

    private var readySavedShares: [SavedSMBShare] {
        savedShares.filter { saved in
            guard saved.hasSharePath, let url = saved.connectionURL else { return true }
            return !settings.isDuplicateShare(urlString: url.absoluteString)
                && !mountedShares.contains { $0.matches(savedShare: saved) }
        }
    }

    private var connectedShare: NetworkShare? {
        connectedShareID.flatMap { settings.share(id: $0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case .welcome: welcomePage
                case .preferences: preferencesPage
                case .connect: connectPage
                case .success: successPage
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity)

            progressDots
                .padding(.top, 10)
                .padding(.bottom, 18)

            Divider()

            footer
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
        }
        .frame(width: 560, height: 500)
        .background(.background)
        .interactiveDismissDisabled(isConnecting)
        .onAppear {
            appModel.onboardingDidBegin()
            loginItemService.refresh()
            Task { await notificationService.refreshAuthorizationStatus() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Picks up a change made in System Settings while onboarding is open.
            Task { await notificationService.refreshAuthorizationStatus() }
        }
        .onDisappear {
            discovery.stop()
            appModel.onboardingDidEnd()
            // Dismissing any other way still counts as finishing, so
            // onboarding never reappears on every launch.
            if !settings.preferences.hasCompletedOnboarding {
                settings.completeOnboarding()
            }
        }
    }

    // MARK: Pages

    private var welcomePage: some View {
        VStack(spacing: 16) {
            AdaptiveOtterIcon()
                .frame(width: 120, height: 120)
                .accessibilityHidden(true)

            Text("Your shares. Always connected.")
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)

            Text("Otter keeps your network shares mounted through sleep, network changes, VPN reconnects, and server restarts.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .frame(maxWidth: 420)
        }
        .padding(.horizontal, 40)
    }

    private var preferencesPage: some View {
        VStack(spacing: 24) {
            header("Make Otter yours", "Choose how Otter behaves in the background.")

            VStack(spacing: 0) {
                OnboardingPreferenceRow(
                    symbol: "power",
                    title: "Launch at Login",
                    detail: "Automatically start Otter when you sign in.",
                    isOn: Binding(
                        get: { loginItemService.isEnabled },
                        set: { loginItemService.setEnabled($0) }
                    )
                )

                Divider().padding(.leading, 62)

                OnboardingPreferenceRow(
                    symbol: "bell",
                    title: "Connection Notifications",
                    detail: notificationsDenied
                        ? "Notifications are turned off for Otter in System Settings. Turn this on to open them."
                        : "Get notified when shares disconnect or require attention.",
                    isOn: notificationsBinding
                )
            }
            .onboardingGroup()
            .padding(.horizontal, 40)
        }
        .padding(.top, 44)
        .frame(maxHeight: .infinity, alignment: .top)
        .task {
            // Notifications default to on, so ask macOS now, while the reason
            // is on screen, rather than leaving the switch on with nothing behind it.
            if settings.preferences.notificationsEnabled {
                requestNotificationPermission()
            }
        }
    }

    private var connectPage: some View {
        ScrollView {
            VStack(spacing: 24) {
                header("Connect your first share", "Otter needs a network share to keep connected.")

                VStack(spacing: 12) {
                    if !readyMountedShares.isEmpty || !readySavedShares.isEmpty {
                        readySharesGroup
                    }

                    OnboardingMethodRow(
                        symbol: "magnifyingglass",
                        title: "Discover Servers",
                        detail: "Find available SMB servers on your local network.",
                        isHighlighted: true,
                        isExpanded: panel == .discover
                    ) { toggle(.discover) }

                    if panel == .discover {
                        discoverList
                    }

                    OnboardingMethodRow(
                        symbol: "server.rack",
                        title: "Connect Manually",
                        detail: "Enter a server address or SMB URL.",
                        isHighlighted: false,
                        isExpanded: panel == .manual
                    ) { toggle(.manual) }

                    if panel == .manual {
                        manualEntry
                    }

                    if let connectionMessage {
                        Label(connectionMessage, systemImage: "info.circle.fill")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text("macOS asks you to sign in and can remember the password in Keychain. Otter never sees it.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, 40)
            }
            .padding(.vertical, 36)
        }
        .scrollBounceBehavior(.basedOnSize)
        .onAppear { beginConnectStep() }
    }

    private var readySharesGroup: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Ready to add")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)

            VStack(spacing: 0) {
                ForEach(readyMountedShares) { suggestion in
                    OnboardingShareRow(
                        symbol: "externaldrive.fill",
                        title: suggestion.displayName,
                        detail: "Mounted in Finder",
                        buttonTitle: "Add",
                        isBusy: busyID == suggestion.id,
                        isDisabled: isConnecting
                    ) {
                        browse(id: suggestion.id) { [suggestion] }
                    }
                    Divider().padding(.leading, 12)
                }
                ForEach(readySavedShares) { saved in
                    OnboardingShareRow(
                        symbol: "key.fill",
                        title: saved.displayName,
                        detail: "Saved in Keychain · \(saved.detail)",
                        buttonTitle: saved.hasSharePath ? "Connect" : "Choose…",
                        isBusy: busyID == saved.id,
                        isDisabled: isConnecting
                    ) {
                        connect(using: saved)
                    }
                    if saved.id != readySavedShares.last?.id { Divider().padding(.leading, 12) }
                }
            }
            .onboardingGroup()
        }
    }

    private var discoverList: some View {
        VStack(spacing: 0) {
            if discovery.servers.isEmpty {
                HStack(spacing: 8) {
                    if discovery.state == .searching {
                        ProgressView().controlSize(.small)
                        Text("Searching the local network…")
                    } else if case let .failed(message) = discovery.state {
                        Text("Discovery unavailable: \(message)")
                    } else {
                        Text("No SMB servers found yet.")
                    }
                    Spacer()
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(12)
            } else {
                ForEach(discovery.servers) { server in
                    OnboardingShareRow(
                        symbol: "server.rack",
                        title: server.name,
                        detail: "macOS will ask you to sign in",
                        buttonTitle: "Connect…",
                        isBusy: busyID == server.id,
                        isDisabled: isConnecting
                    ) {
                        browse(id: server.id) { try await appModel.shareBrowserService.browse(server) }
                    }
                    if server.id != discovery.servers.last?.id { Divider().padding(.leading, 12) }
                }
            }
        }
        .onboardingGroup()
    }

    private var manualEntry: some View {
        HStack(spacing: 8) {
            TextField("Server address", text: $address, prompt: Text("smb://server.local/Share"))
                .textFieldStyle(.roundedBorder)
                .focused($addressFocused)
                .disableAutocorrection(true)
                .onSubmit(connectToAddress)
            Button(busyID == "manual" ? "Connecting…" : "Connect…", action: connectToAddress)
                .disabled(parsedAddress == nil || isConnecting)
        }
        .padding(12)
        .onboardingGroup()
    }

    private var successPage: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark")
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(.green)
                .frame(width: 80, height: 80)
                .background(Color.green.opacity(0.15), in: Circle())
                .accessibilityHidden(true)

            Text("\(connectedShare?.displayName ?? "Share") is connected")
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)

            Text("Otter will automatically reconnect this share when needed.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            if let share = connectedShare {
                HStack(spacing: 12) {
                    OnboardingSymbolTile(symbol: "externaldrive.fill", tint: .secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(share.displayName).font(.headline)
                        HStack(spacing: 5) {
                            Circle().fill(.green).frame(width: 7, height: 7)
                            Text("Connected").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 8)
                    Text(share.mountPath)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(12)
                .onboardingGroup()
                .padding(.horizontal, 40)
                .padding(.top, 8)
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func header(_ title: String, _ subtitle: String) -> some View {
        VStack(spacing: 6) {
            Text(title).font(.title.bold())
            Text(subtitle).font(.body).foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    // MARK: Chrome

    private var progressDots: some View {
        let current = step.progressIndex
        return HStack(spacing: 8) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(index == current ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 7, height: 7)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(current + 1) of 3")
    }

    @ViewBuilder
    private var footer: some View {
        HStack {
            switch step {
            case .welcome:
                Button("Skip Setup") { finish(selecting: nil) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                Spacer()
                Button { go(.preferences) } label: {
                    Label("Get Started", systemImage: "arrow.right").labelStyle(.titleAndTrailingIcon)
                }
                .onboardingPrimaryActionButton()
                .keyboardShortcut(.defaultAction)

            case .preferences:
                backButton(to: .welcome)
                Spacer()
                Button { go(.connect) } label: {
                    Label("Continue", systemImage: "arrow.right").labelStyle(.titleAndTrailingIcon)
                }
                .onboardingPrimaryActionButton()
                .keyboardShortcut(.defaultAction)

            case .connect:
                backButton(to: .preferences)
                    .disabled(isConnecting)
                Spacer()
                Button("Skip for Now") { finish(selecting: nil) }
                    .onboardingSecondaryActionButton()
                    .disabled(isConnecting)
                    .keyboardShortcut(.defaultAction)

            case .success:
                Button("Add Another Share") {
                    connectionMessage = nil
                    go(.connect)
                }
                .onboardingSecondaryActionButton()
                Spacer()
                Button("Start Using Otter") { finish(selecting: connectedShareID) }
                    .onboardingPrimaryActionButton()
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func backButton(to destination: Step) -> some View {
        Button { go(destination) } label: {
            Label("Back", systemImage: "arrow.left")
        }
        .onboardingSecondaryActionButton()
    }

    // MARK: Actions

    private func go(_ destination: Step) {
        withAnimation(.easeInOut(duration: 0.2)) { step = destination }
    }

    private func toggle(_ target: ConnectPanel) {
        connectionMessage = nil
        withAnimation(.easeInOut(duration: 0.2)) {
            panel = panel == target ? nil : target
        }
        if panel == .manual { addressFocused = true }
    }

    private func beginConnectStep() {
        discovery.start()
        Task {
            mountedShares = await Task.detached(priority: .userInitiated) {
                MountedShareSuggestion.discover()
            }.value
        }
        let keychainDiscovery = appModel.keychainShareDiscoveryService
        Task {
            savedShares = await Task.detached(priority: .userInitiated) {
                keychainDiscovery.savedShares()
            }.value
        }
    }

    /// The address as a saved-share location, so it can go through the same
    /// macOS sign-in as a Keychain entry.
    private var parsedAddress: SavedSMBShare? { OnboardingAddress.parse(address) }

    private func connectToAddress() {
        guard let target = parsedAddress else {
            connectionMessage = "Enter a server address such as smb://server.local/Share."
            return
        }
        connect(using: target, busyID: "manual")
    }

    private func connect(using saved: SavedSMBShare, busyID: String? = nil) {
        browse(id: busyID ?? saved.id) {
            guard let url = saved.connectionURL else { throw MountServiceError.invalidURL }
            guard await networkService.canReachServer(for: url, timeout: 2) else {
                throw OnboardingError.unreachable(saved.host)
            }
            return try await appModel.shareBrowserService.browse(saved)
        }
    }

    /// Runs a macOS mount (sign-in and share picker) and adopts whatever it
    /// mounted. Success is only shown once Otter reports the share connected.
    private func browse(id: String, _ work: @escaping () async throws -> [MountedShareSuggestion]) {
        guard busyID == nil else { return }
        busyID = id
        connectionMessage = nil

        Task {
            defer { busyID = nil }
            do {
                let suggestions = try await work()
                guard !suggestions.isEmpty else {
                    connectionMessage = "No share was selected."
                    return
                }
                await adopt(suggestions)
            } catch {
                connectionMessage = "Couldn't connect: \(error.localizedDescription)"
            }
        }
    }

    private func adopt(_ suggestions: [MountedShareSuggestion]) async {
        var adopted: [NetworkShare] = []
        for suggestion in suggestions {
            if let existing = settings.shares.first(where: { $0.mountPath == suggestion.mountPath }) {
                adopted.append(existing)
            } else if !settings.isDuplicateShare(urlString: suggestion.urlString) {
                let share = NetworkShare(
                    displayName: suggestion.displayName,
                    urlString: suggestion.urlString,
                    mountPath: suggestion.mountPath
                )
                settings.addShare(share)
                adopted.append(share)
            }
        }

        guard let share = adopted.first else {
            connectionMessage = "That share is already added."
            return
        }

        await monitor.mount(share)
        if monitor.status(for: share) == .connected {
            connectedShareID = share.id
            mountedShares.removeAll { $0.mountPath == share.mountPath }
            go(.success)
        } else {
            connectionMessage = "\(share.displayName) was added but isn't connected yet. Skip for now and check it in Otter."
        }
    }

    private func finish(selecting shareID: NetworkShare.ID?) {
        settings.completeOnboarding()
        onFinish(shareID.flatMap { settings.share(id: $0) })
        dismiss()
    }

    // MARK: Notifications

    private var notificationsDenied: Bool {
        notificationService.authorizationStatus == .denied
    }

    // The switch shows what will actually happen: on only when Otter wants to
    // notify and macOS has agreed, never on the strength of the preference
    // alone while permission is still undecided.
    private var notificationsBinding: Binding<Bool> {
        Binding(
            get: { settings.preferences.notificationsEnabled && notificationService.isAllowedByMacOS },
            set: { enabled in
                guard enabled else {
                    settings.updatePreferences { $0.notificationsEnabled = false }
                    return
                }

                if notificationsDenied {
                    // macOS will not ask twice; only System Settings can undo a refusal.
                    settings.updatePreferences { $0.notificationsEnabled = true }
                    notificationService.openSystemNotificationSettings()
                } else {
                    requestNotificationPermission()
                }
            }
        )
    }

    /// Asks macOS for permission and keeps the preference in step with the answer.
    private func requestNotificationPermission() {
        settings.updatePreferences { $0.notificationsEnabled = true }
        guard notificationService.canAskForAuthorization else { return }

        Task {
            let granted = await notificationService.requestAuthorization()
            if !granted {
                settings.updatePreferences { $0.notificationsEnabled = false }
            }
        }
    }
}

// MARK: - Flow helpers

enum OnboardingStep: Int, CaseIterable {
    case welcome, preferences, connect, success

    /// The success screen keeps the last progress dot lit.
    var progressIndex: Int { min(rawValue, Self.connect.rawValue) }
}

enum OnboardingAddress {
    /// Reads a typed server address as a saved-share location, so it can go
    /// through the same macOS sign-in as a Keychain entry. Addresses carrying
    /// credentials or a non-SMB scheme are rejected.
    static func parse(_ input: String) -> SavedSMBShare? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.hasPrefix("//") { text = "smb:" + text }
        if !text.contains("://") { text = "smb://" + text }
        guard let components = URLComponents(string: text),
              components.scheme?.lowercased() == "smb",
              let host = components.host,
              components.user == nil, components.password == nil
        else { return nil }
        return SavedSMBShare(host: host, path: components.path, port: components.port)
    }
}

// MARK: - Components

private struct OnboardingSymbolTile: View {
    let symbol: String
    let tint: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.title3)
            .foregroundStyle(tint)
            .frame(width: 40, height: 40)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .accessibilityHidden(true)
    }
}

private struct OnboardingPreferenceRow: View {
    let symbol: String
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            OnboardingSymbolTile(symbol: symbol, tint: .accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
    }
}

private struct OnboardingMethodRow: View {
    let symbol: String
    let title: String
    let detail: String
    let isHighlighted: Bool
    var isExpanded = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                OnboardingSymbolTile(symbol: symbol, tint: isHighlighted ? .accentColor : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isHighlighted ? Color.accentColor.opacity(0.1) : Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isHighlighted ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.08), lineWidth: isHighlighted ? 1.5 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct OnboardingShareRow: View {
    let symbol: String
    let title: String
    let detail: String
    let buttonTitle: String
    let isBusy: Bool
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            OnboardingSymbolTile(symbol: symbol, tint: .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if isBusy {
                ProgressView().controlSize(.small)
            } else {
                Button(buttonTitle, action: action)
                    .disabled(isDisabled)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

private enum OnboardingError: LocalizedError {
    case unreachable(String)

    var errorDescription: String? {
        switch self {
        case let .unreachable(host):
            "\(host) isn't reachable on the current network."
        }
    }
}

private struct TitleAndTrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.title
            configuration.icon
        }
    }
}

private extension LabelStyle where Self == TitleAndTrailingIconLabelStyle {
    static var titleAndTrailingIcon: TitleAndTrailingIconLabelStyle { .init() }
}

private extension View {
    func onboardingGroup() -> some View {
        self
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
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
            .interpolation(.high)
            .antialiased(true)
            .scaledToFit()
            .id(colorScheme)
    }

    static func image(for colorScheme: ColorScheme, bundle: Bundle = .main) -> NSImage? {
        let resourceName = colorScheme == .dark ? "otter-icon-dark" : "otter-icon-light"
        guard let url = bundle.url(forResource: resourceName, withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }
}
