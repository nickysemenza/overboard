import Foundation

public struct ClipEnrichmentPipeline: Sendable {
    public typealias Settings = EnrichmentSettings

    public typealias SettingsProvider = @Sendable () -> Settings
    /// PNG bytes in, recognized text out (nil when nothing was read).
    public typealias TextRecognizer = @Sendable (Data) async -> String?
    /// Legacy adapter accepted for compatibility; never invoked.
    public typealias LinkFetcher = @Sendable (URL) async -> LinkMetadata?
    /// LLM labeling; nil when unavailable or the request failed.
    public typealias TextEnricher = @Sendable (String) async -> ClipEnricher.Enrichment?
    /// LLM image labeling (macOS 27+); PNG bytes in, plus the OCR text
    /// already recognized for this item (nil when OCR found nothing). Nil
    /// when unavailable or the request failed.
    public typealias ImageEnricher = @Sendable (Data, String?) async -> ClipEnricher.Enrichment?

    /// Below this many characters, an LLM title says nothing the preview
    /// doesn't already show, so labeling isn't attempted.
    public static let labelingMinimumLength = 80

    private let store: ClipStore
    private let settings: SettingsProvider
    private let recognizeText: TextRecognizer
    private let enrichText: TextEnricher
    private let enrichImage: ImageEnricher?

    public init(
        store: ClipStore,
        settings: @escaping SettingsProvider = { Settings() },
        recognizeText: @escaping TextRecognizer = { await ImageTextRecognizer.recognizeText(in: $0) },
        fetchLink _: @escaping LinkFetcher = { _ in nil },
        enrichText: @escaping TextEnricher = { text in
            guard ClipEnricher.isAvailable else { return nil }
            return try? await ClipEnricher.enrich(text: text)
        },
        enrichImage: ImageEnricher? = nil
    ) {
        self.store = store
        self.settings = settings
        self.recognizeText = recognizeText
        self.enrichText = enrichText
        self.enrichImage = enrichImage
    }

    /// Enriches one just-ingested item in place.
    /// @concurrent: OCR is sync CPU work and must not land on the main actor.
    /// Plain `nonisolated async` would inherit the caller's actor under
    /// NonisolatedNonsendingByDefault, so the hop off main is made explicit.
    @concurrent
    public func enrich(item: ClipItem, snapshot: PasteboardSnapshot) async {
        // Only fresh, non-secret items; bumped duplicates are already enriched.
        guard !Task.isCancelled, item.useCount == 1, !item.isSecret,
              ClipSensitivity.label(for: snapshot.reps) == nil,
              await (try? self.store.isEnrichmentEligible(itemID: item.id)) == true,
              !Task.isCancelled
        else { return }
        let settings = self.settings()

        var textForLabeling: String?

        if item.kind == .image,
           let png = snapshot.reps.first(where: { $0.uti == WellKnownUTI.png })?.data
        {
            guard settings.ocrEnabled else { return }
            // Attach even empty results so textless images are marked as
            // OCR-attempted (searchText '' vs NULL).
            let recognized = await self.recognizeText(png) ?? ""
            guard !Task.isCancelled,
                  await (try? self.store.attachRecognizedText(itemID: item.id, text: recognized)) == true,
                  !Task.isCancelled
            else { return }
            guard settings.labelingEnabled else { return }

            if let enrichImage = self.enrichImage {
                // macOS 27: the vision-capable model labels the image
                // directly, with any OCR text passed along as a hint. Unlike
                // the text-only path below, this runs even when OCR found
                // nothing — pixels alone are enough for a title.
                guard !Task.isCancelled,
                      let enrichment = await enrichImage(png, recognized.isEmpty ? nil : recognized),
                      !Task.isCancelled
                else { return }
                let summary = recognized.count >= ClipEnricher.summaryWorthwhileLength ? enrichment.summary : nil
                try? await self.store.attachEnrichment(
                    itemID: item.id,
                    title: enrichment.title,
                    category: enrichment.category,
                    summary: summary
                )
                return
            }

            textForLabeling = recognized.isEmpty ? nil : recognized
        } else if item.kind == .text {
            textForLabeling = snapshot.reps
                .first { $0.uti == WellKnownUTI.plainText }
                .flatMap { String(data: $0.data, encoding: .utf8) }
        }

        guard !Task.isCancelled, settings.labelingEnabled, let text = textForLabeling,
              text.count >= Self.labelingMinimumLength,
              ClipSensitivity.label(for: text) == nil,
              let enrichment = await self.enrichText(text), !Task.isCancelled
        else { return }

        // Short clips show fully on the card; a summary only earns its
        // space once the preview truncates.
        let summary = text.count >= ClipEnricher.summaryWorthwhileLength
            ? enrichment.summary : nil
        try? await self.store.attachEnrichment(
            itemID: item.id,
            title: enrichment.title,
            category: enrichment.category,
            summary: summary
        )
    }

    public func fetchLinkMetadata(for _: ClipItem) async {}
}
