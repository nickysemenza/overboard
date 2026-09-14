import OverboardMac
@testable import OverboardUI
import SnapshotTesting
import SwiftUI
import Testing

/// Settings → Permissions with every state it has to render at once: one
/// permission granted, one Automation target refused, one unreadable folder.
/// The stubbed `PermissionService` is what keeps this reproducible — the real
/// one reports whichever browsers this particular Mac happens to have.
@MainActor
struct PermissionsTabSnapshotTests {
    private func host(dark: Bool = false) -> NSImage {
        snapshotImage(
            PermissionsSettingsTab(
                permissions: PermissionService(
                    accessibility: .granted,
                    automation: [
                        "com.apple.Safari": .granted,
                        "com.google.Chrome": .denied,
                        "com.spotify.client": .unknown,
                    ],
                    calendar: .denied
                ),
                fileIssues: {
                    ["/Users/overboard/Library/Mail: You don’t have permission to view this folder."]
                },
                aiAvailability: { .notEnabled }
            ),
            width: 560,
            height: 620,
            dark: dark
        )
    }

    @Test func permissionsTab() {
        assertSnapshot(of: self.host(), as: snapshotImageStrategy, record: snapshotRecordingMode)
    }
}
