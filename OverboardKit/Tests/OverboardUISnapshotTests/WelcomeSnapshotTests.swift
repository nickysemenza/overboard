import OverboardMac
@testable import OverboardUI
import SnapshotTesting
import SwiftUI
import Testing

/// The first-run window, in both appearances. Accessibility is stubbed as
/// denied because that's the state a real first launch is in — the Grant
/// buttons have to fit.
@Suite(.localOnly)
@MainActor
struct WelcomeSnapshotTests {
    private func host(dark: Bool = false) -> NSView {
        snapshotHost(
            WelcomeView(
                permissions: PermissionService(accessibility: .denied),
                openShortcutSettings: {},
                onDone: {}
            ),
            width: 460,
            height: 400,
            dark: dark
        )
    }

    @Test func welcome() {
        assertSnapshot(of: self.host(), as: snapshotImageStrategy)
    }

    @Test func welcomeDark() {
        assertSnapshot(of: self.host(dark: true), as: snapshotImageStrategy)
    }
}
