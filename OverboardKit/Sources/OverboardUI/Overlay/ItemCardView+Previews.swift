import SwiftUI

#if DEBUG
    #Preview("Light") {
        let item = Fixtures.item(preview: "Pick up the package before 6pm — front desk closes early on Fridays.")
        ItemCardView(item: item, index: 0, isSelected: false, store: Fixtures.previewStore())
            .padding()
            .environment(\.referenceDate, Fixtures.referenceDate)
    }

    #Preview("Selected") {
        let item = Fixtures.item(preview: "Pick up the package before 6pm — front desk closes early on Fridays.")
        ItemCardView(item: item, index: 0, isSelected: true, store: Fixtures.previewStore())
            .padding()
            .environment(\.referenceDate, Fixtures.referenceDate)
    }

    #Preview("Dark") {
        let item = Fixtures.item(preview: "Pick up the package before 6pm — front desk closes early on Fridays.")
        ItemCardView(item: item, index: 0, isSelected: false, store: Fixtures.previewStore())
            .padding()
            .environment(\.referenceDate, Fixtures.referenceDate)
            .preferredColorScheme(.dark)
    }

    #Preview("Link") {
        let item = Fixtures.item(
            kind: .link,
            preview: "https://developer.apple.com/documentation/swiftui/imagerenderer",
            linkTitle: "ImageRenderer | Apple Developer Documentation",
            linkDescription: "An object that creates images from SwiftUI views.",
            faviconData: Fixtures.solidPNG(width: 32, height: 32, red: 0.2, green: 0.5, blue: 0.9)
        )
        ItemCardView(item: item, index: 2, isSelected: false, store: Fixtures.previewStore())
            .padding()
            .environment(\.referenceDate, Fixtures.referenceDate)
    }

    #Preview("Image") {
        // previewImageData isn't read for .image cards (that's the link og:image
        // field) — the card loads its thumbnail from the store, which is empty
        // here, so this renders the placeholder icon; the dimensions show in
        // the card footer alongside the relative copy time.
        let item = Fixtures.item(
            kind: .image,
            preview: "Image 1920×1080",
            appName: "Preview",
            pixelWidth: 1920,
            pixelHeight: 1080
        )
        ItemCardView(item: item, index: 5, isSelected: false, store: Fixtures.previewStore())
            .padding()
            .environment(\.referenceDate, Fixtures.referenceDate)
    }

    #Preview("Secret") {
        let item = Fixtures.item(preview: "AWS access key", isSecret: true)
        ItemCardView(item: item, index: 4, isSelected: false, store: Fixtures.previewStore())
            .padding()
            .environment(\.referenceDate, Fixtures.referenceDate)
    }

    #Preview("Pinned") {
        let item = Fixtures.item(
            preview: "Overboard ⛵️ — everything you copy goes overboard.",
            isPinned: true
        )
        ItemCardView(item: item, index: 0, isSelected: false, store: Fixtures.previewStore())
            .padding()
            .environment(\.referenceDate, Fixtures.referenceDate)
    }
#endif
