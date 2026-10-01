import Foundation
@testable import OverboardCore
import Testing

struct AutoTransformTests {
    // MARK: - Parsing

    @Test func parsesBundleIDAndTransform() {
        let rules = AutoTransform.parseRules("""
        com.apple.Safari = stripTrackingParams
        com.apple.Terminal = trimWhitespace
        """)
        #expect(rules == [
            AutoTransformRule(bundleID: "com.apple.Safari", transform: .stripTrackingParams),
            AutoTransformRule(bundleID: "com.apple.Terminal", transform: .trimWhitespace),
        ])
    }

    @Test func skipsBlankAndMalformedLines() {
        let rules = AutoTransform.parseRules("""

        com.apple.Safari = stripTrackingParams
        garbage line
        com.foo = notARealTransform
        = trimWhitespace
        """)
        #expect(rules == [AutoTransformRule(bundleID: "com.apple.Safari", transform: .stripTrackingParams)])
    }

    // MARK: - Application

    @Test func appliesMatchingRule() {
        let rules = [AutoTransformRule(bundleID: "com.apple.Safari", transform: .stripTrackingParams)]
        let out = AutoTransform.apply(
            to: "https://example.com/x?utm_source=news&id=7",
            bundleID: "com.apple.Safari",
            rules: rules
        )
        #expect(out == "https://example.com/x?id=7")
    }

    @Test func nilWhenNoRuleMatchesApp() {
        let rules = [AutoTransformRule(bundleID: "com.apple.Safari", transform: .trimWhitespace)]
        #expect(AutoTransform.apply(to: "  hi  ", bundleID: "com.apple.Terminal", rules: rules) == nil)
        #expect(AutoTransform.apply(to: "  hi  ", bundleID: nil, rules: rules) == nil)
    }

    @Test func nilWhenTransformIsANoOp() {
        // Rule matches but the text has no tracking params → unchanged → nil.
        let rules = [AutoTransformRule(bundleID: "com.apple.Safari", transform: .stripTrackingParams)]
        #expect(AutoTransform.apply(to: "https://example.com/x", bundleID: "com.apple.Safari", rules: rules) == nil)
    }

    @Test func appliesMultipleRulesForSameAppInOrder() {
        let rules = [
            AutoTransformRule(bundleID: "com.apple.Terminal", transform: .trimWhitespace),
            AutoTransformRule(bundleID: "com.apple.Terminal", transform: .uppercase),
        ]
        let out = AutoTransform.apply(to: "  hello  ", bundleID: "com.apple.Terminal", rules: rules)
        #expect(out == "HELLO")
    }

    @Test func transformsEachItemWithoutRemovingUnchangedRichCompanions() {
        let snapshot = PasteboardSnapshot(reps: [
            .init(uti: WellKnownUTI.plainText, data: Data("  first  ".utf8), itemIndex: 0),
            .init(uti: WellKnownUTI.html, data: Data("<b>  first  </b>".utf8), itemIndex: 0),
            .init(uti: WellKnownUTI.plainText, data: Data("second".utf8), itemIndex: 1),
            .init(uti: WellKnownUTI.rtf, data: Data("unchanged rich bytes".utf8), itemIndex: 1),
            .init(uti: WellKnownUTI.plainText, data: Data(" third ".utf8), itemIndex: 2),
        ], sourceBundleID: "com.apple.Terminal", sourceAppName: nil)
        let result = AutoTransform.apply(to: snapshot, rules: [
            .init(bundleID: "com.apple.Terminal", transform: .trimWhitespace),
        ])
        #expect(result.reps.count == 4)
        #expect(result.reps.first?.data == Data("first".utf8))
        #expect(result.reps.contains(snapshot.reps[3]))
        #expect(result.reps.last?.data == Data("third".utf8))
    }
}
