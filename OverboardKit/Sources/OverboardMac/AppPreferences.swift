// Re-exported so the app target and OverboardUI reach Defaults[...] through
// their existing OverboardMac import without a pbxproj package reference.
@_exported import Defaults
import Foundation

public extension Defaults.Keys {
    // Raw key strings predate the Defaults migration — keep them byte-identical
    // so existing users' stored values survive.
    static let historyLimit = Key<Int>("historyLimit", default: 1000)
    static let restoreClipboard = Key<Bool>("restoreClipboardAfterPaste", default: true)
    static let excludedBundleIDs = Key<String>(
        "excludedBundleIDs",
        default: ClipboardMonitor.defaultExclusions.sorted().joined(separator: "\n")
    )
    static let plainTextBundleIDs = Key<String>(
        "plainTextBundleIDs",
        default: "com.apple.Terminal\ncom.googlecode.iterm2"
    )
    /// Minutes before detected secrets are hard-deleted; 0 disables expiry.
    static let secretTTLMinutes = Key<Int>("secretTTLMinutes", default: 10)
    /// Apple Intelligence features: auto-titles, categories, AI transforms.
    static let aiFeatures = Key<Bool>("aiFeatures", default: true)
    /// Spotlight file results in the launcher bar.
    static let launcherFileResults = Key<Bool>("launcherFileResults", default: true)
}

/// Parsed views over the newline-list preference keys.
public enum Preferences {
    public static func currentExclusions() -> Set<String> {
        self.bundleIDSet(Defaults[.excludedBundleIDs])
    }

    /// Apps where pasted text should always be plain (terminals etc.).
    public static func currentPlainTextApps() -> Set<String> {
        self.bundleIDSet(Defaults[.plainTextBundleIDs])
    }

    private static func bundleIDSet(_ raw: String) -> Set<String> {
        Set(
            raw.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        )
    }
}
