import XCTest
@testable import Nexus

/// Stress: large Karpathy-style memory vault → scan → link index → force layout → search.
@MainActor
final class MemoryStressTests: XCTestCase {
    private var vaultURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        vaultURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("nexus-memory-stress-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: vaultURL)
        try await super.tearDown()
    }

    func testNoteSummaryPrefersDescription() {
        let md = """
        ---
        description: Hover summary for graph
        type: concept
        ---
        # Title

        Body that should not win.
        """
        let s = MarkdownParser.noteSummary(from: md)
        XCTAssertEqual(s, "Hover summary for graph")
    }

    func testMemoryVault200() async throws {
        try await runStress(
            noteCount: 200,
            minEdges: 150,
            maxIndexMs: 2_000,
            interactiveSteps: 60,
            maxInteractiveMs: 2_500,
            fullCoolSteps: 300,
            maxFullCoolMs: 12_000
        )
    }

    func testMemoryVault500() async throws {
        try await runStress(
            noteCount: 500,
            minEdges: 400,
            maxIndexMs: 5_000,
            interactiveSteps: 60,
            maxInteractiveMs: 8_000,
            fullCoolSteps: 200,
            maxFullCoolMs: 45_000
        )
    }

    /// Heavier case — index/scan hard-gated; layout reports interactive + cool budgets.
    func testMemoryVault1000() async throws {
        try await runStress(
            noteCount: 1_000,
            minEdges: 800,
            maxIndexMs: 12_000,
            interactiveSteps: 40,
            maxInteractiveMs: 12_000,
            fullCoolSteps: 120,
            maxFullCoolMs: 90_000
        )
    }

    // MARK: - Core stress

    private func runStress(
        noteCount: Int,
        minEdges: Int,
        maxIndexMs: Double,
        interactiveSteps: Int,
        maxInteractiveMs: Double,
        fullCoolSteps: Int,
        maxFullCoolMs: Double
    ) async throws {
        try writeMemoryStressVault(at: vaultURL, noteCount: noteCount)

        let vault = VaultService()
        let tScan0 = CFAbsoluteTimeGetCurrent()
        vault.openVault(at: vaultURL)
        let notes = try await waitForNotes(vault, minCount: noteCount, timeout: 30)
        let scanMs = (CFAbsoluteTimeGetCurrent() - tScan0) * 1000
        XCTAssertGreaterThanOrEqual(notes.count, noteCount, "scan notes")

        // Every note should have a description for hover
        var missingDesc = 0
        for (_, n) in notes {
            let s = n.frontmatter["description"] ?? MarkdownParser.noteSummary(from: n.content)
            if s == nil || s!.isEmpty { missingDesc += 1 }
        }
        XCTAssertEqual(missingDesc, 0, "all notes need description/summary")

        let index = LinkIndex()
        let tIdx0 = CFAbsoluteTimeGetCurrent()
        index.rebuild(from: notes)
        let indexMs = (CFAbsoluteTimeGetCurrent() - tIdx0) * 1000

        let noteNodes = index.graph.nodes.filter { $0.kind == .note }
        XCTAssertGreaterThanOrEqual(noteNodes.count, noteCount)
        XCTAssertGreaterThanOrEqual(index.graph.edges.count, minEdges, "sparse graph?")

        // Summaries on graph nodes
        let withSummary = noteNodes.filter { ($0.summary ?? "").isEmpty == false }.count
        XCTAssertGreaterThan(withSummary, noteCount / 2, "most graph nodes should carry summary")

        // Interactive layout budget (first frames — what the UI needs to feel alive)
        let sim = ForceSimulator()
        sim.load(snapshot: index.graph, preservePositions: [:])
        let tInt0 = CFAbsoluteTimeGetCurrent()
        var intSteps = 0
        while intSteps < interactiveSteps {
            _ = sim.step()
            intSteps += 1
        }
        let interactiveMs = (CFAbsoluteTimeGetCurrent() - tInt0) * 1000

        // Further cool (optional stress of full settle)
        let tCool0 = CFAbsoluteTimeGetCurrent()
        var coolSteps = 0
        while coolSteps < fullCoolSteps {
            let active = sim.step()
            coolSteps += 1
            if !active { break }
        }
        let coolMs = (CFAbsoluteTimeGetCurrent() - tCool0) * 1000
        let layoutMs = interactiveMs + coolMs
        let positions = sim.positions()
        XCTAssertEqual(positions.count, index.graph.nodes.count)

        // Positions finite
        for (_, p) in positions {
            XCTAssertTrue(p.x.isFinite && p.y.isFinite, "NaN/Inf position")
            XCTAssertLessThan(abs(p.x), 50_000)
            XCTAssertLessThan(abs(p.y), 50_000)
        }

        // Search smoke
        let hits = SearchService.search(query: "entity", notes: notes)
        XCTAssertFalse(hits.isEmpty, "search should find entity pages")

        print(
            """
            [MemoryStress] N=\(noteCount)
              scan_ms=\(String(format: "%.1f", scanMs)) notes=\(notes.count)
              index_ms=\(String(format: "%.1f", indexMs)) nodes=\(index.graph.nodes.count) edges=\(index.graph.edges.count) unresolved=\(index.unresolved.count)
              interactive_ms=\(String(format: "%.1f", interactiveMs)) steps=\(intSteps)
              cool_ms=\(String(format: "%.1f", coolMs)) steps=\(coolSteps) alpha=\(String(format: "%.4f", sim.alpha))
              layout_total_ms=\(String(format: "%.1f", layoutMs))
              summaries=\(withSummary)/\(noteNodes.count) search_hits=\(hits.count)
            """
        )

        XCTAssertLessThan(indexMs, maxIndexMs, "index rebuild too slow")
        XCTAssertLessThan(interactiveMs, maxInteractiveMs, "interactive layout ticks too slow")
        XCTAssertLessThan(coolMs, maxFullCoolMs, "full cool layout too slow")
    }

