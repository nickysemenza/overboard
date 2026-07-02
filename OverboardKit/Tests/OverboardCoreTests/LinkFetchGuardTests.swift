import Foundation
@testable import OverboardCore
import Testing

struct LinkFetchGuardTests {
    private func url(_ string: String) -> URL {
        URL(string: string)!
    }

    @Test func acceptsPublicHTTPAndHTTPS() {
        #expect(LinkMetadataFetcher.isFetchable(self.url("https://example.com")))
        #expect(LinkMetadataFetcher.isFetchable(self.url("http://example.com/path?q=1")))
        #expect(LinkMetadataFetcher.isFetchable(self.url("https://sub.domain.example.com:8443/a")))
    }

    @Test func rejectsNonHTTPSchemes() {
        #expect(!LinkMetadataFetcher.isFetchable(self.url("ftp://example.com")))
        #expect(!LinkMetadataFetcher.isFetchable(self.url("file:///etc/passwd")))
        #expect(!LinkMetadataFetcher.isFetchable(self.url("data:text/html,<h1>hi</h1>")))
        #expect(!LinkMetadataFetcher.isFetchable(self.url("javascript:alert(1)")))
    }

    @Test func rejectsEmbeddedCredentials() {
        #expect(!LinkMetadataFetcher.isFetchable(self.url("https://user:pass@example.com")))
        #expect(!LinkMetadataFetcher.isFetchable(self.url("https://user@example.com")))
    }

    @Test func rejectsLocalhostAndLocalDomains() {
        #expect(!LinkMetadataFetcher.isFetchable(self.url("http://localhost")))
        #expect(!LinkMetadataFetcher.isFetchable(self.url("http://localhost:3000/api")))
        #expect(!LinkMetadataFetcher.isFetchable(self.url("http://mymac.local")))
        #expect(!LinkMetadataFetcher.isFetchable(self.url("http://printer.localhost")))
    }

    @Test func rejectsPrivateIPv4Ranges() {
        for host in [
            "127.0.0.1", "127.1.2.3", // loopback 127/8
            "10.0.0.1", "10.255.255.255", // 10/8
            "172.16.0.1", "172.20.5.5", "172.31.255.255", // 172.16–31
            "192.168.0.1", "192.168.1.100", // 192.168/16
            "169.254.1.1", // link-local
            "0.0.0.0", // unspecified
        ] {
            #expect(!LinkMetadataFetcher.isFetchable(self.url("http://\(host)")), "should reject \(host)")
        }
    }

    @Test func acceptsPublicIPv4() {
        #expect(LinkMetadataFetcher.isFetchable(self.url("http://8.8.8.8")))
        #expect(LinkMetadataFetcher.isFetchable(self.url("http://172.32.0.1"))) // just outside private
        #expect(LinkMetadataFetcher.isFetchable(self.url("http://172.15.0.1"))) // just below private
        #expect(LinkMetadataFetcher.isFetchable(self.url("http://93.184.216.34")))
    }

    @Test func rejectsIPv6Loopback() {
        #expect(!LinkMetadataFetcher.isFetchable(self.url("http://[::1]")))
        #expect(!LinkMetadataFetcher.isFetchable(self.url("http://[::1]:8080/x")))
        #expect(!LinkMetadataFetcher.isFetchable(self.url("http://[::]")))
    }

    @Test func rejectsIPv4MappedIPv6Loopback() {
        // ::ffff:127.0.0.1 loops back too.
        #expect(LinkMetadataFetcher.isPrivateHost("::ffff:127.0.0.1"))
    }

    @Test func rejectsMissingHost() {
        // A scheme-only URL with no host.
        if let u = URL(string: "https:///path") {
            #expect(!LinkMetadataFetcher.isFetchable(u))
        }
    }
}
