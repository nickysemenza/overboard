import AppKit
import Foundation
import os
import OverboardCore
import OverboardMac

/// Polls the GitHub Releases API and, when a newer tag than this build exists,
/// exposes it so the menu bar can offer a one-click download. Install stays
/// manual (unsigned zips, no Sparkle) — this only closes the "I never knew a
/// release shipped" gap.
@MainActor
@Observable
final class UpdateChecker {
    /// The newer release tag when one is available, else nil.
    private(set) var availableTag: String?
    /// Where to send the user to download it.
    private(set) var releaseURL: URL?

    private let logger = Logger(subsystem: "com.nickysemenza.overboard", category: "updates")
    private var pollTask: Task<Void, Never>?

    private static let latestReleaseURL =
        URL(string: "https://api.github.com/repos/nickysemenza/overboard/releases/latest")!
    private static let pollInterval: Duration = .seconds(24 * 3600)

    /// Kicks off an immediate check, then rechecks daily. No-op when disabled.
    func start() {
        guard self.pollTask == nil else { return }
        self.pollTask = Task { [weak self] in
            while !Task.isCancelled {
                if Defaults[.updateCheckEnabled] {
                    await self?.checkOnce()
                }
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    func stop() {
        self.pollTask?.cancel()
        self.pollTask = nil
    }

    /// Opens the release page and clears the badge (the user has been told).
    func openReleasePage() {
        guard let releaseURL else { return }
        NSWorkspace.shared.open(releaseURL)
    }

    private func checkOnce() async {
        do {
            var request = URLRequest(url: Self.latestReleaseURL)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 15
            let (data, _) = try await URLSession.shared.data(for: request)
            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)

            if let newer = UpdateCheck.newerRelease(current: AppVersion.marketing, latestTag: release.tagName) {
                self.availableTag = newer
                self.releaseURL = URL(string: release.htmlURL)
            } else {
                self.availableTag = nil
                self.releaseURL = nil
            }
        } catch {
            // Offline / rate-limited / no releases yet — silently try again next cycle.
            self.logger.debug("update check failed: \(String(describing: error), privacy: .public)")
        }
    }
}

private struct GitHubRelease: Decodable {
    let tagName: String
    let htmlURL: String

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
    }
}
