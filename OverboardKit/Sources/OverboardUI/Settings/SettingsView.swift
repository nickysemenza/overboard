import OverboardCore
import SwiftUI

/// Identifies one Settings tab, so callers outside the view (a launcher
/// command, a menu item) can deep-link to a specific one.
public enum SettingsTab: Hashable, Sendable, CaseIterable, Identifiable {
    case general, history, files, apps, actions, permissions

    public var id: Self {
        self
    }

    public var title: String {
        switch self {
        case .general: "General"
        case .history: "History"
        case .files: "Files"
        case .apps: "Apps"
        case .actions: "Actions"
        case .permissions: "Permissions"
        }
    }

    public var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .history: "clock.arrow.circlepath"
        case .files: "folder"
        case .apps: "app.badge.checkmark"
        case .actions: "wand.and.stars"
        case .permissions: "lock.shield"
        }
    }

    /// The sidebar icon tile's fill. This is System Settings' own idiom —
    /// every one of its panes gets a distinct system-color tile — not the
    /// DESIGN.md content-kind ramp (Orange/Blue/Purple/…), which names *what
    /// a result is* and is never reused decoratively. A settings pane isn't
    /// content, so it borrows the platform convention instead.
    public var tileColor: Color {
        switch self {
        case .general: .gray
        case .history: .blue
        case .files: .teal
        case .apps: .indigo
        case .actions: .purple
        case .permissions: .red
        }
    }
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
    @Bindable private var navigation: SettingsNavigation

    public init(
        store: ClipStore,
        navigation: SettingsNavigation = SettingsNavigation()
    ) {
        self.store = store
        self.navigation = navigation
    }

    public var body: some View {
        NavigationSplitView {
            List(SettingsTab.allCases, selection: self.$navigation.selectedTab) { tab in
                SettingsSidebarRow(tab: tab)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(180)
            // System Settings has no collapse button; the modifier only takes
            // effect from inside the sidebar column, not on the split view.
            .toolbar(removing: .sidebarToggle)
        } detail: {
            self.detail(for: self.navigation.selectedTab)
                // Grouped forms inset their content ~40pt under a toolbar;
                // System Settings starts its first group just below it.
                .contentMargins(.top, 8, for: .scrollContent)
        }
        // System Settings' own window doesn't let you resize its width
        // either — a fixed width keeps the sidebar from fighting the detail
        // pane for space.
        .frame(width: 700)
        // A grouped Form's ideal height is its full content height, so
        // without idealHeight the tallest tab (History, with its stats
        // sections) would open very tall no matter which tab is selected.
        .frame(minHeight: 500, idealHeight: 580)
    }

    @ViewBuilder
    private func detail(for tab: SettingsTab) -> some View {
        switch tab {
        case .general:
            GeneralSettingsTab()
                .navigationTitle(tab.title)
        case .history:
            HistorySettingsTab(store: self.store)
                .navigationTitle(tab.title)
        case .files:
            FileSearchSettingsTab()
                .navigationTitle(tab.title)
        case .apps:
            AppsSettingsTab()
                .navigationTitle(tab.title)
        case .actions:
            ActionsSettingsTab()
                .navigationTitle(tab.title)
        case .permissions:
            PermissionsSettingsTab()
                .navigationTitle(tab.title)
        }
    }
}

/// One sidebar row: a colored icon tile in System Settings' own shape, then
/// the pane's name. A Label-shaped HStack rather than SwiftUI's `Label`, so
/// the tile's own corner radius and fill don't have to fight the symbol
/// rendering `Label` otherwise applies to its icon.
private struct SettingsSidebarRow: View {
    let tab: SettingsTab

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 5)
                .fill(self.tab.tileColor)
                .frame(width: 20, height: 20)
                .overlay {
                    Image(systemName: self.tab.systemImage)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                }
            Text(self.tab.title)
        }
    }
}

#if DEBUG
    #Preview("All tabs") {
        SettingsView(store: Fixtures.previewStore())
            .frame(width: 700, height: 580)
    }
#endif
