import Foundation
@testable import OverboardMac
import Testing

/// `CloudflareAccessHost`'s pure logic — the upsert/ordering/cap decision
/// behind `CloudflaredAccessTokens.token(for:)`'s `Defaults` write, and the
/// once-per-launch HUD-hint gate — tested without an actor instance or a
/// real `cloudflared`. Actual process-shelling behavior (`token`,
/// `hasCachedToken`, `login`) lives in `CloudflaredAccessTokensTests.swift`
/// and isn't unit-tested here: it needs a real `cloudflared` binary (or a
/// fake one on `PATH`) and, for `login`, would pop a real browser.
struct CloudflareAccessHostTests {
    private func host(_ origin: String, firstSeen: Date, lastChallenged: Date, lastSignedIn: Date? = nil)
        -> CloudflareAccessHost
    {
        CloudflareAccessHost(
            origin: origin, firstSeen: firstSeen, lastChallenged: lastChallenged, lastSignedIn: lastSignedIn
        )
    }

    // MARK: - Display

    @Test func hostStripsTheScheme() {
        #expect(self.host("https://wiki.cfdata.org", firstSeen: .now, lastChallenged: .now).host == "wiki.cfdata.org")
        #expect(self.host("http://a.b:8443", firstSeen: .now, lastChallenged: .now).host == "a.b:8443")
    }

    @Test func hostFallsBackToTheWholeOriginWithoutAScheme() {
        #expect(CloudflareAccessHost.host(fromOrigin: "not-a-url") == "not-a-url")
    }

    // MARK: - recordChallenge

    @Test func recordChallengeAppendsANewHost() {
        let now = Date()
        let updated = CloudflareAccessHost.recordChallenge(in: [], origin: "https://a.b", now: now)
        #expect(updated.map(\.origin) == ["https://a.b"])
        #expect(updated[0].firstSeen == now)
        #expect(updated[0].lastChallenged == now)
        #expect(updated[0].lastSignedIn == nil)
    }

    @Test func recordChallengeBumpsAnExistingHostWithoutResettingFirstSeen() {
        let firstSeen = Date(timeIntervalSince1970: 1000)
        let existing = [self.host("https://a.b", firstSeen: firstSeen, lastChallenged: firstSeen)]

        let now = Date(timeIntervalSince1970: 2000)
        let updated = CloudflareAccessHost.recordChallenge(in: existing, origin: "https://a.b", now: now)

        #expect(updated.count == 1)
        #expect(updated[0].firstSeen == firstSeen)
        #expect(updated[0].lastChallenged == now)
    }

    @Test func recordChallengeSortsMostRecentlyChallengedFirst() {
        let older = self.host("https://old.example", firstSeen: .now, lastChallenged: Date(timeIntervalSince1970: 0))
        let updated = CloudflareAccessHost.recordChallenge(
            in: [older], origin: "https://new.example", now: Date(timeIntervalSince1970: 100)
        )
        #expect(updated.map(\.origin) == ["https://new.example", "https://old.example"])
    }

    @Test func recordChallengeCapsAtMaxRecordedHosts() {
        let base = Date(timeIntervalSince1970: 0)
        let hosts = (0 ..< CloudflareAccessHost.maxRecordedHosts).map {
            self.host("https://host\($0).example", firstSeen: base, lastChallenged: base.addingTimeInterval(Double($0)))
        }
        let updated = CloudflareAccessHost.recordChallenge(
            in: hosts, origin: "https://newest.example", now: base.addingTimeInterval(1000)
        )
        #expect(updated.count == CloudflareAccessHost.maxRecordedHosts)
        #expect(updated.first?.origin == "https://newest.example")
        // The single oldest-challenged host was pushed out by the cap.
        #expect(!updated.contains { $0.origin == "https://host0.example" })
    }

    // MARK: - needsSignIn

    @Test func needsSignInIsTrueWhenNeverSignedIn() {
        #expect(self.host("https://a.b", firstSeen: .now, lastChallenged: .now).needsSignIn)
    }

