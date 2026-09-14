import OverboardCore
import OverboardMac
import SwiftUI

// MARK: - Per-kind card content

extension ItemCardView {
    @ViewBuilder
    var content: some View {
        switch self.item.kind {
        case .text:
            if self.item.isSecret {
                VStack(spacing: 8) {
                    Image(systemName: "lock.fill")
                        .font(.title)
                        .foregroundStyle(.orange)
                    Text(self.item.previewText ?? "Secret")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("Auto-expires soon")
                        .font(.caption2)
                        .contrastAwareForeground(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let miniCode {
                // Mini syntax-highlighted code straight on the card.
                CodeTextView(attributed: miniCode, selectable: false)
                    .allowsHitTesting(false)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    if let title = item.aiTitle {
                        Text(title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Text(self.item.previewText ?? "")
                        .font(.callout)
                        .lineLimit(self.textPreviewLineLimit)
                    if let summary = item.aiSummary {
                        Spacer(minLength: 0)
                        HStack(alignment: .top, spacing: 4) {
                            Image(systemName: "sparkles")
                                .font(.caption2)
                                .contrastAwareForeground(.tertiary)
                            Text(summary)
                                .font(.caption)
                                .italic()
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                        }
                    }
                }
                .padding(10)
            }
        case .link:
            self.linkContent
        case .image:
            if let thumbnail {
                // Color.clear.overlay + clipped is the canonical
                // non-bleeding aspect-fill: the image can never propose its
                // own size to the layout.
                Color.clear
                    .overlay {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .scaledToFill()
                    }
                    .clipped()
                    .overlay(alignment: .bottom) {
                        // Dimensions now live in the card footer alongside the
                        // relative copy time; only the AI caption stays here.
                        if let title = item.aiTitle {
                            Text(title)
                                .font(.caption2.weight(.medium))
                                .lineLimit(1)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.ultraThinMaterial)
                        }
                    }
            } else {
                self.placeholder("photo")
            }
        case .file:
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "doc.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text(self.item.previewText ?? "")
                    .font(.callout)
                    .lineLimit(4)
            }
            .padding(10)
        case .color:
            if let swatch {
                VStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: swatch))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(.primary.opacity(0.15), lineWidth: 1)
                        }
                    Text(Self.hexString(for: swatch))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                .padding(10)
            } else {
                self.placeholder("paintpalette.fill")
            }
        }
    }

    /// Rich link card, iMessage-preview style: favicon + fetched title headline,
    /// an optional og:image thumbnail, then the URL. Falls back gracefully when
    /// metadata hasn't landed (or the fetch found nothing): the host becomes the
    /// headline and the link SF symbol stands in for a missing favicon. The
    /// host also renders in the footer via `metadataFooter`.
    private var linkContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                self.linkFavicon
                Text(self.resolvedLinkTitle)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(self.hasLinkTitle ? Color.accentColor : .primary)
                    .lineLimit(2)
            }
            if let preview = self.linkPreviewImage {
                Color.clear
                    .overlay {
                        Image(nsImage: preview)
                            .resizable()
                            .scaledToFill()
                    }
                    .frame(height: 74)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            if self.gatedAccessHost != nil {
                self.accessWarning
            } else if let description = item.linkDescription, !description.isEmpty {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(self.linkPreviewImage != nil ? 1 : 3)
            }
            Spacer(minLength: 0)
            Text(self.item.previewText ?? "")
                .font(.caption2)
                .contrastAwareForeground(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color.accentColor.opacity(0.7))
                .frame(width: 3)
        }
    }

    /// 16×16 favicon from fetched bytes, falling back to the link SF symbol.
    @ViewBuilder
    private var linkFavicon: some View {
        if let favicon = self.faviconImage {
            Image(nsImage: favicon)
                .resizable()
                .interpolation(.high)
                .frame(width: 16, height: 16)
        } else {
            Image(systemName: "link")
                .font(.caption)
                .foregroundStyle(Color.accentColor)
                .frame(width: 16, height: 16)
        }
    }

    /// Non-empty fetched title (empty string is the failed-fetch sentinel).
    private var hasLinkTitle: Bool {
        (self.item.linkTitle?.isEmpty == false)
    }

    /// The headline text: the fetched title when present, else the host.
    private var resolvedLinkTitle: String {
        if let title = item.linkTitle, !title.isEmpty {
            return title
        }
        return self.linkHost ?? "Link"
    }

    private var linkHost: String? {
        ClipItem.linkHost(fromPreview: self.item.previewText)
    }

    /// The Cloudflare Access host this link's fetch failed against, when
    /// that's why it has no title: `linkTitle == ""` is the failed-fetch
    /// sentinel (`ClipItem.swift`), and only then is the URL worth checking
    /// against the recorded host list — a link that was never fetched
    /// (`linkTitle == nil`) hasn't necessarily hit a challenge at all.
    /// `internal`: read from `accessibilityCardLabel` in ItemCardView.swift.
    var gatedAccessHost: CloudflareAccessHost? {
        guard self.item.linkTitle == "",
              let preview = item.previewText,
              let url = URL(string: preview.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        return CloudflareAccessHost.gatedHost(for: url, in: self.cloudflareAccessHosts)
    }

    /// The caption shown in place of a description for a link still gated
    /// behind Cloudflare Access — the one thing the card can say without
    /// making the user go find Settings first.
    private var accessWarning: some View {
        HStack(spacing: 4) {
            Image(systemName: "lock.shield")
            Text("Sign in required · Cloudflare Access")
        }
        .font(.caption)
        .foregroundStyle(.orange)
        .lineLimit(1)
        .help("Behind Cloudflare Access — sign in from ⌘K or Settings › General")
    }

    /// Every card's footer: the relative copy time and use count, leading,
    /// then compact metadata (char/line counts, file size, image
    /// dimensions…) trailing when there is any. The absolute time is a
    /// tooltip and lives in the accessibility label instead of cluttering
    /// this row.
    var footer: some View {
        let now = self.referenceDate ?? .now
        let when = TimestampFormatter.relative(self.item.lastUsedAt, now: now, unitsStyle: .abbreviated)
        return VStack(spacing: 0) {
            Divider().opacity(0.25)
            HStack(spacing: 6) {
                // Time + use count, as one unit: this is what the frecency
                // order actually ranks on (ClipStore.frecencyOrderSQL), so
                // unlike metadataFooter it never yields to ViewThatFits below.
                HStack(spacing: 3) {
                    Text(when)
                    if self.rankedAboveNewer {
                        Image(systemName: "arrow.up")
                            .foregroundStyle(Color.accentColor)
                    }
                    // Always shown, not just when reused: a lone "×1" costs
                    // nothing to read and makes the reused cards' "×4" legible
                    // by contrast instead of only appearing once it matters.
                    Text("×\(self.item.useCount)")
                }
                .fixedSize()
                if let meta = self.item.metadataFooter {
                    Spacer(minLength: 0)
                    // The time+count segment never yields; metadata degrades a
                    // segment at a time ("1,240 characters · 32 lines" →
                    // "1,240 characters") before it resorts to truncating
                    // mid-word.
                    ViewThatFits(in: .horizontal) {
                        Text(meta).fixedSize()
                        if let lead = meta.components(separatedBy: ClipItem.metadataSeparator).first,
                           lead != meta
                        {
                            Text(lead).fixedSize()
                        }
                        Text(meta).lineLimit(1).truncationMode(.tail)
                    }
                }
            }
            .font(.caption2.monospacedDigit())
            .contrastAwareForeground(.tertiary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .help(self.footerHelpText)
        }
    }

    /// "Copied once" / "Copied 4 times" — the footer tooltip's count clause,
    /// and (lowercased) the accessibility label's in `ItemCardView.swift`.
    var copiedCountPhrase: String {
        self.item.useCount == 1
            ? String(localized: "Copied once", bundle: .module)
            : String(localized: "Copied \(self.item.useCount) times", bundle: .module)
    }

    /// Absolute copy time, how many times it's been copied, and — when the
    /// frecency order lifted it above a newer item — a note saying so, so
    /// hovering a card that looks out of place explains itself.
    private var footerHelpText: String {
        var parts = [TimestampFormatter.absolute(self.item.lastUsedAt), self.copiedCountPhrase]
        if self.rankedAboveNewer {
            parts.append(String(localized: "ranked above newer items", bundle: .module))
        }
        return parts.joined(separator: ClipItem.metadataSeparator)
    }

    /// Raw text yields lines to the title and summary when they're present.
    /// One line is reserved for the metadata footer row (see `footer`).
    private var textPreviewLineLimit: Int {
        let base = switch (self.item.aiTitle != nil, self.item.aiSummary != nil) {
        case (false, false): 6
        case (true, false): 5
        case (false, true): 3
        case (true, true): 2
        }
        // The card grows with Dynamic Type but not as fast as the type does, so
        // the line budget shrinks to keep the preview inside the content slot.
        return max(1, Int((Double(base) * CardMetrics.height / self.cardHeight).rounded(.down)))
    }

    private func placeholder(_ systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.largeTitle)
            .contrastAwareForeground(.quaternary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
