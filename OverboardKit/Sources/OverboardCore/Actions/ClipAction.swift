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
    /// Fetch the item's image payload and open it in Preview.app.
    case openImage(itemID: String)
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

/// Declarative description of when an action applies, used for both filtering
/// (`ClipAction.isApplicable`) and display (the Settings applicability matrix).
public struct ClipActionInfo: Sendable {
    public enum Selection: Sendable {
        case single
        case multi
        case any
    }

    /// Kinds this action accepts. Empty means any kind.
    public let kinds: Set<ItemKind>
    public let selection: Selection
    /// Human-readable requirement beyond kind/count, for display only
    /// (e.g. "looks like JSON", "≥2 numbers"). nil means no content condition.
    public let condition: String?

    public init(kinds: Set<ItemKind>, selection: Selection, condition: String?) {
        self.kinds = kinds
        self.selection = selection
        self.condition = condition
    }
}

public enum ClipAction: String, CaseIterable, Identifiable, Sendable {
    // Single item
    case openLink
    case openAllLinks
    case copyAsMarkdownLink
    case revealInFinder
    case saveImageToDownloads
    case openImageInPreview
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
        case .openImageInPreview: "Open in Preview"
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
        case .openImageInPreview: "photo.on.rectangle"
        case .prettyPrintJSON: "curlybraces"
        case .decodeBase64: "lock.open"
        case .wordCount: "textformat.123"
        case .sumNumbers: "plus.forwardslash.minus"
        case .pasteAllJoined: "text.append"
        case .addAllToStack: "square.stack.3d.up"
        }
    }

    /// The structural rules (which kinds, how many items) plus a display-only
    /// note for any content requirement beyond them. This is the single source
    /// of truth shared by `isApplicable` and the Settings applicability matrix.
    public var info: ClipActionInfo {
        switch self {
        case .openLink, .copyAsMarkdownLink:
            ClipActionInfo(kinds: [.link], selection: .single, condition: nil)
        case .openAllLinks:
            ClipActionInfo(kinds: [.text], selection: .single, condition: "contains a link")
        case .revealInFinder:
            ClipActionInfo(kinds: [.file], selection: .single, condition: nil)
        case .saveImageToDownloads, .openImageInPreview:
            ClipActionInfo(kinds: [.image], selection: .single, condition: nil)
        case .prettyPrintJSON:
            ClipActionInfo(kinds: [.text], selection: .single, condition: "looks like JSON · not secret")
        case .decodeBase64:
            ClipActionInfo(kinds: [.text], selection: .single, condition: "looks like Base64 · not secret")
        case .wordCount:
            ClipActionInfo(kinds: [.text], selection: .single, condition: "not secret")
        case .sumNumbers:
            ClipActionInfo(kinds: [.text, .link], selection: .any, condition: "≥2 numbers")
        case .pasteAllJoined:
            ClipActionInfo(kinds: [.text, .link], selection: .multi, condition: nil)
        case .addAllToStack:
            ClipActionInfo(kinds: [], selection: .multi, condition: nil)
        }
    }

    /// Synchronous filter on kinds, counts, and preview text, so menus only
    /// offer actions that plausibly apply (no "Pretty-Print JSON" on prose).
    /// Structural rules come from `info`; only content/secret heuristics live
    /// here. Previews are truncated at 500 chars, so `run` still revalidates the
    /// full payload and reports failures as `.showMessage`.
    public func isApplicable(to items: [ClipItem]) -> Bool {
        guard let first = items.first else { return false }
        let info = self.info
        switch info.selection {
        case .single: guard items.count == 1 else { return false }
        case .multi: guard items.count >= 2 else { return false }
        case .any: break
        }
        if !info.kinds.isEmpty {
            guard Set(items.map(\.kind)).isSubset(of: info.kinds) else { return false }
        }
        switch self {
        case .openAllLinks:
            return (first.previewText ?? "").lowercased().contains("http")
        case .prettyPrintJSON:
            return !first.isSecret && TextScraps.looksLikeJSON(first.previewText ?? "")
        case .decodeBase64:
            return !first.isSecret && TextScraps.looksLikeBase64(first.previewText ?? "")
        case .wordCount:
            return !first.isSecret
        case .sumNumbers:
            let previews = items.compactMap(\.previewText).joined(separator: " ")
            return TextScraps.numbers(in: previews).count >= 2
        default:
            return true
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

        case .openImageInPreview:
            guard let item = inputs.first?.item else { return .showMessage("No image") }
            return .openImage(itemID: item.id)

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
