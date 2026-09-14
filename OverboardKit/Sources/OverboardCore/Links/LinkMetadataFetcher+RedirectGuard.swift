import Foundation

// MARK: - Redirect safety

/// Re-validates every redirect target with `isFetchable` and refuses the hop
/// when it points somewhere unsafe (e.g. a public URL that 302s to an
/// internal IP), or when it's a Cloudflare Access login challenge. Passing
/// nil to `completionHandler` refuses the redirect and delivers the redirect
/// response itself back to the caller as the task's result — it does not
/// cancel the task. For the private-host case that response is a non-2xx
/// status, so `fetchHTML` treats it as `.failed`, same as before. For the
/// Access-login case `fetchHTML` recognizes the 3xx status and the
/// `Location` header itself and returns `.accessChallenge` — the guard here
/// only has to stop the automatic follow so that response reaches it.
final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
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
        if LinkMetadataFetcher.isCloudflareAccessLogin(url) {
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
