import Foundation

/// Post-ingest enrichment for a freshly captured clip: OCR for images, rich
/// metadata for links, then an on-device LLM title + category + summary for
/// anything with enough text. Runs off the ingest loop; every step is
/// best-effort and failures are swallowed — a clip is perfectly usable
/// unenriched.
///
/// The three outside-world steps (OCR, link fetch, LLM labeling) and the one
/// user setting (rich link previews) that gates the fetch are injected, so the
/// ordering and the guards — which is what actually goes wrong here — can be
/// tested without a network, Apple Intelligence, or the Vision framework.
public struct ClipEnrichmentPipeline: Sendable {
    /// User settings this pipeline consults. Read fresh on every run through
    /// `settings`, so toggling it in Settings takes effect immediately.
    public struct Settings: Sendable {
        /// Fetch page title/description/favicon/preview for copied links.
        public var richLinkPreviews: Bool

        public init(richLinkPreviews: Bool) {
            self.richLinkPreviews = richLinkPreviews
        }
    }

    public typealias SettingsProvider = @Sendable () -> Settings
    /// PNG bytes in, recognized text out (nil when nothing was read).
    public typealias TextRecognizer = @Sendable (Data) async -> String?
    /// One link fetch; nil on any failure.
    public typealias LinkFetcher = @Sendable (URL) async -> LinkMetadata?
    /// LLM labeling; nil when unavailable or the request failed.
    public typealias TextEnricher = @Sendable (String) async -> ClipEnricher.Enrichment?

    /// Below this many characters, an LLM title says nothing the preview
    /// doesn't already show, so labeling isn't attempted.
    public static let labelingMinimumLength = 80

    /// One long-lived link fetcher, reused for every preview. A per-fetch
    /// `LinkMetadataFetcher()` builds a delegate-backed `URLSession` that retains
    /// itself (and its `RedirectGuard`) until invalidated — which a value type
    /// can't do in `deinit` — so constructing one per link leaked a session each
    /// time. Sharing one session (safe for concurrent tasks) removes the leak.
    /// This default has no `accessToken` provider (`OverboardCore` doesn't
    /// know about `cloudflared`); the app injects its own, equally long-lived
    /// `LinkMetadataFetcher` — with the Access token provider wired to
    /// `CloudflaredAccessTokens` — via `fetchLink` in `AppServices`.
    public static let linkFetcher = LinkMetadataFetcher()

    private let store: ClipStore
    private let settings: SettingsProvider
    private let recognizeText: TextRecognizer
    private let fetchLink: LinkFetcher
    private let enrichText: TextEnricher

    public init(
        store: ClipStore,
        settings: @escaping SettingsProvider,
        recognizeText: @escaping TextRecognizer = { await ImageTextRecognizer.recognizeText(in: $0) },
        fetchLink: @escaping LinkFetcher = { await ClipEnrichmentPipeline.linkFetcher.fetch($0) },
        enrichText: @escaping TextEnricher = { text in
            guard ClipEnricher.isAvailable else { return nil }
            return try? await ClipEnricher.enrich(text: text)
        }
    ) {
        self.store = store
        self.settings = settings
        self.recognizeText = recognizeText
        self.fetchLink = fetchLink
        self.enrichText = enrichText
    }

    /// Enriches one just-ingested item in place.
    /// @concurrent: OCR is sync CPU work and must not land on the main actor.
    /// Plain `nonisolated async` would inherit the caller's actor under
    /// NonisolatedNonsendingByDefault, so the hop off main is made explicit.
    @concurrent
    public func enrich(item: ClipItem, snapshot: PasteboardSnapshot) async {
        // Only fresh, non-secret items; bumped duplicates are already enriched.
        guard item.useCount == 1, !item.isSecret else { return }

        var textForLabeling: String?

        if item.kind == .image,
           let png = snapshot.reps.first(where: { $0.uti == WellKnownUTI.png })?.data
        {
            // Attach even empty results so textless images are marked as
            // OCR-attempted (searchText '' vs NULL).
            let recognized = await self.recognizeText(png) ?? ""
            try? await self.store.attachRecognizedText(itemID: item.id, text: recognized)
            textForLabeling = recognized.isEmpty ? nil : recognized
        } else if item.kind == .text {
            textForLabeling = snapshot.reps
                .first { $0.uti == WellKnownUTI.plainText }
                .flatMap { String(data: $0.data, encoding: .utf8) }
        } else if item.kind == .link, self.settings().richLinkPreviews {
            await self.fetchLinkMetadata(for: item)
        }

        guard let text = textForLabeling,
              text.count >= Self.labelingMinimumLength,
              let enrichment = await self.enrichText(text)
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

    /// Fetches rich-link metadata for one `.link` item and attaches it (or the
    /// empty-title sentinel on failure, so it's marked attempted and won't be
    /// retried by backfill). Guards on fetchability; nil-URL / unfetchable links
    /// still get the sentinel. Shared by post-ingest enrichment and backfill.
    @concurrent
    public func fetchLinkMetadata(for item: ClipItem) async {
        guard let preview = item.previewText,
              let url = URL(string: preview.trimmingCharacters(in: .whitespacesAndNewlines)),
              LinkMetadataFetcher.isFetchable(url)
        else {
            // Not fetchable → record the sentinel so we don't re-check every pass.
            try? await self.store.attachLinkMetadata(
                itemID: item.id, title: "", description: nil, faviconPNG: nil, previewImagePNG: nil
            )
            return
        }
        let metadata = await self.fetchLink(url)
        try? await self.store.attachLinkMetadata(
            itemID: item.id,
            title: metadata?.title ?? "",
            description: metadata?.description,
            faviconPNG: metadata?.faviconPNG,
            previewImagePNG: metadata?.previewImagePNG
        )
    }

    /// Re-fetches metadata for every `.link` item under `origin`, called from
    /// Settings right after a Cloudflare Access sign-in: those links were
    /// healed (metadata cleared) while the host was still gated, and the
    /// startup backfill already ran for this launch and won't run again until
    /// next launch, so nothing would otherwise pick them back up.
    public func refetchLinkMetadata(origin: String) async {
        guard let healed = try? await self.store.resetLinkMetadata(forOrigin: origin) else { return }
        for item in healed {
            await self.fetchLinkMetadata(for: item)
            // Same politeness pause as the startup backfill (`AppServices+Capture.swift`'s
            // `linkBackfillJob`) — several links under one freshly-signed-in
            // host shouldn't hit it in a burst.
            try? await Task.sleep(for: .seconds(1))
        }
    }
}
