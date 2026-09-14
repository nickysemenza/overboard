import Defaults
import OverboardCore
import OverboardMac
import SwiftUI

/// One host's probed sign-in state, refreshed every time the section appears
/// (or a host is added) — "Checking…" until the first `hasCachedToken` probe
/// answers.
private enum HostSignInStatus: Equatable {
    case checking
    case signedIn
    case needsSignIn
}

/// What a host row is doing right now, so its button/progress state reflects
/// an in-flight action instead of a stale probe result.
private enum HostActivity: Equatable {
    case idle
    case signingIn
    case refreshingPreviews
}

/// Settings › General › Cloudflare Access: every origin Overboard has seen
/// challenge a link fetch on this Mac, with its live sign-in status and a way
/// to sign in (or re-sign in) without leaving Overboard. `GeneralSettingsTab`
/// only includes this section when `CloudflaredAccessTokens.isInstalled()` —
/// without `cloudflared` there's nothing here to sign in to.
struct CloudflareAccessSection: View {
    let enrichment: ClipEnrichmentPipeline

    @Default(.cloudflareAccessHosts) private var hosts
    @State private var statuses: [String: HostSignInStatus] = [:]
    @State private var activity: [String: HostActivity] = [:]
    @State private var failedOrigins: Set<String> = []

    var body: some View {
        Section {
            if self.hosts.isEmpty {
                Text("No links behind Cloudflare Access yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(self.hosts) { host in
                    CloudflareAccessHostRow(
                        host: host,
                        status: self.statuses[host.origin] ?? .checking,
                        activity: self.activity[host.origin] ?? .idle,
                        didFail: self.failedOrigins.contains(host.origin),
                        isAnyActionRunning: self.isAnyActionRunning,
                        onSignIn: { await self.signIn(origin: host.origin) },
                        onForget: { self.forget(origin: host.origin) }
                    )
                }
                if self.hostsNeedingSignIn.count >= 2 {
                    Button("Sign in to all") {
                        Task { await self.signInToAll() }
                    }
                    .disabled(self.isAnyActionRunning)
                }
            }
        } header: {
            Text("Cloudflare Access")
        }
        .task(id: self.hosts.map(\.origin)) {
            await self.probeAllStatuses()
        }
    }

    private var isAnyActionRunning: Bool {
        self.activity.values.contains { $0 != .idle }
    }

    private var hostsNeedingSignIn: [CloudflareAccessHost] {
        self.hosts.filter { self.statuses[$0.origin] == .needsSignIn }
    }

    /// Probes every host concurrently — each is a cheap read of `cloudflared`'s
    /// local credential cache, no network round trip — so status doesn't wait
    /// on hosts one at a time the way sign-in has to.
    private func probeAllStatuses() async {
        await withTaskGroup(of: (String, HostSignInStatus).self) { group in
            for host in self.hosts {
                group.addTask {
                    let hasToken = await CloudflaredAccessTokens.shared.hasCachedToken(origin: host.origin)
                    return (host.origin, hasToken ? .signedIn : .needsSignIn)
                }
            }
            for await (origin, status) in group {
                self.statuses[origin] = status
            }
        }
    }

    /// Runs one host's sign-in flow: `cloudflared access login` (opens the
    /// browser), then — on success — re-fetches every link under that origin
    /// so a card's real title shows up without waiting for the next launch's
    /// backfill.
    private func signIn(origin: String) async {
        self.failedOrigins.remove(origin)
        self.activity[origin] = .signingIn
        let success = await CloudflaredAccessTokens.shared.login(origin: origin)
        guard success else {
            self.failedOrigins.insert(origin)
            self.activity[origin] = .idle
            return
        }
        self.statuses[origin] = .signedIn
        self.activity[origin] = .refreshingPreviews
        await self.enrichment.refetchLinkMetadata(origin: origin)
        self.activity[origin] = .idle
    }

    /// `cloudflared access login` blocks on the user finishing one browser
    /// tab before the next can start, so "Sign in to all" runs one host at a
    /// time rather than concurrently.
    private func signInToAll() async {
        for host in self.hostsNeedingSignIn {
            await self.signIn(origin: host.origin)
        }
    }

    private func forget(origin: String) {
        self.hosts.removeAll { $0.origin == origin }
        self.statuses[origin] = nil
        self.activity[origin] = nil
        self.failedOrigins.remove(origin)
    }
}

/// One host row: its display name, live status pill, and either a
/// Sign in / Sign in again button or an in-progress indicator — plus a
/// hover-revealed "Forget" to drop it from the list.
private struct CloudflareAccessHostRow: View {
    let host: CloudflareAccessHost
    let status: HostSignInStatus
    let activity: HostActivity
    let didFail: Bool
    let isAnyActionRunning: Bool
    let onSignIn: () async -> Void
    let onForget: () -> Void

    @State private var isHovering = false

    var body: some View {
        LabeledContent {
            HStack(spacing: 10) {
                self.trailingContent
                if self.isHovering, self.activity == .idle {
                    Button {
                        self.onForget()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Forget this host")
                    .accessibilityLabel("Forget \(self.host.host)")
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(self.host.host)
                if self.didFail {
                    Text("Sign-in didn’t complete")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .onHover { self.isHovering = $0 }
    }

    @ViewBuilder
    private var trailingContent: some View {
        switch self.activity {
        case .signingIn:
            Self.progressLabel("Signing in…")
        case .refreshingPreviews:
            Self.progressLabel("Refreshing previews…")
        case .idle:
            HStack(spacing: 10) {
                HostStatusPill(status: self.status)
                Button(self.status == .signedIn ? "Sign in again" : "Sign in") {
                    Task { await self.onSignIn() }
                }
                .disabled(self.isAnyActionRunning || self.status == .checking)
            }
        }
    }

    private static func progressLabel(_ text: String) -> some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text(text).foregroundStyle(.secondary)
        }
    }
}

/// A host's sign-in status as the same compact status line used elsewhere in
/// Settings (`PermissionStatusPill`, `AIAvailabilityPill`).
private struct HostStatusPill: View {
    let status: HostSignInStatus

    var body: some View {
        StatusPill(title: self.title, symbolName: self.symbolName, tint: self.tint)
    }

    private var title: String {
        switch self.status {
        case .checking: "Checking…"
        case .signedIn: "Signed in"
        case .needsSignIn: "Needs sign-in"
        }
    }

    private var symbolName: String {
        switch self.status {
        case .checking: "ellipsis.circle"
        case .signedIn: "checkmark.circle.fill"
        case .needsSignIn: "exclamationmark.circle.fill"
        }
    }

    private var tint: Color {
        switch self.status {
        case .checking: .secondary
        case .signedIn: .green
        case .needsSignIn: .orange
        }
    }
}

#if DEBUG
    #Preview("Cloudflare Access") {
        let store = Fixtures.previewStore()
        Defaults[.cloudflareAccessHosts] = [
            CloudflareAccessHost(
                origin: "https://wiki.cfdata.org", firstSeen: Fixtures.date, lastChallenged: Fixtures.referenceDate
            ),
            CloudflareAccessHost(
                origin: "https://team.example.com", firstSeen: Fixtures.date, lastChallenged: Fixtures.date,
                lastSignedIn: Fixtures.date
            ),
        ]
        return Form {
            CloudflareAccessSection(enrichment: Fixtures.noOpEnrichmentPipeline(store: store))
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 320)
    }
#endif
