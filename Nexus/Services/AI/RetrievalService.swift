import Foundation

struct RetrievedPassage: Identifiable, Hashable, Sendable {
    var id: String { "\(path)#\(lineStart)" }
    var path: String
    var title: String
    var snippet: String
    var score: Double
    var lineStart: Int
}

/// Hybrid vault retrieval: FTS5 (SQLite) + in-memory fallback + multi-query merge.
/// Grounding layer for Ask Nexus / studio — works fully offline.
enum RetrievalService {
    static let maxPassages = 12
    static let maxContextChars = 12_000

    static func search(
        question: String,
        notes: [String: NoteDocument],
        index: VaultIndexStore?,
        allowedPaths: Set<String>?
    ) -> [RetrievedPassage] {
        let queries = expandQueries(question)
        var byPath = [String: RetrievedPassage]()

        for q in queries {
            // FTS path
            if let index {
                for hit in index.searchFTS(query: q, limit: 40) {
                    if let allowed = allowedPaths, !allowed.contains(hit.path) { continue }
                    let line = firstLineNumber(of: hit.snippet, in: notes[hit.path]?.content)
                    let passage = RetrievedPassage(
                        path: hit.path,
                        title: hit.title,
                        snippet: cleanSnippet(hit.snippet),
                        score: hit.rank + (q == question ? 0.5 : 0),
                        lineStart: line
                    )
                    if let existing = byPath[hit.path] {
                        if passage.score > existing.score { byPath[hit.path] = passage }
                    } else {
                        byPath[hit.path] = passage
                    }
                }
            }

            // In-memory fallback / boost
            for hit in SearchService.search(query: q, notes: notes, limit: 40) {
                if let allowed = allowedPaths, !allowed.contains(hit.path) { continue }
                let score = hit.score + (index == nil ? 0 : 0.1)
                let passage = RetrievedPassage(
                    path: hit.path,
                    title: hit.title,
                    snippet: hit.snippet,
                    score: score,
                    lineStart: hit.line ?? firstLineNumber(of: hit.snippet, in: notes[hit.path]?.content)
                )
                if let existing = byPath[hit.path] {
                    if passage.score > existing.score {
                        byPath[hit.path] = RetrievedPassage(
                            path: existing.path,
                            title: existing.title,
                            snippet: existing.snippet.count >= passage.snippet.count ? existing.snippet : passage.snippet,
                            score: max(existing.score, passage.score),
                            lineStart: existing.lineStart
                        )
                    }
                } else {
                    byPath[hit.path] = passage
                }
            }
        }

        var ranked = byPath.values.sorted { $0.score > $1.score }
        // Prefer richer snippets from full note content
        ranked = ranked.map { p in
            guard let note = notes[p.path] else { return p }
            if p.snippet.count < 40 {
                let snip = SearchService.searchInFile(query: question, content: note.content).first?.snippet
                    ?? MarkdownParser.noteSummary(from: note.content)
                    ?? String(note.content.prefix(160))
                return RetrievedPassage(
                    path: p.path,
                    title: p.title,
                    snippet: snip,
                    score: p.score,
                    lineStart: p.lineStart
                )
            }
            return p
        }

        return Array(ranked.prefix(maxPassages))
    }

    static func buildContextBlock(passages: [RetrievedPassage]) -> (text: String, used: [RetrievedPassage]) {
        var used: [RetrievedPassage] = []
        var parts: [String] = []
        var chars = 0
        for (i, p) in passages.enumerated() {
            let block = """
            <passage index="\(i + 1)" path="\(p.path)" title="\(p.title)" line="\(p.lineStart)">
            \(p.snippet)
            </passage>
            """
            if !used.isEmpty && chars + block.count > maxContextChars { break }
            parts.append(block)
            used.append(p)
            chars += block.count
        }
        return (parts.joined(separator: "\n\n"), used)
    }

    /// Extract a few keyword-rich alternate queries (LibreNote-style multi-angle retrieval).
    static func expandQueries(_ question: String) -> [String] {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        var queries = [q]

        let stop: Set<String> = [
            "what", "whats", "what's", "which", "where", "when", "who", "whom", "whose",
            "why", "how", "is", "are", "was", "were", "do", "does", "did", "the", "a", "an",
            "of", "in", "on", "for", "to", "and", "or", "with", "from", "about", "me", "my",
            "can", "you", "please", "tell", "explain", "summarize", "summary", "list",
        ]
        let tokens = q.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 && !stop.contains($0) }

        if tokens.count >= 2 {
            queries.append(tokens.prefix(6).joined(separator: " "))
        }
        if let longest = tokens.max(by: { $0.count < $1.count }), longest.count >= 4 {
            queries.append(longest)
        }
        // Unique preserve order
        var seen = Set<String>()
        return queries.filter { seen.insert($0.lowercased()).inserted }.prefix(4).map { $0 }
    }

    static func resolveAllowedPaths(
        scope: AIConfiguration.ScopeMode,
        selectedPath: String?,
        notes: [String: NoteDocument],
        backlinks: [String: [Backlink]],
        tagFilter: Set<String> = []
    ) -> Set<String>? {
        switch scope {
        case .entireVault:
            return nil
        case .currentNote:
            guard let selectedPath else { return [] }
            return [selectedPath]
        case .currentAndBacklinks:
            guard let selectedPath else { return [] }
            var set: Set<String> = [selectedPath]
            for bl in backlinks[selectedPath] ?? [] {
                set.insert(bl.sourcePath)
            }
            if let note = notes[selectedPath] {
                let known = Set(notes.keys)
                for link in note.outgoingLinks {
                    if let r = MarkdownParser.resolveLinkTarget(link.target, from: selectedPath, knownPaths: known) {
                        set.insert(r)
                    }
                }
            }
            return set
        case .selectedFolder:
            guard let selectedPath else { return nil }
            let folder: String
            if selectedPath.hasSuffix(".md") || selectedPath.hasSuffix(".markdown") {
                folder = (selectedPath as NSString).deletingLastPathComponent
            } else {
                folder = selectedPath
            }
            if folder.isEmpty { return nil }
            return Set(notes.keys.filter { $0.hasPrefix(folder + "/") || ($0 as NSString).deletingLastPathComponent == folder })
        case .selectedTags:
            guard let selectedPath, let note = notes[selectedPath] else { return tagFilter.isEmpty ? nil : Set() }
            let tags = tagFilter.isEmpty ? Set(note.tags) : tagFilter
            guard !tags.isEmpty else { return [selectedPath] }
            return Set(notes.compactMap { path, doc in
                doc.tags.contains(where: { tags.contains($0) }) ? path : nil
            })
        }
    }

    private static func cleanSnippet(_ s: String) -> String {
        s.replacingOccurrences(of: "«", with: "")
            .replacingOccurrences(of: "»", with: "")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func firstLineNumber(of snippet: String, in content: String?) -> Int {
        guard let content, !snippet.isEmpty else { return 1 }
        let needle = snippet
            .replacingOccurrences(of: "…", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let probe = String(needle.prefix(32))
        guard !probe.isEmpty else { return 1 }
        let lines = content.components(separatedBy: .newlines)
        for (i, line) in lines.enumerated() {
            if line.localizedCaseInsensitiveContains(probe) { return i + 1 }
        }
        return 1
    }
}
