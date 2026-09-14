import Foundation

/// Surfaces CoreAudio output devices as launcher rows: every device for a
/// generic "audio"/"output"/"speaker"/"sound" query, or just the ones whose
/// name matches otherwise (so "airp" finds AirPods Pro without typing the
/// generic keyword first).
///
/// `devices` is injected so OverboardCore stays free of CoreAudio — the real
/// list comes from OverboardMac's `AudioOutputService`, itself called from a
/// `@Sendable` closure since providers run off the main actor.
public struct AudioOutputSearchProvider: LauncherProvider {
    public var searchScopes: Set<LauncherScope> {
        [.all]
    }

    /// Generic terms that mean "show me every output", not a specific device.
    private static let keywords = ["audio", "output", "speaker", "sound"]
    private static let limit = 5

    private let devices: @Sendable () -> [AudioOutputDevice]

    public init(devices: @escaping @Sendable () -> [AudioOutputDevice]) {
        self.devices = devices
    }

    public func results(for query: String) async -> [LauncherResult] {
        // Two characters before a device name can match (`ai` → AirPods),
        // three before a generic keyword does — otherwise a lone `a` would
        // list every output on the Mac.
        guard query.count >= 2, !LauncherQuery.isCommandLike(query) else { return [] }
        let devices = self.devices()
        guard !devices.isEmpty else { return [] }

        if query.count >= 3, Self.isGenericKeyword(query) {
            return devices
                .sorted { $0.isDefault && !$1.isDefault }
                .map { .audioOutput($0) }
        }

        let ranked = AppMatcher.rank(query: query, names: devices.map(\.name), limit: Self.limit)
        return ranked.map { .audioOutput(devices[$0]) }
    }

    /// True when `query` is a prefix of one of the generic keywords — "aud"
    /// matches "audio" the same way app search lets "chr" match "Chrome".
    private static func isGenericKeyword(_ query: String) -> Bool {
        let folded = AppMatcher.fold(query.trimmingCharacters(in: .whitespaces))
        guard !folded.isEmpty else { return false }
        return self.keywords.contains { $0.hasPrefix(folded) }
    }
}
