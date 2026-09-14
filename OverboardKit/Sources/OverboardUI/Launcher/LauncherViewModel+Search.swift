import AsyncAlgorithms
import Foundation
import os
import OverboardCore
import OverboardMac

/// The keystroke-to-results pipeline: the instant pass (apps/calculator/web,
/// every keystroke) and the debounced secondary pass (indexed files FTS,
/// clipboard FTS, snippet scans), plus search history.
public extension LauncherViewModel {
    /// Preps state for a summon. When `clearQuery` is false the previous `query`
    /// is kept so a quickly-reopened launcher resumes where it left off;
    /// `scheduleSearch()` repopulates its rows (and clears them when the query is
    /// empty). When `clearQuery` is true the bar opens fresh.
    func prepareForShow(clearQuery: Bool) {
        self.searchTask?.cancel()
        if clearQuery {
            self.query = ""
        }
        // Pick up entries this session has saved since the model was created so
        // the empty-field recents list is current.
        self.history = Self.normalizedHistory(Defaults[.launcherSearchHistory])
        if self.history != Defaults[.launcherSearchHistory] {
            Defaults[.launcherSearchHistory] = self.history
        }
        self.selectedIndex = 0
        self.showGeneration += 1
        self.scheduleSearch()
    }

    func scheduleSearch(preserveSelection: Bool = false) {
        self.searchTask?.cancel()
        let query = self.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let scope = self.scope
        if !preserveSelection {
            self.clipboardLimit = 200
            self.hasMoreClipboard = false
            // Deliberately not clearing `results` here: the stale list stays on
            // screen until the instant pass (`setResults` below) replaces it, so
            // fast typing doesn't flash the empty state between keystrokes.
            self.resultsAreStale = true
            self.userSelected = false
            self.selectedIndex = 0
            self.isPaletteOpen = false
        }
        self.statusMessage = nil
        self.isSearching = true
        // Each call claims a new generation so a task cancelled by a later
        // keystroke can't clear `isSearching` after a newer task has already
        // taken over (and possibly finished) — only the current generation's
        // exit is allowed to flip the flag back off.
        self.searchGeneration += 1
        let generation = self.searchGeneration
        if query.isEmpty, scope == .all {
            self.scheduleRecentsSearch(preserveSelection: preserveSelection, generation: generation)
        } else {
            self.scheduleQuerySearch(query: query, scope: scope, generation: generation)
        }
    }

    /// The empty-field branch of `scheduleSearch`: recents render immediately,
    /// then a task fills in frecency-sorted app suggestions above them.
    private func scheduleRecentsSearch(preserveSelection: Bool, generation: Int) {
        let recents = self.history.reversed().prefix(self.maxRecentRows)
            .map { LauncherResult.recentSearch(query: $0) }
        self.setResults(recents, preserveSelection: preserveSelection)
        self.searchTask = Task {
            let apps = await self.instantRouter.results(for: "", scope: .apps)
            guard !Task.isCancelled else {
                self.finishSearch(generation)
                return
            }
            let counts = Defaults[.launcherItemUseCounts]
            let candidates = apps.filter { row in
                if counts[row.id, default: 0] > 0 {
                    return true
                }
                if case let .app(_, url) = row {
                    return self.runningAppPaths.contains(url.path)
                }
                return false
            }
            let suggestions = self.sortByFrecency(candidates).prefix(6)
            self.setResults(Array(suggestions) + recents, preserveSelection: true)
            self.finishSearch(generation)
        }
    }

    /// The non-empty-query branch of `scheduleSearch`: the instant pass runs
    /// (or, in clipboard scope, is skipped straight to the debounced store
    /// query), then hands off to the secondary pass when there's more to find.
    private func scheduleQuerySearch(query: String, scope: LauncherScope, generation: Int) {
        self.searchTask = Task {
            // The clipboard-scope store query is itself a "secondary" pass (a
            // full FTS/browse query, not an in-memory lookup), so it's routed
            // through the same debounce as the file/clipboard/snippet
            // fan-out below. `isSearching` stays true — cleared by
            // `runSecondaryPass` once the debounced fetch lands — and
            // `resultsAreStale` (set above) keeps ↩ from acting on the old
            // list until then.
            if scope == .clipboard, self.clipboardStore != nil {
                self.sendToSecondaryChannel()
                return
            }
            let instantState = self.searchSignposter.beginInterval("instant pass")
            let instant = await self.instantRouter.results(for: query, scope: scope)
            self.searchSignposter.endInterval("instant pass", instantState)
            guard !Task.isCancelled else {
                self.finishSearch(generation)
                return
            }
            self.lastInstantResults = instant
            self.setResults(instant, preserveSelection: true)
            // The instant pass never carries `.clip` rows, so any excerpts
            // left over from the previous query no longer pair with anything
            // on screen; the debounced pass repopulates this once its own
            // clip rows land.
            self.matchExcerpts = [:]
            let providers = self.secondaryProviders.filter { $0.searchScopes.contains(scope) }
            guard !LauncherQuery.isCommandLike(query), !providers.isEmpty else {
                self.finishSearch(generation)
                return
            }
            // Secondary providers (indexed files FTS, clipboard FTS, snippet
            // scans) don't run on every keystroke — only once the query has
            // been stable for the debounce interval passed to `init`.
            self.sendToSecondaryChannel()
        }
    }

