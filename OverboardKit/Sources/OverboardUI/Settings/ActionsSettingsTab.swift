import OverboardCore
import SwiftUI

/// Read-only matrix of which actions apply to which content kinds, rendered
/// straight from `ClipAction.info` so it can't drift from real behavior.
struct ActionsSettingsTab: View {
    private let kinds = ItemKind.allCases
    private let kindColumnWidth: CGFloat = 44

    var body: some View {
        Form {
            Section {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 10) {
                    GridRow {
                        Color.clear.frame(height: 0)
                            .gridColumnAlignment(.leading)
                        ForEach(self.kinds, id: \.self) { kind in
                            VStack(spacing: 2) {
                                Image(systemName: kind.symbolName)
                                Text(kind.displayName)
                                    .font(.caption2)
                            }
                            .foregroundStyle(.secondary)
                            .frame(width: self.kindColumnWidth)
                            .gridColumnAlignment(.center)
                        }
                        Text("When")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    Divider()
                    ForEach(ClipAction.allCases) { action in
                        let info = action.info
                        GridRow {
                            VStack(alignment: .leading, spacing: 1) {
                                Label(action.label, systemImage: action.systemImage)
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                                if let condition = info.condition {
                                    Text(condition)
                                        .font(.caption2)
                                        .contrastAwareForeground(.tertiary)
                                        .padding(.leading, 22)
                                }
                            }
                            .gridColumnAlignment(.leading)
                            ForEach(self.kinds, id: \.self) { kind in
                                self.cell(applies: info.kinds.isEmpty || info.kinds.contains(kind))
                                    .frame(width: self.kindColumnWidth)
                                    .gridColumnAlignment(.center)
                            }
                            Text(Self.selectionLabel(info.selection))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("Applies to")
            } footer: {
                Text(
                    """
                    A checkmark means the action can apply to that content kind; “When” is how \
                    many items must be selected (single / 2+ / any). Greyed conditions are extra \
                    checks run against the clip's contents when you open the menu.
                    """
                )
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func cell(applies: Bool) -> some View {
        if applies {
            Image(systemName: "checkmark")
                .foregroundStyle(.green)
        } else {
            Text("–")
                .contrastAwareForeground(.quaternary)
        }
    }

    private static func selectionLabel(_ selection: ClipActionInfo.Selection) -> String {
        switch selection {
        case .single: "single"
        case .multi: "2+"
        case .any: "any"
        }
    }
}

#if DEBUG
    #Preview("Actions") {
        ActionsSettingsTab()
            .frame(width: 520, height: 580)
    }
#endif
