import Foundation

// MARK: - HTML streaming + charset decoding

extension LinkMetadataFetcher {
    /// Streams the response, decodes as UTF-8 (isoLatin1 fallback), and stops
    /// at `</head>` or the byte cap — whichever comes first. Returns the HTML
    /// and the final (post-redirect) URL to resolve relative links against.
    func fetchHTML(_ url: URL) async -> (html: String, finalURL: URL)? {
        guard await Self.isConnectPermitted(url) else { return nil }
        let request = self.htmlRequest(for: url)

        do {
            let (bytes, response) = try await self.session.bytes(for: request)
            let finalURL = response.url ?? url
            if Self.shouldReject(response) {
                bytes.task.cancel()
                return nil
            }
            guard let html = try await Self.readHTMLHead(from: bytes) else { return nil }
            return (html, finalURL)
        } catch {
            return nil
        }
    }

    /// The request `fetchHTML` sends: a browser-ish User-Agent (some servers
    /// refuse bare `Foundation`/no-UA requests) and an HTML `Accept`.
    private func htmlRequest(for url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = self.timeout
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) Overboard link preview",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        return request
    }

    /// Inspects an HTTP response's status and content type before any body
    /// bytes are read. A non-HTTP response is treated as fine to read —
    /// `URLSession` only ever hands back `HTTPURLResponse` for http(s)
    /// requests, which is all `isFetchable` allows in the first place.
    private static func shouldReject(_ response: URLResponse) -> Bool {
        guard let http = response as? HTTPURLResponse else { return false }
        guard (200 ..< 300).contains(http.statusCode) else { return true }

        // Skip obviously-non-HTML payloads early.
        if let type = http.value(forHTTPHeaderField: "Content-Type")?.lowercased(),
           !type.isEmpty,
           !type.contains("html"), !type.contains("xml"), !type.contains("text/plain")
        {
            return true
        }
        return false
    }

    /// Reads `bytes` up to `</head>` or `htmlByteCap`, whichever comes first,
    /// and decodes the result as UTF-8 (isoLatin1 fallback). Nil for an empty
    /// or fully-undecodable body.
    private static func readHTMLHead(from bytes: URLSession.AsyncBytes) async throws -> String? {
        var data = Data()
        data.reserveCapacity(min(Self.htmlByteCap, 64 * 1024))
        let closeTag = Array("</head>".utf8)
        for try await byte in bytes {
            data.append(byte)
            if data.count >= Self.htmlByteCap {
                break
            }
            if data.count >= closeTag.count, Self.hasSuffix(data, closeTag) {
                break
            }
        }
        bytes.task.cancel()

        guard !data.isEmpty else { return nil }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    /// Case-sensitive suffix check on raw bytes (for `</head>`, which is ASCII;
    /// callers pass a lowercase tag and we match either case).
    static func hasSuffix(_ data: Data, _ suffix: [UInt8]) -> Bool {
        guard data.count >= suffix.count else { return false }
        let start = data.index(data.endIndex, offsetBy: -suffix.count)
        var index = start
        for expected in suffix {
            let actual = data[index]
            // Match ASCII case-insensitively.
            let lower = (actual >= 65 && actual <= 90) ? actual + 32 : actual
            let expectedLower = (expected >= 65 && expected <= 90) ? expected + 32 : expected
            if lower != expectedLower {
                return false
            }
            index = data.index(after: index)
        }
        return true
    }
}
