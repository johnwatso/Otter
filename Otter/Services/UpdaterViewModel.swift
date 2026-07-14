import Combine
import Foundation
import Sparkle

// Thin observable wrapper around Sparkle's updater so SwiftUI views can bind
// to it. Sparkle owns the whole update flow: checking the appcast, verifying
// the EdDSA signature, downloading, installing, and relaunching.
@MainActor
final class UpdaterViewModel: ObservableObject {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var lastUpdateCheckDate: Date?

    private let updaterController: SPUStandardUpdaterController

    var updater: SPUUpdater {
        updaterController.updater
    }

    init(startingUpdater: Bool = true) {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: startingUpdater,
            updaterDelegate: nil,
            userDriverDelegate: nil
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
