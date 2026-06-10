import Foundation
@testable import OverboardCore
import Testing

struct MarkdownDetectorTests {
    @Test func detectsHeadingsWithList() {
        let text = """
        ## Release notes

        - Markdown previews
        - Debounced search
        """
        #expect(MarkdownDetector.looksLikeMarkdown(text))
    }

    @Test func detectsFencedReadme() {
        let text = """
        # Overboard

        Install with:

        ```sh
        brew install overboard
        ```
        """
        #expect(MarkdownDetector.looksLikeMarkdown(text))
    }

    @Test func detectsLinksWithBold() {
        let text = """
        **Highlights** of this release:
        See [the changelog](https://example.com/changelog) for details.
        """
        #expect(MarkdownDetector.looksLikeMarkdown(text))
    }

    @Test func detectsTableWithHeading() {
        let text = """
        ### Comparison

        | Feature | Status |
        | ------- | ------ |
        | Search  | Done   |
        """
        #expect(MarkdownDetector.looksLikeMarkdown(text))
    }

    @Test func rejectsSingleLine() {
        #expect(!MarkdownDetector.looksLikeMarkdown("# not a document"))
        #expect(!MarkdownDetector.looksLikeMarkdown("- single bullet"))
    }

    @Test func rejectsPlainProse() {
        let text = """
        Standup notes — Tuesday
        - Ship the drawer entrance animation behind a reduced-motion check
        - Migrate search to FTS5 trigram tokenizer, re-index on launch
        - Alex to write up paste-stack edge cases before Thursday
        """
        #expect(!MarkdownDetector.looksLikeMarkdown(text))
    }

    @Test func rejectsSwiftCode() {
        let text = """
        func debounce<T>(_ delay: Duration, _ values: AsyncStream<T>) -> AsyncStream<T> {
            AsyncStream { continuation in
                let task = Task {
                    for await value in values {
                        continuation.yield(value)
                    }
                }
            }
        }
        """
        #expect(!MarkdownDetector.looksLikeMarkdown(text))
    }

    @Test func rejectsJSON() {
        let text = """
        {
            "name": "overboard",
            "version": "1.4.0",
            "private": true
        }
        """
        #expect(!MarkdownDetector.looksLikeMarkdown(text))
    }

    @Test func rejectsShellOutput() {
        let text = """
        $ swift test --package-path OverboardKit
        Build complete! (1.08s)
        Test run with 97 tests passed
        """
        #expect(!MarkdownDetector.looksLikeMarkdown(text))
    }
}
