import AppKit
import Defaults
import KeyboardShortcuts
import OverboardCore
import OverboardMac
import ServiceManagement
import SwiftUI

struct GeneralSettingsTab: View {
    let enrichment: ClipEnrichmentPipeline

    @Default(.restoreClipboard) private var restoreClipboard
    @Default(.launcherFileResults) private var launcherFileResults
    @Default(.launcherClipResults) private var launcherClipResults
    @Default(.launcherSnippetResults) private var launcherSnippetResults
    @Default(.launcherSettingsResults) private var launcherSettingsResults
    @Default(.launcherNowPlaying) private var launcherNowPlaying
    @Default(.launcherCalendarEvents) private var launcherCalendarEvents
    @Default(.launcherAppAliases) private var launcherAppAliases
    @Default(.launcherQuicklinks) private var launcherQuicklinks
    @Default(.richLinkPreviews) private var richLinkPreviews

    /// Second half of the "Source" row's tooltip — split out so the ternary
    /// doesn't nest quoted strings inside a string interpolation.
    private static var gitSourceHelpSuffix: String {
        AppVersion.isDirtyOrAhead
            ? "ahead of, or dirty against, that tag."
            : "matching the tag means it’s a clean release build."
    }

    /// The base footer, plus one of two `cloudflared`-specific sentences:
    /// installed hosts get the "Cloudflare Access" section below to sign in
    /// from, so the footer just explains the automatic (no-toggle, silent)
    /// reuse of `cloudflared`'s own cached login; without `cloudflared` there's
    /// no section to point at, so the footer suggests installing it instead.
    private static var linkPreviewsFooter: String {
        let base = """
        Connects to the URLs you copy to fetch each page’s title, description, \
        favicon, and preview image, rendered on link cards. Requests come only from \
        your Mac; nothing is sent anywhere else. Turn this off to keep Overboard fully \
        offline.
        """
        guard CloudflaredAccessTokens.isInstalled() else {
            return base + " Install cloudflared to preview links behind Cloudflare Access."
        }
        return base + """
         Links behind Cloudflare Access reuse the login already cached by cloudflared; \
        Overboard never opens a browser to sign you in.
        """
    }

    var body: some View {
        Form {
            Section {
                KeyboardShortcuts.Recorder("Show Drawer", name: .toggleDrawer)
                KeyboardShortcuts.Recorder("Paste next from stack", name: .pasteNextFromStack)
                KeyboardShortcuts.Recorder("Show Launcher", name: .toggleLauncher)
                KeyboardShortcuts.Recorder("Show Emoji Picker", name: .toggleEmojiPicker)
            } header: {
                Text("Shortcuts")
            } footer: {
                Text(
                    """
                    The emoji picker's default shortcut (⌃⌘Space) takes over the system emoji \
                    viewer's binding while Overboard is running — record a different one here to \
                    get the system viewer back.
                    """
                )
            }

            Section {
                Toggle("Show snippet results in launcher", isOn: self.$launcherSnippetResults)
                Toggle("Show clipboard history in launcher", isOn: self.$launcherClipResults)
                Toggle("Show file results in launcher", isOn: self.$launcherFileResults)
                Toggle(
                    "Show system settings, actions, and audio outputs in launcher",
                    isOn: self.$launcherSettingsResults
                )
                Toggle("Show Spotify now playing in launcher", isOn: self.$launcherNowPlaying)
                Toggle("Show calendar events in launcher", isOn: self.$launcherCalendarEvents)
            } header: {
                Text("Launcher")
            } footer: {
                Text(
                    """
                    All mixes apps, files, clipboard, snippets, calculator, system settings, AI, \
                    now playing, and calendar events. System settings, actions, and audio outputs \
                    also add Lock Screen, Sleep, Restart, and switching your Mac’s audio output \
                    device. Use ⌘1–4 to switch scopes. File search locations are managed in Files.
                    """
                )
            }

            Section {
                LabeledContent("App aliases") {
                    SettingsTextListEditor(
                        text: self.$launcherAppAliases,
                        height: 60,
                        accessibilityLabel: "App aliases, one alias per line"
                    )
                }
                LabeledContent("Quicklinks") {
                    SettingsTextListEditor(
                        text: self.$launcherQuicklinks,
                        height: 60,
                        accessibilityLabel: "Quicklinks, one keyword per line"
                    )
                }
            } header: {
                Text("Aliases and quicklinks")
            } footer: {
                Text(
                    """
                    Aliases are one “sm = Sublime Merge” per line; initials work automatically. \
                    Quicklinks are one “gh = https://github.com/search?q={query}” per line \
                    (optionally “gh = GitHub | URL”) — type the keyword, a space, then your search.
                    """
                )
            }

            Section {
                LaunchAtLoginToggle()
                Toggle("Restore previous clipboard after paste", isOn: self.$restoreClipboard)
            } header: {
                Text("Clipboard")
            }

            Section {
                Toggle("Fetch link titles and icons", isOn: self.$richLinkPreviews)
            } header: {
                Text("Link previews")
            } footer: {
                Text(Self.linkPreviewsFooter)
            }

            if CloudflaredAccessTokens.isInstalled() {
                CloudflareAccessSection(enrichment: self.enrichment)
            }

            Section {
                LabeledContent("Version", value: AppVersion.marketing)
                    .help("The tagged release this build descends from; it only changes when a release is cut.")
                LabeledContent("Build", value: AppVersion.build)
                if let git = AppVersion.gitDescribe {
                    LabeledContent("Source") {
                        HStack(spacing: 6) {
                            if AppVersion.isDirtyOrAhead {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                            }
                            Text(git).font(.body.monospaced())
                        }
                    }
                    .help("The exact git state this build was built from — \(Self.gitSourceHelpSuffix)")
                }
                Button("Copy Version Info") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(AppVersion.summary, forType: .string)
                }
            } header: {
                Text("About")
            }
        }
        .formStyle(.grouped)
    }
}

/// The login-item toggle, shared by Settings → General and the Welcome window
/// so the register/unregister handling (and its failure re-sync) lives once.
struct LaunchAtLoginToggle: View {
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Toggle("Launch at login", isOn: self.$launchAtLogin)
            .onChange(of: self.launchAtLogin) {
                self.apply()
            }
    }

    private func apply() {
        do {
            if self.launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Re-sync the toggle with reality on failure.
            self.launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

#if DEBUG
    #Preview("General") {
        let store = Fixtures.previewStore()
        GeneralSettingsTab(enrichment: Fixtures.noOpEnrichmentPipeline(store: store))
            .frame(width: 520, height: 580)
    }
#endif
