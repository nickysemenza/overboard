import Foundation

/// Expands `{placeholder}` tokens in snippet bodies at paste time.
/// Supported: `{date}`, `{time}`, `{datetime}`, `{uuid}`, `{clipboard}`.
public enum SnippetTemplate {
    public static func expand(
        _ body: String,
        now: Date = Date(),
        clipboard: String? = nil,
        uuid: () -> String = { UUID().uuidString }
    ) -> String {
        var result = body
        if result.contains("{date}") {
            let date = now.formatted(date: .abbreviated, time: .omitted)
            result = result.replacingOccurrences(of: "{date}", with: date)
        }
        if result.contains("{time}") {
            let time = now.formatted(date: .omitted, time: .shortened)
            result = result.replacingOccurrences(of: "{time}", with: time)
        }
        if result.contains("{datetime}") {
            let datetime = now.formatted(date: .abbreviated, time: .shortened)
            result = result.replacingOccurrences(of: "{datetime}", with: datetime)
        }
        while result.contains("{uuid}") {
            // Each occurrence gets a fresh UUID.
            if let range = result.range(of: "{uuid}") {
                result = result.replacingCharacters(in: range, with: uuid())
            }
        }
        if result.contains("{clipboard}") {
            result = result.replacingOccurrences(of: "{clipboard}", with: clipboard ?? "")
        }
        return result
    }
}
