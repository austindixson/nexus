import Foundation

struct SearchHit: Identifiable, Hashable {
    let id: String
    var path: String
    var title: String
    var snippet: String
    var score: Double
    var line: Int?
}

/// Instant vault search with Obsidian-like operators: path:, tag:, file:, content defaults.
/// Uses SQLite FTS5 when available, falls back to in-memory scan.
enum SearchService {
    static func search(
        query: String,
        notes: [String: NoteDocument],
        limit: Int = 200,
        index: VaultIndexStore? = nil
    ) -> [SearchHit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var pathFilter: String?
        var tagFilter: String?
        var fileFilter: String?
        var terms: [String] = []

        for token in tokenize(trimmed) {
            let lower = token.lowercased()
            if lower.hasPrefix("path:") {
                pathFilter = String(token.dropFirst(5))
            } else if lower.hasPrefix("tag:") {
                tagFilter = String(token.dropFirst(4)).trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            } else if lower.hasPrefix("file:") {
                fileFilter = String(token.dropFirst(5))
            } else {
                terms.append(token)
            }
        }

        // FTS path when we have pure content terms (operators still applied after)
        if let index, !terms.isEmpty {
            let ftsQuery = terms.joined(separator: " ")
            var hits: [SearchHit] = []
            for fts in index.searchFTS(query: ftsQuery, limit: limit * 2) {
                guard let note = notes[fts.path] else {
                    // Index may be ahead of memory briefly
                    if let pathFilter, !fts.path.localizedCaseInsensitiveContains(pathFilter) { continue }
                    if let fileFilter {
                        let name = (fts.path as NSString).lastPathComponent
                        if !name.localizedCaseInsensitiveContains(fileFilter) { continue }
                    }
                    hits.append(SearchHit(
                        id: fts.path + fts.snippet,
                        path: fts.path,
                        title: fts.title,
                        snippet: fts.snippet,
                        score: fts.rank + 10,
                        line: nil
                    ))
                    continue
                }
                if let pathFilter, !fts.path.localizedCaseInsensitiveContains(pathFilter) { continue }
                if let fileFilter {
                    let name = (fts.path as NSString).lastPathComponent
                    if !name.localizedCaseInsensitiveContains(fileFilter) { continue }
                }
                if let tagFilter {
                    if !note.tags.contains(where: {
                        $0.localizedCaseInsensitiveCompare(tagFilter) == .orderedSame
                            || $0.localizedCaseInsensitiveContains(tagFilter)
                    }) { continue }
                }
                hits.append(SearchHit(
                    id: fts.path + fts.snippet,
                    path: fts.path,
                    title: note.title,
                    snippet: fts.snippet.isEmpty ? String(note.content.prefix(100)) : fts.snippet,
                    score: fts.rank + 10,
                    line: nil
                ))
            }
            if !hits.isEmpty {
                return Array(hits.sorted { $0.score > $1.score }.prefix(limit))
            }
        }

        // In-memory fallback / operator-only queries
        var hits: [SearchHit] = []

        for (path, note) in notes {
            if let pathFilter, !path.localizedCaseInsensitiveContains(pathFilter) { continue }
            if let fileFilter {
                let name = (path as NSString).lastPathComponent
                if !name.localizedCaseInsensitiveContains(fileFilter) { continue }
            }
            if let tagFilter {
                if !note.tags.contains(where: { $0.localizedCaseInsensitiveCompare(tagFilter) == .orderedSame
                    || $0.localizedCaseInsensitiveContains(tagFilter) }) {
                    continue
                }
            }

            if terms.isEmpty {
                hits.append(SearchHit(
                    id: path,
                    path: path,
                    title: note.title,
                    snippet: note.folderPath,
                    score: 1,
                    line: nil
                ))
                continue
            }

            var score = 0.0
            var snippet = ""
            let content = note.content
            let title = note.title

            for term in terms {
                if title.localizedCaseInsensitiveContains(term) { score += 5 }
                if path.localizedCaseInsensitiveContains(term) { score += 2 }
                if let range = content.range(of: term, options: .caseInsensitive) {
                    score += 1
                    if snippet.isEmpty {
                        snippet = makeSnippet(content, around: range)
                    }
                }
            }

            if score > 0 {
                hits.append(SearchHit(
                    id: path + snippet,
                    path: path,
                    title: title,
                    snippet: snippet.isEmpty ? String(content.prefix(100)) : snippet,
                    score: score,
                    line: nil
                ))
            }
        }

        return hits.sorted { $0.score > $1.score }.prefix(limit).map { $0 }
    }

    static func searchInFile(query: String, content: String) -> [SearchHit] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        var hits: [SearchHit] = []
        let lines = content.components(separatedBy: .newlines)
        for (i, line) in lines.enumerated() where line.localizedCaseInsensitiveContains(q) {
            hits.append(SearchHit(
                id: "\(i)-\(line.hashValue)",
                path: "",
                title: "Line \(i + 1)",
                snippet: line.trimmingCharacters(in: .whitespaces),
                score: 1,
                line: i + 1
            ))
        }
        return hits
    }

    private static func tokenize(_ q: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false
        for ch in q {
            if ch == "\"" {
                inQuotes.toggle()
                continue
            }
            if ch == " " && !inQuotes {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    private static func makeSnippet(_ content: String, around range: Range<String.Index>) -> String {
        let start = content.index(range.lowerBound, offsetBy: -50, limitedBy: content.startIndex) ?? content.startIndex
        let end = content.index(range.upperBound, offsetBy: 50, limitedBy: content.endIndex) ?? content.endIndex
        return String(content[start..<end]).replacingOccurrences(of: "\n", with: " ")
    }
}
