import Foundation
import OverboardCore

/// A deterministic, disk-backed benchmark. No user files or clipboard data.
@main
struct FileIndexBenchmark {
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let index = try FileNameIndex(url: directory.appendingPathComponent("files.sqlite"))
        let clock = ContinuousClock()
        let start = clock.now
        let names = ["budget", "meeting", "proposal", "photo", "report", "invoice", "design", "release", "schedule", "notes"]
        let extensions = ["pdf", "xlsx", "md", "jpg", "txt"]
        for batch in 0 ..< 100 {
            let files = (0 ..< 1000).map { offset in
                let id = batch * 1000 + offset
                let root = id.isMultiple(of: 2) ? "/fixture/iCloud Drive" : "/fixture/Documents"
                let name = "\(names[id % names.count])-\(id).\(extensions[(id / 10) % extensions.count])"
                return IndexedFile(path: "\(root)/Project-\(id % 317)/\(name)", name: name, root: root,
                                   generation: "benchmark", availability: id.isMultiple(of: 3) ? .cloud : .local)
            }
            try await index.upsert(files)
        }
        let initial = start.duration(to: clock.now)
        let queries = ["budget", "project 126 invoice", "report 45874", "budegt", "design", "schedule 778", "notes", "photo 2093", "release", "meeting"]
        // Prime caches separately from the warm samples.
        for query in queries {
            let begin = clock.now
            _ = try await index.search(query)
            FileHandle.standardOutput.write(Data("warmup query=\(query) elapsed=\(begin.duration(to: clock.now))\n".utf8))
        }
        var durations: [Double] = []
        for _ in 0 ..< 10 {
            for query in queries {
                let begin = clock.now
                _ = try await index.search(query)
                let parts = begin.duration(to: clock.now).components
                durations.append(Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15)
            }
        }
        durations.sort()
        let p95 = durations[Int(ceil(Double(durations.count) * 0.95)) - 1]
        let bytes = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
            .reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        let report = "FILE_INDEX_BENCHMARK count=100000 initial_metadata_ingest=\(initial) disk_bytes=\(bytes) warm_samples=\(durations.count) p95_ms=\(p95)\n"
        FileHandle.standardOutput.write(Data(report.utf8))
        guard p95 < 100 else { throw BenchmarkFailure.tooSlow }
    }

    enum BenchmarkFailure: Error { case tooSlow }
}
