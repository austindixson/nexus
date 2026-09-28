import Foundation

/// Studio v1: generate vault-native artifacts (notes / flashcards / mindmap canvas) from selection + retrieval.
enum StudioService {
    enum ArtifactKind: String, CaseIterable, Identifiable {
        case summaryNote
        case flashcards
        case mindMap

        var id: String { rawValue }

        var title: String {
            switch self {
            case .summaryNote: return "Summary note"
            case .flashcards: return "Flashcards"
            case .mindMap: return "Mind map canvas"
            }
        }

        var systemImage: String {
            switch self {
            case .summaryNote: return "doc.richtext"
            case .flashcards: return "rectangle.on.rectangle.angled"
            case .mindMap: return "point.3.connected.trianglepath.dotted"
            }
        }
    }

    enum JobStatus: String {
        case pending
        case processing
        case completed
        case failed
    }

    struct Job: Identifiable {
        let id: UUID
        var kind: ArtifactKind
        var status: JobStatus
        var message: String
        var outputPath: String?
    }

    @MainActor
    static func generate(
        kind: ArtifactKind,
        topic: String,
        notes: [String: NoteDocument],
        index: VaultIndexStore?,
        config: AIConfiguration,
        selectedPath: String?,
        backlinks: [String: [Backlink]],
        vault: VaultService
    ) async throws -> String {
        let provider = config.makeProvider()
        let scope = config.scopeMode
        let allowed = RetrievalService.resolveAllowedPaths(
            scope: scope,
            selectedPath: selectedPath,
            notes: notes,
            backlinks: backlinks
        )
        let passages = RetrievalService.search(
            question: topic.isEmpty ? (selectedPath.map { notes[$0]?.title ?? $0 } ?? "overview") : topic,
            notes: notes,
            index: index,
            allowedPaths: allowed
        )
        let (context, _) = RetrievalService.buildContextBlock(passages: passages)

        let focusTitle = topic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (notes[selectedPath ?? ""]?.title ?? "Studio output")
            : topic

        switch kind {
        case .summaryNote:
            let body: String
            if let provider {
                let prompt = """
                Write a clear Markdown summary note titled "\(focusTitle)".
                Use only the vault passages. Include a ## Sources section with wikilinks like [[Note Title]].
                Passages:
                \(context)
                """
                body = try await provider.complete(
                    AIChatRequest(messages: [
                        AIMessage(role: .system, content: "You write concise Markdown notes for a personal knowledge base."),
                        AIMessage(role: .user, content: prompt),
                    ], temperature: 0.3)
                )
            } else {
                body = offlineSummary(title: focusTitle, passages: passages)
            }
            return try writeGeneratedNote(
                title: "Summary — \(focusTitle)",
                tags: ["studio", "summary"],
                body: body,
                vault: vault
            )

        case .flashcards:
            let body: String
            if let provider {
                let prompt = """
                Create study flashcards from the passages as Markdown.
                Format each card as:
                ### Card N
                **Q:** ...
                **A:** ...
                Produce 8–15 cards. End with ## Sources and [[wikilinks]].
                Topic: \(focusTitle)
                Passages:
                \(context)
                """
                body = try await provider.complete(
                    AIChatRequest(messages: [
                        AIMessage(role: .system, content: "You create high-quality study flashcards in Markdown."),
                        AIMessage(role: .user, content: prompt),
                    ], temperature: 0.35)
                )
            } else {
                body = offlineFlashcards(title: focusTitle, passages: passages)
            }
            return try writeGeneratedNote(
                title: "Flashcards — \(focusTitle)",
                tags: ["studio", "flashcards"],
                body: body,
                vault: vault
            )

        case .mindMap:
            let outline: String
            if let provider {
                let prompt = """
                Extract a mind-map outline for "\(focusTitle)" as nested bullet list (max depth 3).
                Only use the passages. No prose intro.
                Passages:
                \(context)
                """
                outline = try await provider.complete(
                    AIChatRequest(messages: [
                        AIMessage(role: .system, content: "You extract hierarchical outlines."),
                        AIMessage(role: .user, content: prompt),
                    ], temperature: 0.2)
                )
            } else {
                outline = offlineOutline(title: focusTitle, passages: passages)
            }
            return try writeMindMapCanvas(title: focusTitle, outline: outline, vault: vault)
        }
    }

    // MARK: - Writers

