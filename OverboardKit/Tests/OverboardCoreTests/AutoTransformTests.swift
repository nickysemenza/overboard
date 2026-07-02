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
}
