import OverboardCore
import SwiftUI

/// Plain debug window listing history. Lets us verify the capture pipeline
/// before the overlay drawer exists; superseded by the drawer for daily use.
public struct HistoryDebugView: View {
    private let store: ClipStore
    @State private var items: [ClipItem] = []

    public init(store: ClipStore) {
        self.store = store
    }

    public var body: some View {
        List(self.items) { item in
            HStack(spacing: 10) {
                Image(systemName: self.icon(for: item.kind))
                    .frame(width: 20)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.previewText ?? "—")
                        .lineLimit(2)
                    Text(self.subtitle(for: item))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
        }
        .overlay {
            if self.items.isEmpty {
                ContentUnavailableView(
                    "Nothing captured yet",
                    systemImage: "sailboat",
                    description: Text("Copy something and it'll wash up here.")
                )
            }
        }
        .task {
            do {
                for try await items in self.store.observeRecent(limit: 200) {
                    self.items = items
                }
            } catch {
                // Observation only fails if the database is gone; nothing to show.
            }
        }
    }

    private func icon(for kind: ItemKind) -> String {
        switch kind {
        case .text: "text.alignleft"
        case .link: "link"
        case .image: "photo"
        case .file: "doc"
        case .color: "paintpalette"
        }
    }

    private func subtitle(for item: ClipItem) -> String {
        var parts: [String] = []
        if let app = item.sourceAppName { parts.append(app) }
        parts.append(item.lastUsedAt.formatted(date: .abbreviated, time: .shortened))
        if item.useCount > 1 { parts.append("×\(item.useCount)") }
        return parts.joined(separator: " · ")
    }
}