    // MARK: - Vault generator (Karpathy memory shape)

    private func writeMemoryStressVault(at root: URL, noteCount: Int) throws {
        let fm = FileManager.default
        let dirs = [
            "raw/inbox", "raw/receipts", "raw/sessions", "raw/proposals",
            "wiki/user", "wiki/projects", "wiki/decisions", "wiki/concepts", "wiki/entities",
        ]
        for d in dirs {
            try fm.createDirectory(at: root.appendingPathComponent(d), withIntermediateDirectories: true)
        }

        try """
        ---
        description: Stress-test maintainer contract
        ---
        # AGENTS.md

        Memory stress vault. Always set description frontmatter.
        """.write(to: root.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)

        try """
        ---
        description: Operation log for stress vault
        ---
        # log

        ## [2026-07-31 00:00] ingest | Stress bootstrap
        """.write(to: root.appendingPathComponent("log.md"), atomically: true, encoding: .utf8)

        try """
        ---
        type: hot
        description: Always-on brief for stress graph
        ---
        # Hot

        - Active: stress-\(noteCount) notes
        - See [[wiki/index]]
        """.write(to: root.appendingPathComponent("wiki/hot.md"), atomically: true, encoding: .utf8)

        try """
        ---
        description: Catalog of stress wiki pages
        ---
        # Index

        - [[wiki/hot]] — hot brief
        - [[wiki/overview]] — overview
        """.write(to: root.appendingPathComponent("wiki/index.md"), atomically: true, encoding: .utf8)

        try """
        ---
        type: concept
        description: Overview of the stress memory vault
        ---
        # Overview

        Generated stress vault with ~\(noteCount) interlinked notes.
        Hub: [[wiki/hot]] · [[wiki/index]]
        """.write(to: root.appendingPathComponent("wiki/overview.md"), atomically: true, encoding: .utf8)

        // Seed hubs
        var written = 5 // agents, log, hot, index, overview
        let entityTarget = max(noteCount - 40, noteCount / 2)
        let conceptCount = min(30, noteCount / 10)
        let projectCount = min(20, noteCount / 15)
        let sessionCount = min(40, noteCount / 8)

        for i in 0..<projectCount {
            let name = "project-\(i)"
            let links = (0..<3).map { "[[wiki/entities/entity-\((i * 3 + $0) % max(entityTarget, 1))]]" }.joined(separator: " ")
            try """
            ---
            type: project
            description: Stress project \(i) — linked entity hub
            tags: [project, stress]
            updated: 2026-07-31
            ---
            # Project \(i)

            ## Compiled truth
            Synthetic project for graph stress.

            ## Links
            \(links) [[wiki/overview]] [[wiki/hot]]
            """.write(
                to: root.appendingPathComponent("wiki/projects/\(name).md"),
                atomically: true,
                encoding: .utf8
            )
            written += 1
        }

        for i in 0..<conceptCount {
            let name = "concept-\(i)"
            let peers = [i, (i + 1) % conceptCount, (i + 7) % conceptCount]
                .map { "[[wiki/concepts/concept-\($0)]]" }
                .joined(separator: " ")
            try """
            ---
            type: concept
            description: Concept \(i) in the stress ontology
            tags: [concept, stress]
            ---
            # Concept \(i)

            Related: \(peers) [[wiki/projects/project-\(i % max(projectCount, 1))]]
            """.write(
                to: root.appendingPathComponent("wiki/concepts/\(name).md"),
                atomically: true,
                encoding: .utf8
            )
            written += 1
        }

        for i in 0..<entityTarget {
            let name = "entity-\(i)"
            let n1 = (i + 1) % entityTarget
            let n2 = (i + 17) % entityTarget
            let n3 = (i * 3) % entityTarget
            let proj = i % max(projectCount, 1)
            try """
            ---
            type: entity
            description: Entity \(i) — node for graph stress with multi-hop links
            tags: [entity, stress, batch-\(i / 50)]
            updated: 2026-07-31
            ---
            # Entity \(i)

            ## Compiled truth
            Synthetic entity for memory wiki stress testing.

            ## Links
            [[wiki/entities/entity-\(n1)]] [[wiki/entities/entity-\(n2)]] [[wiki/entities/entity-\(n3)]]
            [[wiki/projects/project-\(proj)]] [[wiki/concepts/concept-\(i % max(conceptCount, 1))]]
            [[wiki/index]]
            """.write(
                to: root.appendingPathComponent("wiki/entities/\(name).md"),
                atomically: true,
                encoding: .utf8
            )
            written += 1
        }

        for i in 0..<sessionCount {
            let ent = i % max(entityTarget, 1)
            try """
            ---
            type: session
            description: Session digest \(i) touching entity-\(ent)
            date: 2026-07-31
            ---
            # Session \(i)

            ## Focus
            Worked on [[wiki/entities/entity-\(ent)]] and [[wiki/projects/project-\(i % max(projectCount, 1))]].
            """.write(
                to: root.appendingPathComponent("raw/sessions/2026-07-31-session-\(i).md"),
                atomically: true,
                encoding: .utf8
            )
            written += 1
        }

        // Top up to noteCount if needed
        var extra = 0
        while written < noteCount {
            let i = extra
            try """
            ---
            description: Filler note \(i) for count padding
            tags: [filler]
            ---
            # Filler \(i)

            Link [[wiki/hot]] and [[wiki/entities/entity-\(i % max(entityTarget, 1))]].
            """.write(
                to: root.appendingPathComponent("wiki/entities/filler-\(i).md"),
                atomically: true,
                encoding: .utf8
            )
            written += 1
            extra += 1
        }

        _ = written
    }

    private func waitForNotes(_ vault: VaultService, minCount: Int, timeout: TimeInterval) async throws -> [String: NoteDocument] {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if vault.notes.count >= minCount, !vault.isIndexing {
                return vault.notes
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("timed out waiting for \(minCount) notes; got \(vault.notes.count) indexing=\(vault.isIndexing)")
        return vault.notes
    }
}
