import Foundation

/// A join link detected on a calendar event, tagged with which video provider
/// it belongs to so the row/preview can say "Join Zoom Meeting" instead of a
/// bare "Join Meeting".
public struct MeetingLink: Sendable, Equatable {
    public enum Provider: Sendable, Equatable {
        case zoom, googleMeet, teams, facetime, webex, generic
    }

    public let url: URL
    public let provider: Provider

    public init(url: URL, provider: Provider) {
        self.url = url
        self.provider = provider
    }

    /// Detects the event's join link from its url/location/notes fields, in
    /// that order. A known-provider link anywhere in that order beats a later
    /// field's generic https link, so a Zoom link buried in `notes` still
    /// wins over a plain link that happens to sit in `location`.
    public static func detect(url: URL?, location: String?, notes: String?) -> MeetingLink? {
        let candidates = [url?.absoluteString, location, notes].compactMap(\.self).flatMap(self.candidates(in:))
        return candidates.first { $0.provider != .generic } ?? candidates.first
    }

    /// Scans free text for a join link: custom-scheme matches (`zoommtg://`,
    /// `facetime:`, which `NSDataDetector` doesn't recognize) first, then
    /// anything its `.link` detector finds.
    public static func detect(in text: String) -> MeetingLink? {
        self.candidates(in: text).first
    }

    /// Calendar event pages (the event's own link, not a join link) are never
    /// candidates, whether or not their host happens to look meeting-like.
    private static let excludedHosts: Set<String> = [
        "calendar.google.com", "outlook.office.com", "outlook.live.com",
    ]

    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// `NSDataDetector`'s `.link` type only recognizes http(s)/mailto-style
    /// URLs, not custom schemes — Zoom and FaceTime's own deep links need a
    /// dedicated pattern.
    private static let customSchemePattern = try? NSRegularExpression(pattern: #"(zoommtg://|facetime:)\S+"#)

    private static func candidates(in text: String) -> [MeetingLink] {
        var results = self.customSchemeMatches(in: text)
        guard let linkDetector else { return results }
        let range = NSRange(text.startIndex..., in: text)
        for match in linkDetector.matches(in: text, range: range) {
            guard let url = match.url, let trimmed = self.stripTrailingPunctuation(from: url),
                  !self.isExcluded(trimmed)
            else { continue }
            results.append(MeetingLink(url: trimmed, provider: self.knownProvider(for: trimmed) ?? .generic))
        }
        return results
    }

    private static func customSchemeMatches(in text: String) -> [MeetingLink] {
        guard let customSchemePattern else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return customSchemePattern.matches(in: text, range: range).compactMap { match in
            guard let matchRange = Range(match.range, in: text),
                  let url = URL(string: String(text[matchRange])),
                  let trimmed = self.stripTrailingPunctuation(from: url)
            else { return nil }
            return MeetingLink(url: trimmed, provider: trimmed.scheme == "facetime" ? .facetime : .zoom)
        }
    }

    private static func knownProvider(for url: URL) -> Provider? {
        guard let host = url.host?.lowercased() else { return nil }
        if host.contains("zoom.us") {
            return .zoom
        }
        if host == "meet.google.com" {
            return .googleMeet
        }
        if host.contains("teams.microsoft.com") || host.contains("teams.live.com") {
            return .teams
        }
        if host.contains("webex.com") {
            return .webex
        }
        return nil
    }

    private static func isExcluded(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return self.excludedHosts.contains(host)
    }

    /// A join link copy-pasted at the end of a sentence often drags a
    /// trailing "." or ")" along with it.
    private static func stripTrailingPunctuation(from url: URL) -> URL? {
        var string = url.absoluteString
        while let last = string.last, last == "." || last == ")" {
            string.removeLast()
        }
        return URL(string: string)
    }
}
