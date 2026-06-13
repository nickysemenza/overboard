import Foundation

/// What this build actually is. `MARKETING_VERSION` only moves on tagged
/// releases (release.yml stamps it from the tag), so a dogfood build sitting a
/// few commits past the last tag still calls itself e.g. "0.1.0" — true to the
/// tag, a lie about the bits. `gitDescribe` is the honest counterpart, baked in
/// by the "Embed git version" build phase (see Overboard.xcodeproj).
public enum AppVersion {
    /// CFBundleShortVersionString — the tagged release this descends from.
    public static var marketing: String {
        infoString("CFBundleShortVersionString") ?? "?"
    }

    /// CFBundleVersion — the monotonic build number.
    public static var build: String {
        infoString("CFBundleVersion") ?? "?"
    }

    /// `git describe --tags --always --dirty` at build time, e.g.
    /// "v0.1.0-3-gabc1234" (three commits past v0.1.0) or "…-dirty" with
    /// uncommitted changes. Nil when git was unavailable (source-zip builds).
    public static var gitDescribe: String? {
        infoString("GitDescribe")
    }

    /// Short commit SHA at build time. Nil when git was unavailable.
    public static var gitSHA: String? {
        infoString("GitSHA")
    }

    /// One-liner for the launcher subtitle.
    public static var detail: String {
        if let git = gitDescribe { "\(git) · build \(build)" } else { "build \(build)" }
    }

    /// Full human string, suitable for a bug report.
    public static var summary: String {
        if let git = gitDescribe { "Overboard \(marketing) (\(git))" } else { "Overboard \(marketing) (build \(build))" }
    }

    /// True when the source has drifted from the tag — a dirty tree or any
    /// commits past it. Lets the UI flag "you are not on a released version".
    public static var isDirtyOrAhead: Bool {
        guard let git = gitDescribe else { return false }
        return git.hasSuffix("-dirty") || git.contains("-g")
    }

    private static func infoString(_ key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty else { return nil }
        return value
    }
}
