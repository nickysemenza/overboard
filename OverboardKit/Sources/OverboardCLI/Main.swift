import AppKit
import Foundation
import GRDB
import OverboardCore

/// Exit codes are part of the CLI contract — scripts branch on them.
enum ExitCode: Int32 {
    /// Success.
    case ok = 0
    /// A well-formed request that found nothing (empty history, index out of
    /// range, no search hits).
    case notFound = 1
    /// The environment isn't ready: no database, schema drift, or a hot WAL
    /// left behind by an app crash.
    case environment = 2
    /// The command line itself was wrong (unknown subcommand, bad flag).
    case usage = 64
}

@main
struct Overboard {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        let code = await self.run(args)
        exit(code.rawValue)
    }

    static func run(_ args: [String]) async -> ExitCode {
        guard let command = args.first else {
            self.printUsage(to: FileHandle.standardError)
            return .usage
        }

        switch command {
        case "help", "--help", "-h":
            self.printUsage(to: FileHandle.standardOutput)
            return .ok
        case "history":
            return await self.runReading(Array(args.dropFirst())) { store, rest in
                try await self.history(store: store, args: rest)
            }
        case "search":
            return await self.runReading(Array(args.dropFirst())) { store, rest in
                try await self.search(store: store, args: rest)
            }
        case "get":
            return await self.runReading(Array(args.dropFirst())) { store, rest in
                try await self.get(store: store, args: rest)
            }
        case "copy":
            return self.copy(args: Array(args.dropFirst()))
        default:
            FileHandle.standardError.printLine("overboard: unknown command '\(command)'")
            self.printUsage(to: FileHandle.standardError)
            return .usage
        }
    }

    // MARK: - Read-command scaffolding

    /// Opens the store read-only, hands it to `body`, and turns open failures
    /// into friendly stderr messages with the right exit code. Every read
    /// command routes through here so the environment handling lives once.
    static func runReading(
        _ args: [String],
        _ body: (ClipStore, [String]) async throws -> ExitCode
    ) async -> ExitCode {
        let store: ClipStore
        do {
            let dir = try OverboardDatabase.defaultDirectory()
            let pool = try OverboardDatabase.openReadOnly(at: dir)
            let blobs = try BlobStore(directory: dir.appendingPathComponent("blobs", isDirectory: true))
            store = ClipStore(dbWriter: pool, blobs: blobs)
        } catch let error as OverboardDatabase.ReadOnlyOpenError {
            FileHandle.standardError.printLine("overboard: \(error)")
            return .environment
        } catch let error as DatabaseError where self.isRecoveryError(error) {
            FileHandle.standardError.printLine(
                "overboard: the database needs recovery — launch Overboard once to recover the database."
            )
            return .environment
        } catch {
            FileHandle.standardError.printLine("overboard: \(error.localizedDescription)")
            return .environment
        }

        do {
            return try await body(store, args)
        } catch {
            FileHandle.standardError.printLine("overboard: \(error.localizedDescription)")
            return .environment
        }
    }

    /// A hot WAL after an app crash surfaces as SQLITE_READONLY_RECOVERY /
    /// SQLITE_READONLY_ROLLBACK on a read-only open — the file can't be
    /// recovered without a writer.
    static func isRecoveryError(_ error: DatabaseError) -> Bool {
        error.resultCode == .SQLITE_READONLY_RECOVERY
            || error.resultCode == .SQLITE_READONLY_ROLLBACK
            || error.resultCode == .SQLITE_READONLY
    }

    // MARK: - Commands

    static func history(store: ClipStore, args: [String]) async throws -> ExitCode {
        let options = ListOptions(args)
        let items = try await Output.visible(store.recent(limit: options.limit))
        return self.emitList(items, json: options.json)
    }

    static func search(store: ClipStore, args: [String]) async throws -> ExitCode {
        let options = ListOptions(args)
        let query = options.positional.joined(separator: " ")
        guard !query.isEmpty else {
            FileHandle.standardError.printLine("overboard: search requires a query")
            return .usage
        }
        let items = try await Output.visible(store.search(query, limit: options.limit))
        return self.emitList(items, json: options.json)
    }

    static func get(store: ClipStore, args: [String]) async throws -> ExitCode {
        let options = ListOptions(args)
        // Default to the most recent clip. A single positional arg is the
        // 1-based index into the non-secret recents.
        let index: Int
        if let first = options.positional.first {
            guard let parsed = Int(first), parsed >= 1 else {
                FileHandle.standardError.printLine("overboard: get expects a positive index")
                return .usage
            }
            index = parsed
        } else {
            index = 1
        }

        // Pull enough recents to cover the requested index after secret filtering.
        let recents = try await Output.visible(store.recent(limit: max(index, options.limit)))
        guard index <= recents.count else {
            FileHandle.standardError.printLine("overboard: no clip at index \(index)")
            return .notFound
        }
        let item = recents[index - 1]

        if options.json {
            try FileHandle.standardOutput.printLine(Output.jsonObject(item))
            return .ok
        }

        switch item.kind {
        case .image:
            // No binary on stdout — the preview text ("Image W×H") is the
            // useful, scriptable handle.
            FileHandle.standardOutput.printLine(item.previewText ?? "Image")
        case .file:
            let paths = try await store.filePaths(for: item.id)
            if paths.isEmpty {
                FileHandle.standardOutput.printLine(item.previewText ?? "")
            } else {
                FileHandle.standardOutput.printLine(paths.joined(separator: "\n"))
            }
        case .text, .link, .color:
            let text = try await store.plainText(for: item.id) ?? item.previewText ?? ""
            // No trailing decoration — this is meant to be piped.
            FileHandle.standardOutput.write(Data(text.utf8))
        }
        return .ok
    }

    static func copy(args: [String]) -> ExitCode {
        let wantsStdin = args.contains("--stdin")
        let positional = args.filter { $0 != "--stdin" }

        let text: String
        if wantsStdin || (positional.isEmpty && isatty(0) == 0) {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            guard let decoded = String(data: data, encoding: .utf8) else {
                FileHandle.standardError.printLine("overboard: stdin was not valid UTF-8")
                return .usage
            }
            text = decoded
        } else if !positional.isEmpty {
            text = positional.joined(separator: " ")
        } else {
            FileHandle.standardError.printLine("overboard: copy needs text, or pipe stdin / pass --stdin")
            return .usage
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        FileHandle.standardError.printLine(
            "Copied to the clipboard. History capture requires the Overboard app to be running."
        )
        return .ok
    }

    // MARK: - Emitting

    static func emitList(_ items: [ClipItem], json: Bool) -> ExitCode {
        if json {
            do {
                try FileHandle.standardOutput.printLine(Output.jsonArray(items))
            } catch {
                FileHandle.standardError.printLine("overboard: \(error.localizedDescription)")
                return .environment
            }
        } else if !items.isEmpty {
            FileHandle.standardOutput.printLine(Output.textList(items))
        }
        return items.isEmpty ? .notFound : .ok
    }

    // MARK: - Usage

    static func printUsage(to handle: FileHandle) {
        handle.printLine(
            """
            overboard — drive the Overboard clipboard manager from the shell.

            USAGE:
              overboard history [--limit N] [--json]   Recent clips, newest/most-used first
              overboard search <query> [--limit N] [--json]
                                                       Search clips (supports kind: and app: operators)
              overboard get [N] [--json]               Print the Nth recent clip (default 1) to stdout
              overboard copy [text…] [--stdin]         Set the clipboard from args or stdin
              overboard help                           Show this help

            Reads open the app's database read-only; secrets are never printed.
            `copy` sets the system clipboard directly — run the app to capture it into history.
            """
        )
    }
}

/// Shared flag parsing for the list-style commands: `--limit N`, `--json`, and
/// whatever positional words remain (the search query, the get index).
struct ListOptions {
    var limit: Int = 100
    var json = false
    var positional: [String] = []

    init(_ args: [String]) {
        var iterator = args.makeIterator()
        while let arg = iterator.next() {
            switch arg {
            case "--json":
                self.json = true
            case "--limit":
                if let value = iterator.next(), let parsed = Int(value), parsed > 0 {
                    self.limit = parsed
                }
            default:
                self.positional.append(arg)
            }
        }
    }
}

extension FileHandle {
    /// Write a line + newline. Keeps call sites terse and avoids `print`, which
    /// can't target stderr without ceremony.
    func printLine(_ string: String) {
        self.write(Data((string + "\n").utf8))
    }
}