    /// See `secondaryChannel`: the send must outlive `searchTask`'s
    /// cancellation, so it gets a task of its own. The debounce collapses
    /// any pile-up into one pass.
    private func sendToSecondaryChannel() {
        Task { [secondaryChannel] in await secondaryChannel.send(()) }
    }

    /// The debounced half of a search: the clipboard-scope store query, or
    /// the secondary-provider fan-out (indexed files FTS, clipboard FTS,
    /// snippet scans). Runs on the long-lived consumer started in `init`, so
    /// it isn't tied to `searchTask`'s per-keystroke cancellation — instead it
    /// reads the *current* query/scope when the debounce settles (matching
    /// `AsyncChannel.debounce`'s coalescing: only the latest keystroke's send
    /// actually fires this) and checks `searchGeneration` before touching
    /// `results`, so a pass superseded by a still-newer keystroke can't
    /// clobber it.
    internal func runSecondaryPass() async {
        let generation = self.searchGeneration
        let state = self.searchSignposter.beginInterval("secondary pass")
        defer { self.searchSignposter.endInterval("secondary pass", state) }
        let query = self.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let scope = self.scope
        if scope == .clipboard, let store = self.clipboardStore {
            do {
                let items = try await store.browseHistory(
                    query,
                    filter: self.clipboardFilter,
                    limit: self.clipboardLimit + 1
                )
                let stats = try await store.libraryStats(topSources: 100)
                guard self.searchGeneration == generation else { return }
                self.sources = stats.bySource.map(\.app).sorted()
                self.hasMoreClipboard = items.count > self.clipboardLimit
                let clips = Array(items.prefix(self.clipboardLimit))
                self.setResults(clips.map(LauncherResult.clip), preserveSelection: true)
                await self.refreshMatchExcerpts(itemIDs: clips.map(\.id), query: query)
            } catch {
                guard self.searchGeneration == generation else { return }
                self.statusMessage = "Couldn’t search clipboard history. Try again."
                self.setResults([])
            }
            self.finishSearch(generation)
            return
        }
        let instant = self.lastInstantResults
        let providers = self.secondaryProviders.filter { $0.searchScopes.contains(scope) }
        // Re-checked here (not just in `scheduleSearch`, before the send):
        // a command-mode query that arrives while an older, non-command
        // send is still sitting in the debounce window must not let that
        // stale send fan out to secondary providers once it fires.
        guard !LauncherQuery.isCommandLike(query), !providers.isEmpty else {
            self.finishSearch(generation)
            return
        }
        var buckets = [[LauncherResult]](repeating: [], count: providers.count)
        await withTaskGroup(of: (Int, [LauncherResult]).self) { group in
            for (index, provider) in providers.enumerated() {
                group.addTask { await (index, provider.results(for: query)) }
            }
            for await (index, rows) in group {
                guard self.searchGeneration == generation else { return }
                buckets[index] = rows.filter(scope.includes)
                self.setResults(instant + buckets.flatMap(\.self), preserveSelection: true)
            }
        }
        guard self.searchGeneration == generation else { return }
        await self.refreshMatchExcerpts(for: self.results, query: query)
        self.finishSearch(generation)
    }

    /// Batches the FTS excerpts for every `.clip` row currently on screen into
    /// one store call instead of one per row — `LauncherRow` used to run
    /// `store.matchExcerpt` from its own per-row `.task`, firing dozens of
    /// concurrent SQLite calls while typing.
    private func refreshMatchExcerpts(for results: [LauncherResult], query: String) async {
        let ids = results.compactMap { result -> String? in
            guard case let .clip(item) = result else { return nil }
            return item.id
        }
        await self.refreshMatchExcerpts(itemIDs: ids, query: query)
    }

    private func refreshMatchExcerpts(itemIDs: [String], query: String) async {
        guard !itemIDs.isEmpty, !query.isEmpty, let store = self.clipboardStore else {
            self.matchExcerpts = [:]
            return
        }
        self.matchExcerpts = await (try? store.matchExcerpts(itemIDs: itemIDs, query: query)) ?? [:]
    }

