import Foundation
@testable import OverboardCore
import Testing

/// The ranking eval set (docs/adr/0001-blended-launcher-ranking.md): real
/// queries and the row that should come first, run through both stages —
/// the file index's cut and the cross-provider merge. Fixture paths are
/// made up but shaped like the cases that motivated blended ranking. Weight changes in
/// `LauncherScore` are judged against these, not intuition.
struct LauncherRankingEvalTests {
    private static let home = "/Users/me"
    private static let cloud = "/Users/me/Library/Mobile Documents/com~apple~CloudDocs"
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private static let apps: [LauncherResult] = ["Notes", "Numbers", "Sublime Merge", "Stickies", "Budget Tracker"]
        .map { .app(name: $0, url: URL(fileURLWithPath: "/Applications/\($0).app")) }

    /// Home-relative or iCloud-relative paths. `noise` stands in for what
    /// the scanner detects (`FileMetadataScannerTests` covers detection).
    private static let files: [(path: String, noise: Bool)] = [
        ("~/go/pkg/mod/example.com/alpha@v1.2.3/matchers/not.go", true),
        ("~/go/pkg/mod/example.com/beta@v2.0.1/matchers/not.go", true),
        ("~/go/pkg/mod/example.com/api@v0.9.0/NOTES", true),
        ("~/go/pkg/mod/example.com/api@v0.8.0/NOTES", true),
        ("icloud/Documents/projects/old-site/vendor/testlib/src/Not.php", true),
        ("icloud/Documents/projects/old-site/vendor/mailer/notes", true),
        ("icloud/Documents/school/year1/term2/history/Notes", false),
        ("icloud/Documents/school/year3/spring/biology/notes", false),
        ("~/Documents/budget.xlsx", false),
        ("~/Desktop/sm.png", false),
        ("~/dev/sample/hello", false),
        ("~/notebook.md", false),
    ] + ["draft4", "draft6", "draft7", "draft2019-09", "draft2020-12"].map {
        ("~/go/pkg/mod/example.com/schema@v0.4.1/testdata/tests/\($0)/not.json", true)
    } + ["draft4", "draft6", "draft7"].map {
        ("~/dev/schemas/tests/\($0)/not.json", false)
    }

    private static func indexed(_ entry: (path: String, noise: Bool)) -> IndexedFile {
        let (root, relative) = entry.path.hasPrefix("icloud/")
            ? (self.cloud, String(entry.path.dropFirst(7)))
            : (self.home, String(entry.path.dropFirst(2)))
        let path = root + "/" + relative
        return IndexedFile(path: path, name: (path as NSString).lastPathComponent, root: root, generation: "g",
                           modifiedAt: self.now.addingTimeInterval(-400 * 86400), isNoise: entry.noise)
    }

    private static func ranked(
        _ query: String,
        files extra: [IndexedFile] = [],
        context: LauncherSearchContext = LauncherSearchContext(now: now)
    ) async throws -> [LauncherResult] {
        let index = try FileNameIndex()
        try await index.upsert(self.files.map(self.indexed) + extra)
        let files = try await index.search(query, context: context)
        let apps = self.apps.filter { LauncherRanking.match(for: $0, query: query).tier != .related }
        return context.sorted(apps + files, query: query)
    }

    @Test(arguments: [
        ("not", "Notes"), // App prefix beats `not.go` stems in the Go module cache.
        ("notes", "Notes"),
        ("no", "Notes"),
        ("sm", "Sublime Merge"), // Short queries lean to apps over `sm.png`.
        ("hello", "hello"), // ...but by five letters an exact file stands on its own.
        ("budget", "budget.xlsx"),
    ])
    func topResult(query: String, expected: String) async throws {
        #expect(try await Self.ranked(query).first?.label == expected)
    }

    @Test func ownFoldersOutrankVendoredCopies() async throws {
        let paths = try await Self.ranked("notes").map(\.id)
        let own = try #require(paths.firstIndex { $0.contains("biology") })
        let vendored = try #require(paths.firstIndex { $0.contains("mailer") })
        let cached = try #require(paths.firstIndex { $0.contains("api@v0.9.0") })
        #expect(own < vendored)
        #expect(own < cached)
    }

