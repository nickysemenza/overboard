import Foundation

/// Deterministic, pattern-based secret detection. Intentionally no entropy
/// heuristics — false positives (hashes, URLs, IDs the user *wants* in
/// history) are worse than the occasional miss.
public enum SecretDetector {
    public enum SecretKind: String, Sendable, CaseIterable {
        case awsAccessKey
        case privateKey
        case jwt
        case apiToken
        case creditCard

        public var label: String {
            switch self {
            case .awsAccessKey: "AWS access key"
            case .privateKey: "Private key"
            case .jwt: "JWT"
            case .apiToken: "API token"
            case .creditCard: "Card number"
            }
        }
    }

    /// Prefixes of well-known token formats (GitHub, Stripe, Slack, Google,
    /// GitLab, npm, OpenAI/Anthropic-style).
    private static let tokenPrefixes = [
        "ghp_", "gho_", "ghu_", "ghs_", "ghr_", "github_pat_",
        "sk-", "sk_live_", "sk_test_", "rk_live_", "rk_test_", "pk_live_",
        "xoxb-", "xoxp-", "xoxa-", "xoxr-", "xapp-",
        "glpat-", "npm_", "AIza",
    ]

    public static func detect(in text: String) -> SecretKind? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 8192 else { return nil }

        if trimmed.contains("-----BEGIN"), trimmed.contains("PRIVATE KEY") {
            return .privateKey
        }

        // Remaining patterns are single-token shaped.
        guard !trimmed.contains(where: \.isWhitespace), trimmed.count >= 12 else {
            return self.creditCard(in: trimmed)
        }

        if trimmed.count == 20,
           trimmed.hasPrefix("AKIA") || trimmed.hasPrefix("ASIA"),
           trimmed.allSatisfy({ $0.isUppercase || $0.isNumber })
        {
            return .awsAccessKey
        }

        if self.looksLikeJWT(trimmed) {
            return .jwt
        }

        for prefix in self.tokenPrefixes where trimmed.hasPrefix(prefix) {
            // Require a substantial body after the prefix to avoid matching
            // prose like "sk-something I typed".
            let body = trimmed.dropFirst(prefix.count)
            if body.count >= 16, body.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) {
                return .apiToken
            }
        }

        return self.creditCard(in: trimmed)
    }

    private static func looksLikeJWT(_ token: String) -> Bool {
        guard token.hasPrefix("eyJ") else { return false }
        let parts = token.split(separator: ".")
        guard parts.count == 3, parts.allSatisfy({ $0.count >= 4 }) else { return false }
        let base64url = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
        )
        return parts.allSatisfy {
            $0.unicodeScalars.allSatisfy(base64url.contains)
        }
    }

    /// 13–19 digits (spaces/dashes allowed) passing Luhn.
    private static func creditCard(in text: String) -> SecretKind? {
        // A card number is never multi-line, and stripping newlines would
        // concatenate unrelated rows into one candidate: a copied column of
        // figures becomes a 13–19 digit string that passes Luhn ~10% of the
        // time. Flagged items are masked, unsearchable, and swept on the
        // secret TTL, so that false positive silently destroys ordinary data.
        guard !text.contains(where: \.isNewline) else { return nil }
        let stripped = text.filter { !$0.isWhitespace && $0 != "-" }
        guard stripped.count >= 13, stripped.count <= 19,
              stripped.allSatisfy(\.isNumber)
        else { return nil }

        let digits = stripped.reversed().compactMap(\.wholeNumberValue)
        let sum = digits.enumerated().reduce(0) { total, pair in
            let (index, digit) = pair
            if index.isMultiple(of: 2) { return total + digit }
            let doubled = digit * 2
            return total + (doubled > 9 ? doubled - 9 : doubled)
        }
        return sum.isMultiple(of: 10) ? .creditCard : nil
    }
}
