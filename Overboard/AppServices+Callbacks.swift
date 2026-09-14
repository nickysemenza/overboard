import AppKit
import OverboardCore
import OverboardMac
import OverboardUI

/// Wiring for the overlay drawer, the launcher panel, and the emoji picker —
/// each panel's callbacks assigned to the shared services above. Split by
/// theme (`installLauncherCallbacks()`'s groups especially) so no single
/// function accumulates the branching of two dozen independent closures.
extension AppServices {
    func installOverlayCallbacks() {
        self.overlay.onCommit = { [weak self] item, mode, target in
            self?.pasteItem(item, mode: mode, into: target)
        }

        self.overlay.onCommitSnippet = { [weak self] snippet, target in
            guard let self else { return }
            let clipboard = NSPasteboard.general.string(forType: .string)
            let expanded = SnippetTemplate.expand(snippet.body, clipboard: clipboard)
            self.pasteString(expanded, into: target)
        }

        self.overlay.onCommitTransform = { [weak self] item, transform, target in
            guard let self else { return }
            Task {
                guard let text = try? await self.store.plainText(for: item.id) else { return }
                try? await self.store.markUsed(id: item.id)
                self.pasteString(transform.apply(to: text), into: target)
            }
        }

        self.overlay.onCommitEditedText = { [weak self] text, target in
            self?.pasteString(text, into: target)
        }

        self.overlay.onRunAction = { [weak self] action, items, target in
            guard let self else { return }
            Task {
                await self.runAction(action, on: items, target: target)
            }
        }

        self.overlay.onCommitAITransform = { [weak self] item, transform, target in
            guard let self else { return }
            Task {
                guard let text = try? await self.store.plainText(for: item.id) else { return }
                HUDController.shared.flash("✨ \(transform.label)…", duration: .seconds(15))
                do {
                    let result = try await AITransformer.apply(transform, to: text)
                    try? await self.store.markUsed(id: item.id)
                    self.pasteString(result, into: target)
                } catch {
                    HUDController.shared.flash("AI transform failed")
                    self.logger.error("AI transform failed: \(String(describing: error), privacy: .public)")
                }
            }
        }
    }

    func installLauncherCallbacks() {
        self.installLauncherLifecycleCallbacks()
        self.installLauncherFileCallbacks()
        self.installLauncherClipCallbacks()
        self.installLauncherCommandCallbacks()
        self.installLauncherMiscCallbacks()
        self.installLauncherShellCallbacks()
        self.installLauncherSystemCallbacks()
    }

    /// Summon-time refresh (Spotify snapshot, running-app dots) and the
    /// search-invalidation hooks that keep the launcher's rows fresh while
    /// it's open.
    private func installLauncherLifecycleCallbacks() {
        if !Self.isDemo {
            FileIndexService.shared.onChange = { [weak self] in
                guard let self, self.launcher.isVisible else { return }
                self.launcherViewModel.scheduleSearch(preserveSelection: true)
            }
        }
        self.overlay.onBrowseHistory = { [weak self] query, target in
            self?.launcher.show(scope: .clipboard, query: query, target: target)
        }
        // Reconcile the Spotify now-playing snapshot (its onChange only
        // refreshes an open panel, so a missed track change is caught here)
        // and snapshot running apps for the row indicator dots. Observation
        // runs only while the panel is visible.
        self.launcher.onWillShow = { [weak self] in
            guard let self else { return }
            if !Self.isDemo {
                self.spotify.refreshSnapshot()
            }
            self.launcherViewModel.runningAppPaths = self.runningApps.snapshot()
            self.runningApps.startObserving()
        }
        self.launcher.onWillHide = { [weak self] in
            self?.runningApps.stopObserving()
        }
        self.runningApps.onChange = { [weak self] in
            guard let self, self.launcher.isVisible else { return }
            self.launcherViewModel.runningAppPaths = self.runningApps.snapshot()
        }
    }

