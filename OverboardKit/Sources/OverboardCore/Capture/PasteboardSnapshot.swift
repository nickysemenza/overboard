import Foundation

/// A plain-struct picture of the pasteboard at one change count, taken by the
/// platform layer. Nothing in OverboardCore ever touches NSPasteboard; this is
/// the boundary type.
public struct PasteboardSnapshot: Sendable, Equatable {
    public struct Rep: Sendable, Equatable {
        public var uti: String
        public var data: Data

        public init(uti: String, data: Data) {
            self.uti = uti
            self.data = data
        }
    }

    public var reps: [Rep]
    public var sourceBundleID: String?
    public var sourceAppName: String?
    /// Back-to-source provenance: the front-tab URL/title of the browser the
    /// copy came from, attached after capture (nil for non-browser copies).
    public var sourceURL: String?
    public var sourceTitle: String?
    public var capturedAt: Date

    public init(
        reps: [Rep],
        sourceBundleID: String?,
        sourceAppName: String?,
        sourceURL: String? = nil,
        sourceTitle: String? = nil,
        capturedAt: Date = Date()
    ) {
        self.reps = reps
        self.sourceBundleID = sourceBundleID
        self.sourceAppName = sourceAppName
        self.sourceURL = sourceURL
        self.sourceTitle = sourceTitle
        self.capturedAt = capturedAt
    }
}

/// Well-known UTIs used across capture and paste-back.
public enum WellKnownUTI {
    public static let plainText = "public.utf8-plain-text"
    public static let rtf = "public.rtf"
    public static let html = "public.html"
    public static let png = "public.png"
    public static let tiff = "public.tiff"
    /// JSON-encoded `[String]` of absolute file URL strings. Internal flavor —
    /// the platform layer converts to/from real file URLs on the pasteboard.
    public static let fileURLs = "com.nickysemenza.overboard.file-urls"
    public static let color = "com.apple.cocoa.pasteboard.color"
}
