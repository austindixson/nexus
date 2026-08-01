import XCTest
@testable import Nexus

final class MarkdownParserTests: XCTestCase {
    func testWikiLinksAndAliases() {
        let md = "See [[Welcome]] and [[Graph View|the graph]] and ![[Embed]]"
        let links = MarkdownParser.extractWikiLinks(from: md)
        XCTAssertEqual(links.count, 3)
        XCTAssertEqual(links[0].target, "Welcome")
        XCTAssertFalse(links[0].isEmbed)
        XCTAssertEqual(links[1].alias, "the graph")
        XCTAssertTrue(links[2].isEmbed)
    }

    func testTagsAndFrontmatter() {
        let md = """
        ---
        title: Hello
        tags: [a, b]
        ---
        Body #c #inbox/later
        """
        let (meta, _) = MarkdownParser.parseFrontmatter(md)
        XCTAssertEqual(meta["title"], "Hello")
        let tags = MarkdownParser.extractTags(from: md, frontmatter: meta)
        XCTAssertTrue(tags.contains("a"))
        XCTAssertTrue(tags.contains("c"))
        XCTAssertTrue(tags.contains("inbox/later"))
    }

    func testHeadings() {
        let md = "# H1\n## H2\n### H3"
        let h = MarkdownParser.extractHeadings(from: md)
        XCTAssertEqual(h.map(\.level), [1, 2, 3])
    }

    func testResolveLink() {
        let known: Set<String> = ["Welcome.md", "Projects/Ideas.md"]
        XCTAssertEqual(
            MarkdownParser.resolveLinkTarget("Welcome", from: "x.md", knownPaths: known),
            "Welcome.md"
        )
        XCTAssertEqual(
            MarkdownParser.resolveLinkTarget("Ideas", from: "x.md", knownPaths: known),
            "Projects/Ideas.md"
        )
    }
}

final class PreviewRendererTests: XCTestCase {
    func testGFMTable() {
        let md = """
        | Name | Score |
        | --- | ---: |
        | Ada | 10 |
        | Lin | 8 |
        """
        let html = MarkdownParser.renderBodyHTML(md)
        XCTAssertTrue(html.contains("<table class=\"md-table\">"), html)
        XCTAssertTrue(html.contains("<th"), html)
        XCTAssertTrue(html.contains("Ada"), html)
        XCTAssertTrue(html.contains("align-right") || html.contains("Score"), html)
    }

    func testObsidianCallout() {
        let md = """
        > [!tip] Pro tip
        > Use [[wikilinks]] in callouts.
        """
        let html = MarkdownParser.renderBodyHTML(md)
        XCTAssertTrue(html.contains("class=\"callout\""), html)
        XCTAssertTrue(html.contains("data-type=\"tip\""), html)
        XCTAssertTrue(html.contains("Pro tip"), html)
        XCTAssertTrue(html.contains("wikilink"), html)
    }

    func testPlainBlockquote() {
        let md = "> quoted text with **bold**"
        let html = MarkdownParser.renderBodyHTML(md)
        XCTAssertTrue(html.contains("<blockquote>"), html)
        XCTAssertTrue(html.contains("<strong>bold</strong>"), html)
    }

    func testTaskAndOrderedLists() {
        let md = """
        - [x] done
        - [ ] todo

        1. first
        2. second
        """
        let html = MarkdownParser.renderBodyHTML(md)
        XCTAssertTrue(html.contains("task done"), html)
        XCTAssertTrue(html.contains("<ol>"), html)
        XCTAssertTrue(html.contains("first"), html)
    }

    func testMathExtraction() {
        let md = """
        Einstein: $E=mc^2$

        $$
        a^2 + b^2 = c^2
        $$
        """
        let html = MarkdownParser.renderBodyHTML(md)
        XCTAssertTrue(html.contains("math-inline"), html)
        XCTAssertTrue(html.contains("math-display"), html)
        XCTAssertTrue(html.contains("E=mc^2") || html.contains("E=mc"), html)
        let full = MarkdownParser.renderPreviewHTML(md, title: "Math")
        XCTAssertTrue(full.contains("katex.min.js"), full)
    }
}

final class SearchServiceTests: XCTestCase {
    func testOperators() {
        let notes: [String: NoteDocument] = [
            "a.md": NoteDocument(
                id: "a.md", title: "Alpha", content: "hello world #tag1",
                absoluteURL: URL(fileURLWithPath: "/tmp/a.md"), modified: Date(),
                frontmatter: [:], tags: ["tag1"], outgoingLinks: [], headings: []
            ),
            "folder/b.md": NoteDocument(
                id: "folder/b.md", title: "Beta", content: "other",
                absoluteURL: URL(fileURLWithPath: "/tmp/b.md"), modified: Date(),
                frontmatter: [:], tags: [], outgoingLinks: [], headings: []
            ),
        ]
        let byTag = SearchService.search(query: "tag:tag1", notes: notes)
        XCTAssertEqual(byTag.count, 1)
        XCTAssertEqual(byTag.first?.path, "a.md")

        let byPath = SearchService.search(query: "path:folder", notes: notes)
        XCTAssertEqual(byPath.count, 1)
        XCTAssertEqual(byPath.first?.path, "folder/b.md")
    }
}

@MainActor
final class BacklinkSnippetTests: XCTestCase {
    func testContextSkipsFrontmatterAndDoesNotMidWordCut() {
        let welcome = """
        ---
        tags: [meta, welcome]
        ---
        # Welcome to Nexus

        See [[Graph View]] and [[Daily Notes]] and [[Markdown Guide]].
        """
        let links = MarkdownParser.extractWikiLinks(from: welcome)
        let notes: [String: NoteDocument] = [
            "Welcome.md": NoteDocument(
                id: "Welcome.md", title: "Welcome", content: welcome,
                absoluteURL: URL(fileURLWithPath: "/tmp/Welcome.md"), modified: Date(),
                frontmatter: ["tags": "[meta, welcome]"], tags: ["meta", "welcome"],
                outgoingLinks: links, headings: []
            ),
            "Graph View.md": NoteDocument(
                id: "Graph View.md", title: "Graph View", content: "# Graph View\n",
                absoluteURL: URL(fileURLWithPath: "/tmp/Graph View.md"), modified: Date(),
                frontmatter: [:], tags: [], outgoingLinks: [], headings: []
            ),
        ]
        let index = LinkIndex()
        index.rebuild(from: notes)
        let bl = index.backlinks(for: "Graph View.md")
        XCTAssertFalse(bl.isEmpty)
        let ctx = bl[0].context
        // No YAML junk like "a, welcome]"
        XCTAssertFalse(ctx.contains("tags:"), ctx)
        XCTAssertFalse(ctx.contains("a, welcome"), ctx)
        XCTAssertFalse(ctx.hasPrefix("---"), ctx)
        // Should mention the link / surrounding prose
        XCTAssertTrue(ctx.localizedCaseInsensitiveContains("Graph View") || ctx.localizedCaseInsensitiveContains("See"), ctx)
        // Word-boundary trim: never end mid-token like "Markdown Guid"
        XCTAssertFalse(ctx.hasSuffix("Guid"), ctx)
        XCTAssertFalse(ctx.hasSuffix("Markdow"), ctx)
    }
}
