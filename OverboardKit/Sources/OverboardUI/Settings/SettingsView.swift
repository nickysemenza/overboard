import OverboardCore
import SwiftUI

/// Identifies one Settings tab, so callers outside the view (a launcher
/// command, a menu item) can deep-link to a specific one.
public enum SettingsTab: Hashable, Sendable {
    case general, history, files, apps, actions, permissions, ai
}

/// Shared, externally-settable tab selection for the Settings scene. SwiftUI
/// builds the `Settings` scene once at launch, long before any window exists,
/// so there's no view instance around for a caller like
/// `AppServices.openSettings` to hand a binding to — this observable object
/// is the bridge: `SettingsView` binds its `TabView` selection to it, and a
/// caller sets `selectedTab` before raising the window.
@Observable
public final class SettingsNavigation {
    public var selectedTab: SettingsTab

    public init(selectedTab: SettingsTab = .general) {
        self.selectedTab = selectedTab
    }
}

/// Shared copy for the "clear all clipboard history" confirmation, so the
/// Settings confirmation dialog and the `:clear` launcher command's `NSAlert`
/// (which can't use a SwiftUI dialog since it runs outside a view) can't drift.
public enum ClearHistoryPrompt {
    public static let title = "Clear Clipboard History?"
    public static let message = "All unpinned items will be deleted. Pinned items are kept. This can't be undone."
    public static let confirm = "Clear History"
}

public struct SettingsView: View {
    private let store: ClipStore
    private let checkForUpdates: () async -> Void
    @Bindable private var navigation: SettingsNavigation

    public init(
        store: ClipStore,
        navigation: SettingsNavigation = SettingsNavigation(),
        checkForUpdates: @escaping () async -> Void = {}
    ) {
        self.store = store
        self.navigation = navigation
        self.checkForUpdates = checkForUpdates
    }

    public var body: some View {
        TabView(selection: self.$navigation.selectedTab) {
            Tab("General", systemImage: "gearshape", value: SettingsTab.general) {
                GeneralSettingsTab(checkForUpdates: self.checkForUpdates)
            }
            Tab("History", systemImage: "clock.arrow.circlepath", value: SettingsTab.history) {
                HistorySettingsTab(store: self.store)
            }
            Tab("Files", systemImage: "folder", value: SettingsTab.files) {
                FileSearchSettingsTab()
            }
            Tab("Apps", systemImage: "app.badge.checkmark", value: SettingsTab.apps) {
                AppsSettingsTab()
            }
            Tab("Actions", systemImage: "wand.and.stars", value: SettingsTab.actions) {
                ActionsSettingsTab()
            }
            Tab("Permissions", systemImage: "lock.shield", value: SettingsTab.permissions) {
                PermissionsSettingsTab()
            }
            Tab("AI", systemImage: "sparkles", value: SettingsTab.ai) {
                AISettingsTab()
            }
        }
        // A fixed floor big enough for the tallest tab (History, with its
        // stats sections) so switching tabs doesn't resize the window.
        .frame(minWidth: 520, minHeight: 420)
    }
}

#if DEBUG
    #Preview("All tabs") {
        SettingsView(store: Fixtures.previewStore())
    }
#endif
