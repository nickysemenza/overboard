import Foundation
import OverboardCore
import OverboardMac

/// Row actions: what a row can do (`selectedActions`/`actions(for:)`), and
/// `perform`/`commit`, the single routing point that executes one. Dispatch
/// in `perform` is split by result kind (`performAction`/`performMiscAction`
/// below, then one `perform*Action` helper per kind) purely to keep each
/// switch's cyclomatic complexity low — the matched (action, result) pairs
/// are unchanged from what used to be a single flat switch.
extension LauncherViewModel {
    // MARK: - Commit / actions

    /// Actions available for the currently-selected row, in footer/palette
    /// order (index 0/1/2 = ↩/⌘↩/⌥↩). Empty when nothing is selected.
    public var selectedActions: [LauncherAction] {
        guard self.results.indices.contains(self.selectedIndex) else { return [] }
        return LauncherActions.actions(for: self.results[self.selectedIndex], context: self.actionContext)
    }

    /// Actions for an arbitrary row, not just the selected one — powers each
    /// row's VoiceOver accessibility actions (a non-selected row must still
    /// list what it can do), sharing `selectedActions`' running-app context
    /// rule for app rows.
    public func actions(for result: LauncherResult) -> [LauncherAction] {
        let isRunning: Bool = if case let .app(_, url) = result {
            self.runningAppPaths.contains(url.path)
        } else {
            false
        }
        return LauncherActions.actions(for: result, context: LauncherActionContext(isAppRunning: isRunning))
    }

    /// The row's primary (↩) action — what the footer bar advertises.
    public var primaryAction: LauncherAction? {
        self.selectedActions.first
    }

    /// Whether the selected app row is one macOS reports as running. Drives
    /// the "Switch to" label and the Quit action; always false until a later
    /// slice fills `runningAppPaths`.
    public var isSelectedAppRunning: Bool {
        guard self.results.indices.contains(self.selectedIndex),
              case let .app(_, url) = self.results[self.selectedIndex]
        else { return false }
        return self.runningAppPaths.contains(url.path)
    }

    private var actionContext: LauncherActionContext {
        LauncherActionContext(isAppRunning: self.isSelectedAppRunning)
    }

    /// Keyboard commit (↩/⌘↩/⌥↩). A thin wrapper that maps the modifier to the
    /// positional action for the selected row and routes it through `perform`,
    /// so the footer, palette, and keyboard all share one execution path.
    public func commit(modifier: CommitModifier = .none) {
        let actions = self.selectedActions
        guard !actions.isEmpty else { return }
        // Modifiers on rows with fewer actions fall back to ↩ — single-action
        // rows (web search, settings panes, commands) must not index past the
        // list, and snippet/calc ⌥↩ keeps its old alias-of-↩ behavior.
        let index: Int = switch modifier {
        case .none: 0
        case .command: actions.indices.contains(1) ? 1 : 0
        case .option: actions.indices.contains(2) ? 2 : 0
        }
        self.perform(actions[index])
    }

    /// Executes one action against the selected row. The single routing point
    /// for the footer's primary action, the ⌘K palette, and `commit`.
    public func perform(_ action: LauncherAction) {
        guard !self.resultsAreStale, self.results.indices.contains(self.selectedIndex) else { return }
        if action == .preview {
            self.togglePreview()
            return
        }
        self.performAction(action, on: self.results[self.selectedIndex])
    }

    private func performAction(_ action: LauncherAction, on result: LauncherResult) {
        switch result {
        case let .calculation(_, display):
            self.performCalculationAction(action, display: display)
        case let .app(_, url):
            self.performAppAction(action, url: url)
        case let .file(_, url, _):
            self.performFileAction(action, url: url)
        case let .snippet(snippet):
            self.performSnippetAction(action, snippet: snippet)
        case let .clip(item):
            self.performClipAction(action, item: item)
        default:
            self.performMiscAction(action, on: result)
        }
    }

    private func performMiscAction(_ action: LauncherAction, on result: LauncherResult) {
        switch result {
        case let .webSearch(_, url):
            self.performWebSearchAction(action, url: url)
        case let .systemSetting(_, url):
            self.performSystemSettingAction(action, url: url)
        case let .command(command, _):
            self.performCommandAction(action, command: command)
        case let .nowPlaying(track):
            self.performNowPlayingAction(action, track: track)
        case let .askAI(prompt):
            self.performAskAIAction(action, prompt: prompt)
        case let .recentSearch(query):
            self.performRecentSearchAction(action, query: query)
        case .systemAction, .audioOutput, .quicklink, .shellCommand, .calendarEvent:
            self.performLauncherExtraAction(action, on: result)
        default:
            break
        }
    }

    /// The system/audio/quicklink/shell/calendar kinds — split out of `performMiscAction` purely
    /// to keep its cyclomatic complexity under budget.
    private func performLauncherExtraAction(_ action: LauncherAction, on result: LauncherResult) {
        switch result {
        case let .systemAction(systemAction):
            self.performSystemAction(action, systemAction: systemAction)
        case let .audioOutput(device):
            self.performAudioOutputAction(action, device: device)
        case let .quicklink(_, _, url):
            self.performQuicklinkAction(action, url: url)
        case let .shellCommand(command):
            self.performShellCommandAction(action, command: command)
        case let .calendarEvent(event):
            self.performCalendarAction(action, event: event)
        default:
            break
        }
    }

    private func performCalculationAction(_ action: LauncherAction, display: String) {
        switch action {
        case .copy: self.onCopyText(display)
        case .paste: self.onPasteText(display)
        default: break
        }
    }

