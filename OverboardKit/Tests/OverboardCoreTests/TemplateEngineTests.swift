import Foundation
@testable import OverboardCore
import Synchronization
import Testing

struct TemplateEngineTests {
    @Test func preservesAllLegacyPlaceholdersAndDateFormatting() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let body = "{date} / {time} / {datetime} / {uuid} / {clipboard} / {unknown}"
        let context = TemplateEngine.Context(now: now, clipboard: "{date}", uuid: { "fixed-uuid" })
        #expect(try TemplateEngine.expand(body, context: context) == SnippetTemplate.expand(
            body, now: now, clipboard: "{date}", uuid: { "fixed-uuid" }
        ))
    }

    @Test func namedArgumentsDefaultsAndExplicitEmptyValues() throws {
        let body = "Hello {{name}} from {{city|London}}! {{name}}"
        #expect(TemplateEngine.arguments(in: body).map(\.name) == ["name", "city"])
        #expect(try TemplateEngine.expand(body, arguments: ["name": "Nicky"]) == "Hello Nicky from London! Nicky")
        #expect(try TemplateEngine.expand(body, arguments: ["name": "", "city": ""]) == "Hello  from ! ")
    }

    @Test func missingArgumentsThrowBeforeUUIDGeneration() {
        let context = TemplateEngine.Context(uuid: { Issue.record("UUID generated before validation"); return "bad" })
        #expect(throws: TemplateEngine.Error.missingArguments(["name"])) {
            try TemplateEngine.expand("{uuid} {{name}}", context: context)
        }
    }

    @Test func previewNeverGeneratesUUIDsAndKeepsUnresolvedTokensVisible() {
        let context = TemplateEngine.Context(uuid: { Issue.record("Preview generated UUID"); return "bad" })
        #expect(TemplateEngine.preview("{uuid} {clipboard} {{name}} {{city|London}}", context: context)
            == "{uuid} {clipboard} {{name}} London")
    }

    @Test func formattedDateUsesCapturedContext() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let context = TemplateEngine.Context(now: now, clipboard: "captured")
        #expect(try TemplateEngine.expand("{{date:yyyy}} {clipboard}", context: context) == "2023 captured")
    }

    @Test func argumentsAreNotRecursivelyExpanded() throws {
        #expect(try TemplateEngine.expand("{{name}}", arguments: ["name": "{uuid} {{other}}"])
            == "{uuid} {{other}}")
    }

    @Test(arguments: ["{uuid} {uuid}", "{uuid} {uuid} {{name|default}}"])
    func eachLegacyUUIDOccurrenceGeneratesFreshValue(body: String) throws {
        let counter = Mutex(0)
        let context = TemplateEngine.Context(uuid: {
            counter.withLock { value in
                value += 1
                return "uuid-\(value)"
            }
        })
        let expanded = try TemplateEngine.expand(body, context: context)
        #expect(expanded.hasPrefix("uuid-1 uuid-2"))
        #expect(counter.withLock { $0 } == 2)
    }

    @Test func invocationCapturesDistinctUUIDsOnceForStablePreviewsAndPublication() throws {
        let counter = Mutex(0)
        let context = TemplateEngine.Context(now: Date(timeIntervalSince1970: 1_700_000_000),
                                             clipboard: "captured {uuid}", uuid: {
                                                 counter.withLock { value in
                                                     value += 1
                                                     return "uuid-\(value)"
                                                 }
                                             })
        let invocation = TemplateEngine.Invocation("{uuid} {uuid} {{name}} {{date:yyyy}} {clipboard}", context: context)
        let first = "uuid-1 uuid-2 Nicky 2023 captured {uuid}"
        #expect(invocation.preview(arguments: ["name": "Nicky"]) == first)
        #expect(invocation.preview(arguments: ["name": "Nicky"]) == first)
        #expect(try invocation.expand(arguments: ["name": "Nicky"]) == first)
        #expect(invocation.preview(arguments: ["name": "Other"]) == "uuid-1 uuid-2 Other 2023 captured {uuid}")
        #expect(counter.withLock { $0 } == 2)
    }

    @Test func invocationRetainsLegacyFormattingAndUnresolvedPreviewTokens() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let body = "{date} / {time} / {datetime} / {clipboard} / {unknown}"
        let context = TemplateEngine.Context(now: now, clipboard: "{date}")
        let invocation = TemplateEngine.Invocation(body, context: context)
        #expect(try invocation.expand() == SnippetTemplate.expand(body, now: now, clipboard: "{date}"))
        let required = TemplateEngine.Invocation("{{name}} {clipboard}", context: .init(now: now))
        #expect(required.preview() == "{{name}} {clipboard}")
        #expect(throws: TemplateEngine.FormatError.missingArguments(["name"])) { try required.expand() }
    }

    @Test(arguments: ["{uuid} {uuid}", "{uuid} {uuid} {{name|default}}"])
    func capturedContextReusesUUIDPositionsAcrossPreviewAndCommit(body: String) throws {
        let counter = Mutex(0)
        let context = TemplateEngine.Context.capture(for: body, clipboard: "captured", uuidFactory: {
            counter.withLock { value in
                value += 1
                return "uuid-\(value)"
            }
        })
        let preview = TemplateEngine.preview(body, context: context)
        #expect(preview.hasPrefix("uuid-1 uuid-2"))
        #expect(TemplateEngine.preview(body, context: context) == preview)
        #expect(try TemplateEngine.expand(body, context: context) == preview)
        #expect(try TemplateEngine.expand(body, context: context.captured(for: body)) == preview)
        #expect(counter.withLock { $0 } == 2)
        #expect(SnippetTemplate.expand("{uuid} {uuid}", uuid: context.uuid) == "uuid-3 uuid-4")
    }

    @Test func capturedUUIDPositionsAreNotReusedForADifferentBody() throws {
        let counter = Mutex(0)
        let context = TemplateEngine.Context.capture(for: "{uuid}", uuidFactory: {
            counter.withLock { value in
                value += 1
                return "uuid-\(value)"
            }
        })
        #expect(try TemplateEngine.expand("different {uuid} {uuid}", context: context) == "different uuid-2 uuid-3")
        #expect(TemplateEngine.preview("different {uuid} {uuid}", context: context) == "different {uuid} {uuid}")
    }
}
