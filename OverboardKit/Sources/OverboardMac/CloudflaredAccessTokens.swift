import Foundation
import os

/// Looks up a cached Cloudflare Access JWT for a URL by shelling out to the
/// user's own `cloudflared` CLI — `cloudflared access token --app <origin>`
/// prints whatever token that CLI already has cached for the app and, unlike
/// `cloudflared access curl`, never opens a browser to start a fresh login.
/// That "never prompts" property is the whole point here: link-preview
/// fetching runs unattended on a background timer, on whichever of the
/// user's two laptops happens to reach a given internal host, and must never
/// pop a login window the user didn't ask for.
///
/// An actor because lookups race: the link backfill (`AppServices+Capture.swift`)
/// can hand this 25 links from the same Access-gated host in one batch, and
/// without coalescing that's 25 `cloudflared` processes for one answer.
public actor CloudflaredAccessTokens {
    public static let shared = CloudflaredAccessTokens()

    private static let logger = Logger(subsystem: "com.nickysemenza.overboard", category: "cloudflared-access")

    /// How long a successful lookup is trusted before asking `cloudflared`
    /// again. Shorter than the JWT's own lifetime (cloudflared access tokens
    /// are typically valid for hours), so this is purely about not spawning a
    /// process per link during a backfill burst, not about respecting the
    /// JWT's actual expiry.
    private static let positiveTTL: TimeInterval = 5 * 60
    /// Held longer than the positive TTL. Lookups only happen after an
    /// Access challenge, so a miss means this machine has no cached login
    /// for the host (the other laptop, or `cloudflared access login` never
    /// run) — and that isn't going to change in the next few minutes, while a
    /// backfill batch may hold many links from that host.
    private static let negativeTTL: TimeInterval = 10 * 60
    /// `cloudflared access token` should return near-instantly (it reads a
    /// local credential cache, no network round trip for a cache hit) or not
    /// at all (hung daemon, broken install). Past this, treat it as absent
    /// rather than block the caller indefinitely.
    private static let processTimeout: TimeInterval = 8

    private struct CacheEntry {
        let token: String?
        let expiresAt: Date
    }

    private var cache: [String: CacheEntry] = [:]
    /// In-flight lookups keyed by origin, so concurrent callers for the same
    /// origin await one process instead of each spawning their own.
    private var inFlight: [String: Task<String?, Never>] = [:]

    public init() {}

    // MARK: - Public API

    /// A cached Access JWT for `url`'s origin, or nil if `cloudflared` isn't
    /// installed, has no cached token for this app, or the lookup failed or
    /// timed out. Never throws and never blocks longer than
    /// `processTimeout` — every failure mode here is meant to be silent, per
    /// the fetcher's "a link works fine without a preview" philosophy.
    public func token(for url: URL) async -> String? {
        guard let origin = Self.origin(for: url) else { return nil }

        let now = Date()
        if let cached = self.cache[origin], cached.expiresAt > now {
            return cached.token
        }

        if let existing = self.inFlight[origin] {
            return await existing.value
        }

        // Detached so the actual process wait runs off this actor's executor —
        // the actor stays free to serve cache hits for other origins (or to
        // hand the *same* in-flight task to other callers below) while this
        // one is parked on the child process.
        let task = Task<String?, Never>.detached(priority: .utility) {
            await Self.lookUpToken(origin: origin)
        }
        self.inFlight[origin] = task
        let token = await task.value
        self.inFlight[origin] = nil

        self.cache[origin] = CacheEntry(
            token: token,
            expiresAt: now.addingTimeInterval(token != nil ? Self.positiveTTL : Self.negativeTTL)
        )
        if token == nil {
            Self.logger.debug("no token for \(origin, privacy: .public)")
        }
        return token
    }

    /// `scheme://host[:port]` — the granularity `cloudflared access token
    /// --app` expects and the granularity Access itself gates on (path
    /// doesn't matter to Access, only the app's hostname).
    static func origin(for url: URL) -> String? {
        guard let scheme = url.scheme, let host = url.host else { return nil }
        if let port = url.port {
            return "\(scheme)://\(host):\(port)"
        }
        return "\(scheme)://\(host)"
    }

    // MARK: - Executable lookup

    private static let candidatePaths = [
        "/opt/homebrew/bin/cloudflared",
        "/usr/local/bin/cloudflared",
        "/usr/bin/cloudflared",
    ]

    public nonisolated static func isInstalled() -> Bool {
        self.executableURL() != nil
    }

    /// First existing `cloudflared` on a short list of common Homebrew/system
    /// install locations, falling back to a `$PATH` scan — mirrors
    /// `GhosttyLauncher`'s "check well-known locations first" shape, but
    /// `cloudflared` (a CLI, not an `.app`) has no `NSWorkspace` bundle
    /// lookup to lean on, so this walks `PATH` by hand instead.
    public nonisolated static func executableURL() -> URL? {
        self.executableURL(
            searchPaths: self.candidatePaths,
            environment: ProcessInfo.processInfo.environment
        )
    }

    /// Testable overload: `searchPaths` stands in for the fixed candidate
    /// list, `environment` for `ProcessInfo.processInfo.environment`.
    nonisolated static func executableURL(searchPaths: [String], environment: [String: String]) -> URL? {
        let fileManager = FileManager.default
        for path in searchPaths where fileManager.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        guard let pathVariable = environment["PATH"] else { return nil }
        for directory in pathVariable.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent("cloudflared")
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    // MARK: - Process execution

    private static func lookUpToken(origin: String) async -> String? {
        guard let executableURL = self.executableURL() else { return nil }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["access", "token", "--app", origin]

        var environment = ProcessInfo.processInfo.environment
        // LaunchServices-launched apps don't reliably inherit a login-shell
        // environment (see `GhosttyLauncher.loginShell`'s comment); `HOME` is
        // the one variable `cloudflared` needs to find its credential cache,
        // so it's made explicit rather than trusted to already be set.
        if environment["HOME"] == nil {
            environment["HOME"] = NSHomeDirectory()
        }
        process.environment = environment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        // Drained on background queues so the child can't block writing to a
        // full pipe while nothing is reading it.
        stderr.fileHandleForReading.readabilityHandler = { handle in _ = handle.availableData }

        return await withCheckedContinuation { continuation in
            let state = OSAllocatedUnfairLock(initialState: false) // has-resumed guard
            @Sendable func resume(_ value: String?) {
                let shouldResume = state.withLock { hasResumed in
                    guard !hasResumed else { return false }
                    hasResumed = true
                    return true
                }
                guard shouldResume else { return }
                stderr.fileHandleForReading.readabilityHandler = nil
                continuation.resume(returning: value)
            }

            process.terminationHandler = { _ in
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                // Only the JWT shape counts as success. `cloudflared`'s
                // "failed to find Access application" / "Unable to find
                // token" messages have moved between stdout and stderr and
                // between exit codes across versions (2026.9.1: stderr,
                // exit 1), so neither the exit code nor "stdout non-empty"
                // is a reliable signal.
                resume(self.isJWTShaped(output) ? output : nil)
            }

            do {
                try process.run()
            } catch {
                resume(nil)
                return
            }

            Task.detached(priority: .utility) {
                try? await Task.sleep(for: .seconds(Self.processTimeout))
                if process.isRunning {
                    process.terminate()
                }
                resume(nil)
            }
        }
    }

    /// A cloudflared access token is a compact JWT: three base64url segments
    /// (header, payload, signature) joined by `.`, none of them empty. This
    /// is the actual validation — see `lookUpToken`'s comment on why the exit
    /// code and stdout-non-empty checks aren't enough on their own.
    nonisolated static func isJWTShaped(_ string: String) -> Bool {
        let segments = string.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3 else { return false }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")
        return segments.allSatisfy { segment in
            !segment.isEmpty && segment.unicodeScalars.allSatisfy(allowed.contains)
        }
    }
}
