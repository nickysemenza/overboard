import Foundation
@testable import OverboardCore
import Testing

struct CloudflareAccessTests {
    private func url(_ string: String) -> URL {
        URL(string: string)!
    }

    // MARK: - isCloudflareAccessLogin

    @Test func recognizesAccessLoginHosts() {
        #expect(LinkMetadataFetcher.isCloudflareAccessLogin(
            self.url("https://cfdata.cloudflareaccess.com/cdn-cgi/access/login/wiki.cfdata.org?kid=x")
        ))
        #expect(LinkMetadataFetcher.isCloudflareAccessLogin(
            self.url("https://cloudflareaccess.com/cdn-cgi/access/login/x")
        ))
    }

    @Test func rejectsLookalikesAndWrongPaths() {
        // Not a subdomain of cloudflareaccess.com — a lookalike domain.
        #expect(!LinkMetadataFetcher.isCloudflareAccessLogin(
            self.url("https://notcloudflareaccess.com/cdn-cgi/access/login/x")
        ))
        // Right host, wrong path.
        #expect(!LinkMetadataFetcher.isCloudflareAccessLogin(
            self.url("https://team.cloudflareaccess.com/other")
        ))
        // Right path, wrong host entirely.
        #expect(!LinkMetadataFetcher.isCloudflareAccessLogin(
            self.url("https://example.com/cdn-cgi/access/login")
        ))
    }

    // MARK: - End-to-end challenge + retry

    /// Intercepts every request the fetcher makes so the test never touches
    /// the network. Registered into a `URLSessionConfiguration.ephemeral`
    /// that's handed straight to `LinkMetadataFetcher(session:)` — this
    /// bypasses `RedirectGuard` (the session has no delegate), which is fine
    /// here since the point of this test is `fetchHTML`'s own handling of the
    /// 3xx + Location it receives, not the redirect-following behavior.
    private final class StubProtocol: URLProtocol, @unchecked Sendable {
        /// Keyed by whether the incoming request carries `cf-access-token`,
        /// set by the test right before each `fetch(_:)` call. `NSLock`-backed
        /// static state is the only way to reach into `URLProtocol`, which
        /// URLSession instantiates itself.
        static let lock = NSLock()
        nonisolated(unsafe) static var tokenSeenOnRetry = false

        override static func canInit(with request: URLRequest) -> Bool {
            request.url?.host != nil
        }

        override static func canonicalRequest(for request: URLRequest) -> URLRequest {
            request
        }

        override func startLoading() {
            guard let url = request.url else {
                self.client?.urlProtocolDidFinishLoading(self)
                return
            }
            let token = self.request.value(forHTTPHeaderField: "cf-access-token")

            // The favicon fetch (default `/favicon.ico`) and anything besides
            // the page URL itself: answer 404 so it's harmlessly skipped.
            guard url.path == "/wiki" else {
                self.respond(status: 404, headers: [:], body: Data())
                return
            }

            if let token, token == "a.b.c" {
                Self.lock.lock()
                Self.tokenSeenOnRetry = true
                Self.lock.unlock()
                let html = "<html><head><title>Wiki</title></head></html>"
                self.respond(
                    status: 200,
                    headers: ["Content-Type": "text/html"],
                    body: Data(html.utf8)
                )
                return
            }

            // Unauthenticated (or wrong-token) request: Access's real-world
            // 302 to the team's login page.
            self.respond(
                status: 302,
                headers: [
                    "Location": "https://team.cloudflareaccess.com/cdn-cgi/access/login/example.com?kid=x",
                ],
                body: Data()
            )
        }

        override func stopLoading() {}

        private func respond(status: Int, headers: [String: String], body: Data) {
            guard let url = request.url,
                  let response = HTTPURLResponse(
                      url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers
                  )
            else {
                self.client?.urlProtocolDidFinishLoading(self)
                return
            }
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: body)
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }

    /// A resolvable public hostname (DNS-only — `isConnectPermitted` does a
    /// real `getaddrinfo` lookup even though `StubProtocol` intercepts the
    /// actual connection) so the SSRF host-resolution gate doesn't reject the
    /// request before the stub ever sees it.
    private func makeFetcher(accessToken: LinkMetadataFetcher.AccessTokenProvider?) -> LinkMetadataFetcher {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let session = URLSession(configuration: config)
        return LinkMetadataFetcher(session: session, accessToken: accessToken)
    }

    @Test func noProviderMeansChallengeIsNeverRetried() async {
        StubProtocol.tokenSeenOnRetry = false
        let fetcher = self.makeFetcher(accessToken: nil)
        let result = await fetcher.fetch(self.url("https://example.com/wiki"))
        #expect(result == nil)
        #expect(!StubProtocol.tokenSeenOnRetry)
    }

    @Test func providerReturningTokenRetriesAndSucceeds() async {
        StubProtocol.tokenSeenOnRetry = false
        let fetcher = self.makeFetcher(accessToken: { _ in "a.b.c" })
        let result = await fetcher.fetch(self.url("https://example.com/wiki"))
        #expect(result?.title == "Wiki")
        #expect(StubProtocol.tokenSeenOnRetry)
    }

    @Test func providerReturningNilGivesUpSilently() async {
        StubProtocol.tokenSeenOnRetry = false
        let fetcher = self.makeFetcher(accessToken: { _ in nil })
        let result = await fetcher.fetch(self.url("https://example.com/wiki"))
        #expect(result == nil)
        #expect(!StubProtocol.tokenSeenOnRetry)
    }
}