    /// Clears `isSearching` only if no newer `scheduleSearch` call has started
    /// since this task began — a stale, cancelled task must never clear the
    /// spinner out from under a search that superseded it.
    internal func finishSearch(_ generation: Int) {
        guard self.searchGeneration == generation else { return }
        self.isSearching = false
        let waiters = self.settleWaiters
        self.settleWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    /// Returns once the search pipeline is idle: the current `searchTask` has
    /// finished and, if it handed off to the debounced secondary pass, that
    /// pass has landed too.
    ///
    /// This exists so tests can wait on the real end of a search instead of
    /// polling `isSearching` on a sleep loop — a loop that is both slower than
    /// it needs to be and, on a loaded machine, capable of timing out while the
    /// search is still perfectly healthy. Everything is main-actor, so
    /// `scheduleSearch(); await settle()` cannot miss the signal: nothing can
    /// run between the call that sets `isSearching` and the `await` that parks.
    /// The loop re-checks the flag because a newer keystroke may have claimed a
    /// fresh generation while this caller was parked.
    func settle() async {
        while self.isSearching {
            await withCheckedContinuation { continuation in
                self.settleWaiters.append(continuation)
            }
        }
    }

    // MARK: - Search history

    /// Save the current query as the most-recent history entry. Called on every
    /// dismissal (commit / click-outside) and by the first, query-clearing
    /// stage of Esc; no-ops on empty queries and de-dupes, so a double call
    /// (Esc, then `hide`) is harmless.
    func recordCurrentQuery() {
        let trimmed = self.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var updated = BoundedRecents(mostRecentFirst: self.history.reversed(), limit: Self.maxHistory)
        updated.record(trimmed)
        self.history = Array(updated.mostRecentFirst.reversed())
        Defaults[.launcherSearchHistory] = self.history
    }

    /// Removes the selected recent-search row from history (⌘⌫ on the empty
    /// field). Returns true only when a recent was actually deleted, so the
    /// caller can swallow the keystroke; any other row kind is left untouched.
    @discardableResult
    func deleteSelectedRecent() -> Bool {
        guard self.results.indices.contains(self.selectedIndex),
              case let .recentSearch(query) = self.results[self.selectedIndex]
        else { return false }
        var updated = BoundedRecents(mostRecentFirst: self.history.reversed(), limit: Self.maxHistory)
        updated.remove(query)
        self.history = Array(updated.mostRecentFirst.reversed())
        Defaults[.launcherSearchHistory] = self.history
        // Re-render the (still empty-field) recents list; setResults reclamps the
        // selection so it lands on the next row down.
        let oldIndex = self.selectedIndex
        self.setResults(
            self.results.filter {
                if case .app = $0 {
                    true
                } else {
                    false
                }
            }
                + self.history.reversed().prefix(self.maxRecentRows).map { .recentSearch(query: $0) }
        )
        self.selectedIndex = min(oldIndex, max(self.results.count - 1, 0))
        return true
    }

    internal static func normalizedHistory(_ persisted: [String]) -> [String] {
        Array(BoundedRecents(mostRecentFirst: persisted.reversed(), limit: LauncherViewModel.maxHistory).mostRecentFirst
            .reversed())
    }

    private func sortByFrecency(_ rows: [LauncherResult]) -> [LauncherResult] {
        LauncherFrecency.sorted(
            rows,
            counts: Defaults[.launcherItemUseCounts],
            lastUsed: Defaults[.launcherItemLastUsed]
        )
    }

    internal func setResults(_ newResults: [LauncherResult], preserveSelection: Bool = false) {
        // Only a manual selection is re-anchored by id. An automatic
        // selection deliberately snaps back to row 0 when a later provider
        // bucket re-sorts the list: the product rule is "the best match is
        // first and selected", so a file that outranks the instant web row
        // must be what ↩ opens. The 120 ms secondary-pass debounce is what
        // keeps that re-sort from racing a keypress.
        let anchor = preserveSelection && self.userSelected ? self.selectedResult?.id : nil
        let prefix = AppMatcher.fold(self.query.trimmingCharacters(in: .whitespacesAndNewlines)) + "\u{1F}"
        let usage = Dictionary(uniqueKeysWithValues: Defaults[.launcherSelectionUsage].compactMap { key, value in
            key.hasPrefix(prefix) ? (String(key.dropFirst(prefix.count)), value) : nil
        })
        let combined: [LauncherResult] = if self.scope == .clipboard {
            // The store owns FTS/OCR relevance and chronological browsing.
            newResults
        } else if self.query.isEmpty, self.scope == .apps {
            self.sortByFrecency(newResults)
        } else if self.query.isEmpty {
            newResults + (self.scope == .all ? self.pinnedResults() : [])
        } else {
            LauncherRanking.sorted(newResults + (self.scope == .all ? self.pinnedResults() : []), query: self.query,
                                   aliases: AppMatcher.parseAliases(Defaults[.launcherAppAliases]), usage: usage)
        }
        var seen = Set<String>()
        self.results = combined.filter { seen.insert($0.id).inserted }
        self.resultsAreStale = false
        if let anchor, let index = self.results.firstIndex(where: { $0.id == anchor }) {
            self.selectedIndex = index
        } else {
            self.selectedIndex = 0
        }
    }
}
