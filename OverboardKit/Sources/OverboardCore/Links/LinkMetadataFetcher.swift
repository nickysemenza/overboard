import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Fetches rich-link metadata for a URL over the network: streams the page's
/// `<head>`, parses it, then pulls and downscales the favicon and preview
/// image. Silent-fail throughout (nil on any error), by design —
/// a link works fine without a preview. Networking is user-opt-in and gated by
/// the caller; this type assumes it's allowed to run.
public struct LinkMetadataFetcher: Sendable {
    /// Internal (not `private`) so `fetchHTML` can reach it from
    /// LinkMetadataFetcher+Decoding.swift.
    let session: URLSession
    /// Internal (not `private`) so `fetchHTML` can reach it from
    /// LinkMetadataFetcher+Decoding.swift.
    let timeout: TimeInterval

    /// Cap on streamed HTML — enough for any real `<head>`, small enough that a
    /// pathological page can't exhaust memory. Internal (not `private`) so
    /// `fetchHTML` can reach it from LinkMetadataFetcher+Decoding.swift.
    static let htmlByteCap = 512 * 1024
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

        if host == "localhost" || host.hasSuffix(".localhost") {
            return true
        }
        if host == "local" || host.hasSuffix(".local") {
            return true
        }

        // IPv6 loopback / unspecified.
        if host == "::1" || host == "::" {
            return true
        }
        // IPv4-mapped IPv6 loopback, e.g. ::ffff:127.0.0.1.
        if host.hasPrefix("::ffff:"), self.isPrivateIPv4(String(host.dropFirst(7))) {
            return true
        }
        // IPv6 link-local (fe80::/10) and unique-local (fc00::/7).
        if host.hasPrefix("fe8") || host.hasPrefix("fe9") || host.hasPrefix("fea") || host.hasPrefix("feb") {
            return true
        }
        if host.hasPrefix("fc") || host.hasPrefix("fd") {
            return true
        }

        if self.isPrivateIPv4(host) {
            return true
        }

        return false
    }

    /// Resolves `host` via DNS and returns true if *any* resolved address is
    /// loopback/private/link-local. `isPrivateHost` only inspects the literal
    /// host string, but URLSession resolves the name itself when it connects —
    /// so a public-looking hostname whose A/AAAA record points at 127.0.0.1 or
    /// 169.254.169.254 (SSRF via DNS) would otherwise slip through. A resolution
    /// failure returns false and lets the request fail on its own.
    ///
    /// Best-effort: URLSession re-resolves at connect time, so a resolver that
    /// flips its answer between this check and the connection (DNS rebinding with
    /// a near-zero TTL) could still bypass it. Closing that fully needs pinning
    /// the connection to the vetted address, which URLSession doesn't expose.
    ///
    /// `getaddrinfo` is a blocking syscall — a slow or hung resolver would
    /// otherwise tie up a cooperative-pool thread for the system DNS timeout
    /// (tens of seconds). It runs on a detached task backed by a plain
    /// dispatch thread, raced against a 3s timeout; losing that race is
    /// treated as "resolves to private" (i.e. not fetchable) rather than
    /// letting an unresolved host through unchecked.
    static func hostResolvesToPrivate(_ host: String) async -> Bool {
        let resolution = Task.detached(priority: .utility) { () -> Bool in
            var hints = addrinfo()
            hints.ai_family = AF_UNSPEC
            hints.ai_socktype = SOCK_STREAM
            var info: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, nil, &hints, &info) == 0, let head = info else { return false }
            defer { freeaddrinfo(head) }

            var node: UnsafeMutablePointer<addrinfo>? = head
            while let current = node {
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if let addr = current.pointee.ai_addr,
                   getnameinfo(
                       addr, current.pointee.ai_addrlen,
                       &buffer, socklen_t(buffer.count),
                       nil, 0, NI_NUMERICHOST
                   ) == 0
                {
                    // getnameinfo can append a scope id to link-local addrs (fe80::1%en0).
                    let numeric = buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
                    let bare = numeric.split(separator: "%").first.map(String.init) ?? numeric
                    if self.isPrivateHost(bare) {
                        return true
                    }
                }
                node = current.pointee.ai_next
            }
            return false
        }

        return await withTaskGroup(of: Bool.self) { group in
            group.addTask { await resolution.value }
            group.addTask {
                try? await Task.sleep(for: .seconds(3))
                return true // timeout → treat as unresolved/private, i.e. not fetchable.
            }
            let first = await group.next() ?? true
            group.cancelAll()
            resolution.cancel()
            return first
        }
    }

    /// The full connect-time gate: cheap string checks (`isFetchable`) plus a DNS
    /// resolution check. Applied at every outbound-connection boundary, including
    /// redirects, so a name that resolves to an internal address is never dialed.
    /// Internal (not `private`) so `fetchHTML` can reach it from
    /// LinkMetadataFetcher+Decoding.swift.
    static func isConnectPermitted(_ url: URL) async -> Bool {
        guard self.isFetchable(url), let host = url.host else { return false }
        return await !self.hostResolvesToPrivate(host)
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
        guard let url, await Self.isConnectPermitted(url) else { return nil }
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
        guard let url = request.url else {
            completionHandler(nil)
            return
        }
        // The DNS check is now async (see `isConnectPermitted`), so the
        // decision can't be made before this synchronous delegate callback
        // returns. `completionHandler` isn't `Sendable` (it's a plain
        // `@escaping` closure from the ObjC-bridged protocol), so it's boxed
        // to cross into the `Task` — this call site is its only use, so the
        // box just carries it, it doesn't share it.
        let box = CompletionHandlerBox(completionHandler)
        Task {
            let permitted = await LinkMetadataFetcher.isConnectPermitted(url)
            box.handler(permitted ? request : nil)
        }
    }
}

/// Asserts (rather than proves) that a captured `@escaping` completion
/// handler is safe to hand to a `Task` — true here because each box is
/// constructed and consumed exactly once, on the delegate queue this session
/// was created with, in `RedirectGuard`.
private struct CompletionHandlerBox: @unchecked Sendable {
    let handler: (URLRequest?) -> Void
    init(_ handler: @escaping (URLRequest?) -> Void) {
        self.handler = handler
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
