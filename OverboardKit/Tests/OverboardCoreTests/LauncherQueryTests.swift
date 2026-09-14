@testable import OverboardCore
import Testing

struct LauncherQueryTests {
    @Test func colonPrefixIsCommandLike() {
        #expect(LauncherQuery.isCommandLike(":stats"))
        #expect(LauncherQuery.isCommandLike(":"))
    }

    @Test func greaterThanPrefixIsCommandLike() {
        #expect(LauncherQuery.isCommandLike("> brew upgrade"))
        #expect(LauncherQuery.isCommandLike(">"))
    }

    @Test func plainQueryIsNotCommandLike() {
        #expect(!LauncherQuery.isCommandLike("hello"))
        #expect(!LauncherQuery.isCommandLike(""))
        #expect(!LauncherQuery.isCommandLike("2+2"))
    }
}
