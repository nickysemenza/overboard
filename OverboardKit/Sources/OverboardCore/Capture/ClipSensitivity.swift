import Foundation

public enum ClipSensitivity {
    public static func label(for text: String) -> String? {
        if text.contains("-----BEGIN"), text.contains("PRIVATE KEY-----") {
            return SecretDetector.SecretKind.privateKey.label
        }
        if let secret = SecretDetector.detect(in: text) {
            return secret.label
        }
        let punctuation = CharacterSet(charactersIn: "\"'`,;()[]<>")
        let candidates = text.components(separatedBy: .newlines) + text.components(
            separatedBy: .whitespacesAndNewlines.union(punctuation)
        )
        for candidate in candidates {
            let trimmed = candidate.trimmingCharacters(in: punctuation.union(.whitespaces))
            if let secret = SecretDetector.detect(in: trimmed) {
                return secret.label
            }
            if let url = URL(string: trimmed), url.scheme != nil, URLSensitivity.isSensitive(url) {
                return "Link with credentials"
            }
            if let separator = trimmed.firstIndex(of: "="),
               let secret = SecretDetector.detect(in: String(trimmed[trimmed.index(after: separator)...]))
            {
                return secret.label
            }
        }
        return nil
    }

    public static func label(for representations: [PasteboardSnapshot.Rep]) -> String? {
        for representation in representations where [
            WellKnownUTI.plainText, WellKnownUTI.html, WellKnownUTI.rtf, "public.url",
        ].contains(representation.uti) {
            if let text = String(data: representation.data, encoding: .utf8),
               let label = self.label(for: text)
            {
                return label
            }
        }
        return nil
    }

    public static func maskedPreview(label: String) -> String {
        "Secret — \(label)"
    }
}
