import Darwin
import Foundation
import OverboardCore

/// Index-time noise detection for one scan: a folder is a noise location
/// when its name carries a version stamp or a `.gitignore` above it ignores
/// it, and everything inside a noise location is noise too. Results are
/// cached per folder, so each folder's name and `.gitignore` are examined
/// once per scan however many files it holds.
///
/// `.gitignore` is the one file whose contents indexing reads, and only when
/// it is already on disk: a dataless cloud placeholder is never downloaded.
final nonisolated class NoiseTracker {
    private let root: String
    private var folders: [String: Bool] = [:]
    private var rules: [String: GitIgnoreRules?] = [:]

    init(root: String) {
        self.root = root
    }

    func isNoise(path: String, isDirectory: Bool) -> Bool {
        if isDirectory, let cached = self.folders[path] {
            return cached
        }
        let parent = (path as NSString).deletingLastPathComponent
        let noisy = self.folderIsNoise(parent)
            || (isDirectory && NoiseClassifier.isVersionStamped(folderName: (path as NSString).lastPathComponent))
            || self.ignoredByGitignore(path, isDirectory: isDirectory)
        if isDirectory {
            self.folders[path] = noisy
        }
        return noisy
    }

    private func folderIsNoise(_ folder: String) -> Bool {
        guard folder != self.root, folder.hasPrefix(self.root + "/") else { return false }
        return self.isNoise(path: folder, isDirectory: true)
    }

    /// Each `.gitignore` from the file's own folder up to the root, as git
    /// itself would consult them.
    private func ignoredByGitignore(_ path: String, isDirectory: Bool) -> Bool {
        var folder = (path as NSString).deletingLastPathComponent
        while folder == self.root || folder.hasPrefix(self.root + "/") {
            if let rules = self.rules(in: folder),
               rules.ignores(relativePath: String(path.dropFirst(folder.count + 1)), isDirectory: isDirectory)
            {
                return true
            }
            guard folder != self.root else { break }
            folder = (folder as NSString).deletingLastPathComponent
        }
        return false
    }

    private func rules(in folder: String) -> GitIgnoreRules? {
        if let cached = self.rules[folder] {
            return cached
        }
        let loaded = Self.readGitignore(at: folder + "/.gitignore")
        self.rules[folder] = .some(loaded)
        return loaded
    }

    private static func readGitignore(at path: String) -> GitIgnoreRules? {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_flags & UInt32(SF_DATALESS) == 0, info.st_size <= 64 * 1024,
              let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        let rules = GitIgnoreRules(text)
        return rules.isEmpty ? nil : rules
    }
}
