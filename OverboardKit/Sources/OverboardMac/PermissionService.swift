import ApplicationServices
import Foundation

/// Accessibility (TCC) state. Direct paste is an upgrade, not a gate: every
/// feature except ⌘V synthesis works without this permission.
@MainActor
public enum PermissionService {
    private static var hasPromptedThisLaunch = false

    public static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Shows the system Accessibility prompt at most once per launch.
    public static func promptIfNeeded() {
        guard !self.isTrusted, !self.hasPromptedThisLaunch else { return }
        self.hasPromptedThisLaunch = true
        // Literal key because kAXTrustedCheckOptionPrompt (a global Unmanaged
        // CFString) isn't concurrency-safe to reference under Swift 6.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }
}
