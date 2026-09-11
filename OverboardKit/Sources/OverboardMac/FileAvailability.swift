import AppKit
import Darwin
import OverboardCore

public nonisolated enum FileAvailability {
    public static func status(at url: URL, values: URLResourceValues? = nil) -> FileSearchInfo.Availability {
        var attributes = stat()
        guard lstat(url.path, &attributes) == 0 else { return .unavailable }
        if attributes.st_flags & UInt32(SF_DATALESS) != 0 { return .cloud }
        let values = values ?? (try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey, .ubiquitousItemIsDownloadingKey]))
        if values?.ubiquitousItemIsDownloading == true { return .downloading }
        if values?.ubiquitousItemDownloadingStatus == .notDownloaded { return .cloud }
        return .local
    }
}

public enum FileOpening {
    /// Re-check availability at action time: a stored entry can have been
    /// evicted, moved or downloaded since its metadata was indexed.
    public static func open(_ url: URL) async throws {
        let state = await Task.detached(priority: .userInitiated) { FileAvailability.status(at: url) }.value
        if state == .unavailable { throw CocoaError(.fileNoSuchFile) }
        if state == .cloud {
            let ubiquitous = try url.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem == true
            if ubiquitous {
                try FileManager.default.startDownloadingUbiquitousItem(at: url)
                for _ in 0 ..< 120 {
                    try Task.checkCancellation()
                    try await Task.sleep(for: .milliseconds(500))
                    let values = try url.resourceValues(forKeys: [.ubiquitousItemDownloadingErrorKey])
                    if let error = values.ubiquitousItemDownloadingError { throw error }
                    if FileAvailability.status(at: url) == .local { break }
                }
                guard FileAvailability.status(at: url) == .local else { throw URLError(.timedOut) }
            }
            // Third-party File Providers hydrate through their registered open
            // handler. Never impersonate their private enumeration APIs.
        }
        try await NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration())
    }
}
