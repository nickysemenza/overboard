import Foundation
@testable import OverboardMac
import Testing

struct CloudflaredAccessTokensTests {
    private func url(_ string: String) -> URL {
        URL(string: string)!
    }

    // MARK: - Origin derivation

    @Test func originIsSchemeHostAndExplicitPort() {
        #expect(CloudflaredAccessTokens.origin(for: self.url("https://a.b:8443/x?y")) == "https://a.b:8443")
    }

    @Test func originOmitsPortWhenNotSpecified() {
        #expect(CloudflaredAccessTokens.origin(for: self.url("http://a.b/x")) == "http://a.b")
    }

    @Test func originIsNilWithoutAHost() {
        #expect(CloudflaredAccessTokens.origin(for: self.url("file:///etc/passwd")) == nil)
    }

    // MARK: - JWT shape

    @Test func acceptsThreeNonEmptyBase64URLSegments() {
        #expect(CloudflaredAccessTokens.isJWTShaped("aaa.bbb.ccc"))
        #expect(CloudflaredAccessTokens.isJWTShaped("aaa-BBB_1.c2Rm.ZXhhbXBsZQ"))
    }

    @Test func rejectsWrongSegmentCount() {
        #expect(!CloudflaredAccessTokens.isJWTShaped("aaa.bbb"))
        #expect(!CloudflaredAccessTokens.isJWTShaped("aaa.bbb.ccc.ddd"))
        #expect(!CloudflaredAccessTokens.isJWTShaped("aaa"))
    }

    @Test func rejectsAnEmptySegment() {
        #expect(!CloudflaredAccessTokens.isJWTShaped("aaa..ccc"))
        #expect(!CloudflaredAccessTokens.isJWTShaped(".bbb.ccc"))
    }

    @Test func rejectsWhitespace() {
        #expect(!CloudflaredAccessTokens.isJWTShaped("aaa bbb ccc"))
        #expect(!CloudflaredAccessTokens.isJWTShaped("aaa.bbb.ccc "))
    }

    /// `cloudflared` prints this (with exit code 0) for any host that isn't
    /// behind Access — the shape check is what keeps that sentence from being
    /// mistaken for a token.
    @Test func rejectsTheNotBehindAccessSentence() {
        #expect(!CloudflaredAccessTokens.isJWTShaped(
            "failed to find Access application at https://example.com"
        ))
    }

    // MARK: - Executable lookup

    @Test func findsExecutableOnAFakePATH() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cloudflared-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let executable = directory.appendingPathComponent("cloudflared")
        try Data("#!/bin/sh\necho hi\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let found = CloudflaredAccessTokens.executableURL(
            searchPaths: ["/nonexistent/cloudflared"],
            environment: ["PATH": directory.path]
        )
        #expect(found == executable)
    }

    @Test func noExecutableAnywhereYieldsNil() {
        let found = CloudflaredAccessTokens.executableURL(
            searchPaths: ["/nonexistent/cloudflared"],
            environment: ["PATH": "/also/nonexistent"]
        )
        #expect(found == nil)
    }
}
