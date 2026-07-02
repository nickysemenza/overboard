import Foundation
@testable import OverboardCore
import Testing

struct LinkMetadataParserTests {
    private let base = URL(string: "https://example.com/articles/one")!

    @Test func openGraphTagsWin() {
        let html = """
        <html><head>
        <title>Bare Title</title>
        <meta property="og:title" content="OG Title">
        <meta property="og:description" content="OG description here.">
        <meta name="description" content="Plain description.">
        <meta property="og:image" content="https://cdn.example.com/preview.png">
        </head><body></body></html>
        """
        let result = LinkMetadataParser.parse(html: html, baseURL: self.base)
        #expect(result.title == "OG Title")
        #expect(result.description == "OG description here.")
        #expect(result.previewImageURL == URL(string: "https://cdn.example.com/preview.png"))
    }

    @Test func fallsBackToBareTitleAndMetaDescription() {
        let html = """
        <head>
        <title>Just The Title</title>
        <meta name="description" content="A plain meta description.">
        </head>
        """
        let result = LinkMetadataParser.parse(html: html, baseURL: self.base)
        #expect(result.title == "Just The Title")
        #expect(result.description == "A plain meta description.")
        #expect(result.previewImageURL == nil)
    }

    @Test func relativeFaviconHrefResolvesAgainstBase() {
        let html = #"""
        <head><link rel="icon" href="/favicon-32.png"></head>
        """#
        let result = LinkMetadataParser.parse(html: html, baseURL: self.base)
        #expect(result.faviconURL == URL(string: "https://example.com/favicon-32.png"))
    }

    @Test func iconRelVariantsAllMatch() {
        for rel in ["icon", "shortcut icon", "apple-touch-icon", "ICON"] {
            let html = "<head><link rel=\"\(rel)\" href=\"/f.ico\"></head>"
            let result = LinkMetadataParser.parse(html: html, baseURL: self.base)
            #expect(result.faviconURL == URL(string: "https://example.com/f.ico"), "rel=\(rel)")
        }
    }

    @Test func attributeOrderAndCaseVariants() {
        // content-before-property, uppercase attribute names, single quotes.
        let html = """
        <head>
        <META CONTENT='Reversed Order' PROPERTY='og:title'>
        <meta content="single quoted desc" name='description'>
        </head>
        """
        let result = LinkMetadataParser.parse(html: html, baseURL: self.base)
        #expect(result.title == "Reversed Order")
        #expect(result.description == "single quoted desc")
    }

    @Test func decodesHTMLEntities() {
        let html = """
        <head><title>Tom &amp; Jerry &lt;3 &quot;quotes&quot; &#39;apos&#39; caf&#233;</title></head>
        """
        let result = LinkMetadataParser.parse(html: html, baseURL: self.base)
        #expect(result.title == "Tom & Jerry <3 \"quotes\" 'apos' café")
    }

    @Test func decodesHexNumericEntities() {
        let html = "<head><title>A&#x26;B</title></head>"
        let result = LinkMetadataParser.parse(html: html, baseURL: self.base)
        #expect(result.title == "A&B")
    }

    @Test func noHeadYieldsNothing() {
        let html = "<html><body><p>Just a body, no head or meta.</p></body></html>"
        let result = LinkMetadataParser.parse(html: html, baseURL: self.base)
        #expect(result.title == nil)
        #expect(result.description == nil)
        #expect(result.faviconURL == nil)
        #expect(result.previewImageURL == nil)
    }

    @Test func collapsesWhitespaceInTitle() {
        let html = "<head><title>  Spaced\n\t out   title  </title></head>"
        let result = LinkMetadataParser.parse(html: html, baseURL: self.base)
        #expect(result.title == "Spaced out title")
    }

    @Test func titleWithAttributesOnTag() {
        let html = "<head><title data-foo=\"bar\">Titled</title></head>"
        let result = LinkMetadataParser.parse(html: html, baseURL: self.base)
        #expect(result.title == "Titled")
    }

    @Test func absoluteImageURLUnchanged() {
        let html = #"<head><meta property="og:image" content="https://img.example.org/a.jpg"></head>"#
        let result = LinkMetadataParser.parse(html: html, baseURL: self.base)
        #expect(result.previewImageURL == URL(string: "https://img.example.org/a.jpg"))
    }

    @Test func metaNameDoesNotFalseMatchLongerName() {
        // "description" must not be found inside "og:sitename" etc.
        let html = #"<head><meta property="og:sitename" content="Ignore"></head>"#
        let result = LinkMetadataParser.parse(html: html, baseURL: self.base)
        #expect(result.description == nil)
    }
}
