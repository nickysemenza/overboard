import Foundation
import OverboardCore

nonisolated struct FileIndexScanRequest: Sendable {
    var root: URL
    var exclusions: [String]
    var generation: String
    var index: FileNameIndex
    var roots: [URL]
}

nonisolated struct FileIndexOperations: Sendable {
    var search: @Sendable (FileNameIndex, String, LauncherSearchContext) async throws -> [LauncherResult] = {
        try await $0.search($1, context: $2)
    }

    var scan: @Sendable (FileIndexScanRequest) async throws -> [String] = { request in
        try await FileMetadataScanner.scan(
            root: request.root,
            exclusions: request.exclusions,
            generation: request.generation,
            index: request.index,
            roots: request.roots
        )
    }

    var refresh: @Sendable (FileIndexRefreshRequest) async throws -> [String] = { request in
        try await FileMetadataScanner.refresh(
            request.path, roots: request.roots, exclusions: request.exclusions, index: request.index
        )
    }
}

nonisolated struct FileIndexRefreshRequest: Sendable {
    var path: URL
    var roots: [URL]
    var exclusions: [String]
    var index: FileNameIndex
}
