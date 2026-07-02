import Foundation
@testable import OverboardCore
import Testing

struct BrowserScriptTests {
    @Test func mapsSafariBundleIDs() {
        #expect(BrowserScript.dialect(forBundleID: "com.apple.Safari") == .safari)
        #expect(BrowserScript.dialect(forBundleID: "com.apple.SafariTechnologyPreview") == .safari)
    }

    @Test func mapsChromiumFamilyBundleIDs() {
        for id in [
            "com.google.Chrome",
            "com.google.Chrome.canary",
            "com.brave.Browser",
            "com.microsoft.edgemac",
            "com.vivaldi.Vivaldi",
            "company.thebrowser.Browser", // Arc
            "org.chromium.Chromium",
        ] {
            #expect(BrowserScript.dialect(forBundleID: id) == .chromium)
        }
    }

    @Test func firefoxAndOthersHaveNoDialect() {
        // Firefox has no AppleScript URL support — must map to nil.
        #expect(BrowserScript.dialect(forBundleID: "org.mozilla.firefox") == nil)
        #expect(BrowserScript.dialect(forBundleID: "com.apple.TextEdit") == nil)
        #expect(BrowserScript.dialect(forBundleID: "") == nil)
    }

    @Test func safariSourceTargetsBundleAndFrontDocument() {
        let source = BrowserScript.source(for: .safari, bundleID: "com.apple.Safari")
        #expect(source.contains("tell application id \"com.apple.Safari\""))
        #expect(source.contains("front document"))
        // Guards no-windows rather than erroring.
        #expect(source.contains("return \"\""))
        #expect(source.contains("on error"))
    }

    @Test func chromiumSourceTargetsBundleAndActiveTab() {
        let source = BrowserScript.source(for: .chromium, bundleID: "com.google.Chrome")
        #expect(source.contains("tell application id \"com.google.Chrome\""))
        #expect(source.contains("active tab of front window"))
        #expect(source.contains("return \"\""))
        #expect(source.contains("on error"))
    }
}
