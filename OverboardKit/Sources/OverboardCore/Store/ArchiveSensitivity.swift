import Foundation

struct ArchiveSettingsFilter: Sendable {
    let settings: ClipArchive.Settings
    let excluded: Int
}

enum ArchiveSensitivity {
    static func label(for reps: [ClipArchive.Rep], in directory: URL, sharded: Bool,
                      limit: Int = 512 * 1024 * 1024) throws -> String?
    {
        for rep in reps
            where [WellKnownUTI.plainText, WellKnownUTI.html, WellKnownUTI.rtf, "public.url"].contains(rep.uti)
        {
            let bytes: Data
            if let data = rep.data {
                bytes = data
            } else if let hash = rep.blob {
                guard ArchiveIO.isHash(hash), rep.byteSize >= 0, rep.byteSize < Int.max,
                      rep.byteSize <= limit else { throw ClipArchive.Failure.invalid("blob reference") }
                let name = sharded ? "\(hash.prefix(2))/\(hash)" : "blobs/\(hash)"
                guard let handle = try ArchiveIO.file(name, in: directory, optional: true) else { continue }
                defer { try? handle.close() }
                bytes = try handle.read(upToCount: rep.byteSize + 1) ?? Data()
                guard bytes.count == rep.byteSize else { throw ClipArchive.Failure.invalid("blob size") }
            } else {
                throw ClipArchive.Failure.invalid("representation")
            }
            if let label = ClipSensitivity.label(for: [.init(uti: rep.uti, data: bytes)]) {
                return label
            }
        }
        return nil
    }

    static func containsSecret(_ value: ClipArchive.SettingValue) -> Bool {
        switch value {
        case let .string(text): ClipSensitivity.label(for: text) != nil
        case let .strings(strings): strings.contains { ClipSensitivity.label(for: $0) != nil }
        case let .counts(counts): counts.keys.contains { self.containsSecret(inRankingKey: $0) }
        case let .timestamps(timestamps): timestamps.keys.contains { ClipSensitivity.label(for: $0) != nil }
        case .boolean, .integer: false
        }
    }

    static func filterCountMap(_ counts: [String: Int]) -> [String: Int] {
        counts.filter { !self.containsSecret(inRankingKey: $0.key) }
    }

    static func filterSettings(_ settings: ClipArchive.Settings) -> ArchiveSettingsFilter {
        var filtered = settings
        var excluded = 0
        for (name, value) in settings.values {
            switch value {
            case let .counts(counts):
                let safeCounts = self.filterCountMap(counts)
                filtered.values[name] = .counts(safeCounts)
                excluded += counts.count - safeCounts.count
            default:
                if self.containsSecret(value) {
                    filtered.values.removeValue(forKey: name)
                    excluded += 1
                }
            }
        }
        return ArchiveSettingsFilter(settings: filtered, excluded: excluded)
    }

    private static func containsSecret(inRankingKey key: String) -> Bool {
        let query = key.split(separator: "\u{1F}", maxSplits: 1, omittingEmptySubsequences: false).first
            .map(String.init) ?? key
        return ClipSensitivity.label(for: query) != nil || ClipSensitivity.label(for: key) != nil
    }
}
