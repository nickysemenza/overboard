import Darwin
import Foundation
import OverboardCore
import OverboardMac

/// Exercises real filesystem discovery and incremental refreshes on synthetic
/// files. Database and files are temporary; no user locations are scanned.
@main
struct FileScanBenchmark {
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = directory.appendingPathComponent("fixture", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for folder in 0 ..< 50 {
            let folderURL = root.appendingPathComponent("project-\(folder)", isDirectory: true)
            try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
            for file in 0 ..< 100 {
                try Data().write(to: folderURL.appendingPathComponent("notes-\(file).txt"))
            }
        }
        let rootURL = FileMetadataScanner.canonicalURL(root)
        let index = try FileNameIndex(url: directory.appendingPathComponent("files.sqlite"))
        _ = try await FileMetadataScanner.scan(root: rootURL, exclusions: [], generation: "initial", index: index)
        for scope in [FileIndexRefreshScope.subtree, .children, .entry] {
            let clock = ContinuousClock()
            let start = clock.now
            let cpu = Self.cpuSeconds()
            let issues = try await FileMetadataScanner.refresh(rootURL, roots: [rootURL], exclusions: [],
                                                               index: index, scope: scope)
            let elapsed = start.duration(to: clock.now)
            let cpuUsed = Self.cpuSeconds() - cpu
            let count = try await index.count()
            print("FILE_SCAN_BENCHMARK scope=\(scope) elapsed=\(elapsed) cpu_seconds=\(cpuUsed) " +
                "count=\(count) issues=\(issues.count)")
            guard issues.isEmpty, count == 5050 else { throw Failure.lostFiles }
        }
    }

    private static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }

    enum Failure: Error { case lostFiles }
}
