import CoreServices
import Foundation

nonisolated struct FileIndexChange: Sendable {
    let path: URL
    let scope: FileIndexRefreshScope
}

extension FileIndexService {
    func consumeDirtyChanges() -> [FileIndexChange] {
        let paths = self.dirtyPaths.sorted {
            self.dirtyOrder[$0, default: 0] < self.dirtyOrder[$1, default: 0]
        }.prefix(32)
        return paths.map { path in
            let scope = self.dirtyScopes.removeValue(forKey: path) ?? .entry
            self.dirtyPaths.remove(path)
            self.dirtyOrder.removeValue(forKey: path)
            self.dirtyOwners.removeValue(forKey: path)
            return FileIndexChange(path: URL(fileURLWithPath: path, isDirectory: false), scope: scope)
        }
    }

    func clearDirtyChanges() {
        self.dirtyPaths.removeAll()
        self.dirtyScopes.removeAll()
        self.dirtyOrder.removeAll()
        self.dirtyOwners.removeAll()
    }

    func enqueueChange(_ rawPath: String, subtree: Bool = false) {
        self.enqueueChange(rawPath, scope: subtree ? .subtree : .entry)
    }

    func enqueueChange(_ rawPath: String, scope: FileIndexRefreshScope) {
        guard !self.isStopped else { return }
        let url = URL(fileURLWithPath: rawPath, isDirectory: false).standardized
        let path = url.path.precomposedStringWithCanonicalMapping
        guard let root = self.pathPolicy.owner(of: url) else { return }
        if self.isCovered(path, scope: scope, owner: root.path) {
            return
        }
        self.coalesce(path, scope: scope, owner: root.path)
        if self.dirtyPaths.count > 512 {
            self.compactChanges(around: path, root: root)
        }
    }

    /// Whether an already-dirty ancestor (or the path itself) makes this change
    /// redundant. Only the path and its ancestors can cover it, so this walks
    /// the path upward through dictionary lookups instead of scanning every
    /// dirty path on every event.
    private func isCovered(_ path: String, scope: FileIndexRefreshScope, owner: String) -> Bool {
        var candidate = path
        while true {
            if self.dirtyPaths.contains(candidate), self.dirtyOwners[candidate] == owner,
               Self.covers(candidate, scope: self.dirtyScopes[candidate, default: .entry], path: path, scope: scope)
            {
                return true
            }
            let parent = (candidate as NSString).deletingLastPathComponent
            if parent == candidate || parent.isEmpty {
                return false
            }
            candidate = parent
        }
    }

    private static func covers(_ ancestor: String, scope: FileIndexRefreshScope,
                               path: String, scope requested: FileIndexRefreshScope) -> Bool
    {
        if path == ancestor {
            return scope.rawValue >= requested.rawValue
        }
        if scope == .subtree {
            return path.hasPrefix(ancestor + "/")
        }
        return scope == .children && requested == .entry && (path as NSString).deletingLastPathComponent == ancestor
    }

    private func coalesce(_ path: String, scope: FileIndexRefreshScope, owner: String) {
        var order = self.nextDirtyOrder
        for existing in self.dirtyPaths {
            guard Self.covers(path, scope: scope, path: existing,
                              scope: self.dirtyScopes[existing, default: .entry]),
                self.dirtyOwners[existing] == owner else { continue }
            order = min(order, self.dirtyOrder[existing, default: order])
            self.dirtyPaths.remove(existing)
            self.dirtyScopes.removeValue(forKey: existing)
            self.dirtyOrder.removeValue(forKey: existing)
            self.dirtyOwners.removeValue(forKey: existing)
        }
        self.dirtyPaths.insert(path)
        self.dirtyScopes[path] = scope
        self.dirtyOrder[path] = order
        self.dirtyOwners[path] = owner
        self.nextDirtyOrder += 1
    }

    /// Prefer a shallow sibling reconcile. Only truly scattered overflow
    /// requires a recursive common ancestor, and never promotes other roots.
    private func compactChanges(around path: String, root: URL) {
        let parent = (path as NSString).deletingLastPathComponent
        let siblings = self.dirtyPaths.filter {
            self.dirtyScopes[$0] == .entry && ($0 as NSString).deletingLastPathComponent == parent
                && self.dirtyOwners[$0] == root.path
        }
        if siblings.count > 1, self.pathPolicy.owner(of: URL(fileURLWithPath: parent, isDirectory: true)) == root {
            self.coalesce(parent, scope: .children, owner: root.path)
            return
        }
        var nearest = root.path
        for existing in self.dirtyPaths where existing != path {
            guard self.dirtyOwners[existing] == root.path else { continue }
            var ancestor = parent
            while ancestor != root.path, existing != ancestor, !existing.hasPrefix(ancestor + "/") {
                ancestor = (ancestor as NSString).deletingLastPathComponent
            }
            if ancestor.count > nearest.count {
                nearest = ancestor
            }
        }
        self.coalesce(nearest, scope: .subtree, owner: root.path)
    }

    /// Re-queues every root recursively: after dropped events the only safe
    /// assumption is that anything may have changed.
    func enqueueAllRoots() {
        for root in self.activeRoots {
            self.enqueueChange(root.path, scope: .subtree)
        }
    }

    func enqueueEvents(_ paths: [String], flags: [FSEventStreamEventFlags]) {
        if flags.contains(where: { $0 & FileIndexEventFilter.lostFlags != 0 }) {
            self.enqueueAllRoots()
            return
        }
        for (path, flags) in zip(paths, flags) {
            // Noise classification depends on ancestor rules. The file itself
            // is hidden/excluded, but changing it invalidates the subtree.
            if (path as NSString).lastPathComponent == ".gitignore" {
                self.enqueueChange((path as NSString).deletingLastPathComponent, scope: .subtree)
                continue
            }
            let scope = FileIndexEventFilter.scope(for: flags)
            self.enqueueChange(path, scope: scope)
            if scope == .subtree {
                // A parent scan intentionally skips separately owned roots.
                // Recovery for that parent must therefore enqueue them too.
                let prefix = URL(fileURLWithPath: path, isDirectory: true).standardized.path + "/"
                for root in self.activeRoots where root.path.hasPrefix(prefix) {
                    self.enqueueChange(root.path, scope: .subtree)
                }
            }
        }
    }
}
