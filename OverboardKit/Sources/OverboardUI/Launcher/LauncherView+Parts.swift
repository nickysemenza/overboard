import OverboardCore
import OverboardMac
import SwiftUI

/// Subviews extracted out of `LauncherView` purely to keep that struct's body
/// under SwiftLint's type_body_length — the rendered tree is unchanged
/// (snapshot tests pin the output byte-for-byte).
struct LauncherSearchBar: View {
    @Bindable var viewModel: LauncherViewModel
    var fieldFocused: FocusState<Bool>.Binding
    /// Gates the search-bar spinner behind a short delay so it doesn't
    /// flicker on every keystroke — `isSearching` is true through the whole
    /// 120 ms debounce window (stream 2a), not just while a request is
    /// actually in flight.
    @State private var showSpinner = false
    @State private var spinnerDelayTask: Task<Void, Never>?

    var body: some View {
        PanelSearchField(
            symbol: "magnifyingglass",
            prompt: self.viewModel.scope == .clipboard
                ? String(localized: "Find something you copied…", bundle: .module)
                : String(localized: "Search apps, files, clipboard, or the web…", bundle: .module),
            text: self.$viewModel.query,
            size: .large,
            accessibilityLabel: String(localized: "Search \(self.viewModel.scope.rawValue)", bundle: .module),
            focus: self.fieldFocused
        ) {
            if self.showSpinner {
                ProgressView().controlSize(.small)
            }
        }
        .onChange(of: self.viewModel.isSearching) { self.scheduleSpinnerDelay() }
    }

    /// Only shows the spinner once `isSearching` has held continuously for
    /// ~300 ms; cancelled (and the spinner hidden) the moment a search
    /// finishes before that window elapses.
    private func scheduleSpinnerDelay() {
        self.spinnerDelayTask?.cancel()
        guard self.viewModel.isSearching else {
            self.showSpinner = false
            return
        }
        self.spinnerDelayTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self.showSpinner = true
        }
    }
}

struct LauncherScopeBar: View {
    @Bindable var viewModel: LauncherViewModel

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(LauncherScope.allCases.enumerated()), id: \.element) { index, scope in
                Button { self.viewModel.setScope(scope) } label: {
                    HStack(spacing: 6) {
                        Text(scope.rawValue).font(.subheadline.weight(.medium))
                        Text("⌘\(index + 1)").font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 11).padding(.vertical, 6)
                    .background(
                        self.viewModel.scope == scope ? SelectionTint.neutral : .clear,
                        in: RoundedRectangle(cornerRadius: ControlRadius.compact)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(self.viewModel.scope == scope ? .isSelected : [])
            }
            Spacer(minLength: 0)
            if self.viewModel.scope == .files {
                Text(FileIndexService.shared.status).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.horizontal, 12).padding(.bottom, 10)
    }
}

struct LauncherFooterBar: View {
    @Bindable var viewModel: LauncherViewModel

    var body: some View {
        PanelFooterBar(
            primary: self.viewModel.primaryAction.map { action in
                .init(label: self.viewModel.primaryActionLabel ?? action.label) { self.viewModel.commit() }
            },
            secondary: .actions { self.viewModel.togglePalette() }
        )
        .padding(.horizontal, 12).padding(.vertical, 9)
    }
}

struct LauncherResultList: View {
    @Bindable var viewModel: LauncherViewModel
    let store: ClipStore

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(self.viewModel.results.enumerated()), id: \.element.id) { index, result in
                        if let header = self.historyHeader(at: index) {
                            PanelSectionHeader(title: header)
                        }
                        // Computed once per search pass in the view model
                        // (batched into one store call) rather than per row.
                        let excerpt: String? = if case let .clip(item) = result {
                            self.viewModel.matchExcerpts[item.id]
                        } else {
                            nil
                        }
                        LauncherRow(
                            result: result,
                            store: self.store,
                            isSelected: index == self.viewModel.selectedIndex,
                            runningAppPaths: self.viewModel.runningAppPaths,
                            query: self.viewModel.query,
                            showsSourceBadge: self.viewModel.scope != .clipboard,
                            excerpt: excerpt,
                            actions: self.viewModel.actions(for: result),
                            onSelect: { self.viewModel.select(at: index) },
                            onCommit: { self.viewModel.select(at: index); self.viewModel.commit() },
                            onPerformAction: { action in
                                self.viewModel.select(at: index)
                                self.viewModel.perform(action)
                            }
                        )
                        .id(result.id)
                    }
                    if self.viewModel.hasMoreClipboard {
                        Button("Show more history", action: self.viewModel.loadMoreClipboard)
                            .buttonStyle(.plain).font(.caption).padding(12)
                    }
                }
                .padding(8)
            }
            // Centered over the whole scroll viewport instead of living inside
            // the LazyVStack, where it used to hug the top with dead space
            // below. Hidden entirely while a search is still in flight — the
            // previous list stays on screen by design (stream 2a) — so it
            // only ever describes the *current* list, never a stale one.
            .overlay {
                if !self.viewModel.isSearching, self.viewModel.results.isEmpty {
                    self.emptyState
                }
            }
            .onChange(of: self.viewModel.selectedResult?.id) {
                if let id = self.viewModel.selectedResult?.id {
                    proxy.scrollTo(id)
                }
            }
            .onChange(of: self.viewModel.results.count) {
                if let id = self.viewModel.selectedResult?.id {
                    proxy.scrollTo(id)
                }
            }
        }
    }

    @ViewBuilder private var emptyState: some View {
        let query = self.viewModel.query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            PanelEmptyState(
                mark: .symbol("magnifyingglass"),
                title: String(localized: "No results for “\(query)”", bundle: .module),
                subtitle: String(localized: "Check the spelling or try a new search.", bundle: .module)
            )
        } else if self.viewModel.scope == .clipboard {
            PanelEmptyState(
                mark: .symbol("doc.on.clipboard"),
                title: String(localized: "No results", bundle: .module),
                subtitle: String(localized: "Copy something, or try a different search or filter.", bundle: .module)
            )
        } else {
            PanelEmptyState(
                mark: .symbol("magnifyingglass"),
                title: String(localized: "No results", bundle: .module),
                subtitle: String(localized: "Try a shorter name or choose another scope.", bundle: .module)
            )
        }
    }

    private func historyHeader(at index: Int) -> String? {
        if self.viewModel.scope == .all, self.viewModel.query.isEmpty {
            switch self.viewModel.results[index] {
            case .app: return index == 0 ? "Suggestions" : nil
            case .recentSearch:
                if index > 0, case .recentSearch = self.viewModel.results[index - 1] {
                    return nil
                }
                return "Recent searches"
            default: return nil
            }
        }
        guard self.viewModel.scope == .clipboard, self.viewModel.query.isEmpty,
              case let .clip(item) = self.viewModel.results[index] else { return nil }
        func label(_ date: Date) -> String {
            if Calendar.current.isDateInToday(date) {
                return "Today"
            }
            if Calendar.current.isDateInYesterday(date) {
                return "Yesterday"
            }
            return date.formatted(date: .abbreviated, time: .omitted)
        }
        let title = label(item.lastUsedAt)
        if index > 0, case let .clip(previous) = self.viewModel.results[index - 1],
           label(previous.lastUsedAt) == title
        {
            return nil
        }
        return title
    }
}
