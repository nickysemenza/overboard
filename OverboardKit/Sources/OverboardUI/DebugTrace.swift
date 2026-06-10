import Foundation

/// Dev-only tracing to a flat file, because unified log querying is unreliable
/// for headless debugging. No-op in release builds.
public func obTrace(_ message: String) {
    #if DEBUG
        let line = "\(Date().formatted(date: .omitted, time: .standard)) \(message)\n"
        let url = URL(fileURLWithPath: "/tmp/overboard-trace.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    #endif
}
