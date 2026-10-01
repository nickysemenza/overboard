public struct EnrichmentSettings: Sendable, Equatable {
    public var ocrEnabled: Bool
    public var labelingEnabled: Bool
    public var richLinkPreviews: Bool {
        get { false }
        set { _ = newValue }
    }

    public init(ocrEnabled: Bool = true, labelingEnabled: Bool = true) {
        self.ocrEnabled = ocrEnabled
        self.labelingEnabled = labelingEnabled
    }

    public init(richLinkPreviews _: Bool) {
        self.init()
    }
}
