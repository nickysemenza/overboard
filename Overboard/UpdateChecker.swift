import AppKit
import Foundation
import os
import OverboardCore
import OverboardMac

/// Polls the GitHub Releases API and, when a newer tag than this build exists,
/// exposes it so the menu bar can offer a one-click download. Install stays
/// manual (no Sparkle) — this only closes the "I never knew a
/// release shipped" gap.
@Observable
final class UpdateChecker {
    /// The newer release tag when one is available, else nil.
    private(set) var availableTag: String?
    /// Where to send the user to download it.
    private(set) var releaseURL: URL?

    private let logger = Logger(subsystem: "com.nickysemenza.overboard", category: "updates")
    private var pollTask: Task<Void, Never>?

    /// Ephemeral, no cookies/cache: same reasoning as LinkMetadataFetcher (see
    /// OverboardKit/Sources/OverboardCore/Links/LinkMetadataFetcher.swift) —
    /// this is a background API poll, not a browsing session, so it shouldn't
    /// persist cookies or leave a cache entry on disk.
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

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
        self.availableTag = nil
    }

    private func checkOnce() async {
        do {
            var request = URLRequest(url: Self.latestReleaseURL)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 15
            let (data, response) = try await self.session.data(for: request)

            let statusCode = (response as? HTTPURLResponse)?.statusCode
            guard statusCode == 200 else {
                // Distinguishes a GitHub rate-limit (403) or other API hiccup
                // from being offline, which throws instead and lands below.
                self.logger.info("update check got status \(statusCode ?? -1, privacy: .public), skipping")
                return
            }

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
