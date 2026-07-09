import Foundation
@testable import OverboardCore
import Testing

struct URLSensitivityTests {
    private func url(_ string: String) -> URL {
        URL(string: string)!
    }

    @Test func flagsPresignedAndTokenURLs() {
        // Presigned S3.
        #expect(URLSensitivity.isSensitive(self.url(
            "https://bucket.s3.amazonaws.com/key?X-Amz-Signature=abc123&X-Amz-Credential=AKIA"
        )))
        // OAuth implicit-flow fragment.
        #expect(URLSensitivity.isSensitive(self.url(
            "https://app.example.com/cb#access_token=ya29.a0AfH&token_type=Bearer"
        )))
        // Magic-login / reset token in query.
        #expect(URLSensitivity.isSensitive(self.url(
            "https://app.example.com/reset?token=s3cr3ttoken"
        )))
        // Embedded credentials.
        #expect(URLSensitivity.isSensitive(self.url("https://user:pass@example.com/")))
        // API key.
        #expect(URLSensitivity.isSensitive(self.url("https://api.example.com/v1?api_key=live_abcdef")))
        // Magic link with an opaque token in the path.
        #expect(URLSensitivity.isSensitive(self.url(
            "https://example.com/verify/aB3xK9pQ2mZ7wR1t"
        )))
    }

    @Test func leavesOrdinaryURLsFetchable() {
        #expect(!URLSensitivity.isSensitive(self.url("https://example.com/article/how-to-swift")))
        #expect(!URLSensitivity.isSensitive(self.url("https://github.com/login")))
        #expect(!URLSensitivity.isSensitive(self.url("https://shop.example.com/p?q=token-ring")))
        #expect(!URLSensitivity.isSensitive(self.url("https://news.example.com/2026/07/09/headline")))
        // A "verify" path without an opaque token is a normal page.
        #expect(!URLSensitivity.isSensitive(self.url("https://example.com/verify")))
    }

    @Test func sensitiveLinkClipIsClassifiedSecret() throws {
        let snapshot = PasteboardSnapshot(
            reps: [.init(
                uti: WellKnownUTI.plainText,
                data: Data("https://bucket.s3.amazonaws.com/k?X-Amz-Signature=abc".utf8)
            )],
            sourceBundleID: "com.apple.Safari",
            sourceAppName: "Safari"
        )
        let classified = try #require(CaptureClassifier.classify(snapshot))
        #expect(classified.kind == .link)
        #expect(classified.isSecret)
        #expect(classified.searchText == nil) // never indexed
        #expect(classified.previewText == "Secret — Link with credentials")
    }

    @Test func ordinaryLinkClipIsNotSecret() throws {
        let snapshot = PasteboardSnapshot(
            reps: [.init(
                uti: WellKnownUTI.plainText,
                data: Data("https://example.com/article".utf8)
            )],
            sourceBundleID: "com.apple.Safari",
            sourceAppName: "Safari"
        )
        let classified = try #require(CaptureClassifier.classify(snapshot))
        #expect(classified.kind == .link)
        #expect(!classified.isSecret)
        #expect(classified.searchText != nil)
    }
}
