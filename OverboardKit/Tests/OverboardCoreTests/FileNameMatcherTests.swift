@testable import OverboardCore
import Testing

struct FileNameMatcherTests {
    @Test func shortQueryRequiresWordPrefix() {
        // The original complaint: "zz" CONTAINS-matched every fuzz-test file.
        #expect(FileNameMatcher.rank(name: "fuzz-test-corpus.txt", query: "zz") == nil)
        #expect(FileNameMatcher.rank(name: "zz-plan.md", query: "zz") == 0)
        #expect(FileNameMatcher.rank(name: "notes zz draft.md", query: "zz") == 1)
    }

    @Test func longQueryAllowsSubstring() {
        #expect(FileNameMatcher.rank(name: "prefuzzed-data.bin", query: "fuzz") == 2)
        #expect(FileNameMatcher.rank(name: "fuzz-test.txt", query: "fuzz") == 0)
        #expect(FileNameMatcher.rank(name: "run-fuzzer.sh", query: "fuzz") == 1)
        #expect(FileNameMatcher.rank(name: "unrelated.txt", query: "fuzz") == nil)
    }

    @Test func ranksPrefixAboveWordPrefixAboveSubstring() {
        let names = ["archive-release.zip", "release-notes.md", "old-releases.txt"]
        let ranked = names.compactMap { name in
            FileNameMatcher.rank(name: name, query: "release").map { (name, $0) }
        }.sorted { $0.1 < $1.1 }
        #expect(ranked.map(\.0) == ["release-notes.md", "archive-release.zip", "old-releases.txt"])
    }

    @Test func foldsCaseAndDiacritics() {
        #expect(FileNameMatcher.rank(name: "Résumé.pdf", query: "resume") == 0)
        #expect(FileNameMatcher.rank(name: "MY-NOTES.md", query: "my") == 0)
    }

    @Test func wordsSplitOnNonAlphanumerics() {
        #expect(FileNameMatcher.rank(name: "report_q3_final.xlsx", query: "q3") == 1)
        #expect(FileNameMatcher.rank(name: "report.q3.xlsx", query: "q3") == 1)
    }

    @Test func emptyQueryDrops() {
        #expect(FileNameMatcher.rank(name: "anything.txt", query: "") == nil)
    }
}
