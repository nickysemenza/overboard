import OverboardCore

public struct ClipboardBrowserHandoff: Sendable, Equatable {
    public var query: String
    public var selectedItemID: String?
    public var filter: ClipboardFilter

    public init(query: String, selectedItemID: String? = nil, filter: ClipboardFilter = ClipboardFilter()) {
        self.query = query
        self.selectedItemID = selectedItemID
        self.filter = filter
    }
}
