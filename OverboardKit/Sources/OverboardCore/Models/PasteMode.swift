/// How an item should be written back to the pasteboard.
public enum PasteMode: Sendable {
    /// All captured representations (RTF, HTML, images, …).
    case full
    /// Plain text only — strips formatting on paste (⇧↩ in the drawer).
    case plainText
}
