import Foundation

public struct FileSearchInfo: Sendable, Equatable, Codable {
    public enum Availability: String, Sendable, Codable {
        case local, cloud, downloading, unavailable
    }

    public var availability: Availability
    public var isDirectory: Bool
    public var modifiedAt: Date?
    public var location: String?

    public init(
        availability: Availability = .local,
        isDirectory: Bool = false,
        modifiedAt: Date? = nil,
        location: String? = nil
    ) {
        self.availability = availability
        self.isDirectory = isDirectory
        self.modifiedAt = modifiedAt
        self.location = location
    }
}