    /// Copy/paste/open/reveal for launcher rows backed by a filesystem path.
    private func installLauncherFileCallbacks() {
        self.launcher.onCopyText = { [weak self] text in
            self?.copyString(text, hud: "Result copied — ⌘V to paste")
        }
        self.launcher.onPasteText = { [weak self] text, target in
            self?.pasteString(text, into: target)
        }
        self.launcher.onOpenFile = { [weak self] url in
            guard let self else { return }
            let query = self.launcherViewModel.query
            let id = self.launcherViewModel.selectedResult?.id
            Task {
                do {
                    let needsDownload = FileAvailability.status(at: url) == .cloud
                    if needsDownload {
                        HUDController.shared.flash("Downloading \(url.lastPathComponent)…", duration: .seconds(60))
                    }
                    try await FileOpening.open(url)
                    if needsDownload {
                        HUDController.shared.flash("Opened \(url.lastPathComponent)")
                    }
                    if let id {
                        self.launcherViewModel.recordSuccessfulSelection(id: id, query: query)
                    }
                } catch {
                    HUDController.shared.flash(
                        "Couldn’t open \(url.lastPathComponent). Check its location or internet " +
                            "connection and try again.",
                        duration: .seconds(6)
                    )
                }
            }
        }
        self.launcher.onRevealFile = { url in
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        self.launcher.onCopyPath = { [weak self] path in
            self?.copyString(path, hud: "Path copied")
        }
        self.launcher.onOpenWebSearch = { url in
            NSWorkspace.shared.open(url)
        }
        self.launcher.onOpenSystemSetting = { url in
            NSWorkspace.shared.open(url)
        }
    }

    /// Paste/copy for clips and snippets picked in the launcher.
    private func installLauncherClipCallbacks() {
        self.launcher.onPasteClip = { [weak self] item, mode, target in
            guard let self else { return }
            let query = self.launcherViewModel.query
            self.pasteItem(item, mode: mode, into: target) { [weak self] in
                self?.launcherViewModel.recordSuccessfulSelection(id: LauncherResult.clip(item).id, query: query)
            }
        }
        self.launcher.onCopyClip = { [weak self] item in
            guard let self else { return }
            Task {
                do {
                    try await self.pasteback.copy(item)
                    HUDController.shared.flash("Copied — ⌘V to paste")
                } catch {
                    self.logger.error("copy failed: \(String(describing: error), privacy: .public)")
                }
            }
        }
        self.launcher.onPasteSnippet = { [weak self] snippet, target in
            guard let self else { return }
            // Read {clipboard} before pasteString overwrites the pasteboard.
            let clipboard = NSPasteboard.general.string(forType: .string)
            let expanded = SnippetTemplate.expand(snippet.body, clipboard: clipboard)
            self.pasteString(expanded, into: target)
        }
        self.launcher.onCopySnippet = { [weak self] snippet in
            guard let self else { return }
            let clipboard = NSPasteboard.general.string(forType: .string)
            let expanded = SnippetTemplate.expand(snippet.body, clipboard: clipboard)
            self.copyString(expanded, hud: "Snippet copied — ⌘V to paste")
        }
    }

    /// The `:pause`/`:resume`/`:clear`/`:stats`/`:settings` command palette rows.
    private func installLauncherCommandCallbacks() {
        self.launcher.onRunCommand = { [weak self] command in
            guard let self else { return }
            switch command {
            case .version, .settings: Self.openSettings()
            // `:stats` has no action of its own — ↩ opens Settings, where the
            // full library breakdown lives (the row subtitle is the summary).
            // Deep-links straight to the History tab via SettingsNavigation.
            case .stats: Self.openSettings(tab: .history)
            case .pause: self.setCapturePaused(true)
            case .resume: self.setCapturePaused(false)
            case .clear: self.confirmAndClearHistory()
            }
        }
    }

    /// Spotify row actions, Ask AI, and app quit/reveal — the launcher
    /// callbacks that don't fit the groups above.
    private func installLauncherMiscCallbacks() {
        self.launcher.onCopyNowPlayingLink = { [weak self] track in
            let text = track.shareURL?.absoluteString ?? "\(track.title) — \(track.artist)"
            self?.copyString(text, hud: "Spotify link copied — ⌘V to paste")
        }
        self.launcher.onOpenSpotify = { _ in
            let id = SpotifyNowPlayingMonitor.spotifyBundleID
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first {
                app.activate()
            } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            }
        }
        self.launcher.onAskAI = { [weak self] prompt, delivery, target in
            guard let self else { return }
            // Read the clipboard text now — the launcher captured `target`
            // before hiding, so a paste lands back in the originating app.
            guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
                HUDController.shared.flash("Clipboard is empty")
                return
            }
            Task {
                HUDController.shared.flash("✨ Thinking…", duration: .seconds(15))
                do {
                    let result = try await AITransformer.apply(prompt: prompt, to: text)
                    switch delivery {
                    case .paste: self.pasteString(result, into: target)
                    case .copy: self.copyString(result, hud: "Copied — ⌘V to paste")
                    }
                } catch {
                    HUDController.shared.flash("AI transform failed")
                    self.logger.error("Ask AI failed: \(String(describing: error), privacy: .public)")
                }
            }
        }
        self.launcher.onQuitApp = { url in
            // Match the running instance by its bundle URL and ask it to quit.
            NSWorkspace.shared.runningApplications
                .first { $0.bundleURL == url }?
                .terminate()
        }
        self.launcher.onOpenClipLink = { url in
            NSWorkspace.shared.open(url)
        }
    }

    /// The `>`-prefixed shell row: runs the command in Ghostty. Quicklinks
    /// need no callback of their own — they route through the existing
    /// `onOpenWebSearch(url)`.
    private func installLauncherShellCallbacks() {
        self.launcher.onRunShellCommand = { command in
            Task {
                do {
                    try await GhosttyLauncher.run(command)
                } catch {
                    HUDController.shared.flash("Couldn't open Ghostty")
                }
            }
        }
    }

    /// Lock/sleep/restart and audio-output switching. `SystemActionService`
    /// can't flash a HUD itself (OverboardMac sits below OverboardUI in the
    /// module graph), so its failures are routed here.
    private func installLauncherSystemCallbacks() {
        SystemActionService.shared.onFailure = { message in
            HUDController.shared.flash(message)
        }
        self.launcher.onRunSystemAction = { action in
            SystemActionService.shared.perform(action)
        }
        self.launcher.onSwitchAudioOutput = { device in
            do {
                try AudioOutputService.shared.setDefaultOutput(device)
                HUDController.shared.flash("Output → \(device.name)")
            } catch {
                HUDController.shared.flash("Couldn't switch output")
            }
        }
    }

    func installEmojiCallbacks() {
        // Both paths reuse the shared clipboard plumbing: marker tagging keeps
        // the emoji out of history, and paste falls back to copy-only + HUD
        // without Accessibility.
        self.emojiPicker.onPaste = { [weak self] emoji, target in
            self?.pasteString(emoji, into: target)
        }
        self.emojiPicker.onCopy = { [weak self] emoji in
            self?.copyString(emoji, hud: "Copied — ⌘V to paste")
        }
    }
}