    private func performAppAction(_ action: LauncherAction, url: URL) {
        switch action {
        case .open, .switchTo: self.onOpenFile(url)
        case .revealInFinder: self.onRevealFile(url)
        case .copyPath: self.onCopyPath(url.path)
        case .quitApp: self.onQuitApp(url)
        default: break
        }
    }

    private func performFileAction(_ action: LauncherAction, url: URL) {
        switch action {
        case .open, .downloadAndOpen: self.onOpenFile(url)
        case .revealInFinder: self.onRevealFile(url)
        case .copyPath: self.onCopyPath(url.path)
        default: break
        }
    }

    private func performSnippetAction(_ action: LauncherAction, snippet: Snippet) {
        switch action {
        case .paste: self.onPasteSnippet(snippet)
        case .copy: self.onCopySnippet(snippet)
        default: break
        }
    }

    private func performClipAction(_ action: LauncherAction, item: ClipItem) {
        switch action {
        case .pin, .unpin:
            Task {
                try? await self.clipboardStore?.setPinned(id: item.id, !item.isPinned)
                self.scheduleSearch(preserveSelection: true)
            }
        case .openSource:
            if let source = item.sourceURL, let url = URL(string: source) {
                self.onOpenClipLink(url)
            }
        case .paste: self.onPasteClip(item, .full)
        case .pastePlain: self.onPasteClip(item, .plainText)
        case .copy: self.onCopyClip(item)
        case .openLink:
            if let url = Self.clipLinkURL(item) {
                self.onOpenClipLink(url)
            }
        default: break
        }
    }

    private func performWebSearchAction(_ action: LauncherAction, url: URL) {
        guard action == .search else { return }
        self.onOpenWebSearch(url)
    }

    private func performSystemSettingAction(_ action: LauncherAction, url: URL) {
        guard action == .openSetting else { return }
        self.onOpenSystemSetting(url)
    }

    private func performCommandAction(_ action: LauncherAction, command: LauncherCommand) {
        guard action == .runCommand else { return }
        self.onRunCommand(command)
    }

    private func performNowPlayingAction(_ action: LauncherAction, track: NowPlayingTrack) {
        switch action {
        case .copyLink: self.onCopyNowPlayingLink(track)
        case .openInSpotify: self.onOpenSpotify(track)
        default: break
        }
    }

    private func performAskAIAction(_ action: LauncherAction, prompt: String) {
        switch action {
        case .paste: self.onAskAI(prompt, .paste)
        case .copy: self.onAskAI(prompt, .copy)
        default: break
        }
    }

    private func performSystemAction(_ action: LauncherAction, systemAction: SystemAction) {
        guard action == .runCommand else { return }
        self.onRunSystemAction(systemAction)
    }

    private func performAudioOutputAction(_ action: LauncherAction, device: AudioOutputDevice) {
        guard action == .switchTo else { return }
        self.onSwitchAudioOutput(device)
    }

    /// A quicklink's ↩ opens the already-resolved URL through the same
    /// callback a web-search row uses — it needs no dedicated closure.
    private func performQuicklinkAction(_ action: LauncherAction, url: URL) {
        guard action == .openLink else { return }
        self.onOpenWebSearch(url)
    }

    private func performShellCommandAction(_ action: LauncherAction, command: String) {
        guard action == .runCommand else { return }
        self.onRunShellCommand(command)
    }

    private func performCalendarAction(_ action: LauncherAction, event: CalendarEvent) {
        switch action {
        case .joinMeeting:
            if let link = event.meetingLink {
                self.onJoinMeeting(event, link.url)
            }
        case .copyLink:
            if let link = event.meetingLink {
                self.onCopyMeetingLink(event, link.url)
            }
        case .openInCalendar:
            self.onOpenInCalendar(event)
        default: break
        }
    }

    private func performRecentSearchAction(_ action: LauncherAction, query: String) {
        switch action {
        case .rerunSearch:
            // Re-run the past search in place — refill the bar, stay open.
            self.query = query
            self.selectedIndex = 0
            self.scheduleSearch()
        case .removeRecent:
            self.deleteSelectedRecent()
        default: break
        }
    }

    /// The link clip's destination URL, trimmed the same way `ClipAction.openLink`
    /// parses it. `previewText` is the launcher's available text (full payload
    /// isn't prefetched here); links are short, so it's the whole URL.
    private static func clipLinkURL(_ item: ClipItem) -> URL? {
        guard let text = item.previewText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else { return nil }
        return URL(string: text)
    }

    public func recordSuccessfulSelection(id: String, query: String) {
        var counts = Defaults[.launcherItemUseCounts]
        var lastUsed = Defaults[.launcherItemLastUsed]
        counts[id] = min(counts[id, default: 0] + 1, 100_000)
        lastUsed[id] = Date.now.timeIntervalSince1970
        if counts.count > 2000 {
            for key in counts.keys.sorted(by: { lastUsed[$0, default: 0] < lastUsed[$1, default: 0] })
                .prefix(counts.count - 2000)
            {
                counts.removeValue(forKey: key)
                lastUsed.removeValue(forKey: key)
            }
        }
        Defaults[.launcherItemUseCounts] = counts
        Defaults[.launcherItemLastUsed] = lastUsed
        let query = AppMatcher.fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !query.isEmpty else { return }
        var usage = Defaults[.launcherSelectionUsage]
        let key = query + "\u{1F}" + id
        usage[key] = min(usage[key, default: 0] + 1, 100)
        if usage.count > 2000 {
            let oldest = usage.sorted { $0.value < $1.value }.prefix(usage.count - 2000)
            for entry in oldest {
                usage.removeValue(forKey: entry.key)
            }
        }
        Defaults[.launcherSelectionUsage] = usage
    }
}
