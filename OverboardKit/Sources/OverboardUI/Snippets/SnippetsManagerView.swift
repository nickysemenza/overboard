import Observation
import OverboardCore
import SwiftUI

@Observable
final class SnippetsManagerViewModel {
    var snippets: [Snippet] = []
    var selectedID: String?
    var draftTitle: String = ""
    var draftBody: String = ""
    var filter: String = ""
    private var operationError: String?
    private var draftErrors: [String: String] = [:]
    var saveError: String? {
        self.selectedID.flatMap { self.draftErrors[$0] }
            ?? self.draftErrors.sorted { $0.key < $1.key }.first?.value
            ?? self.operationError
    }

    private(set) var savingIDs: Set<String> = []

    private struct Draft {
        var baseline: Snippet
        var title: String
        var body: String
    }

    private var drafts: [String: Draft] = [:]
    private var draftBaseline: Snippet?

    private let store: ClipStore
    private let previewContext = TemplateEngine.Context()

    var previewText: String {
        TemplateEngine.preview(self.draftBody, context: self.previewContext)
    }

    func insertToken(_ token: String) {
        guard self.selectedID != nil else { return }
        self.draftBody.append(token)
    }

    /// The in-flight (or most recently finished) persist triggered by
    /// `saveDraft()` or the switch-triggered auto-save. Not used by any UI
    /// call site — both fire-and-forget — but gives tests a way to await
    /// completion instead of racing the background write.
    private(set) var pendingSaveTask: Task<Void, Never>?

    init(store: ClipStore) {
        self.store = store
    }

    var selected: Snippet? {
        self.snippets.first { $0.id == self.selectedID } ?? self.draftBaseline
    }

    /// Whether the draft has edits the selected snippet doesn't have yet.
    /// False once nothing is selected — there's nothing to compare against.
    var isDirty: Bool {
        guard let baseline = self.draftBaseline else { return false }
        return self.draftTitle != baseline.title || self.draftBody != baseline.body
    }

    /// Snippets matching `filter` by title, case-insensitively. Selection is
    /// untouched here — a still-visible selected snippet stays selected as
    /// the filter changes.
    var filteredSnippets: [Snippet] {
        guard !self.filter.isEmpty else { return self.snippets }
        return self.snippets.filter { $0.title.localizedCaseInsensitiveContains(self.filter) }
    }

    func load() async {
        do {
            self.snippets = try await self.store.snippets()
            self.operationError = nil
            if self.selectedID == nil {
                self.selectSnippet(self.snippets.first?.id)
            } else if !self.isDirty, let latest = self.snippets.first(where: { $0.id == self.selectedID }) {
                self.draftBaseline = latest
                self.draftTitle = latest.title
                self.draftBody = latest.body
            }
        } catch {
            self.operationError = error.localizedDescription
        }
    }

    /// Selects a different snippet. This is a personal editor with no
    /// explicit "discard changes?" prompt, so dirty drafts survive selection
    /// changes while non-empty titles are auto-saved against their revision.
    func selectSnippet(_ id: String?) {
        guard id != self.selectedID else { return }
        if let baseline = self.draftBaseline {
            self.drafts[baseline.id] = Draft(baseline: baseline, title: self.draftTitle, body: self.draftBody)
            if self.isDirty, !self.draftTitle.isEmpty {
                self.persist(baseline: baseline, title: self.draftTitle, body: self.draftBody)
            }
        }
        self.selectedID = id
        let snippet = self.snippets.first { $0.id == id }
        let draft = id.flatMap { self.drafts[$0] }.flatMap {
            $0.title != $0.baseline.title || $0.body != $0.baseline.body ? $0 : nil
        }
        self.draftBaseline = draft?.baseline ?? snippet
        self.draftTitle = draft?.title ?? snippet?.title ?? ""
        self.draftBody = draft?.body ?? snippet?.body ?? ""
    }

    func addSnippet() {
        let snippet = Snippet(title: "New Snippet", body: "")
        Task {
            do {
                try await self.store.saveSnippet(snippet)
                await self.load()
                self.selectSnippet(snippet.id)
            } catch {
                self.operationError = error.localizedDescription
            }
        }
    }

    /// Explicit Save (button / ⌘S). Unlike the switch-triggered auto-save,
    /// this always applies — an empty title falls back to "Untitled" rather
    /// than silently discarding the edit, since the user asked for it directly.
    func saveDraft() {
        guard let baseline = self.draftBaseline else { return }
        let title = self.draftTitle.isEmpty ? "Untitled" : self.draftTitle
        self.persist(baseline: baseline, title: title, body: self.draftBody)
    }

