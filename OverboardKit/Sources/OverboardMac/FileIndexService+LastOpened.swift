import CoreServices
import Foundation
import OverboardCore

/// Borrows one signal from Spotlight: when macOS last saw each file opened,
/// by any app. Spotlight stays out of retrieval and matching; this only
/// feeds `LauncherScore`'s last-opened boost. Without Spotlight (disabled, or
/// a folder excluded from it) the boost is simply absent.
extension FileIndexService {
    nonisolated static let lastOpenedWindowDays = 90
    nonisolated static let lastOpenedRefresh: Duration = .seconds(30 * 60)

    /// Syncs now, then every `lastOpenedRefresh`, until the lifecycle ends.
    /// Only the app's own index syncs: test instances configure their roots.
    func startLastOpenedSync(index: FileNameIndex) {
        guard self.rootsOverride == nil else { return }
        self.lastOpenedTask?.cancel()
        self.lastOpenedTask = Task.detached(priority: .background) {
            while !Task.isCancelled {
                try? await index.setLastOpened(Self.spotlightLastOpened())
                try? await Task.sleep(for: Self.lastOpenedRefresh)
            }
        }
    }

    nonisolated static func spotlightLastOpened() -> [String: Date] {
        let predicate = "kMDItemLastUsedDate >= $time.today(-\(self.lastOpenedWindowDays))" as CFString
        guard let query = MDQueryCreate(kCFAllocatorDefault, predicate, nil, nil) else { return [:] }
        MDQuerySetSearchScope(query, [NSHomeDirectory()] as CFArray, 0)
        guard MDQueryExecute(query, CFOptionFlags(kMDQuerySynchronous.rawValue)) else { return [:] }
        var dates: [String: Date] = [:]
        for position in 0 ..< MDQueryGetResultCount(query) {
            guard let raw = MDQueryGetResultAtIndex(query, position) else { continue }
            let item = Unmanaged<MDItem>.fromOpaque(raw).takeUnretainedValue()
            guard let path = MDItemCopyAttribute(item, kMDItemPath) as? String,
                  let date = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
            else { continue }
            dates[path.precomposedStringWithCanonicalMapping] = date
        }
        return dates
    }
}
