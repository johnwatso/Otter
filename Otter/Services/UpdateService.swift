import Foundation

@MainActor
final class UpdateService: ObservableObject {
    @Published private(set) var isChecking = false
    @Published private(set) var updateAvailable = false
    @Published private(set) var latestVersion: String?
    @Published private(set) var lastCheckedAt: Date?
    @Published private(set) var lastCheckError: String?
    @Published private(set) var releaseURL = UpdateService.releasesPageURL

    static let releasesPageURL = URL(string: "https://github.com/johnwatso/Otter/releases/latest")!
    private static let latestReleaseAPIURL = URL(string: "https://api.github.com/repos/johnwatso/Otter/releases/latest")!

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    func checkForUpdates() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        var request = URLRequest(url: Self.latestReleaseAPIURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }

            guard httpResponse.statusCode == 200 else {
                lastCheckError = httpResponse.statusCode == 404
                    ? "No releases published yet."
                    : "GitHub returned status \(httpResponse.statusCode)."
                return
            }

            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            latestVersion = release.tagName
            releaseURL = release.htmlURL ?? Self.releasesPageURL
            updateAvailable = Self.isVersion(release.tagName, newerThan: currentVersion)
            lastCheckedAt = Date()
            lastCheckError = nil
        } catch {
            lastCheckError = error.localizedDescription
        }
    }

    // Compares dotted numeric versions, tolerating a leading "v" and suffixes
    // like "-beta" ("v0.10.1" > "0.9", "0.2" == "0.2.0").
    nonisolated static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        let candidateComponents = numericComponents(of: candidate)
        let currentComponents = numericComponents(of: current)

        for index in 0..<max(candidateComponents.count, currentComponents.count) {
            let candidateValue = index < candidateComponents.count ? candidateComponents[index] : 0
            let currentValue = index < currentComponents.count ? currentComponents[index] : 0

            if candidateValue != currentValue {
                return candidateValue > currentValue
            }
        }

        return false
    }

    private nonisolated static func numericComponents(of version: String) -> [Int] {
        version
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .drop(while: { $0 == "v" || $0 == "V" })
            .split(separator: ".")
            .map { component in
                Int(component.prefix(while: \.isNumber)) ?? 0
            }
    }
}

private struct GitHubRelease: Decodable {
    let tagName: String
    let htmlURL: URL?

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
    }
}