    @MainActor
    private static func writeGeneratedNote(
        title: String,
        tags: [String],
        body: String,
        vault: VaultService
    ) throws -> String {
        _ = vault.createFolder(named: "Studio")
        let day: String = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd"
            return f.string(from: Date())
        }()
        let tagList = tags.map { $0 }.joined(separator: ", ")
        let content = """
        ---
        title: \(title)
        generated: \(day)
        tags: [\(tagList)]
        ---

        # \(title)

        \(body.trimmingCharacters(in: .whitespacesAndNewlines))
        """
        let safe = title
            .components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>"))
            .joined(separator: "-")
        guard let path = vault.createNote(named: safe, inFolder: "Studio", content: content) else {
            throw AIError.emptyResponse
        }
        return path
    }

    @MainActor
    private static func writeMindMapCanvas(title: String, outline: String, vault: VaultService) throws -> String {
        guard let root = vault.rootURL else { throw AIError.emptyResponse }
        _ = vault.createFolder(named: "Studio")
        let safe = title
            .components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>"))
            .joined(separator: "-")
        let fileName = "Mindmap — \(safe).canvas"
        let rel = "Studio/\(fileName)"
        let url = root.appendingPathComponent(rel)

        let lines = outline
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var nodes: [CanvasCard] = []
        var edges: [CanvasArrow] = []
        let rootID = UUID().uuidString
        nodes.append(CanvasCard(
            id: rootID, x: 0, y: 0, width: 220, height: 80,
            type: "text", text: title, file: nil, color: "accent"
        ))

        var stack: [(depth: Int, id: String)] = [(0, rootID)]
        var y: Double = 120
        var xByDepth: [Int: Double] = [1: -200, 2: 80, 3: 360]

        for line in lines.prefix(24) {
            var depth = 1
            var text = line
            if let match = line.range(of: #"^(\s*)[-*+]\s+"#, options: .regularExpression) {
                let indent = line[match].filter { $0 == " " }.count
                depth = min(3, max(1, indent / 2 + 1))
                text = String(line[match.upperBound...]).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("#") {
                depth = 1
                text = line.replacingOccurrences(of: #"^#+\s*"#, with: "", options: .regularExpression)
            }
            while let last = stack.last, last.depth >= depth { stack.removeLast() }
            let parent = stack.last?.id ?? rootID
            let id = UUID().uuidString
            let x = xByDepth[depth] ?? Double(depth) * 240
            nodes.append(CanvasCard(
                id: id, x: x, y: y, width: 200, height: 72,
                type: "text", text: String(text.prefix(80)), file: nil, color: nil
            ))
            edges.append(CanvasArrow(id: UUID().uuidString, from: parent, to: id, label: nil))
            stack.append((depth, id))
            y += 100
            xByDepth[depth] = x + 20
        }

        let doc = CanvasDocument(nodes: nodes, edges: edges, groups: [])
        let data = try JSONEncoder().encode(doc)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        vault.fullRescan()
        return rel
    }

    // MARK: - Offline fallbacks

    private static func offlineSummary(title: String, passages: [RetrievedPassage]) -> String {
        var md = "Auto-generated offline summary for **\(title)**.\n\n## Key passages\n\n"
        for (i, p) in passages.prefix(8).enumerated() {
            md += "### \(i + 1). [[\(p.title)]]\n\(p.snippet)\n\n"
        }
        md += "## Sources\n"
        for p in passages.prefix(8) {
            md += "- [[\(p.title)]]\n"
        }
        return md
    }

    private static func offlineFlashcards(title: String, passages: [RetrievedPassage]) -> String {
        var md = "Flashcards for **\(title)** (offline extraction).\n\n"
        for (i, p) in passages.prefix(10).enumerated() {
            md += "### Card \(i + 1)\n"
            md += "**Q:** What does [[\(p.title)]] say about this topic?\n"
            md += "**A:** \(p.snippet)\n\n"
        }
        md += "## Sources\n"
        for p in passages.prefix(10) {
            md += "- [[\(p.title)]]\n"
        }
        return md
    }

    private static func offlineOutline(title: String, passages: [RetrievedPassage]) -> String {
        var md = "- \(title)\n"
        for p in passages.prefix(12) {
            md += "  - \(p.title)\n"
            let short = String(p.snippet.prefix(60))
            if !short.isEmpty {
                md += "    - \(short)\n"
            }
        }
        return md
    }
}
