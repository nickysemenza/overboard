import Defaults
import OverboardCore
import OverboardMac

enum SelectedClipQuicklinks {
    static func available(for item: ClipItem?) -> [Quicklink] {
        guard let item, !item.isSecret, item.kind == .text || item.kind == .link else { return [] }
        return Quicklink.parse(Defaults[.launcherQuicklinks]).filter {
            !$0.keyword.contains(where: \.isWhitespace) && Quicklink.validationIssues(for: $0.template).isEmpty
        }
    }

    static func label(for quicklink: Quicklink) -> String {
        "\(quicklink.name) with Selected Clipboard"
    }
}