    @Test func needsSignInIsTrueWhenChallengedAgainAfterSigningIn() {
        let signedIn = Date(timeIntervalSince1970: 1000)
        let challengedAgain = Date(timeIntervalSince1970: 2000)
        let host = self.host(
            "https://a.b", firstSeen: .now, lastChallenged: challengedAgain, lastSignedIn: signedIn
        )
        #expect(host.needsSignIn)
    }

    @Test func needsSignInIsFalseWhenTheSignInCoversTheLastChallenge() {
        let challenged = Date(timeIntervalSince1970: 1000)
        let signedInAfter = Date(timeIntervalSince1970: 2000)
        let host = self.host(
            "https://a.b", firstSeen: .now, lastChallenged: challenged, lastSignedIn: signedInAfter
        )
        #expect(!host.needsSignIn)
    }

    // MARK: - gatedHost

    @Test func gatedHostMatchesAnOriginThatNeedsSignIn() throws {
        let hosts = [self.host("https://a.b", firstSeen: .now, lastChallenged: .now)]
        let url = try #require(URL(string: "https://a.b/some/page"))
        #expect(CloudflareAccessHost.gatedHost(for: url, in: hosts)?.origin == "https://a.b")
    }

    @Test func gatedHostIsNilForASignedInHost() throws {
        let signedIn = Date(timeIntervalSince1970: 2000)
        let challenged = Date(timeIntervalSince1970: 1000)
        let hosts = [self.host("https://a.b", firstSeen: .now, lastChallenged: challenged, lastSignedIn: signedIn)]
        let url = try #require(URL(string: "https://a.b/some/page"))
        #expect(CloudflareAccessHost.gatedHost(for: url, in: hosts) == nil)
    }

    @Test func gatedHostIsNilWithoutAMatchingOrigin() throws {
        let hosts = [self.host("https://a.b", firstSeen: .now, lastChallenged: .now)]
        let url = try #require(URL(string: "https://other.example/some/page"))
        #expect(CloudflareAccessHost.gatedHost(for: url, in: hosts) == nil)
    }

    @Test func gatedHostRespectsExplicitPorts() throws {
        let hosts = [self.host("https://a.b:8443", firstSeen: .now, lastChallenged: .now)]
        // Same host, default port — a different origin, no match.
        let defaultPortURL = try #require(URL(string: "https://a.b/some/page"))
        #expect(CloudflareAccessHost.gatedHost(for: defaultPortURL, in: hosts) == nil)

        let matchingURL = try #require(URL(string: "https://a.b:8443/some/page"))
        #expect(CloudflareAccessHost.gatedHost(for: matchingURL, in: hosts)?.origin == "https://a.b:8443")
    }

    // MARK: - recordSignIn

    @Test func recordSignInSetsLastSignedInOnTheMatchingHost() {
        let existing = [self.host("https://a.b", firstSeen: .now, lastChallenged: .now)]
        let now = Date()
        let updated = CloudflareAccessHost.recordSignIn(in: existing, origin: "https://a.b", now: now)
        #expect(updated[0].lastSignedIn == now)
    }

    @Test func recordSignInIsANoOpForAnUnknownHost() {
        let existing = [self.host("https://a.b", firstSeen: .now, lastChallenged: .now)]
        let updated = CloudflareAccessHost.recordSignIn(in: existing, origin: "https://unknown.example", now: .now)
        #expect(updated == existing)
    }

    // MARK: - Once-per-launch HUD hint gating

    @Test func shouldHintTheFirstTimeAnOriginIsSeen() {
        #expect(CloudflaredAccessTokens.shouldHint(origin: "https://a.b", alreadyHinted: []))
    }

    @Test func shouldNotHintAnOriginAlreadyHinted() {
        #expect(!CloudflaredAccessTokens.shouldHint(origin: "https://a.b", alreadyHinted: ["https://a.b"]))
    }

    @Test func shouldHintADifferentOriginEvenWithOthersAlreadyHinted() {
        #expect(CloudflaredAccessTokens.shouldHint(origin: "https://c.d", alreadyHinted: ["https://a.b"]))
    }
}
