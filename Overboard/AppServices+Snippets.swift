import AppKit
import Observation
import OverboardCore
import SwiftUI

extension AppServices {
    func invokeSnippet(_ snippet: Snippet, into target: NSRunningApplication?, copyOnly: Bool) {
        guard self.libraryRecovery == nil, self.isStarted else { return }
        let query = self.launcherViewModel.query
        let context = TemplateEngine.Context.capture(
            for: snippet.body, clipboard: NSPasteboard.general.string(forType: .string)
        )
        let model = SnippetInvocationModel(body: snippet.body, context: context)
        if !model.arguments.isEmpty {
            let alert = NSAlert()
            alert.messageText = snippet.title
            alert.informativeText = "Review the arguments and expanded text before publishing to the clipboard."
            alert.addButton(withTitle: copyOnly ? "Copy" : "Paste")
            alert.addButton(withTitle: "Cancel")
            let view = NSHostingView(rootView: SnippetInvocationView(model: model))
            view.frame = NSRect(x: 0, y: 0, width: 460, height: min(540, 260 + model.arguments.count * 52))
            alert.accessoryView = view
            NSApp.activate()
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        do {
            let text = try TemplateEngine.expand(snippet.body, arguments: model.values, context: context)
            Task {
                let outcome = if copyOnly {
                    await self.actions.copyStringAndWait(text, hud: "Snippet copied — ⌘V to paste")
                } else {
                    await self.actions.pasteStringAndWait(text, into: target)
                }
                if outcome == .copied || outcome == .dispatched {
                    self.launcherViewModel.recordSuccessfulSelection(
                        id: LauncherResult.snippet(snippet).id,
                        query: query
                    )
                }
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Snippet could not be expanded"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}

@Observable
private final class SnippetInvocationModel {
    let body: String
    let context: TemplateEngine.Context
    let arguments: [TemplateEngine.Argument]
    var values: [String: String]

    init(body: String, context: TemplateEngine.Context) {
        self.body = body
        self.context = context
        self.arguments = TemplateEngine.arguments(in: body)
        self.values = Dictionary(uniqueKeysWithValues: self.arguments.map { ($0.name, $0.defaultValue ?? "") })
    }

    var preview: String {
        (try? TemplateEngine.expand(self.body, arguments: self.values, context: self.context)) ?? self.body
    }
}

private struct SnippetInvocationView: View {
    @Bindable var model: SnippetInvocationModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(self.model.arguments) { argument in
                    TextField(argument.name, text: Binding(
                        get: { self.model.values[argument.name] ?? "" },
                        set: { self.model.values[argument.name] = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Snippet argument \(argument.name)")
                }
                Text("Preview").font(.headline)
                Text(self.model.preview)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }
            .padding(8)
        }
    }
}
