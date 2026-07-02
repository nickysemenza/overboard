@testable import OverboardCore
import Testing

struct UpdateCheckTests {
    // MARK: - Parsing

    @Test func parsesCommonTagShapes() {
        #expect(SemanticVersion("v0.2.0")?.components == [0, 2, 0])
        #expect(SemanticVersion("0.2.0")?.components == [0, 2, 0])
        #expect(SemanticVersion("1.2")?.components == [1, 2])
        // git describe drift: keep only the release core.
        #expect(SemanticVersion("v0.1.0-3-gabc1234")?.components == [0, 1, 0])
    }

    @Test func rejectsNonNumeric() {
        #expect(SemanticVersion("nightly") == nil)
        #expect(SemanticVersion("") == nil)
        #expect(SemanticVersion("v.")?.components == nil)
    }

    // MARK: - Ordering

    @Test func comparesNumericallyNotLexically() throws {
        #expect(try #require(SemanticVersion("0.10.0")) > SemanticVersion("0.9.0")!)
        #expect(try #require(SemanticVersion("1.0.0")) > SemanticVersion("0.99.0")!)
    }

    @Test func missingComponentsTreatedAsZero() throws {
        #expect(SemanticVersion("1.2") == SemanticVersion("1.2.0")!)
        #expect(try #require(SemanticVersion("1.2.1")) > SemanticVersion("1.2")!)
    }

    // MARK: - newerRelease decision

    @Test func flagsStrictlyNewerRelease() {
        #expect(UpdateCheck.newerRelease(current: "0.1.0", latestTag: "v0.2.0") == "v0.2.0")
        #expect(UpdateCheck.newerRelease(current: "0.9.0", latestTag: "v0.10.0") == "v0.10.0")
    }

    @Test func ignoresSameOrOlderRelease() {
        #expect(UpdateCheck.newerRelease(current: "0.2.0", latestTag: "v0.2.0") == nil)
        #expect(UpdateCheck.newerRelease(current: "0.2.0", latestTag: "v0.1.0") == nil)
    }

    @Test func unparseableInputsNeverFalseAlarm() {
        #expect(UpdateCheck.newerRelease(current: "?", latestTag: "v0.2.0") == nil)
        #expect(UpdateCheck.newerRelease(current: "0.1.0", latestTag: "nightly") == nil)
    }
}
