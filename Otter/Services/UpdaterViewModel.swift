import Combine
import Foundation
import Sparkle

// Sparkle keeps this delegate weakly. UpdaterViewModel owns it for the
// lifetime of the updater and declares that the standard user driver may use
// its gentle scheduled-update behavior for Otter's dockless menu-bar app.
private final class UpdateReminderDelegate: NSObject, SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }
}

// Sparkle stages a silently-downloaded update to install "on quit". Otter is a
// menu-bar app that can run for weeks, so that moment may never come and an
// unattended update would sit downloaded forever. This delegate takes over:
// it always installs in place, and the configured policy only decides when.
private final class UpdateInstallDelegate: NSObject, SPUUpdaterDelegate {
    /// Reads the current policy. Set by UpdaterViewModel.
    var installPolicy: @MainActor () -> (AutoUpdateInstallPolicy, Int) = { (.whenIdle, 3) }
    /// Answers whether relaunching right now would interrupt work in flight.
    var isSafeToInstallNow: @MainActor () -> Bool = { true }
    /// Reports the version and a human-readable description of when it lands.
    var onScheduledInstall: (@MainActor (String, String) -> Void)?

    /// A nonstop app must not be able to defer an update forever.
    private static let deferralLimit: TimeInterval = 24 * 60 * 60
    private static let pollInterval: Duration = .seconds(60)

    func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock: @escaping () -> Void
    ) -> Bool {
        let version = item.displayVersionString

        Task { @MainActor in
            let (policy, hour) = installPolicy()

            switch policy {
            case .immediate:
                onScheduledInstall?(version, "installing now")

            case .whenIdle:
                if isSafeToInstallNow() {
                    onScheduledInstall?(version, "Otter is idle — installing now")
                } else {
                    onScheduledInstall?(version, "waiting until Otter is idle (installs within 24 hours regardless)")
                    let deadline = Date().addingTimeInterval(Self.deferralLimit)
                    while Date() < deadline, !isSafeToInstallNow() {
                        try? await Task.sleep(for: Self.pollInterval)
                    }
                }

            case .scheduled:
                if let target = Calendar.current.nextDate(
                    after: Date(),
                    matching: DateComponents(hour: hour, minute: 0),
                    matchingPolicy: .nextTime
                ) {
                    onScheduledInstall?(version, "installing at \(target.formatted(date: .omitted, time: .shortened))")
                    // One-minute steps so a Mac sleeping through a single long
                    // sleep cannot overshoot the window by hours.
                    while Date() < target {
                        try? await Task.sleep(for: Self.pollInterval)
                    }
                } else {
                    onScheduledInstall?(version, "installing now")
                }
            }

            immediateInstallationBlock()
        }

        return true
    }
}

// Thin observable wrapper around Sparkle's updater so SwiftUI views can bind
// to it. Sparkle owns the whole update flow: checking the appcast, verifying
// the EdDSA signature, downloading, installing, and relaunching.
@MainActor
final class UpdaterViewModel: ObservableObject {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var lastUpdateCheckDate: Date?
    /// Set when Sparkle has an update downloaded and this view model is holding
    /// it back until the configured install moment.
    @Published private(set) var pendingInstallDescription: String?

    private let updaterController: SPUStandardUpdaterController
    private let reminderDelegate: UpdateReminderDelegate
    private let installDelegate: UpdateInstallDelegate
    private var automaticDownloadsObservation: NSKeyValueObservation?

    /// False when the bundle has no appcast URL or no public key, which is the
    /// case for unsigned local builds. The UI explains itself instead of
    /// offering controls that cannot work.
    let isConfigured: Bool

    var updater: SPUUpdater {
        updaterController.updater
    }

    init(
        startingUpdater: Bool = true,
        settings: SettingsStore? = nil,
        isSafeToInstallNow: (@MainActor () -> Bool)? = nil
    ) {
        let feedURL = (Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let publicKey = (Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        isConfigured = !feedURL.isEmpty && !publicKey.isEmpty

        let reminderDelegate = UpdateReminderDelegate()
        let installDelegate = UpdateInstallDelegate()
        self.reminderDelegate = reminderDelegate
        self.installDelegate = installDelegate

        updaterController = SPUStandardUpdaterController(
            startingUpdater: startingUpdater,
            updaterDelegate: installDelegate,
            userDriverDelegate: reminderDelegate
        )

        updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .assign(to: &$canCheckForUpdates)

        lastUpdateCheckDate = updater.lastUpdateCheckDate

        if let settings {
            installDelegate.installPolicy = {
                (settings.preferences.autoUpdateInstallPolicy, settings.preferences.autoUpdateInstallHour)
            }
        }

        if let isSafeToInstallNow {
            installDelegate.isSafeToInstallNow = isSafeToInstallNow
        }

        installDelegate.onScheduledInstall = { [weak self] version, timing in
            self?.pendingInstallDescription = "Otter \(version) is ready — \(timing)."
        }

        // Sparkle stores this in its own defaults, so mirror changes made
        // anywhere (including by Sparkle's own prompts) back into the UI.
        automaticDownloadsObservation = updater.observe(
            \.automaticallyDownloadsUpdates,
            options: [.initial, .new]
        ) { [weak self] _, _ in
            Task { @MainActor in
                self?.objectWillChange.send()
            }
        }
    }

    func checkForUpdates() {
        updater.checkForUpdates()
        lastUpdateCheckDate = updater.lastUpdateCheckDate
    }

    var automaticallyChecksForUpdates: Bool {
        get { updater.automaticallyChecksForUpdates }
        set {
            objectWillChange.send()
            updater.automaticallyChecksForUpdates = newValue
            // Sparkle ignores unattended downloads when checks are off; keep
            // the stored value honest so the UI never claims otherwise.
            if !newValue {
                updater.automaticallyDownloadsUpdates = false
            }
        }
    }

    /// Sparkle's "download and install without asking". Only meaningful while
    /// automatic checks are on.
    var automaticallyDownloadsUpdates: Bool {
        get { updater.automaticallyDownloadsUpdates }
        set {
            objectWillChange.send()
            updater.automaticallyDownloadsUpdates = newValue
        }
    }

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
    }

    var currentBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
    }
}
