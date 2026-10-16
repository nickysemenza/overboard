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
            return FileIndexChange(path: URL(fileURLWithPath: path, isDirectory: false), scope: scope)
        }
    }

    func enqueueChange(_ rawPath: String, subtree: Bool = false) {
        self.enqueueChange(rawPath, scope: subtree ? .subtree : .entry)
    }

    func enqueueChange(_ rawPath: String, scope: FileIndexRefreshScope) {
        guard !self.isStopped else { return }
        let url = URL(fileURLWithPath: rawPath, isDirectory: false).standardized
        let path = url.path.precomposedStringWithCanonicalMapping
        guard let root = self.pathPolicy.owner(of: url) else { return }
        if self.dirtyPaths.contains(where: {
            Self.covers($0, scope: self.dirtyScopes[$0, default: .entry], path: path, scope: scope)
                && self.pathPolicy.owner(of: URL(fileURLWithPath: $0, isDirectory: false)) == root
        }) {
            return
        }
        self.coalesce(path, scope: scope, owner: root)
        if self.dirtyPaths.count > 512 {
            self.compactChanges(around: path, root: root)
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

    private func coalesce(_ path: String, scope: FileIndexRefreshScope, owner: URL) {
        var order = self.nextDirtyOrder
        for existing in self.dirtyPaths {
            guard Self.covers(path, scope: scope, path: existing,
                              scope: self.dirtyScopes[existing, default: .entry]),
                self.pathPolicy.owner(of: URL(fileURLWithPath: existing, isDirectory: false)) == owner else { continue }
            order = min(order, self.dirtyOrder[existing, default: order])
            self.dirtyPaths.remove(existing)
            self.dirtyScopes.removeValue(forKey: existing)
            self.dirtyOrder.removeValue(forKey: existing)
        }
        self.dirtyPaths.insert(path)
        self.dirtyScopes[path] = scope
        self.dirtyOrder[path] = order
        self.nextDirtyOrder += 1
    }

    /// Prefer a shallow sibling reconcile. Only truly scattered overflow
    /// requires a recursive common ancestor, and never promotes other roots.
    private func compactChanges(around path: String, root: URL) {
        let parent = (path as NSString).deletingLastPathComponent
        let siblings = self.dirtyPaths.filter {
            self.dirtyScopes[$0] == .entry && ($0 as NSString).deletingLastPathComponent == parent
                && self.pathPolicy.owner(of: URL(fileURLWithPath: $0, isDirectory: false)) == root
        }
        if siblings.count > 1, self.pathPolicy.owner(of: URL(fileURLWithPath: parent, isDirectory: true)) == root {
            self.coalesce(parent, scope: .children, owner: root)
            return
        }
        var nearest = root.path
        for existing in self.dirtyPaths where existing != path {
            guard self.pathPolicy.owner(of: URL(fileURLWithPath: existing, isDirectory: false)) == root
            else { continue }
            var ancestor = parent
            while ancestor != root.path, existing != ancestor, !existing.hasPrefix(ancestor + "/") {
                ancestor = (ancestor as NSString).deletingLastPathComponent
            }
            if ancestor.count > nearest.count {
                nearest = ancestor
            }
        }
        self.coalesce(nearest, scope: .subtree, owner: root)
    }

    func enqueueEvents(_ paths: [String], flags: [FSEventStreamEventFlags]) {
        let lost = UInt32(kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped |
            kFSEventStreamEventFlagEventIdsWrapped)
        if flags.contains(where: { $0 & lost != 0 }) {
            for root in self.activeRoots {
                self.enqueueChange(root.path, scope: .subtree)
            }
            return
        }
        for (path, flags) in zip(paths, flags) {
            // Noise classification depends on ancestor rules. The file itself
            // is hidden/excluded, but changing it invalidates the subtree.
            if (path as NSString).lastPathComponent == ".gitignore" {
                self.enqueueChange((path as NSString).deletingLastPathComponent, scope: .subtree)
                continue
            }
            let recover = flags & UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged) !=
                0
            let directory = flags & UInt32(kFSEventStreamEventFlagItemIsDir) != 0
            let introduced = flags & UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRenamed) !=
                0
            let scope: FileIndexRefreshScope = recover || (directory && introduced) ? .subtree : directory ? .children :
                .entry
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
