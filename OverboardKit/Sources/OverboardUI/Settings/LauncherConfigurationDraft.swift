import Foundation
import OverboardCore

nonisolated enum LauncherConfigurationKind: String {
    case aliases, quicklinks
}

nonisolated struct LauncherConfigurationEntry: Identifiable, Equatable {
    let line: Int
    var keyword: String
    var name: String
    var destination: String
    var id: Int {
        self.line
    }

    func serialized(for kind: LauncherConfigurationKind) -> String {
        let value = kind == .quicklinks && !self.name.isEmpty ? "\(self.name) | \(self.destination)" : self.destination
        return "\(self.keyword) = \(value)"
    }
}

nonisolated struct LauncherConfigurationIssue: Identifiable, Equatable {
    let line: Int
    let message: String
    var id: Int {
        self.line
    }
}

nonisolated struct LauncherConfigurationDraft {
    let text: String
    let kind: LauncherConfigurationKind

    var entries: [LauncherConfigurationEntry] {
        self.text.components(separatedBy: .newlines).enumerated().compactMap { index, line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let separator = trimmed.firstIndex(of: "=") else {
                return nil
            }
            let keyword = String(trimmed[..<separator]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            if self.kind == .quicklinks, let pipe = value.firstIndex(of: "|") {
                return .init(
                    line: index, keyword: keyword,
                    name: String(value[..<pipe]).trimmingCharacters(in: .whitespaces),
                    destination: String(value[value.index(after: pipe)...]).trimmingCharacters(in: .whitespaces)
                )
            }
            return .init(line: index, keyword: keyword, name: "", destination: value)
        }
    }

    var issues: [LauncherConfigurationIssue] {
        let entries = Dictionary(uniqueKeysWithValues: self.entries.map { ($0.line, $0) })
        var seen: Set<String> = []
        return self.text.components(separatedBy: .newlines).enumerated().compactMap { index, line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
            guard let entry = entries[index] else {
                return .init(line: index, message: "Use keyword = destination.")
            }
            guard !entry.keyword.isEmpty, !entry.keyword.contains(where: \.isWhitespace) else {
                return .init(line: index, message: "Keywords must be a single nonempty word.")
            }
            guard seen.insert(AppMatcher.fold(entry.keyword)).inserted else {
                return .init(line: index, message: "This keyword is already used above.")
            }
            guard !entry.destination.isEmpty else {
                return .init(line: index, message: "A destination is required.")
            }
            if self.kind == .quicklinks,
               let message = Quicklink.validationIssues(for: entry.destination).first
            {
                return .init(line: index, message: message)
            }
            return nil
        }
    }

    func replacing(_ entry: LauncherConfigurationEntry) -> String {
        var lines = self.text.components(separatedBy: .newlines)
        guard lines.indices.contains(entry.line) else { return self.text }
        lines[entry.line] = entry.serialized(for: self.kind)
        return lines.joined(separator: "\n")
    }

    func removing(line: Int) -> String {
        var lines = self.text.components(separatedBy: .newlines)
        guard lines.indices.contains(line) else { return self.text }
        lines.remove(at: line)
        return lines.joined(separator: "\n")
    }
}
