import Foundation

/// Fetched, pre-rendered metadata for a `.link` clip: a page title and
/// description plus already-downscaled PNG bytes for the favicon and a preview
/// image. All optional — any field may be missing for a page that doesn't
/// advertise it, and an all-nil result is still meaningful ("we tried").
public struct LinkMetadata: Sendable, Equatable {
    public var title: String?
    public var description: String?
    public var faviconPNG: Data?
    public var previewImagePNG: Data?

    public init(
        title: String? = nil,
        description: String? = nil,
        faviconPNG: Data? = nil,
        previewImagePNG: Data? = nil
    ) {
        self.title = title
        self.description = description
        self.faviconPNG = faviconPNG
        self.previewImagePNG = previewImagePNG
    }
}
