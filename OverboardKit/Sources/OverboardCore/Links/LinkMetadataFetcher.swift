import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Fetches rich-link metadata for a URL over the network: streams the page's
/// `<head>`, parses it, then pulls and downscales the favicon and preview
/// image. Silent-fail throughout (nil on any error), like `UpdateChecker` —
/// a link works fine without a preview. Networking is user-opt-in and gated by
/// the caller; this type assumes it's allowed to run.
public struct LinkMetadataFetcher: Sendable {
    private let session: URLSession
    private let timeout: TimeInterval

    /// Cap on streamed HTML — enough for any real `<head>`, small enough that a
    /// pathological page can't exhaust memory.
    private static let htmlByteCap = 512 * 1024
    private static let faviconByteCap = 256 * 1024
    private static let previewImageByteCap = 2 * 1024 * 1024

    private static let faviconMaxPixel = 64
    private static let previewImageMaxPixel = 480

    public init(session: URLSession? = nil, timeout: TimeInterval = 10) {
        self.timeout = timeout
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = timeout
            config.timeoutIntervalForResource = timeout * 3
            config.httpCookieStorage = nil
            config.urlCache = nil
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(
                configuration: config,
                delegate: RedirectGuard(),
                delegateQueue: nil
            )
        }
    }

    // MARK: - Fetchability guard

    /// Whether a URL is safe and sensible to fetch: http/https only, no
    /// embedded credentials, a real host, and not something on the local
    /// machine or a private network (SSRF hardening — we never want a copied
    /// link to reach an internal service).
    public static func isFetchable(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return false
        }
        guard url.user == nil, url.password == nil else { return false }
        guard let host = url.host, !host.isEmpty else { return false }
        return !self.isPrivateHost(host)
    }

    /// True for hosts that resolve to the local machine or a private/link-local
    /// network. Rejects by name (localhost, *.local) and by literal IP range.
    static func isPrivateHost(_ rawHost: String) -> Bool {
        // URLComponents leaves IPv6 literals bracketed; strip for matching.
        var host = rawHost.lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }

        if host == "localhost" || host.hasSuffix(".localhost") { return true }
        if host == "local" || host.hasSuffix(".local") { return true }

        // IPv6 loopback / unspecified.
        if host == "::1" || host == "::" { return true }
        // IPv4-mapped IPv6 loopback, e.g. ::ffff:127.0.0.1.
        if host.hasPrefix("::ffff:"), self.isPrivateIPv4(String(host.dropFirst(7))) { return true }

        if self.isPrivateIPv4(host) { return true }

        return false
    }

    /// True if `host` is a dotted-quad IPv4 in a loopback/private/link-local
    /// range: 127/8, 10/8, 172.16–31, 192.168/16, 169.254/16, plus 0.0.0.0.
    private static func isPrivateIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        let octets = parts.compactMap { UInt8($0) }
        guard octets.count == 4 else { return false }
        switch (octets[0], octets[1]) {
        case (0, _): return true
        case (127, _): return true
        case (10, _): return true
        case (172, 16 ... 31): return true
        case (192, 168): return true
        case (169, 254): return true
        default: return false
        }
    }

    // MARK: - Fetch

    public func fetch(_ url: URL) async -> LinkMetadata? {
        guard Self.isFetchable(url) else { return nil }
        guard let (html, finalURL) = await self.fetchHTML(url) else { return nil }

        let parsed = LinkMetadataParser.parse(html: html, baseURL: finalURL)

        // A page with no usable text yields nothing worth storing.
        let hasText = (parsed.title?.isEmpty == false) || (parsed.description?.isEmpty == false)

        let faviconURL = parsed.faviconURL ?? self.defaultFaviconURL(for: finalURL)
        let faviconPNG = await self.fetchImagePNG(
            faviconURL, byteCap: Self.faviconByteCap, maxPixel: Self.faviconMaxPixel
        )
        let previewPNG = await parsed.previewImageURL.asyncFlatMap {
            await self.fetchImagePNG(
                $0, byteCap: Self.previewImageByteCap, maxPixel: Self.previewImageMaxPixel
            )
        }

        guard hasText || faviconPNG != nil || previewPNG != nil else { return nil }

        return LinkMetadata(
            title: parsed.title,
            description: parsed.description,
            faviconPNG: faviconPNG,
            previewImagePNG: previewPNG
        )
    }

    // MARK: - HTML streaming

    /// Streams the response, decodes as UTF-8 (isoLatin1 fallback), and stops
    /// at `</head>` or the byte cap — whichever comes first. Returns the HTML
    /// and the final (post-redirect) URL to resolve relative links against.
    private func fetchHTML(_ url: URL) async -> (html: String, finalURL: URL)? {
        var request = URLRequest(url: url)
        request.timeoutInterval = self.timeout
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) Overboard link preview",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")

        do {
            let (bytes, response) = try await self.session.bytes(for: request)
            let finalURL = response.url ?? url
            if let http = response as? HTTPURLResponse {
                guard (200 ..< 300).contains(http.statusCode) else {
                    bytes.task.cancel()
                    return nil
                }
                // Skip obviously-non-HTML payloads early.
                if let type = http.value(forHTTPHeaderField: "Content-Type")?.lowercased(),
                   !type.isEmpty,
                   !type.contains("html"), !type.contains("xml"), !type.contains("text/plain")
                {
                    bytes.task.cancel()
                    return nil
                }
            }

            var data = Data()
            data.reserveCapacity(min(Self.htmlByteCap, 64 * 1024))
            let closeTag = Array("</head>".utf8)
            for try await byte in bytes {
                data.append(byte)
                if data.count >= Self.htmlByteCap { break }
                if data.count >= closeTag.count, Self.hasSuffix(data, closeTag) { break }
            }
            bytes.task.cancel()

            guard !data.isEmpty else { return nil }
            let html = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
            guard let html else { return nil }
            return (html, finalURL)
        } catch {
            return nil
        }
    }

    /// Case-sensitive suffix check on raw bytes (for `</head>`, which is ASCII;
    /// callers pass a lowercase tag and we match either case).
    private static func hasSuffix(_ data: Data, _ suffix: [UInt8]) -> Bool {
        guard data.count >= suffix.count else { return false }
        let start = data.index(data.endIndex, offsetBy: -suffix.count)
        var i = start
        for expected in suffix {
            let actual = data[i]
            // Match ASCII case-insensitively.
            let lower = (actual >= 65 && actual <= 90) ? actual + 32 : actual
            let expectedLower = (expected >= 65 && expected <= 90) ? expected + 32 : expected
            if lower != expectedLower { return false }
            i = data.index(after: i)
        }
        return true
    }

    // MARK: - Image fetch + downscale

    /// The site's `/favicon.ico` at the document's origin — the fallback when a
    /// page advertises no `<link rel="icon">`.
    private func defaultFaviconURL(for url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.path = "/favicon.ico"
        components.query = nil
        components.fragment = nil
        return components.url
    }

    /// Downloads an image (capped at `byteCap`), downscales it to `maxPixel` on
    /// its longest side, and re-encodes as PNG via ImageIO — no AppKit. Nil on
    /// any failure, so a broken image URL never blocks the rest of the card.
    private func fetchImagePNG(_ url: URL?, byteCap: Int, maxPixel: Int) async -> Data? {
        guard let url, Self.isFetchable(url) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = self.timeout
        request.setValue("image/*", forHTTPHeaderField: "Accept")

        do {
            let (bytes, response) = try await self.session.bytes(for: request)
            if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
                bytes.task.cancel()
                return nil
            }
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count > byteCap {
                    bytes.task.cancel()
                    return nil
                }
            }
            bytes.task.cancel()
            guard !data.isEmpty else { return nil }
            return Self.downscaledPNG(from: data, maxPixel: maxPixel)
        } catch {
            return nil
        }
    }

    /// Downscales image bytes to `maxPixel` on the longest side and re-encodes
    /// as PNG. Reuses `ImageDownsampler` for the memory-frugal decode, then
    /// serializes via CGImageDestination. Nil if the bytes aren't a decodable
    /// image.
    static func downscaledPNG(from data: Data, maxPixel: Int) -> Data? {
        guard let cgImage = ImageDownsampler.downsampledImage(from: data, maxPixel: maxPixel) else {
            return nil
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output as CFMutableData, UTType.png.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}

// MARK: - Redirect safety

/// Re-validates every redirect target with `isFetchable` and cancels the
/// request when a hop points somewhere unsafe (e.g. a public URL that 302s to
/// an internal IP). Returning nil to the completion handler stops the redirect.
private final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        if let url = request.url, LinkMetadataFetcher.isFetchable(url) {
            completionHandler(request)
        } else {
            completionHandler(nil)
        }
    }
}

// MARK: - Optional async helper

private extension Optional {
    /// `flatMap` for an async transform — keeps the fetch flow readable.
    func asyncFlatMap<T>(_ transform: (Wrapped) async -> T?) async -> T? {
        guard let self else { return nil }
        return await transform(self)
    }
}
