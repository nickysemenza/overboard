import Foundation
import GRDB

public struct IndexedFile: Codable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "file_entry"
    public var path: String
    public var name: String
    public var foldedName: String
    public var foldedPath: String
    public var root: String
    public var generation: String
    public var modifiedAt: Date
    public var availability: FileSearchInfo.Availability
    public var isDirectory: Bool
    public var location: String
    /// Recognised at index time from the folder's own traits or the user's
    /// noise list; see `NoiseClassifier`.
    public var isNoise: Bool
    /// Written only by the Spotlight last-opened sync, never by scans.
    public var lastOpenedAt: Date?

    public init(
        path: String,
        name: String,
        root: String,
        generation: String,
        modifiedAt: Date = .distantPast,
        availability: FileSearchInfo.Availability = .local,
        isDirectory: Bool = false,
        location: String = "On this Mac",
        isNoise: Bool = false,
        lastOpenedAt: Date? = nil
    ) {
        // APFS can enumerate a canonically equivalent spelling different from
        // a URL supplied by the caller. SQLite's binary keys must agree.
        self.path = path.precomposedStringWithCanonicalMapping
        self.name = name
        self.foldedName = AppMatcher.fold(name)
        self.foldedPath = AppMatcher.fold(self.path)
        self.root = root.precomposedStringWithCanonicalMapping
        self.generation = generation
        self.modifiedAt = modifiedAt
        self.availability = availability
        self.isDirectory = isDirectory
        self.location = location
        self.isNoise = isNoise
        self.lastOpenedAt = lastOpenedAt
    }

    public var result: LauncherResult {
        .file(name: self.name, url: URL(fileURLWithPath: self.path), info: FileSearchInfo(
            availability: self.availability, isDirectory: self.isDirectory, modifiedAt: self.modifiedAt,
            location: self.location, isNoise: self.isNoise, lastOpenedAt: self.lastOpenedAt
        ))
    }
}
