import Foundation

/// Detects URLs that carry a credential, signature, or single-use token in their
/// userinfo, query, or fragment — presigned S3 links (`X-Amz-Signature=…`),
/// magic-login / password-reset links (`?token=…`), OAuth implicit-flow
/// redirects (`#access_token=…`), and the like.
///
/// A `.link` clip flagged here is treated exactly like a detected text secret:
/// masked preview, kept out of FTS / embeddings / the CLI, and — because the
/// enrichment and backfill paths both skip `isSecret` items — never fetched over
/// the network. So one flag closes both the "credential indexed/exposed" gap and
/// the "single-use link auto-consumed" gap.
///
/// High precision by design: it keys on unambiguous credential parameter names
/// and, for tokens carried in the path, requires both a sensitive path hint and
/// a high-entropy segment. A bare `/login` or `?q=token` page is left fetchable.
public enum URLSensitivity {
    /// Query / fragment parameter names that carry a secret value.
    private static let credentialKeys: Set<String> = [
        "signature", "x-amz-signature", "x-amz-credential", "x-amz-security-token",
        "access_token", "id_token", "refresh_token", "auth_token",
        "apikey", "api_key", "secret", "client_secret", "password", "passwd",
    ]

    /// Path segments that mark a consumable one-time-action link. Only treated as
    /// sensitive when the path *also* carries a token — either an opaque path
    /// segment or a token-shaped query parameter.
    private static let oneTimePathHints: Set<String> = [
        "reset", "verify", "verification", "confirm", "confirmation",
        "magic", "magiclink", "activate", "activation", "invite", "invitation",
    ]

    /// Query names that carry a one-time token when paired with a one-time path.
    /// Too generic to flag on their own (`?token=csrf` appears on public pages),
    /// but decisive alongside a `reset`/`verify`/`magic` path.
    private static let oneTimeTokenKeys: Set<String> = ["token", "code", "oobcode", "t", "key"]

    /// Whether a copied URL should be masked, kept unindexed, and never fetched.
    public static func isSensitive(_ url: URL) -> Bool {
        if url.user != nil || url.password != nil { return true }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)

        for item in components?.queryItems ?? [] {
            if self.credentialKeys.contains(item.name.lowercased()),
               let value = item.value, !value.isEmpty { return true }
        }

        if let fragment = components?.fragment?.lowercased() {
            for key in self.credentialKeys where fragment.contains("\(key)=") {
                return true
            }
        }

        let segments = (components?.path ?? url.path)
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { String($0).lowercased() }
        if segments.contains(where: { self.oneTimePathHints.contains($0) }) {
            // A one-time path plus a token — opaque path segment or token query.
            if segments.contains(where: self.looksLikeToken) { return true }
            for item in components?.queryItems ?? [] {
                if self.oneTimeTokenKeys.contains(item.name.lowercased()),
                   let value = item.value, !value.isEmpty { return true }
            }
        }

        return false
    }

    /// A long, high-entropy path segment — the opaque part of a magic link. Not
    /// a normal slug (words, hyphens) but a dense alphanumeric blob.
    private static func looksLikeToken(_ segment: String) -> Bool {
        guard segment.count >= 16 else { return false }
        let alphanumeric = segment.filter { $0.isLetter || $0.isNumber }
        guard Double(alphanumeric.count) / Double(segment.count) >= 0.9 else { return false }
        return segment.contains(where: \.isNumber) && segment.contains(where: \.isLetter)
    }
}
