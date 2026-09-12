---
name: Overboard
description: A compact native macOS launcher with recognizable results and predictable actions.
typography:
  body:
    fontFamily: "system-ui"
    fontWeight: 400
  caption:
    fontFamily: "system-ui"
    fontWeight: 400
  caption-emphasis:
    fontFamily: "system-ui"
    fontWeight: 600
  code:
    fontFamily: "ui-monospace"
    fontSize: "12pt"
    fontWeight: 400
rounded:
  compact-control: "7pt"
  inset-content: "8pt"
  clipboard-card: "10pt"
spacing:
  tight: "4pt"
  compact: "6pt"
  inset: "8pt"
  related: "10pt"
  control: "12pt"
  section: "16pt"
  content: "20pt"
components:
  query-field:
    padding: "0pt 20pt"
    height: "62pt"
  scope-control:
    rounded: "{rounded.compact-control}"
    padding: "6pt 11pt"
  result-row:
    typography: "{typography.body}"
    rounded: "{rounded.inset-content}"
    padding: "3pt 8pt"
    height: "52pt"
  palette-row:
    rounded: "{rounded.compact-control}"
    padding: "7pt 10pt"
  clipboard-card:
    rounded: "{rounded.clipboard-card}"
    width: "190pt"
    height: "180pt"
  footer-action:
    typography: "{typography.caption}"
  source-badge:
    padding: "2.5pt 6pt"
  action-palette:
    rounded: "12pt"
    width: "380pt"
---

# Design System: Overboard

## Overview

**Creative North Star: "The native command surface"**

Make the selected result recognizable and its action predictable. Overboard extends its existing macOS vocabulary: system type, native icons, restrained glass, and a single accent for selection. The interface is compact, calm, and useful at a glance. Content supplies the variety; the surrounding controls remain familiar.

Keep filenames, source apps, breadcrumbs, and the selected action legible before adding decoration. The launcher and clipboard drawer share materials and interaction cues while retaining the forms appropriate to searching and scanning recent copies. System appearance and accessibility preferences are part of the visual system.

**Key Characteristics:**

- Native semantic colors and system typography.
- One clear selection with a readable primary action.
- Bounded lists, content-led previews, and compact metadata.
- Restrained glass with an opaque accessibility fallback.
- Source imagery and syntax color belong to content.

The source of truth is SwiftUI/AppKit. Frontmatter records reusable portable primitives; native semantic colors and type sizes that cannot be expressed faithfully as CSS tokens are documented below and in `.impeccable/design.json`. Dimensions are logical macOS points. HTML sidecar samples are structural previews, not replacements for native rendering.

## Colors

The palette follows macOS appearance and accent preferences; it is not a fixed set of sampled light and dark hex values.

### Primary

- **Selection Accent:** `Color.accentColor` marks selected items. Launcher rows use opacity `0.20`; palette rows use `0.22`. Clipboard cards use the full accent for their selected border. The tint remains behind readable primary text.

### Neutral

- **Primary Ink:** `.primary` for result titles and the primary footer action.
- **Supporting Ink:** `.secondary` for filenames' breadcrumbs, source metadata, scope shortcuts, and drawer action hints. Drawer hints use `.caption`; do not reduce their legibility to make them recede.
- **Quiet Surface:** `.background` supports preview and card content. The launcher preview uses opacity `0.35`; clipboard cards use `0.6`.
- **Subtle Control Fill:** `.quaternary.opacity(0.6)` supplies source badges, saved-search chips, and keyboard keycaps. `.primary.opacity(0.10)` marks the active scope without competing with result selection.
- **Opaque Panel:** `NSColor.windowBackgroundColor` replaces glass when Reduce Transparency is enabled. Native `Divider` separates structural regions.

App icons, file icons, syntax highlighting, image previews, and source-derived card-header tints retain their own colors. These are information, not additional brand accents.

**The Selection Accent Rule.** Use the system accent to identify actionable selection; preserve primary and secondary text hierarchy inside the tint.

**The Native Color Rule.** Keep semantic color bindings live across appearance and accessibility changes. Do not turn screenshot pixel samples into application colors.

## Typography

**Body Font:** the macOS system font, selected through SwiftUI semantic roles.
**Label/Mono Font:** the same system family for labels and keyboard hints; the system monospaced face for code and selected numeric or shortcut metadata.

**Character:** a compact utility hierarchy with regular-weight results and subdued supporting lines. System typography is an explicit part of this native app's approved direction.

### Hierarchy

- **Search:** the launcher query uses system regular type (20pt). Drawer and action-palette queries use `.title3`.
- **Result:** `.body`, normally regular; calculation results and query matches gain emphasis through weight.
- **Preview:** readable plain text uses system regular type (14pt). Code uses the shared `code` token and the existing appearance-specific Highlightr themes (`atom-one-dark` and `xcode`).
- **Section:** `.caption.weight(.semibold)` with secondary foreground, sentence case.
- **Metadata and actions:** `.caption`; selected footer actions use medium weight. Compact source badges and keycaps use `.caption2`.

**The Recognition Rule.** Give the title the first reading position, then the source or path. Emphasize matched text with weight rather than adding another highlight color.

## Layout

The search field and scope controls sit above a vertically scrolling result region. A reserved footer follows that region in the layout. The optional preview sits beside the list with a native divider and its own content padding. Both columns share available width; long content scrolls within its region.

