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
