import os

public func obTrace(_ message: String) {
    #if DEBUG
        let event = RedactedUITrace.event(for: message)
        Logger(subsystem: "com.nickysemenza.overboard", category: "ui")
            .debug("UI event: \(event, privacy: .public)")
        OSSignposter(subsystem: "com.nickysemenza.overboard", category: "ui")
            .emitEvent("UI event", "\(event, privacy: .public)")
    #endif
}

public func obTracePanelPresentation(_ message: String) -> () -> Void {
    #if DEBUG
        let event = RedactedUITrace.event(for: message)
        guard ["launcher.show", "drawer.show", "emoji.show"].contains(event) else { return {} }
        let signposter = OSSignposter(subsystem: "com.nickysemenza.overboard", category: "ui")
        let interval = signposter.beginInterval(
            "Panel presentation", id: signposter.makeSignpostID(), "\(event, privacy: .public)"
        )
        obTrace(event)
        return { signposter.endInterval("Panel presentation", interval, "\(event, privacy: .public)") }
    #else
        return {}
    #endif
}

enum RedactedUITrace {
    private nonisolated static let allowedEvents: Set<String> = [
        "launcher.show", "launcher.hide", "launcher.search.start", "launcher.search.finish",
        "drawer.show", "drawer.hide", "emoji.show", "emoji.hide", "palette.open", "palette.close",
    ]

    nonisolated static func event(for message: String) -> String {
        self.allowedEvents.contains(message) ? message : "redacted"
    }
}
