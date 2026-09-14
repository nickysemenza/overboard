import AppKit
import OverboardMac
import SwiftUI

/// First-run orientation, one screen. Overboard has no Dock icon and no window
/// to open, so without this a new user sees a menu-bar boat and nothing else.
/// Deliberately not a wizard: three shortcuts, one permission, one toggle, and
/// a way out. Reopenable from the menu.
///
/// A plain window, not a summonable panel — no glass, the standard window
/// background (see DESIGN.md). Nothing here animates, so Reduce Motion needs
/// no special path.
public struct WelcomeView: View {
    private let permissions: PermissionService
    /// Injected so this module never reaches into the app target for
    /// `AppServices.openSettings(tab:)`.
    private let openShortcutSettings: () -> Void
    private let onDone: () -> Void

    @Environment(\.dismiss) private var dismiss

    public init(
        permissions: PermissionService = .shared,
        openShortcutSettings: @escaping () -> Void,
        onDone: @escaping () -> Void
    ) {
        self.permissions = permissions
        self.openShortcutSettings = openShortcutSettings
        self.onDone = onDone
    }

    private var shortcuts: [WelcomeShortcut] {
        [
            WelcomeShortcut(
                name: "Launcher",
                description: "Search apps, files, clipboard, and the web.",
                keys: HotkeyService.toggleLauncherShortcutDescription
            ),
            WelcomeShortcut(
                name: "Drawer",
                description: "Browse what you copied recently.",
                keys: HotkeyService.toggleDrawerShortcutDescription
            ),
            WelcomeShortcut(
                name: "Emoji Picker",
                description: "Find an emoji and paste it.",
                keys: HotkeyService.toggleEmojiPickerShortcutDescription
            ),
        ]
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            self.header

            VStack(spacing: 10) {
                ForEach(self.shortcuts) { shortcut in
                    WelcomeShortcutRow(
                        shortcut: shortcut,
                        change: self.openShortcutSettings
                    )
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                AccessibilityPermissionRow(permissions: self.permissions)
                Text("Without it, items are copied and you press ⌘V yourself.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                CalendarPermissionRow(permissions: self.permissions)
                Text("Optional — shows your next meeting in the launcher.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LaunchAtLoginToggle()
                Text("No account and no analytics — your clipboard stays on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            HStack {
                Text(self.footerHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done") {
                    self.onDone()
                    self.dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 460, minHeight: 400)
        // An ordinary window, explicitly: no glass, and a real background so
        // the content reads in both appearances (see DESIGN.md).
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            self.permissions.refresh()
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            self.icon
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Overboard")
                    .font(.largeTitle)
                Text("A launcher and clipboard manager that lives in your menu bar.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var icon: some View {
        // Only the app bundle declares an icon; previews and snapshot tests run
        // out of a bundle that doesn't, and NSApp would hand back the generic
        // executable icon there. The menu-bar boat stands in instead.
        if Bundle.main.object(forInfoDictionaryKey: "CFBundleIconName") != nil,
           let image = NSApp?.applicationIconImage
        {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: "sailboat.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.tint)
        }
    }

    private var footerHint: String {
        guard let launcher = HotkeyService.toggleLauncherShortcutDescription else {
            return "Set a Launcher shortcut to get started."
        }
        return "Try it: press \(launcher) now."
    }
}

/// One summonable surface and the shortcut that opens it.
private struct WelcomeShortcut: Identifiable {
    let name: String
    let description: String
    let keys: String?

    var id: String {
        self.name
    }
}

private struct WelcomeShortcutRow: View {
    let shortcut: WelcomeShortcut
    let change: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(self.shortcut.name)
                Text(self.shortcut.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let keys = self.shortcut.keys {
                Text(keys)
                    .font(.caption)
                    .monospacedDigit()
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2.5)
                    .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 7))
            } else {
                Text("Not set")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Change…", action: self.change)
                    .controlSize(.small)
            }
        }
    }
}

#if DEBUG
    #Preview("Welcome") {
        WelcomeView(
            permissions: PermissionService(accessibility: .denied),
            openShortcutSettings: {},
            onDone: {}
        )
        .frame(width: 460, height: 400)
    }
#endif
