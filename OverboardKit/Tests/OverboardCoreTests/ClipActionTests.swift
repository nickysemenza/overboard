import Foundation
@testable import OverboardCore
import Testing

private func makeItem(kind: ItemKind, aiTitle: String? = nil) -> ClipItem {
    ClipItem(
        contentHash: UUID().uuidString, kind: kind, previewText: "p",
        sourceBundleID: nil, sourceAppName: nil, byteSize: 1,
        aiTitle: aiTitle,
        createdAt: Date(), lastUsedAt: Date(), updatedAt: Date()
    )
}

private func input(_ kind: ItemKind, text: String?, files: [URL] = [], title: String? = nil) -> ActionInput {
    ActionInput(item: makeItem(kind: kind, aiTitle: title), plainText: text, fileURLs: files)
}

struct TextScrapsTests {
    @Test func extractsLinks() {
        let text = "see https://a.example/x and http://b.example, not ftp://c.example"
        let links = TextScraps.links(in: text)
        #expect(links.count == 2)
        #expect(links[0].host == "a.example")
    }

    @Test func extractsNumbers() {
        let numbers = TextScraps.numbers(in: "items: 3 at $1,200.50 each, -7 returned")
        #expect(numbers == [3, 1200.50, -7])
    }

    @Test func formatsTotals() {
        #expect(TextScraps.format(10.0) == "10")
        #expect(TextScraps.format(10.5) == "10.5")
    }

    @Test func prettyPrintsJSON() {
        let pretty = TextScraps.prettyPrintedJSON(#"{"b":1,"a":[2,3]}"#)
        #expect(pretty?.contains("\"a\" : [") == true)
        #expect(TextScraps.prettyPrintedJSON("not json") == nil)
    }
}

struct ClipActionTests {
    @Test func applicabilityByKindAndCount() {
        let link = makeItem(kind: .link)
        let text = makeItem(kind: .text)
        let image = makeItem(kind: .image)

        #expect(ClipAction.applicable(to: [link]).contains(.openLink))
        #expect(!ClipAction.applicable(to: [text]).contains(.openLink))
        #expect(ClipAction.applicable(to: [text]).contains(.openAllLinks))
        #expect(ClipAction.applicable(to: [image]).contains(.saveImageToDownloads))
        // Multi-only actions need 2+.
        #expect(!ClipAction.applicable(to: [text]).contains(.pasteAllJoined))
        #expect(ClipAction.applicable(to: [text, link]).contains(.pasteAllJoined))
        #expect(ClipAction.applicable(to: [text, image]).contains(.addAllToStack))
        #expect(!ClipAction.applicable(to: [text, image]).contains(.pasteAllJoined))
    }

    @Test func sumNumbersAcrossSelection() {
        let effect = ClipAction.sumNumbers.run([
            input(.text, text: "invoice $1,200.50"),
            input(.text, text: "tip 19.50 and fee 30"),
        ])
        #expect(effect == .copyText("1250", hud: "Sum: 1250 — copied"))
    }

    @Test func sumNeedsAtLeastTwoNumbers() {
        let effect = ClipAction.sumNumbers.run([input(.text, text: "just 42 here")])
        #expect(effect == .showMessage("Need at least two numbers"))
    }

    @Test func openLinkParsesURL() throws {
        let effect = ClipAction.openLink.run([input(.link, text: " https://example.com/x \n")])
        #expect(try effect == .openURLs([#require(URL(string: "https://example.com/x"))]))
    }

    @Test func markdownLinkUsesAITitle() {
        let effect = ClipAction.copyAsMarkdownLink.run([
            input(.link, text: "https://example.com/post", title: "Great Post"),
        ])
        #expect(effect == .copyText("[Great Post](https://example.com/post)", hud: "Markdown link copied"))
    }

    @Test func pasteAllJoinsInOrder() {
        let effect = ClipAction.pasteAllJoined.run([
            input(.text, text: "one"),
            input(.text, text: "two"),
        ])
        #expect(effect == .pasteText("one\ntwo"))
    }

    @Test func jsonAndBase64Validate() {
        #expect(ClipAction.prettyPrintJSON.run([input(.text, text: "nope")])
            == .showMessage("Not valid JSON"))
        let effect = ClipAction.decodeBase64.run([input(.text, text: "YWhveQ==")])
        #expect(effect == .pasteText("ahoy"))
    }

    @Test func wordCount() {
        let effect = ClipAction.wordCount.run([input(.text, text: "three short words")])
        #expect(effect == .showMessage("3 words · 17 characters"))
    }
}
