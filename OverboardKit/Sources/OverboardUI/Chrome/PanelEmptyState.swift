import SwiftUI

/// The one "nothing here" treatment. The launcher, the clipboard drawer, the
/// snippets manager, and the emoji picker each grew their own — a native
/// `ContentUnavailableView`, a hand-rolled boat stack, a bare caption — so the
/// same situation read differently on every surface.
struct PanelEmptyState: View {
    /// What sits above the title: an SF Symbol, or the app's bobbing boat for
    /// the "you haven't copied anything yet" case that is Overboard's own.
    enum Mark {
        case symbol(String)
        case boat
    }

    let mark: Mark
    let title: String
    var subtitle: String?

    var body: some View {
        ContentUnavailableView {
            Label {
                Text(self.title)
            } icon: {
                switch self.mark {
                case let .symbol(name): Image(systemName: name)
                case .boat: BobbingBoat()
                }
            }
        } description: {
            if let subtitle {
                Text(subtitle)
            }
        }
    }
}

#if DEBUG
    #Preview("Symbol") {
        PanelEmptyState(
            mark: .symbol("doc.on.clipboard"),
            title: "No results",
            subtitle: "Copy something, or try a different search or filter."
        )
        .frame(width: 420, height: 240)
    }

    #Preview("Boat") {
        PanelEmptyState(
            mark: .boat,
            title: "Nothing captured yet",
            subtitle: "Copy something and it'll wash up here."
        )
        .frame(width: 420, height: 240)
    }

    #Preview("No subtitle") {
        PanelEmptyState(mark: .symbol("face.smiling"), title: "No emoji found")
            .frame(width: 420, height: 240)
    }
#endif
