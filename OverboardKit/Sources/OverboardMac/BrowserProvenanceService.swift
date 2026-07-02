import AppKit
import Foundation
import os
import OverboardCore

/// The page a browser copy came from: the front tab's URL and (optional) title.
public struct SourceProvenance: Sendable, Equatable {
    public let url: String
    public let title: String?

    public init(url: String, title: String?) {
        self.url = url
        self.title = title
    }
}

/// Reads a browser's front-tab URL/title via AppleScript so a copy can carry a
/// link back to where it came from. Mirrors `SpotifyNowPlayingMonitor`'s house
/// pattern: NSAppleScript on a private serial queue, silent nil on any error.
public enum BrowserProvenanceService {
    private static let scriptQueue = DispatchQueue(label: "com.nickysemenza.overboard.browser-provenance")

    /// Bundle IDs whose Automation permission the user has denied (TCC -1743).
    /// Cached for the process lifetime so we stop round-tripping to a browser
    /// that will only deny us again. Behind a lock — `fetch` runs off any actor.
    private static let deniedBundleIDs = OSAllocatedUnfairLock(initialState: Set<String>())

    /// Fetches the front-tab provenance for a browser copy, or nil when the app
    /// isn't a scriptable browser, isn't running, has denied Automation, or the
    /// front tab has no usable http(s) URL. Never relaunches a quit browser, and
    /// never blocks longer than `timeout`.
    public static func fetch(bundleID: String, timeout: Duration = .milliseconds(500)) async -> SourceProvenance? {
        guard let dialect = BrowserScript.dialect(forBundleID: bundleID) else { return nil }
        // A quit browser must not be relaunched by the Apple Event we're about
        // to send, so skip anything that isn't already running.
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty else { return nil }
        // The user already said no — don't prompt or round-trip again this run.
        if self.deniedBundleIDs.withLock({ $0.contains(bundleID) }) { return nil }

        let source = BrowserScript.source(for: dialect, bundleID: bundleID)

        // Race the script against the timeout: whichever finishes first wins.
        // The loser is cancelled, but the continuation is single-resume-safe so
        // a late script completion can never resume it twice.
        let line: String? = await withTaskGroup(of: String?.self) { group in
            group.addTask { await self.runScript(source, bundleID: bundleID) }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }

        guard let line else { return nil }
        return self.parse(line)
    }

    /// Runs the provenance AppleScript on the private serial queue and bridges
    /// the completion back with a checked continuation. Returns the raw
    /// "URL\ttitle" line, "" when the browser has no windows, or nil on error
    /// (Automation denied, script failure). Caches TCC denials per bundle id.
    private static func runScript(_ source: String, bundleID: String) async -> String? {
        await withCheckedContinuation { continuation in
            self.scriptQueue.async {
                guard let script = NSAppleScript(source: source) else {
                    continuation.resume(returning: nil)
                    return
                }
                var error: NSDictionary?
                let output = script.executeAndReturnError(&error)
                if let error {
                    // -1743: user denied Automation for this app. Remember it so
                    // we stop asking (and stop re-triggering the TCC prompt).
                    if (error[NSAppleScript.errorNumber] as? Int) == -1743 {
                        self.deniedBundleIDs.withLock { _ = $0.insert(bundleID) }
                    }
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: output.stringValue ?? "")
            }
        }
    }

    /// Parses a "URL\ttitle" line into a `SourceProvenance`, discarding results
    /// whose URL isn't http(s) with a host — this filters out empty results,
    /// `about:blank`, and AppleScript's "missing value". An empty title becomes
    /// nil rather than "".
    static func parse(_ line: String) -> SourceProvenance? {
        let fields = line.components(separatedBy: "\t")
        guard let rawURL = fields.first else { return nil }
        let urlString = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty
        else { return nil }

        let title = fields.count > 1
            ? fields[1].trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        return SourceProvenance(url: urlString, title: title.isEmpty ? nil : title)
    }
}
