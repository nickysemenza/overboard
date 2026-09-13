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

    private let store: ClipStore

    /// The in-flight (or most recently finished) persist triggered by
    /// `saveDraft()` or the switch-triggered auto-save. Not used by any UI
    /// call site — both fire-and-forget — but gives tests a way to await
    /// completion instead of racing the background write.
    private(set) var pendingSaveTask: Task<Void, Never>?

    init(store: ClipStore) {
        self.store = store
    }

    var selected: Snippet? {
        self.snippets.first { $0.id == self.selectedID }
    }

    /// Whether the draft has edits the selected snippet doesn't have yet.
    /// False once nothing is selected — there's nothing to compare against.
    var isDirty: Bool {
        guard let selected else { return false }
        return self.draftTitle != selected.title || self.draftBody != selected.body
    }

    /// Snippets matching `filter` by title, case-insensitively. Selection is
    /// untouched here — a still-visible selected snippet stays selected as
    /// the filter changes.
    var filteredSnippets: [Snippet] {
        guard !self.filter.isEmpty else { return self.snippets }
        return self.snippets.filter { $0.title.localizedCaseInsensitiveContains(self.filter) }
    }

    func load() async {
        self.snippets = await (try? self.store.snippets()) ?? []
        if self.selectedID == nil {
            self.selectSnippet(self.snippets.first?.id)
        }
    }

    /// Selects a different snippet. This is a personal editor with no
    /// explicit "discard changes?" prompt, so silently dropping a dirty draft
    /// on switch would be more surprising than saving it — auto-save the
    /// outgoing draft first, unless its title is empty (that would create a
    /// junk blank-titled snippet; those edits are simply dropped instead).
    func selectSnippet(_ id: String?) {
        if self.isDirty, let previous = self.selected, !self.draftTitle.isEmpty {
            self.persist(id: previous.id, title: self.draftTitle, body: self.draftBody)
        }
        self.selectedID = id
        let snippet = self.snippets.first { $0.id == id }
        self.draftTitle = snippet?.title ?? ""
        self.draftBody = snippet?.body ?? ""
    }

    func addSnippet() {
        let snippet = Snippet(title: "New Snippet", body: "")
        Task {
            try? await self.store.saveSnippet(snippet)
            await self.load()
            self.selectSnippet(snippet.id)
        }
    }

    /// Explicit Save (button / ⌘S). Unlike the switch-triggered auto-save,
    /// this always applies — an empty title falls back to "Untitled" rather
    /// than silently discarding the edit, since the user asked for it directly.
    func saveDraft() {
        guard let selected else { return }
        let title = self.draftTitle.isEmpty ? "Untitled" : self.draftTitle
        self.persist(id: selected.id, title: title, body: self.draftBody)
    }

    private func persist(id: String, title: String, body: String) {
        guard var snippet = self.snippets.first(where: { $0.id == id }) else { return }
        snippet.title = title
        snippet.body = body
        self.pendingSaveTask = Task {
            try? await self.store.saveSnippet(snippet)
            await self.load()
        }
    }

    func deleteSelected() {
        guard let id = self.selectedID else { return }
        Task {
            try? await self.store.deleteSnippet(id: id)
            self.selectedID = nil
            await self.load()
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

                HStack {
                    Text("Placeholders: {date} {time} {datetime} {uuid} {clipboard}")
                        .font(.caption)
                        .contrastAwareForeground(.tertiary)
                    Spacer()
                    Button("Save") {
                        self.viewModel.saveDraft()
                    }
                    .keyboardShortcut("s")
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
