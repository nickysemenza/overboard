import AppKit
import OverboardMac
import SwiftUI

/// One permission's current state, as a compact status line. Green means the
/// feature it unlocks works; orange means it silently falls back. The symbol
/// repeats the word, so it's hidden from VoiceOver.
struct PermissionStatusPill: View {
    let state: PermissionState

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: self.symbolName)
                .accessibilityHidden(true)
            Text(self.title)
        }
        .font(.callout)
        .foregroundStyle(self.tint)
    }

    private var title: String {
        switch self.state {
        case .granted: "Granted"
        case .denied: "Not Granted"
        case .unknown: "Not Asked"
        }
    }

    private var symbolName: String {
        switch self.state {
        case .granted: "checkmark.circle.fill"
        case .denied: "exclamationmark.circle.fill"
        case .unknown: "questionmark.circle"
        }
    }

    private var tint: Color {
        switch self.state {
        case .granted: .green
        case .denied: .orange
        case .unknown: .secondary
        }
    }
}

/// The Accessibility status plus the one button that can change it. Shared by
/// Settings → Permissions and the Welcome window so first-run and later
/// visits show the same thing.
struct AccessibilityPermissionRow: View {
    let permissions: PermissionService
    /// "Accessibility" where the permission needs naming; "Status" under a
    /// section header that already names it.
    var label = "Accessibility"

    var body: some View {
        LabeledContent(self.label) {
            HStack(spacing: 10) {
                PermissionStatusPill(state: self.permissions.accessibility)
                if self.permissions.accessibility != .granted {
                    Button("Grant…") {
                        self.permissions.requestAccessibility()
                    }
                }
            }
        }
    }
}

/// The Calendar status plus its two possible actions. Shared by Settings →
/// Permissions and the Welcome window, same shape as `AccessibilityPermissionRow`.
struct CalendarPermissionRow: View {
    let permissions: PermissionService
    /// "Calendar" where the permission needs naming; "Status" under a section
    /// header that already names it.
    var label = "Calendar"

    var body: some View {
        LabeledContent(self.label) {
            HStack(spacing: 10) {
                PermissionStatusPill(state: self.permissions.calendar)
                if self.permissions.calendar == .denied {
                    // macOS won't show its own prompt again once denied —
                    // System Settings is the only way back.
                    Button("Open System Settings…") {
                        self.permissions.openCalendarSettings()
                    }
                } else if self.permissions.calendar != .granted {
                    Button("Request…") {
                        self.permissions.requestCalendar()
                    }
                }
            }
        }
    }
}

/// Every permission Overboard can ask for, what each one buys, and the state
/// macOS reports right now — in one place, instead of a prompt that only
/// appears after a paste has already fallen back.
struct PermissionsSettingsTab: View {
    private let permissions: PermissionService
    /// A closure, not the service, so a snapshot can seed issues without a
    /// live index. Read inside `body`, so observation tracking still works.
    private let fileIssues: () -> [String]

    init(
        permissions: PermissionService = .shared,
        fileIssues: @escaping () -> [String] = { FileIndexService.shared.issues }
    ) {
        self.permissions = permissions
        self.fileIssues = fileIssues
    }

    private var issues: [FileIndexIssue] {
        self.fileIssues().map(FileIndexIssue.init(raw:))
    }

    var body: some View {
        Form {
            Section {
                AccessibilityPermissionRow(permissions: self.permissions, label: "Status")
                if self.permissions.accessibility != .granted {
                    // macOS only shows its own prompt once per launch, and not
                    // at all once the user has said no — this always works.
                    Button("Open System Settings…") {
                        self.permissions.openAccessibilitySettings()
                    }
                }
            } header: {
                Text("Accessibility")
            } footer: {
                Text(
                    """
                    Lets Overboard paste directly into the app you were using. Without it, items \
                    are copied and you press ⌘V yourself.
                    """
                )
            }

            Section {
                CalendarPermissionRow(permissions: self.permissions, label: "Status")
            } header: {
                Text("Calendar")
            } footer: {
                Text(
                    """
                    Shows your next meeting in the launcher and lets ↩ open its join link. Requested \
                    only here — never from the launcher itself.
                    """
                )
            }

            Section {
                if self.permissions.visibleAutomationTargets.isEmpty {
                    Text("None of the supported apps are installed.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(self.permissions.visibleAutomationTargets) { target in
                        LabeledContent(target.name) {
                            HStack(spacing: 10) {
                                PermissionStatusPill(state: self.permissions.automation(for: target.bundleID))
                                if self.permissions.automation(for: target.bundleID) != .granted {
                                    Button("Request…") {
                                        self.permissions.requestAutomation(for: target.bundleID)
                                    }
                                }
                            }
                        }
                    }
                }
            } header: {
                Text("Automation")
            } footer: {
                Text(
                    """
                    Remembers the page or track you copied from. Only installed apps are listed, \
                    and each one is asked for separately.
                    """
                )
            }

            Section {
                if self.issues.isEmpty {
                    Text("No problems reading your indexed folders.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(self.issues) { issue in
                        FileIndexIssueRow(issue: issue, permissions: self.permissions)
                    }
                }
            } header: {
                Text("File Search")
            } footer: {
                Text(
                    """
                    Folders the indexer couldn’t read. Some need Full Disk Access; others have \
                    simply moved. Locations are managed in Files.
                    """
                )
            }
        }
        .formStyle(.grouped)
        .onAppear {
            // TCC changes in System Settings, not here — re-read whenever this
            // tab comes back into view.
            self.permissions.refresh()
        }
    }
}

/// One unreadable folder, with the two things that actually fix it.
private struct FileIndexIssueRow: View {
    let issue: FileIndexIssue
    let permissions: PermissionService

    var body: some View {
        LabeledContent {
            Menu("Fix…") {
                if self.issue.url != nil {
                    Button("Reveal in Finder") {
                        self.issue.revealInFinder()
                    }
                }
                Button("Open Full Disk Access…") {
                    self.permissions.openFullDiskAccessSettings()
                }
            }
            .fixedSize()
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Image(systemName: "folder.badge.questionmark")
                        .accessibilityHidden(true)
                    Text(self.issue.url?.lastPathComponent ?? "File index")
                        .lineLimit(1)
                }
                Text(self.issue.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
                    .padding(.leading, 22)
            }
        }
    }
}

#if DEBUG
    #Preview("Permissions") {
        PermissionsSettingsTab(
            permissions: PermissionService(
                accessibility: .granted,
                automation: ["com.apple.Safari": .granted, "com.google.Chrome": .denied],
                calendar: .denied
            ),
            fileIssues: { ["/Users/you/Library/Mail: You don’t have permission to view this folder."] }
        )
        .frame(width: 600, height: 500)
    }
#endif