The launcher uses a stable 740×612pt viewport for ordinary searches, including its first appearance before results arrive. Result counts and home section headings never resize the window. An explicit preview expands it to 1020×650pt; Clipboard scope adds 36pt for filters. Expansion keeps the search field's top edge anchored. All sizes fit inside the screen's visible frame with 40pt of horizontal and 60pt of vertical clearance. These are launcher-specific window constraints, not global breakpoints.

Result rows use the frontmatter geometry, a 28pt icon slot, a two-line title/metadata stack, and a trailing information area. The list has 8pt inset and 2pt gaps. Filenames stay on one line; breadcrumbs truncate in the middle so both location and nearby folder context survive.

The empty All scope presents sentence-case Suggestions before Recent searches. Both use ordinary result rows and the same selection treatment. Clipboard history uses date headings and compact native filters; the bottom drawer uses a horizontal card strip for recent copies. Avoid transferring one surface's composition into the other simply to make them identical.

**The Reserved Footer Rule.** Keep the primary action and Actions affordance outside scrolling content, visible without covering the last result.

## Elevation & Depth

Summonable surfaces share `glassPanel`, using regular Liquid Glass and a rounded silhouette. Floating action menus use an independent opaque native surface; overlapping glass shapes would merge behind the host content. Reduce Transparency supplies an opaque native window background; Reduce Motion disables the glass subtree's animations. Tonal content backgrounds and native dividers do most of the internal separation.

The command palette has an ambient shadow (black at 0.25 opacity, radius 18pt, vertical offset 6pt). Selected clipboard and snippet cards use a modest lift (scale 1.04) and a shadow (black at 0.28 opacity, radius 9pt, vertical offset 4pt). These soft shadows express elevation; they are not hard offset decoration.

Drawer cards enter with a short spring and a capped stagger; selection and palette changes use short springs. Honor the existing reduced-motion path when adding motion. Exact native spring parameters live in the sidecar because CSS easing cannot reproduce them faithfully.

**The Accessible Material Rule.** Every shared glass surface must remain understandable with opaque backgrounds and without motion.

## Shapes

Use soft rounded rectangles for selectable rows, content blocks, and cards; use capsules for small source or saved-search labels. The reusable inset, compact-control, and clipboard-card radii are in the frontmatter. Larger shells retain their component-specific shapes: launcher 18pt, drawer 16pt, and action palette 12pt.

Clip images to their slot or card before applying selection outlines. Preserve native SF Symbols, application icons, file icons, and macOS keyboard notation; each conveys a recognizable platform meaning.

## Components

### Inputs / Fields

Plain native text fields sit directly in the panel. The launcher query has a search symbol and generous horizontal padding, without a second enclosing input box. Focus returns to search when the surface opens, the scope changes, or the action palette closes. Clipboard filters retain native small pickers and a pin toggle.

### Navigation

The four launcher scopes use compact rounded buttons, medium-weight labels, secondary keyboard shortcuts, and a neutral active fill. Result selection remains visually stronger. Home and history group labels are functional sentence-case headings.

### Result Rows

An icon, recognizable title, secondary source or breadcrumb, and optional trailing badge form one selectable unit. The selected background fills the row's rounded shape. Running-app dots, pin marks, and cloud availability symbols are small contextual signals. Focused clipboard scope omits redundant Clipboard badges.

### Buttons and Footer

Footer buttons are plain text actions, with the primary action in primary foreground and the remaining controls in secondary foreground. The action label describes the selected item's behavior and paste destination when applicable. Return and the Actions keycap stay beside their controls. Native buttons handle explicit actions such as Download & Open.

### Chips

Source badges and saved searches use compact capsules with quiet native fill. They name a type or recall a query; their treatment does not compete with the selected result. Keyboard hints are compact rounded keycaps rather than prominent buttons.

### Preview

The content occupies the main preview area; a divider separates its metadata below. Text supports selection and scrolling, images fit their bounds, code uses the shared syntax renderer, and eligible local readable-text files use the same bounded renderer as the Quick Look extension. Eligibility is an explicit readable-format map plus macOS `public.plain-text` conformance; rich `public.text` formats remain native. The loader samples at most 256 KiB and rejects recognized binary signatures before decoding. Other local files use native Quick Look. Cloud, unavailable, loading, and empty states use concise text with meaningful native symbols. Keep descriptive metadata readable when the content is small or absent.

### Clipboard Cards

The drawer preserves compact, equal-size cards with source-app headers, content previews, and metadata footers. Header tint comes from the source app's icon; image, link, code, color, file, and protected content keep their distinct presentations. Selected cards have an accent outline and soft lift; hover reveals compact native actions. The drawer's centered action hints use caption-sized secondary text.

### Action Palette

The launcher and drawer share a compact palette with an opaque `NSColor.windowBackgroundColor` fill, a subtle border, and a shadow: a plain query field, divider, filtered action rows, and accent selection. Use the same chrome and focus behavior while preserving the actions appropriate to each host. Its launcher placement leaves the reserved footer exposed.

## Do's and Don'ts

### Do:

- **Do** use native semantic colors, system type, and meaningful platform icons.
- **Do** preserve readable titles, breadcrumbs, source metadata, and action hints in both appearances.
- **Do** keep a selected result and its primary action visually connected.
- **Do** let previews and source imagery provide content-specific color.
- **Do** verify glass, selection, and text with reduced transparency and reduced motion.

### Don't:

- **Don't** replace semantic native colors with fixed screenshot samples.
- **Don't** use faint text to solve density or hierarchy problems for actionable hints.
- **Don't** cover the last result or the primary footer action with an overlay.
- **Don't** promote source artwork, demo content, or syntax colors into brand tokens.
- **Don't** add decorative display typography or ornamental section labels to the compact command surface.
