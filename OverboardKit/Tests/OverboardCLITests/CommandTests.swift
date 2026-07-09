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

    // MARK: - ListOptions parsing

    @Test func listOptionsParsing() {
        let opts = ListOptions(["--json", "--limit", "5", "hello", "world"])
        #expect(opts.json)
        #expect(opts.limit == 5)
        #expect(opts.positional == ["hello", "world"])

        // Defaults, and a bad --limit value is ignored (keeps the default).
        let defaults = ListOptions([])
        #expect(!defaults.json)
        #expect(defaults.limit == 100)
        #expect(defaults.positional.isEmpty)
        #expect(ListOptions(["--limit", "0"]).limit == 100) // non-positive rejected
        #expect(ListOptions(["--limit", "abc"]).limit == 100) // non-numeric rejected
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

        // Valid 1-based indices and the default (1) succeed.
        #expect(try await Overboard.get(store: store, args: []) == .ok)
        #expect(try await Overboard.get(store: store, args: ["1"]) == .ok)
        #expect(try await Overboard.get(store: store, args: ["3"]) == .ok)
        // Out of range is a well-formed request that found nothing.
        #expect(try await Overboard.get(store: store, args: ["4"]) == .notFound)
        // Malformed indices are usage errors.
        #expect(try await Overboard.get(store: store, args: ["0"]) == .usage)
        #expect(try await Overboard.get(store: store, args: ["-1"]) == .usage)
        #expect(try await Overboard.get(store: store, args: ["abc"]) == .usage)
    }

    @Test func getSkipsSecretsInIndexing() async throws {
        let store = try self.makeStore()
        // A detected secret is filtered from `Output.visible`, so it must not
        // occupy an index — with one secret + one normal clip, only index 1 is
        // reachable.
        _ = try await store.ingest(self.textSnapshot("AKIAIOSFODNN7EXAMPLE")) // secret
        _ = try await store.ingest(self.textSnapshot("ordinary clip"))
        #expect(try await Overboard.get(store: store, args: ["1"]) == .ok)
        #expect(try await Overboard.get(store: store, args: ["2"]) == .notFound)
    }

    // MARK: - search contract

    @Test func searchRequiresAQuery() async throws {
        let store = try self.makeStore()
        #expect(try await Overboard.search(store: store, args: []) == .usage)
        #expect(try await Overboard.search(store: store, args: ["--json"]) == .usage)
        // A query with no hits is notFound, not usage.
        #expect(try await Overboard.search(store: store, args: ["nomatch"]) == .notFound)
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
