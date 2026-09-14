import Foundation

// MARK: - HTML streaming + charset decoding

extension LinkMetadataFetcher {
    /// Outcome of a single `fetchHTML` attempt.
    enum HTMLFetch {
        /// A usable HTML page, plus the final (post-redirect) URL to resolve
        /// relative links against.
        case page(html: String, finalURL: URL)
        /// The request landed on a Cloudflare Access login redirect instead
        /// of the page — the caller should retry with a token, if it has one.
        case accessChallenge
        /// Anything else that isn't a usable page: a non-2xx/non-Access-redirect
        /// status, a non-HTML content type, or a network error.
        case failed
    }

    /// Streams the response, decodes as UTF-8 (isoLatin1 fallback), and stops
    /// at `</head>` or the byte cap — whichever comes first.
    ///
    /// `RedirectGuard` refuses to auto-follow a redirect to a Cloudflare
    /// Access login page (see `isCloudflareAccessLogin`), so that hop surfaces
    /// here as the 3xx response itself rather than being silently followed
    /// into the login page's `<title>`. `classifyResponse` reads the
    /// `Location` header off that response and, when it points at an Access
    /// login, reports `.accessChallenge` instead of `.failed` so `fetch(_:)`
    /// knows a token retry is worth attempting.
    func fetchHTML(_ url: URL, headers: [String: String] = [:]) async -> HTMLFetch {
        guard await Self.isConnectPermitted(url) else { return .failed }
        let request = self.htmlRequest(for: url, headers: headers)

        do {
            let (bytes, response) = try await self.session.bytes(for: request)
            let finalURL = response.url ?? url
            if let outcome = Self.classifyResponse(response, finalURL: finalURL) {
                bytes.task.cancel()
                return outcome
            }
            guard let html = try await Self.readHTMLHead(from: bytes) else { return .failed }
            return .page(html: html, finalURL: finalURL)
        } catch {
            return .failed
        }
    }

    /// The request `fetchHTML` sends: a browser-ish User-Agent (some servers
    /// refuse bare `Foundation`/no-UA requests), an HTML `Accept`, and
    /// whatever caller-supplied headers (the Access token, on retry).
    private func htmlRequest(for url: URL, headers: [String: String]) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = self.timeout
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) Overboard link preview",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        return request
    }

    /// Inspects an HTTP response's status and content type before any body
    /// bytes are read. Nil means "keep going, read the body"; a non-nil
    /// result is `fetchHTML`'s answer as-is. A non-HTTP response (nil here)
    /// is treated as fine to read — `URLSession` only ever hands back
    /// `HTTPURLResponse` for http(s) requests, which is all `isFetchable`
    /// allows in the first place.
    private static func classifyResponse(_ response: URLResponse, finalURL: URL) -> HTMLFetch? {
        guard let http = response as? HTTPURLResponse else { return nil }

        if (300 ..< 400).contains(http.statusCode) {
            let location = http.value(forHTTPHeaderField: "Location")
                .flatMap { URL(string: $0, relativeTo: finalURL)?.absoluteURL }
            return (location.map(Self.isCloudflareAccessLogin) == true) ? .accessChallenge : .failed
        }
        guard (200 ..< 300).contains(http.statusCode) else { return .failed }

        // Skip obviously-non-HTML payloads early.
        if let type = http.value(forHTTPHeaderField: "Content-Type")?.lowercased(),
           !type.isEmpty,
           !type.contains("html"), !type.contains("xml"), !type.contains("text/plain")
        {
            return .failed
        }
        return nil
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
