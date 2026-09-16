import Foundation

// MARK: - Redirect safety

/// Re-validates every redirect target with `isFetchable` and refuses the hop
/// when it points somewhere unsafe (e.g. a public URL that 302s to an
/// internal IP). Passing nil to `completionHandler` refuses the redirect and
/// delivers the redirect response itself back to the caller as the task's
/// result; `fetchHTML` then rejects its non-2xx status.
final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = newRequest.url else {
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
            box.handler(permitted ? newRequest : nil)
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
