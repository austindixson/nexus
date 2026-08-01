import XCTest
@testable import Nexus

/// End-to-end path: temp vault → scan → link graph → force layout → CRUD → search.
@MainActor
final class EndToEndTests: XCTestCase {
    private var vaultURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        vaultURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("nexus-e2e-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true)
        try writeSampleVault(at: vaultURL)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: vaultURL)
        try await super.tearDown()
    }

    func testVaultScanLinkGraphForceAndSearch() async throws {
        let vault = VaultService()
        vault.openVault(at: vaultURL)

        // fullRescan is async off MainActor — wait for notes
        let notes = try await waitForNotes(vault, minCount: 5, timeout: 5)
        XCTAssertGreaterThanOrEqual(notes.count, 5, "expected sample vault notes")
        XCTAssertNotNil(notes["Welcome.md"])
        XCTAssertNotNil(notes["Projects/Ideas.md"])
        XCTAssertTrue(notes["Welcome.md"]!.tags.contains("meta") || notes["Welcome.md"]!.tags.contains("inbox"))

        // Link index rebuild
        let index = LinkIndex()
        index.rebuild(from: notes)

        let noteNodes = index.graph.nodes.filter { $0.kind == .note }
        XCTAssertGreaterThanOrEqual(noteNodes.count, 5)
        XCTAssertFalse(index.graph.edges.isEmpty, "wikilinks should produce edges")

        // Welcome ↔ Graph View bi-directional edges (via mutual links)
        let edgeIDs = Set(index.graph.edges.map(\.id))
        XCTAssertTrue(
            edgeIDs.contains { $0.contains("Welcome.md") && $0.contains("Graph View.md") },
            "expected Welcome ↔ Graph View edge; got \(edgeIDs)"
        )

        // Unresolved target
        XCTAssertTrue(index.unresolved.contains("Does Not Exist"), "expected unresolved wikilink")

        // Backlinks into Welcome
        let bl = index.backlinks(for: "Welcome.md")
        XCTAssertFalse(bl.isEmpty, "Welcome should have backlinks")
        XCTAssertTrue(bl.contains { $0.sourcePath == "Graph View.md" || $0.sourcePath == "Daily Notes.md" || $0.sourcePath == "Projects/Ideas.md" })

        // Local graph around Welcome
        let local = index.localGraph(
            center: "Welcome.md",
            depth: 1,
            includeTags: false,
            includeUnresolved: true,
            includeOrphans: false
        )
        XCTAssertTrue(local.nodes.contains { $0.id == "Welcome.md" })
        XCTAssertGreaterThan(local.nodes.count, 1)

        // Global graph with query filter
        let filtered = index.globalGraph(
            query: "graph",
            folders: [],
            tagsFilter: [],
            showTags: false,
            showAttachments: false,
            showOrphans: true,
            showUnresolved: false
        )
        XCTAssertTrue(filtered.nodes.allSatisfy {
            $0.label.lowercased().contains("graph") || ($0.path?.lowercased().contains("graph") ?? false)
        })

        // Force layout steps — must not collapse into a speck (Obsidian-like spread).
        let sim = ForceSimulator()
        sim.load(snapshot: index.graph)
        XCTAssertEqual(sim.nodes.count, index.graph.nodes.count)
        var advanced = false
        for _ in 0..<200 {
            if sim.step() { advanced = true }
        }
        XCTAssertTrue(advanced, "simulator should integrate at least one step")
        if let box = sim.boundingBox() {
            let span = max(box.maxX - box.minX, box.maxY - box.minY)
            // With default spring length ~110, a multi-note graph should stay open.
            XCTAssertGreaterThan(span, 40, "layout collapsed (span \(span)); center/spring forces too aggressive")
        } else {
            XCTFail("expected bounding box after layout")
        }
        XCTAssertLessThan(sim.alpha, 1.0, "alpha should decay after steps")

        // Search operators over real notes
        let tagHits = SearchService.search(query: "tag:guide", notes: notes)
        XCTAssertTrue(tagHits.contains { $0.path == "Markdown Guide.md" })

        let pathHits = SearchService.search(query: "path:Projects", notes: notes)
        XCTAssertEqual(pathHits.count, 1)
        XCTAssertEqual(pathHits.first?.path, "Projects/Ideas.md")

        // CRUD: create note with wikilink, rescan, reindex
        let created = vault.createNote(named: "E2E Note", content: """
        # E2E Note

        Links to [[Welcome]]
        #e2e
        """)
        XCTAssertEqual(created, "E2E Note.md")

        let after = try await waitForNotes(vault, minCount: 6, timeout: 5)
        XCTAssertNotNil(after["E2E Note.md"])

        index.rebuild(from: after)
        let welcomeBL = index.backlinks(for: "Welcome.md")
        XCTAssertTrue(
            welcomeBL.contains { $0.sourcePath == "E2E Note.md" },
            "new note should backlink Welcome"
        )

        // Preview pipeline on real guide content
        let guide = after["Markdown Guide.md"]!
        let html = MarkdownParser.renderBodyHTML(guide.content)
        XCTAssertTrue(html.contains("callout") || html.contains("table") || html.contains("md-table"), html)
        let full = MarkdownParser.renderPreviewHTML(guide.content, title: guide.title)
        XCTAssertTrue(full.contains("katex.min.js"), full)

        // Workspace snapshot round-trip (encode/decode only — no live AppState window)
        let snap = WorkspaceService.Snapshot(
            mainMode: MainMode.graph.rawValue,
            editorMode: EditorMode.split.rawValue,
            showLeftSidebar: true,
            showRightSidebar: false,
            leftSidebarTab: LeftSidebarTab.files.rawValue,
            rightSidebarTab: RightSidebarTab.backlinks.rawValue,
            selectedPath: "Welcome.md",
            openTabs: ["Welcome.md", "Graph View.md"],
            graphMode: GraphViewMode.global.rawValue,
            graphLocalDepth: 2,
            graphShowTags: true,
            graphShowOrphans: false,
            graphShowUnresolved: true,
            graphShowAttachments: false,
            graphQuery: "test",
            graphColorBy: GraphColorMode.folder.rawValue,
            graphLabels: GraphLabelMode.hover.rawValue,
            useMetalGraph: true,
            appearance: AppAppearance.dark.rawValue,
            windowFrame: nil
        )
        let data = try JSONEncoder().encode(snap)
        let decoded = try JSONDecoder().decode(WorkspaceService.Snapshot.self, from: data)
        XCTAssertEqual(decoded, snap)

        vault.closeVault()
        XCTAssertFalse(vault.isOpen)
        XCTAssertEqual(vault.notes.count, 0)
    }

    // MARK: - Helpers

    private func writeSampleVault(at root: URL) throws {
        let files: [String: String] = [
            "Welcome.md": """
            ---
            tags: [meta, welcome]
            ---
            # Welcome to Nexus

            See [[Graph View]] and [[Daily Notes]] and [[Markdown Guide]].
            Also unresolved: [[Does Not Exist]].

            #inbox
            """,
            "Graph View.md": """
            # Graph View

            Related: [[Welcome]] and [[Markdown Guide]].
            """,
            "Daily Notes.md": """
            # Daily Notes

            Related: [[Welcome]]
            """,
            "Markdown Guide.md": """
            # Markdown Guide

            ## Callouts
            > [!tip] Live preview
            > Tables and callouts.

            | Feature | Status |
            | --- | :---: |
            | Wikilinks | yes |
            | Graph | yes |

            Inline $E = mc^2$

            Tags: #guide #markdown
            """,
            "Projects/Ideas.md": """
            # Ideas

            Link back to [[Welcome]]
            #project
            """,
        ]

        let fm = FileManager.default
        for (rel, body) in files {
            let url = root.appendingPathComponent(rel)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try body.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func waitForNotes(_ vault: VaultService, minCount: Int, timeout: TimeInterval) async throws -> [String: NoteDocument] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if vault.notes.count >= minCount, !vault.isIndexing {
                return vault.notes
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("timed out waiting for \(minCount) notes; got \(vault.notes.count) indexing=\(vault.isIndexing)")
        return vault.notes
    }
}
