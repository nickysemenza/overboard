import Foundation

public struct FileSearchInfo: Sendable, Equatable, Codable {
    public enum Availability: String, Sendable, Codable {
        case local, cloud, downloading, unavailable
    }

    public var availability: Availability
    public var isDirectory: Bool
    public var modifiedAt: Date?
    public var location: String?
    /// Inside a noise location (see GLOSSARY.md): demoted, never hidden.
    public var isNoise: Bool
    /// When macOS last saw the file opened, by any app (Spotlight's
    /// `kMDItemLastUsedDate`); nil when Spotlight hasn't reported one.
    public var lastOpenedAt: Date?
    /// Folders between the file and its search root; 1 for a root's child.
    public var depth: Int?

    public init(
        availability: Availability = .local,
        isDirectory: Bool = false,
        modifiedAt: Date? = nil,
        location: String? = nil,
        isNoise: Bool = false,
        lastOpenedAt: Date? = nil,
        depth: Int? = nil
    ) {
        self.availability = availability
        self.isDirectory = isDirectory
        self.modifiedAt = modifiedAt
        self.location = location
        self.isNoise = isNoise
        self.lastOpenedAt = lastOpenedAt
        self.depth = depth
    }
}
