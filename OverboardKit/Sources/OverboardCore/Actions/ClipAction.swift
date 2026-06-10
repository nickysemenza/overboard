import Foundation

/// What executing an action should do. Actions themselves are pure — the app
/// layer owns all side effects (opening URLs, writing files, pasting).
public enum ActionEffect: Sendable, Equatable {
    /// Paste the text into the target app (same path as committing a clip).
    case pasteText(String)
    /// Put text on the clipboard and flash a HUD.
    case copyText(String, hud: String)
    case openURLs([URL])
    case revealFiles([URL])
    /// Fetch the item's image payload and save it to ~/Downloads.
    case saveImage(itemID: String)
    case addToStack([ClipItem])
    /// HUD-only outcome (counts, errors like "not valid JSON").
    case showMessage(String)
}

/// Everything an action needs to know about one selected item, prefetched by
/// the app layer so actions stay synchronous and pure.
public struct ActionInput: Sendable {
    public let item: ClipItem
    public let plainText: String?
    public let fileURLs: [URL]

    public init(item: ClipItem, plainText: String?, fileURLs: [URL]) {
        self.item = item
        self.plainText = plainText
        self.fileURLs = fileURLs
    }
}

public enum ClipAction: String, CaseIterable, Identifiable, Sendable {
    // Single item
    case openLink
    case openAllLinks
    case copyAsMarkdownLink
    case revealInFinder
    case saveImageToDownloads
    case prettyPrintJSON
    case decodeBase64
    case wordCount
    /// Single or multi
    case sumNumbers
    // Multi
    case pasteAllJoined
    case addAllToStack

    public var id: String {
        self.rawValue
    }

    public var label: String {
        switch self {
        case .openLink: "Open Link in Browser"
        case .openAllLinks: "Open All Links"
        case .copyAsMarkdownLink: "Copy as Markdown Link"
        case .revealInFinder: "Reveal in Finder"
        case .saveImageToDownloads: "Save Image to Downloads"
        case .prettyPrintJSON: "Pretty-Print JSON"
        case .decodeBase64: "Decode Base64"
        case .wordCount: "Word Count"
        case .sumNumbers: "Sum the Numbers"
        case .pasteAllJoined: "Paste All (joined)"
        case .addAllToStack: "Add All to Stack"
        }
    }

    public var systemImage: String {
        switch self {
        case .openLink, .openAllLinks: "safari"
        case .copyAsMarkdownLink: "text.badge.checkmark"
        case .revealInFinder: "folder"
        case .saveImageToDownloads: "square.and.arrow.down"
        case .prettyPrintJSON: "curlybraces"
        case .decodeBase64: "lock.open"
        case .wordCount: "textformat.123"
        case .sumNumbers: "plus.forwardslash.minus"
        case .pasteAllJoined: "text.append"
        case .addAllToStack: "square.stack.3d.up"
        }
    }

    /// Cheap, synchronous filter on kinds/counts so menus can be built without
    /// touching payloads. `run` revalidates content and reports failures as
    /// `.showMessage`.
    public func isApplicable(to items: [ClipItem]) -> Bool {
        guard let first = items.first else { return false }
        let kinds = Set(items.map(\.kind))
        switch self {
        case .openLink, .copyAsMarkdownLink:
            return items.count == 1 && first.kind == .link
        case .openAllLinks:
            return items.count == 1 && first.kind == .text
        case .revealInFinder:
            return items.count == 1 && first.kind == .file
        case .saveImageToDownloads:
            return items.count == 1 && first.kind == .image
        case .prettyPrintJSON, .decodeBase64, .wordCount:
            return items.count == 1 && first.kind == .text
        case .sumNumbers:
            return kinds.isSubset(of: [.text, .link])
        case .pasteAllJoined:
            return items.count >= 2 && kinds.isSubset(of: [.text, .link])
        case .addAllToStack:
            return items.count >= 2
        }
    }

    public static func applicable(to items: [ClipItem]) -> [ClipAction] {
        allCases.filter { $0.isApplicable(to: items) }
    }

    public func run(_ inputs: [ActionInput]) -> ActionEffect {
        let texts = inputs.compactMap(\.plainText)
        switch self {
        case .openLink:
            guard let text = texts.first,
                  let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines))
            else { return .showMessage("No URL found") }
            return .openURLs([url])

        case .openAllLinks:
            let urls = TextScraps.links(in: texts.first ?? "")
            return urls.isEmpty ? .showMessage("No links found") : .openURLs(urls)

        case .copyAsMarkdownLink:
            guard let input = inputs.first,
                  let text = input.plainText?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let url = URL(string: text)
            else { return .showMessage("No URL found") }
            let title = input.item.aiTitle ?? url.host ?? text
            return .copyText("[\(title)](\(text))", hud: "Markdown link copied")

        case .revealInFinder:
            let urls = inputs.first?.fileURLs ?? []
            return urls.isEmpty ? .showMessage("File no longer available") : .revealFiles(urls)

        case .saveImageToDownloads:
            guard let item = inputs.first?.item else { return .showMessage("No image") }
            return .saveImage(itemID: item.id)

        case .prettyPrintJSON:
            guard let text = texts.first else { return .showMessage("Empty clip") }
            guard let pretty = TextScraps.prettyPrintedJSON(text) else {
                return .showMessage("Not valid JSON")
            }
            return .pasteText(pretty)

        case .decodeBase64:
            guard let text = texts.first,
                  let data = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let decoded = String(data: data, encoding: .utf8)
            else { return .showMessage("Not valid Base64 text") }
            return .pasteText(decoded)

        case .wordCount:
            guard let text = texts.first else { return .showMessage("Empty clip") }
            let words = text.split(whereSeparator: \.isWhitespace).count
            return .showMessage("\(words) words · \(text.count) characters")

        case .sumNumbers:
            let numbers = texts.flatMap(TextScraps.numbers(in:))
            guard numbers.count >= 2 else { return .showMessage("Need at least two numbers") }
            let total = numbers.reduce(0, +)
            let formatted = TextScraps.format(total)
            return .copyText(formatted, hud: "Sum: \(formatted) — copied")

        case .pasteAllJoined:
            guard !texts.isEmpty else { return .showMessage("Nothing to paste") }
            return .pasteText(texts.joined(separator: "\n"))

        case .addAllToStack:
            return .addToStack(inputs.map(\.item))
        }
    }
}