    @Test func repeatNamesYieldToOtherMatches() async throws {
        // Three clean `not.json`s all match "not" exactly; the third sinks
        // below a prefix match it would otherwise outrank.
        let labels = try await Self.ranked("not").map(\.label)
        let notebook = try #require(labels.firstIndex(of: "notebook.md"))
        let jsons = labels.indices.filter { labels[$0] == "not.json" }
        #expect(jsons.count >= 3)
        #expect(notebook < jsons[2])
    }

    @Test func picksCarryToShorterQueries() async throws {
        let numbers = Self.apps[1]
        #expect(try await Self.ranked("n").first?.label == "Notes")
        let context = LauncherSearchContext(
            query: "n", selectionUsage: ["numbers\u{1F}" + numbers.id: 1], counts: [:],
            lastUsed: [numbers.id: Self.now.timeIntervalSince1970], now: Self.now
        )
        #expect(context.usage.isEmpty)
        #expect(try await Self.ranked("n", context: context).first == numbers)
    }

    @Test func exactQueryPickWinsOutright() async throws {
        let cached = Self.indexed(Self.files[0]).result
        let context = LauncherSearchContext(
            query: "not", selectionUsage: ["not\u{1F}" + cached.id: 1], counts: [:], lastUsed: [:], now: Self.now
        )
        #expect(try await Self.ranked("not", context: context).first == cached)
    }

    @Test func recentlyOpenedFileBeatsUnopenedPeer() async throws {
        let opened = Self.indexed(("~/dev/schemas/tests/draft7/not.json", false))
        let index = try FileNameIndex()
        try await index.upsert(Self.files.map(Self.indexed))
        let unopened = try await index.search("not.json", context: LauncherSearchContext(now: Self.now))
        #expect(unopened.first?.id != opened.result.id)
        try await index.setLastOpened([opened.path: Self.now.addingTimeInterval(-86400)])
        let files = try await index.search("not.json", context: LauncherSearchContext(now: Self.now))
        #expect(files.first?.id == opened.result.id)
    }

    @Test func noiseClearsForAFolderTheUserPicksFrom() async throws {
        let cached = Self.indexed(Self.files[1]).result
        #expect(try await Self.ranked("not.go").first != cached)
        let neighbour = "file:" + (cached.id.dropFirst(5) as NSString).deletingLastPathComponent + "/other.go"
        let context = LauncherSearchContext(counts: [neighbour: 1], now: Self.now)
        #expect(try await Self.ranked("not.go", context: context).first == cached)
    }

    @Test func settingsListsOverrideDetection() {
        let rules = NoiseRules(noise: "archive\n~/old", notNoise: "/Users/me/go/pkg/mod/example.com/alpha")
        #expect(rules.isNoise(path: "/x/archive/a.txt", detected: false))
        #expect(!rules.isNoise(path: "/Users/me/go/pkg/mod/example.com/alpha/lib@v1/not.go", detected: true))
        #expect(!rules.isNoise(path: "/x/archived/a.txt", detected: false))
    }

    @Test func gitignoreRulesCoverCommonShapes() {
        let rules = GitIgnoreRules("# deps\n/vendor/\nbuild\n*.log\n!keep.log\ndocs/generated\n")
        #expect(rules.ignores(relativePath: "vendor", isDirectory: true))
        #expect(!rules.ignores(relativePath: "vendor", isDirectory: false))
        #expect(!rules.ignores(relativePath: "src/vendor", isDirectory: true))
        #expect(rules.ignores(relativePath: "src/build", isDirectory: true))
        #expect(rules.ignores(relativePath: "a/b.log", isDirectory: false))
        #expect(rules.ignores(relativePath: "docs/generated", isDirectory: true))
        #expect(!rules.ignores(relativePath: "other/docs/generated", isDirectory: true))
    }

    @Test func versionStampsNeedASeparatorAndADot() {
        for name in ["alpha@v1.2.3", "api@v0.9.0", "lib-4.17.21", "schema@v0.4.1"] {
            #expect(NoiseClassifier.isVersionStamped(folderName: name), "\(name)")
        }
        for name in ["draft2020-12", "BIO101", "S17", "Backup 01:05:2020", "7th grade"] {
            #expect(!NoiseClassifier.isVersionStamped(folderName: name), "\(name)")
        }
    }
}

private extension LauncherResult {
    var label: String {
        switch self {
        case let .app(name, _), let .file(name, _, _): name
        default: self.id
        }
    }
}
