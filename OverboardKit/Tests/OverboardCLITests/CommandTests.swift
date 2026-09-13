import ArgumentParser
import Foundation
import GRDB
@testable import OverboardCLI
import OverboardCore
import Testing

/// Exercises the CLI's dispatch, exit-code contract, and `get` index math —
/// the parts scripts depend on. Presentation is covered separately in
/// OutputTests. Command bodies take an injected in-memory store, so no real
/// database is touched.
struct CommandTests {
    private func makeStore() throws -> ClipStore {
        let queue = try OverboardDatabase.openInMemory()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("overboard-cli-\(UUID().uuidString)", isDirectory: true)
        let blobs = try BlobStore(directory: dir)
        return ClipStore(dbWriter: queue, blobs: blobs)
    }

    private func textSnapshot(_ text: String) -> PasteboardSnapshot {
        PasteboardSnapshot(
            reps: [.init(uti: WellKnownUTI.plainText, data: Data(text.utf8))],
            sourceBundleID: "com.apple.TextEdit",
            sourceAppName: "TextEdit"
        )
    }

    // MARK: - Dispatch

    @Test func dispatchExitCodes() async {
        #expect(await Overboard.run([]) == .usage) // no subcommand
        #expect(await Overboard.run(["help"]) == .ok)
        #expect(await Overboard.run(["--help"]) == .ok)
        #expect(await Overboard.run(["-h"]) == .ok)
        #expect(await Overboard.run(["bogus"]) == .usage) // unknown subcommand
    }

    // MARK: - Flag and argument parsing

    @Test func listOptionsParsing() throws {
        let opts = try ListOptions.parse(["--json", "--limit", "5"])
        #expect(opts.json)
        #expect(opts.limit == 5)

        let defaults = try ListOptions.parse([])
        #expect(!defaults.json)
        #expect(defaults.limit == 100)
    }

    @Test func subcommandsTakeTheirOwnPositionalArguments() throws {
        let search = try Search.parse(["--json", "--limit", "5", "hello", "world"])
        #expect(search.query == ["hello", "world"])
        #expect(search.options.json)
        #expect(search.options.limit == 5)

        #expect(try Get.parse([]).index == nil)
        #expect(try Get.parse(["3", "--json"]).index == "3")
        #expect(try Copy.parse(["--stdin"]).stdin)
        #expect(try Copy.parse(["hello", "there"]).text == ["hello", "there"])
    }

    /// A bad `--limit` used to be silently ignored; ArgumentParser rejects it
    /// instead. Both spellings surface as the same `.usage` (64) the CLI has
    /// always returned for a malformed command line, so scripts branching on
    /// the exit code see no new value — just an error where a wrong limit
    /// previously went unnoticed.
    @Test func badLimitIsAUsageError() async {
        #expect(throws: (any Error).self) { try ListOptions.parse(["--limit", "0"]) }
        #expect(throws: (any Error).self) { try ListOptions.parse(["--limit", "abc"]) }
        #expect(await Overboard.run(["history", "--limit", "abc"]) == .usage)
        #expect(await Overboard.run(["history", "--limit", "0"]) == .usage)
    }

    // MARK: - emitList contract

    @Test func emitListMapsEmptinessToExitCode() {
        #expect(Overboard.emitList([], json: false) == .notFound)
        #expect(Overboard.emitList([], json: true) == .notFound)
    }

    // MARK: - get index math

    @Test func getIndexContract() async throws {
        let store = try self.makeStore()
        for i in 1 ... 3 {
            _ = try await store.ingest(self.textSnapshot("clip \(i)"))
        }

        let options = try ListOptions.parse([])
        // Valid 1-based indices and the default (1) succeed.
        #expect(try await Overboard.get(store: store, index: nil, options: options) == .ok)
        #expect(try await Overboard.get(store: store, index: "1", options: options) == .ok)
        #expect(try await Overboard.get(store: store, index: "3", options: options) == .ok)
        // Out of range is a well-formed request that found nothing.
        #expect(try await Overboard.get(store: store, index: "4", options: options) == .notFound)
        // Malformed indices are usage errors.
        #expect(try await Overboard.get(store: store, index: "0", options: options) == .usage)
        #expect(try await Overboard.get(store: store, index: "abc", options: options) == .usage)
        // "-1" never reaches the body: ArgumentParser reads it as an unknown
        // option, which the root maps to the same `.usage` exit code.
        #expect(throws: (any Error).self) { try Get.parse(["-1"]) }
    }

    @Test func getSkipsSecretsInIndexing() async throws {
        let store = try self.makeStore()
        // A detected secret is filtered from `Output.visible`, so it must not
        // occupy an index — with one secret + one normal clip, only index 1 is
        // reachable.
        _ = try await store.ingest(self.textSnapshot("AKIAIOSFODNN7EXAMPLE")) // secret
        _ = try await store.ingest(self.textSnapshot("ordinary clip"))
        let options = try ListOptions.parse([])
        #expect(try await Overboard.get(store: store, index: "1", options: options) == .ok)
        #expect(try await Overboard.get(store: store, index: "2", options: options) == .notFound)
    }

    // MARK: - search contract

    @Test func searchRequiresAQuery() async throws {
        let store = try self.makeStore()
        let options = try ListOptions.parse([])
        #expect(try await Overboard.search(store: store, query: [], options: options) == .usage)
        #expect(try await Overboard.search(store: store, query: [""], options: options) == .usage)
        // A query with no hits is notFound, not usage.
        #expect(try await Overboard.search(store: store, query: ["nomatch"], options: options) == .notFound)
    }

    // MARK: - Environment recovery detection

    @Test func recoveryErrorsAreRecognized() {
        #expect(Overboard.isRecoveryError(DatabaseError(resultCode: .SQLITE_READONLY_RECOVERY)))
        #expect(Overboard.isRecoveryError(DatabaseError(resultCode: .SQLITE_READONLY_ROLLBACK)))
        #expect(Overboard.isRecoveryError(DatabaseError(resultCode: .SQLITE_READONLY)))
        // An unrelated error is not treated as recoverable.
        #expect(!Overboard.isRecoveryError(DatabaseError(resultCode: .SQLITE_CONSTRAINT)))
    }
}
