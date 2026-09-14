import Defaults
import Foundation
import OverboardCore
import OverboardMac

// MARK: - ⌘K palette

/// A drawer keyboard shortcut surfaced in the ⌘K palette so it can be
/// discovered and run without memorizing the shortcut. UI-only vocabulary —
/// unlike `ClipAction` (content transforms shared with the Settings
/// applicability matrix), these just replay the same `DrawerViewModel`
/// methods `OverlayController+Keyboard.swift` calls for their key.
enum DrawerCommand: String, CaseIterable {
    case pastePlain
    case preview
    case edit
    case addToStack
    case togglePin
    case delete
    case switchToSnippets

    var systemImage: String {
        switch self {
        case .pastePlain: "textformat"
        case .preview: "eye"
        case .edit: "pencil"
        case .addToStack: "square.stack.3d.up"
        case .togglePin: "pin"
        case .delete: "trash"
        case .switchToSnippets: "text.badge.star"
        }
    }

    /// The keycap shown in the palette row — same glyphs
    /// `OverlayController+Keyboard.swift` handles for this command.
    var keycap: String {
        switch self {
        case .pastePlain: "⇧↩"
        case .preview: "Space"
        case .edit: "⌘E"
        case .addToStack: "⌘↩"
        case .togglePin: "⌘P"
        case .delete: "⌘⌫"
        case .switchToSnippets: "⌘/"
        }
    }

    /// `isPinned` only changes `.togglePin`'s title; every other case ignores it.
    func title(isPinned: Bool) -> String {
        switch self {
        case .pastePlain: String(localized: "Paste as Plain Text", bundle: .module)
        case .preview: String(localized: "Preview", bundle: .module)
        case .edit: String(localized: "Edit", bundle: .module)
        case .addToStack: String(localized: "Add to Stack", bundle: .module)
        case .togglePin:
            if isPinned {
                String(localized: "Unpin", bundle: .module)
            } else {
                String(localized: "Pin", bundle: .module)
            }
        case .delete: String(localized: "Delete", bundle: .module)
        case .switchToSnippets: String(localized: "Switch to Snippets", bundle: .module)
        }
    }

    /// Whether this command applies to the current selection — only `.edit`
    /// has a content requirement (mirrors `DrawerViewModel.beginEdit`'s guard).
    func isApplicable(to selectedItem: ClipItem?) -> Bool {
        guard self == .edit else { return true }
        guard let selectedItem else { return false }
        return selectedItem.kind == .text || selectedItem.kind == .link
    }

    func run(on viewModel: DrawerViewModel) {
        switch self {
        case .pastePlain: viewModel.selectCurrent(mode: .plainText)
        case .preview: viewModel.togglePreview()
        case .edit: viewModel.beginEdit()
        case .addToStack: viewModel.addSelectedToStack()
        case .togglePin: viewModel.togglePinSelected()
        case .delete: viewModel.deleteSelected()
        case .switchToSnippets: viewModel.toggleMode()
        }
    }
}

/// One row in the drawer's ⌘K palette: either a content `ClipAction` or a
/// `DrawerCommand` — the two vocabularies `filteredPaletteActions` merges so
/// the palette can list "everything you can do to the selection" in one list.
enum DrawerPaletteEntry: Identifiable, Hashable {
    case clip(ClipAction)
    case command(DrawerCommand)
    /// The selection's link is still gated behind Cloudflare Access — see
    /// `DrawerViewModel.gatedAccessHostForSelection`.
    case signInToAccess(CloudflareAccessHost)

    var id: String {
        switch self {
        case let .clip(action): "clip-\(action.id)"
        case let .command(command): "command-\(command.rawValue)"
        case let .signInToAccess(host): "sign-in-\(host.origin)"
        }
    }

    var systemImage: String {
        switch self {
        case let .clip(action): action.systemImage
        case let .command(command): command.systemImage
        case .signInToAccess: "lock.shield"
        }
    }

    /// The palette-row keycap hint; `nil` for clip actions (no
    /// positional-shortcut convention, see `CommandPaletteItem.hint`) and for
    /// the sign-in action, which has no shortcut of its own.
    var hint: String? {
        switch self {
        case .clip, .signInToAccess: nil
        case let .command(command): command.keycap
        }
    }

    func label(isPinned: Bool) -> String {
        switch self {
        case let .clip(action): action.label
        case let .command(command): command.title(isPinned: isPinned)
        case let .signInToAccess(host):
            String(localized: "Sign in to \(host.host) (Cloudflare Access)", bundle: .module)
        }
    }
}

public extension DrawerViewModel {
    /// Clip actions and drawer commands for the current selection, filtered
    /// by a case-insensitive fuzzy subsequence of the label; empty query
    /// shows them all. A gated link's sign-in action comes first — it's the
    /// one thing standing between the user and the card actually working —
    /// then clip actions (content transforms), then commands (keyboard
    /// shortcuts); the fuzzy match is identical to what `ClipAction`
    /// filtering did before commands joined the list.
    internal var filteredPaletteActions: [DrawerPaletteEntry] {
        let signInEntries = self.gatedAccessHostForSelection.map { [DrawerPaletteEntry.signInToAccess($0)] } ?? []
        let clipEntries = self.applicableActions.map(DrawerPaletteEntry.clip)
        let commandEntries = DrawerCommand.allCases
            .filter { $0.isApplicable(to: self.selectedItem) }
            .map(DrawerPaletteEntry.command)
        let all = signInEntries + clipEntries + commandEntries
        let needle = self.paletteQuery.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return all }
        let isPinned = self.selectedItem?.isPinned ?? false
        // Subsequence "fuzzy" match on the label.
        return all.filter { entry in
            var remaining = Substring(needle)
            for char in entry.label(isPinned: isPinned).lowercased() where char == remaining.first {
                remaining = remaining.dropFirst()
                if remaining.isEmpty {
                    return true
                }
            }
            return remaining.isEmpty
        }
    }

    /// The Cloudflare Access host the selected item's link is still gated
    /// behind, if any. `linkTitle == ""` is the failed-fetch sentinel
    /// (`ClipItem.swift`) — only then is the URL worth checking against the
    /// recorded host list, since a link that was never fetched
    /// (`linkTitle == nil`) hasn't necessarily hit a challenge at all.
    private var gatedAccessHostForSelection: CloudflareAccessHost? {
        guard let item = self.selectedItem, item.kind == .link, item.linkTitle == "",
              let preview = item.previewText,
              let url = URL(string: preview.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        return CloudflareAccessHost.gatedHost(for: url, in: Defaults[.cloudflareAccessHosts])
    }

    func togglePalette() {
        guard self.mode == .history else { return }
        if self.isPaletteOpen {
            self.closePalette()
        } else {
            guard !self.selectedItems.isEmpty else { return }
            self.paletteQuery = ""
            self.paletteIndex = 0
            self.isPaletteOpen = true
        }
    }

    func closePalette() {
        self.isPaletteOpen = false
    }

    func movePaletteSelection(_ delta: Int) {
        let count = self.filteredPaletteActions.count
        guard count > 0 else { return }
        self.paletteIndex = min(max(self.paletteIndex + delta, 0), count - 1)
    }

    func runPaletteAction(at index: Int? = nil) {
        let entries = self.filteredPaletteActions
        let chosen = index ?? self.paletteIndex
        guard entries.indices.contains(chosen) else { return }
        self.closePalette()
        switch entries[chosen] {
        case let .clip(action): self.runAction(action)
        case let .command(command): command.run(on: self)
        case let .signInToAccess(host): self.onSignInToAccess(host)
        }
    }
}
