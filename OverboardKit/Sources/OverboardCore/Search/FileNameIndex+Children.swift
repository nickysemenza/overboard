import Foundation
import GRDB

public extension FileNameIndex {
    /// Drops a former directory's children while preserving its own record.
    func removeDescendants(under path: String) async throws {
        let path = path.precomposedStringWithCanonicalMapping
        try await self.database.write { db in
            try db.execute(sql: "DELETE FROM file_entry WHERE path >= ? AND path < ?",
                           arguments: [path + "/", path + "0"])
        }
    }

    /// The previous immediate children for a shallow filesystem reconcile.
    /// Seek through the path index, jumping over descendant ranges instead of
    /// filtering every row in a large root. Root ownership is checked after
    /// each seek so SQLite cannot pick the root index and scan the whole root.
    func children(under path: String, root: String) async throws -> [IndexedFile] {
        let path = path.precomposedStringWithCanonicalMapping
        let root = root.precomposedStringWithCanonicalMapping
        let prefix = path + "/"
        return try await self.database.read { db in
            let statement = try db.cachedStatement(sql: """
            SELECT * FROM file_entry WHERE path >= ? AND path < ? AND path != ? ORDER BY path LIMIT 1
            """)
            var lowerBound = prefix
            var previousPath = ""
            var children: [IndexedFile] = []
            while let child = try IndexedFile.fetchOne(statement, arguments: [lowerBound, path + "0", previousPath]) {
                let relative = child.path.dropFirst(prefix.count)
                if let separator = relative.firstIndex(of: "/") {
                    lowerBound = prefix + relative[..<separator] + "0"
                    previousPath = ""
                } else {
                    if child.root == root {
                        children.append(child)
                    }
                    // Exclude the exact row without skipping siblings such as
                    // folder.backup, which sort before folder's descendants.
                    lowerBound = child.path
                    previousPath = child.path
                }
            }
            return children
        }
    }
}