    private func persist(baseline: Snippet, title: String, body: String) {
        let id = baseline.id
        guard !self.savingIDs.contains(id) else { return }
        self.savingIDs.insert(id)
        var snippet = baseline
        snippet.title = title
        snippet.body = body
        self.pendingSaveTask = Task {
            defer { self.savingIDs.remove(id) }
            do {
                let saved = try await self.store.saveSnippet(snippet, expectedRevision: baseline.lamport)
                if var draft = self.drafts[id] {
                    draft.baseline = saved
                    self.drafts[id] = draft
                }
                if self.selectedID == id {
                    self.draftBaseline = saved
                    if self.draftBody == body, self.draftTitle == title || self.draftTitle.isEmpty {
                        self.draftTitle = saved.title
                        self.draftBody = saved.body
                        self.drafts[id] = nil
                    }
                }
                self.draftErrors[id] = nil
                self.snippets = try await self.store.snippets()
            } catch {
                self.draftErrors[id] = "Could not save \(baseline.title): \(error.localizedDescription)"
            }
        }
    }

    func reloadSelected() {
        guard let latest = self.snippets.first(where: { $0.id == self.selectedID }) else { return }
        self.drafts[latest.id] = nil
        self.draftBaseline = latest
        self.draftTitle = latest.title
        self.draftBody = latest.body
        self.draftErrors[latest.id] = nil
    }

    func deleteSelected() {
        guard let id = self.selectedID else { return }
        Task {
            do {
                try await self.store.deleteSnippet(id: id)
                self.drafts[id] = nil
                self.draftErrors[id] = nil
                if self.selectedID == id {
                    self.draftBaseline = nil
                    self.selectedID = nil
                }
                await self.load()
            } catch {
                self.operationError = error.localizedDescription
            }
        }
    }
}

public struct SnippetsManagerView: View {
    @State private var viewModel: SnippetsManagerViewModel

    public init(store: ClipStore) {
        self._viewModel = State(initialValue: SnippetsManagerViewModel(store: store))
    }

    public var body: some View {
        HSplitView {
            self.snippetList
                .frame(minWidth: 180, maxWidth: 260)
            self.editor
                .frame(minWidth: 320, maxWidth: .infinity)
        }
        .searchable(text: Binding(
            get: { self.viewModel.filter },
            set: { self.viewModel.filter = $0 }
        ))
        .toolbar {
            ToolbarItemGroup {
                Button {
                    self.viewModel.addSnippet()
                } label: {
                    Image(systemName: "plus")
                }
                .help("Add Snippet")
                .accessibilityLabel("Add Snippet")
                Button {
                    self.viewModel.deleteSelected()
                } label: {
                    Image(systemName: "minus")
                }
                .help("Remove Snippet")
                .accessibilityLabel("Remove Snippet")
                .disabled(self.viewModel.selectedID == nil)
            }
        }
        .task {
            NSApp.activate(ignoringOtherApps: true)
            await self.viewModel.load()
        }
        .safeAreaInset(edge: .bottom) {
            if let error = self.viewModel.saveError {
                HStack {
                    Text(error).foregroundStyle(.red)
                    Spacer()
                    Button("Reload Latest") {
                        Task {
                            await self.viewModel.load()
                            self.viewModel.reloadSelected()
                        }
                    }
                }
                .font(.caption)
                .padding(10)
            }
        }
    }

    private var snippetList: some View {
        List(self.viewModel.filteredSnippets, selection: Binding(
            get: { self.viewModel.selectedID },
            set: { self.viewModel.selectSnippet($0) }
        )) { snippet in
            Text(snippet.title)
                .lineLimit(1)
                .tag(snippet.id)
        }
    }

    @ViewBuilder
    private var editor: some View {
        if self.viewModel.selectedID != nil {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Title", text: Binding(
                    get: { self.viewModel.draftTitle },
                    set: { self.viewModel.draftTitle = $0 }
                ))
                .font(.title3)
                .textFieldStyle(.roundedBorder)

                TextEditor(text: Binding(
                    get: { self.viewModel.draftBody },
                    set: { self.viewModel.draftBody = $0 }
                ))
                .font(.body.monospaced())
                .scrollContentBackground(.hidden)
                .background(.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))

                Text(self.viewModel.previewText)
                    .font(.caption.monospaced())
                    .lineLimit(3)
                    .textSelection(.enabled)
                    .accessibilityLabel("Template preview")

                HStack {
                    Text("Tokens: {date} {time} {datetime} {uuid} {clipboard} · {{name|default}} · {{date:yyyy-MM-dd}}")
                        .font(.caption)
                        .contrastAwareForeground(.tertiary)
                    Spacer()
                    Menu("Insert Token") {
                        ForEach(
                            [
                                "{date}", "{time}", "{datetime}", "{uuid}", "{clipboard}",
                                "{{name}}", "{{name|default}}", "{{date:yyyy-MM-dd}}",
                            ], id: \.self
                        ) { token in
                            Button(token) { self.viewModel.insertToken(token) }
                        }
                    }
                    Button("Save") {
                        self.viewModel.saveDraft()
                    }
                    .keyboardShortcut("s")
                    .disabled(self.viewModel.selectedID.map { self.viewModel.savingIDs.contains($0) } ?? true)
                }
            }
            .padding(12)
        } else {
            ContentUnavailableView(
                "No snippet selected",
                systemImage: "text.badge.star",
                description: Text("Add a snippet with the + button.")
            )
        }
    }
}

#if DEBUG
    #Preview("Manager") {
        SeededPreview { store in
            SnippetsManagerView(store: store)
        }
        .frame(width: 700, height: 420)
    }
#endif
