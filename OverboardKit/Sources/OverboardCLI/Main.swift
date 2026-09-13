import AppKit
import ArgumentParser
import Foundation
import GRDB
import OverboardCore

/// Exit codes are part of the CLI contract — scripts branch on them. They're
/// `Error`s so a subcommand can throw one out of `run()` and the root can turn
/// it back into a process status.
enum ExitCode: Int32, Error {
    /// Success.
    case ok = 0
    /// A well-formed request that found nothing (empty history, index out of
    /// range, no search hits).
    case notFound = 1
    /// The environment isn't ready: no database, schema drift, or a hot WAL
    /// left behind by an app crash.
    case environment = 2
    /// The command line itself was wrong (unknown subcommand, bad flag).
    /// Matches ArgumentParser's own validation-failure status, so its parse
    /// errors and our hand-written ones report the same thing.
    case usage = 64
}

@main
enum Main {
    static func main() async {
        let code = await Overboard.run(Array(CommandLine.arguments.dropFirst()))
        exit(code.rawValue)
    }
}

struct Overboard: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "overboard",
        abstract: "Drive the Overboard clipboard manager from the shell.",
        discussion: """
        Reads open the app's database read-only; secrets are never printed.
        `copy` sets the system clipboard directly — run the app to capture it \
        into history.
        """,
        subcommands: [History.self, Search.self, Get.self, Copy.self]
    )

    /// `overboard` with no subcommand is a malformed command line, not a help
    /// request — ArgumentParser's default would exit 0, and scripts rely on 64.
    func run() async throws {
        FileHandle.standardError.printLine(Overboard.helpMessage())
        throw ExitCode.usage
    }

    /// Parses and runs `args`, mapping every outcome onto the documented exit
    /// codes. Kept separate from `Main.main()` so tests can drive the whole
    /// command line without spawning a process.
    static func run(_ args: [String]) async -> ExitCode {
        do {
            var command = try self.parseAsRoot(args)
            if var asyncCommand = command as? AsyncParsableCommand {
                try await asyncCommand.run()
            } else {
                try command.run()
            }
            return .ok
        } catch let code as ExitCode {
            return code
        } catch {
            // ArgumentParser's own errors: a help request is a success that
            // prints to stdout, anything else is a usage error on stderr.
            let isHelp = self.exitCode(for: error) == .success
            let message = self.fullMessage(for: error)
            if !message.isEmpty {
                (isHelp ? FileHandle.standardOutput : FileHandle.standardError).printLine(message)
            }
            return isHelp ? .ok : .usage
        }
    }

    // MARK: - Read-command scaffolding

    /// Opens the store read-only, hands it to `body`, and turns open failures
    /// into friendly stderr messages with the right exit code. Every read
    /// command routes through here so the environment handling lives once.
    static func runReading(
        _ body: (ClipStore) async throws -> ExitCode
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
            return try await body(store)
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

    // MARK: - Command bodies

    //
    // Static functions over an injected store, so the tests can exercise the
    // exit-code contract without touching a real database.

    static func history(store: ClipStore, options: ListOptions) async throws -> ExitCode {
        let items = try await Output.visible(store.recent(limit: options.limit))
        return self.emitList(items, json: options.json)
    }

    static func search(store: ClipStore, query words: [String], options: ListOptions) async throws -> ExitCode {
        let query = words.joined(separator: " ")
        guard !query.isEmpty else {
            FileHandle.standardError.printLine("overboard: search requires a query")
            return .usage
        }
        let items = try await Output.visible(store.search(query, limit: options.limit))
        return self.emitList(items, json: options.json)
    }

    static func get(store: ClipStore, index requested: String?, options: ListOptions) async throws -> ExitCode {
        // Default to the most recent clip. The positional arg is the 1-based
        // index into the non-secret recents.
        let index: Int
        if let requested {
            guard let parsed = Int(requested), parsed >= 1 else {
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

    static func copy(stdin wantsStdin: Bool, text positional: [String]) -> ExitCode {
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
}

// MARK: - Subcommands

/// The flags every read command shares. Each command adds its own positional
/// argument, so `--help` describes what that command actually takes.
struct ListOptions: ParsableArguments {
    @Option(name: .long, help: "Maximum number of clips to consider.")
    var limit: Int = 100

    @Flag(name: .long, help: "Emit the stable JSON projection instead of text.")
    var json = false

    func validate() throws {
        guard self.limit > 0 else {
            throw ValidationError("--limit must be a positive integer")
        }
    }
}

struct History: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Recent clips, newest/most-used first."
    )

    @OptionGroup var options: ListOptions

    func run() async throws {
        try await Overboard.finish(Overboard.runReading { store in
            try await Overboard.history(store: store, options: self.options)
        })
    }
}

struct Search: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Search clips (supports the kind: and app: operators)."
    )

    @OptionGroup var options: ListOptions

    @Argument(help: ArgumentHelp("Words to search for.", valueName: "query"))
    var query: [String] = []

    func run() async throws {
        try await Overboard.finish(Overboard.runReading { store in
            try await Overboard.search(store: store, query: self.query, options: self.options)
        })
    }
}

struct Get: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Print the Nth recent clip (default 1) to stdout."
    )

    @OptionGroup var options: ListOptions

    @Argument(help: ArgumentHelp("1-based index into the recent clips.", valueName: "n"))
    var index: String?

    func run() async throws {
        try await Overboard.finish(Overboard.runReading { store in
            try await Overboard.get(store: store, index: self.index, options: self.options)
        })
    }
}

struct Copy: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Set the clipboard from arguments or stdin."
    )

    @Flag(name: .long, help: "Read the text from stdin.")
    var stdin = false

    @Argument(help: ArgumentHelp("The text to copy.", valueName: "text"))
    var text: [String] = []

    func run() throws {
        try Overboard.finish(Overboard.copy(stdin: self.stdin, text: self.text))
    }
}

extension Overboard {
    /// Subcommands report through the shared `ExitCode`; anything but success
    /// is thrown so the root can turn it into the process's status.
    static func finish(_ code: ExitCode) throws {
        guard code == .ok else { throw code }
    }
}

extension FileHandle {
    /// Write a line + newline. Keeps call sites terse and avoids `print`, which
    /// can't target stderr without ceremony.
    func printLine(_ string: String) {
        self.write(Data((string + "\n").utf8))
    }
}
