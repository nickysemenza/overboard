import Foundation
@testable import OverboardCore
import Testing

private struct StubFileProvider: LauncherProvider {
    let hits: [LauncherResult]
    func results(for _: String) async -> [LauncherResult] {
        self.hits
    }
}

struct QueryRouterTests {
    private func makeRouter(files: [LauncherResult] = []) -> QueryRouter {
        QueryRouter(providers: [
            CalculatorProvider(),
            StubFileProvider(hits: files),
            WebSearchProvider(),
        ])
    }

    @Test func mathQueryPutsCalculationFirstAndWebLast() async {
        let file = LauncherResult.file(name: "21*2.txt", url: URL(fileURLWithPath: "/tmp/21*2.txt"))
        let results = await makeRouter(files: [file]).results(for: "21*2")

        #expect(results.count == 3)
        guard case let .calculation(_, display) = results.first else {
            Issue.record("expected calculation first, got \(results)")
            return
        }
        #expect(display == "42")
        #expect(results[1] == file)
        guard case .webSearch = results.last else {
            Issue.record("expected web search last, got \(results)")
            return
        }
    }

    @Test func nonMathQueryHasNoCalculationRow() async {
        let results = await makeRouter().results(for: "Package.swift")
        #expect(results.count == 1)
        guard case let .webSearch(query, _) = results.first else {
            Issue.record("expected only a web row, got \(results)")
            return
        }
        #expect(query == "Package.swift")
    }

    @Test func emptyAndWhitespaceQueriesReturnNothing() async {
        #expect(await self.makeRouter().results(for: "").isEmpty)
        #expect(await self.makeRouter().results(for: "   ").isEmpty)
    }

    @Test func queryIsTrimmedBeforeProvidersSeeIt() async {
        let results = await makeRouter().results(for: "  2+2  ")
        guard case let .calculation(input, display) = results.first else {
            Issue.record("expected calculation, got \(results)")
            return
        }
        #expect(input == "2+2")
        #expect(display == "4")
    }

    @Test func appsRankAboveFilesAndBelowCalculations() async {
        let app = LauncherResult.app(name: "Calculator", url: URL(fileURLWithPath: "/Applications/Calculator.app"))
        let file = LauncherResult.file(name: "calc.txt", url: URL(fileURLWithPath: "/tmp/calc.txt"))
        let router = QueryRouter(providers: [
            CalculatorProvider(),
            StubFileProvider(hits: [app]),
            StubFileProvider(hits: [file]),
            WebSearchProvider(),
        ])

        let results = await router.results(for: "2+2")
        guard case .calculation = results.first else {
            Issue.record("expected calculation first, got \(results)")
            return
        }
        #expect(results[1] == app)
        #expect(results[2] == file)
    }

    @Test func conditionalProviderRespectsSwitch() async {
        let hit = LauncherResult.file(name: "a", url: URL(fileURLWithPath: "/tmp/a"))
        let enabled = ConditionalProvider(StubFileProvider(hits: [hit])) { true }
        let disabled = ConditionalProvider(StubFileProvider(hits: [hit])) { false }

        #expect(await enabled.results(for: "a") == [hit])
        #expect(await disabled.results(for: "a").isEmpty)
    }

    @Test func webSearchURLEncodesPlusAndUnicode() {
        let url = WebSearchProvider.searchURL(for: "c++ tutorial")
        #expect(url?.absoluteString == "https://www.google.com/search?q=c%2B%2B%20tutorial")

        let unicode = WebSearchProvider.searchURL(for: "héllo & wörld")
        let query = unicode?.absoluteString.split(separator: "?").last ?? ""
        #expect(!query.contains("&"), "ampersand must be encoded, got \(query)")
        #expect(!query.contains("ö"), "non-ASCII must be encoded, got \(query)")
    }
}
