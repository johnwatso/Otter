import Combine
import Foundation
import Sparkle

// Sparkle keeps this delegate weakly. UpdaterViewModel owns it for the
// lifetime of the updater and declares that the standard user driver may use
// its gentle scheduled-update behavior for Otter's dockless menu-bar app.
private final class UpdateReminderDelegate: NSObject, SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }
}

// Thin observable wrapper around Sparkle's updater so SwiftUI views can bind
// to it. Sparkle owns the whole update flow: checking the appcast, verifying
// the EdDSA signature, downloading, installing, and relaunching.
@MainActor
final class UpdaterViewModel: ObservableObject {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var lastUpdateCheckDate: Date?

    private let updaterController: SPUStandardUpdaterController
    private let reminderDelegate: UpdateReminderDelegate

    var updater: SPUUpdater {
        updaterController.updater
    }

    init(startingUpdater: Bool = true) {
        let reminderDelegate = UpdateReminderDelegate()
        self.reminderDelegate = reminderDelegate
        updaterController = SPUStandardUpdaterController(
            startingUpdater: startingUpdater,
            updaterDelegate: nil,
            userDriverDelegate: reminderDelegate
        )

        updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .assign(to: &$canCheckForUpdates)

        lastUpdateCheckDate = updater.lastUpdateCheckDate
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
        }
    }

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
    }

    var currentBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
    }
}
