import Foundation
@testable import OverboardCore
import Testing

struct SecretDetectorTests {
    @Test func detectsAWSAccessKey() {
        #expect(SecretDetector.detect(in: "AKIAIOSFODNN7EXAMPLE") == .awsAccessKey)
        #expect(SecretDetector.detect(in: "ASIAIOSFODNN7EXAMPLE") == .awsAccessKey)
    }

    @Test func detectsPrivateKey() {
        let pem = """
        -----BEGIN RSA PRIVATE KEY-----
        MIIEpAIBAAKCAQEA7
        -----END RSA PRIVATE KEY-----
        """
        #expect(SecretDetector.detect(in: pem) == .privateKey)
    }

    @Test func detectsJWT() {
        let jwt = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U"
        #expect(SecretDetector.detect(in: jwt) == .jwt)
    }

    @Test func detectsKnownTokenPrefixes() {
        #expect(SecretDetector.detect(in: "ghp_16C7e42F292c6912E7710c838347Ae178B4a") == .apiToken)
        #expect(SecretDetector.detect(in: "sk-proj-abc123def456ghi789jkl012") == .apiToken)
        #expect(SecretDetector.detect(in: "xoxb-1234567890-abcdefghijklmnop") == .apiToken)
    }

    @Test func detectsCreditCardViaLuhn() {
        #expect(SecretDetector.detect(in: "4532 0151 1283 0366") == .creditCard)
        #expect(SecretDetector.detect(in: "4532015112830366") == .creditCard)
        // Fails Luhn → not a card.
        #expect(SecretDetector.detect(in: "4532015112830367") == nil)
    }

    @Test func ignoresOrdinaryContent() {
        #expect(SecretDetector.detect(in: "just some ordinary text") == nil)
        #expect(SecretDetector.detect(in: "https://example.com/page?q=1") == nil)
        #expect(SecretDetector.detect(in: "sk-but this has spaces") == nil)
        #expect(SecretDetector.detect(in: "1234") == nil)
        // Hex hash — no recognized prefix, no entropy heuristics.
        #expect(SecretDetector.detect(in: "5fc187e18ce754a1d318d90497a70e64") == nil)
    }
}

struct ClipTransformTests {
    @Test func stripsTrackingParams() {
        let url = "https://example.com/article?id=42&utm_source=x&utm_campaign=y&fbclid=abc"
        #expect(ClipTransform.stripTrackingParams.apply(to: url) == "https://example.com/article?id=42")
    }

    @Test func stripsAllParamsWhenAllAreTracking() {
        let url = "https://example.com/article?utm_source=x"
        #expect(ClipTransform.stripTrackingParams.apply(to: url) == "https://example.com/article")
    }

    @Test func leavesCleanURLsAlone() {
        let url = "https://example.com/article?id=42"
        #expect(ClipTransform.stripTrackingParams.apply(to: url) == url)
    }

    @Test func caseAndTrimTransforms() {
        #expect(ClipTransform.trimWhitespace.apply(to: "  hi  \n") == "hi")
        #expect(ClipTransform.uppercase.apply(to: "hi") == "HI")
        #expect(ClipTransform.lowercase.apply(to: "HI") == "hi")
    }

    @Test func applicabilityByKind() {
        #expect(ClipTransform.stripTrackingParams.applies(to: .link))
        #expect(!ClipTransform.stripTrackingParams.applies(to: .text))
        #expect(ClipTransform.uppercase.applies(to: .text))
        #expect(!ClipTransform.uppercase.applies(to: .image))
    }
}

struct EmbeddingCoderTests {
    @Test func roundTrips() {
        let vector = [0.1, -0.5, 0.9, 0.0]
        let decoded = EmbeddingCoder.decode(EmbeddingCoder.encode(vector))
        #expect(decoded.count == 4)
        #expect(abs(decoded[0] - 0.1) < 0.0001)
        #expect(abs(decoded[1] - -0.5) < 0.0001)
    }

    @Test func cosineSimilarity() {
        #expect(EmbeddingCoder.cosineSimilarity([1, 0], [1, 0]) == 1.0)
        #expect(EmbeddingCoder.cosineSimilarity([1, 0], [0, 1]) == 0.0)
        #expect(EmbeddingCoder.cosineSimilarity([1, 0], [-1, 0]) == -1.0)
        #expect(EmbeddingCoder.cosineSimilarity([], []) == 0.0)
    }
}

struct SecretStoreTests {
    private func makeStore() throws -> ClipStore {
        let queue = try OverboardDatabase.openInMemory()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("overboard-secret-\(UUID().uuidString)", isDirectory: true)
        return try ClipStore(dbWriter: queue, blobs: BlobStore(directory: dir))
    }

    private func snapshot(_ text: String, at date: Date = Date()) -> PasteboardSnapshot {
        PasteboardSnapshot(
            reps: [.init(uti: WellKnownUTI.plainText, data: Data(text.utf8))],
            sourceBundleID: "com.test",
            sourceAppName: "Test",
            capturedAt: date
        )
    }

    @Test func secretsAreMaskedAndUnsearchable() async throws {
        let store = try makeStore()
        let item = try await store.ingest(self.snapshot("AKIAIOSFODNN7EXAMPLE"))

        #expect(item?.isSecret == true)
        #expect(item?.previewText == "Secret — AWS access key")
        // Payload is intact for pasting…
        let text = try await store.plainText(for: #require(item?.id))
        #expect(text == "AKIAIOSFODNN7EXAMPLE")
        // …but FTS can't find it, by preview or by content.
        #expect(try await store.search("AKIA").isEmpty)
        #expect(try await store.search("secret").isEmpty)
    }

    @Test func expiredSecretsArePurged() async throws {
        let store = try makeStore()
        let old = Date().addingTimeInterval(-3600)
        try await store.ingest(self.snapshot("AKIAIOSFODNN7EXAMPLE", at: old))
        try await store.ingest(self.snapshot("AKIAIOSFODNN7EXAMPL2")) // fresh
        try await store.ingest(self.snapshot("ordinary old text", at: old)) // non-secret

        try await store.purgeExpiredSecrets(olderThan: Date().addingTimeInterval(-600))

        let remaining = try await store.recent(limit: 10)
        #expect(remaining.count == 2)
        #expect(remaining.contains { $0.previewText == "ordinary old text" })
        #expect(remaining.filter(\.isSecret).count == 1)
    }
}
