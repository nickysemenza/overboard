import Observation
import OverboardCore
import SwiftUI

@MainActor
@Observable
final class SnippetsManagerViewModel {
    var snippets: [Snippet] = []
    var selectedID: String?
    var draftTitle: String = ""
    var draftBody: String = ""

    private let store: ClipStore

    init(store: ClipStore) {
        self.store = store
    }

    var selected: Snippet? {
        self.snippets.first { $0.id == self.selectedID }
    }

    func load() async {
        self.snippets = await (try? self.store.snippets()) ?? []
        if self.selectedID == nil { self.selectSnippet(self.snippets.first?.id) }
    }

    func selectSnippet(_ id: String?) {
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

    func saveDraft() {
        guard var snippet = self.selected else { return }
        snippet.title = self.draftTitle.isEmpty ? "Untitled" : self.draftTitle
        snippet.body = self.draftBody
        Task {
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
        .task {
            NSApp.activate(ignoringOtherApps: true)
            await self.viewModel.load()
        }
    }

    private var snippetList: some View {
        VStack(spacing: 0) {
            List(self.viewModel.snippets, selection: Binding(
                get: { self.viewModel.selectedID },
                set: { self.viewModel.selectSnippet($0) }
            )) { snippet in
                Text(snippet.title)
                    .lineLimit(1)
                    .tag(snippet.id)
            }
            Divider()
            HStack {
                Button {
                    self.viewModel.addSnippet()
                } label: {
                    Image(systemName: "plus")
                }
                Button {
                    self.viewModel.deleteSelected()
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(self.viewModel.selectedID == nil)
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(8)
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
                        .foregroundStyle(.tertiary)
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
