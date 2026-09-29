import Foundation
import Combine

/// Maintains reverse link graph, unresolved targets, tags, and unlinked mention search.
@MainActor
final class LinkIndex: ObservableObject {
    @Published private(set) var backlinks: [String: [Backlink]] = [:]
    @Published private(set) var unresolved: Set<String> = []
    @Published private(set) var tags: [String: Set<String>] = [:] // tag -> note paths
    @Published private(set) var graph: GraphSnapshot = GraphSnapshot(nodes: [], edges: [])
    @Published private(set) var lastBuilt = Date()

    private var notes: [String: NoteDocument] = [:]
    /// Fingerprint of graph topology — skip lastBuilt bump when structure is unchanged.
    private var lastTopologyKey: String = ""

    /// Basename / path-without-ext / title → candidate paths (handles duplicate note names).
    private var titleIndex: [String: [String]] = [:]

    func rebuild(from notes: [String: NoteDocument]) {
        self.notes = notes
        var backlinks: [String: [Backlink]] = [:]
        var unresolved = Set<String>()
        var tags: [String: Set<String>] = [:]
        var edgeMap: [String: GraphEdge] = [:]
        var nodeIDs = Set<String>()

        let known = Set(notes.keys)
        titleIndex = Self.buildTitleIndex(notes: notes)

        for (path, note) in notes {
            nodeIDs.insert(path)
            for tag in note.tags {
                tags[tag, default: []].insert(path)
            }

            for link in note.outgoingLinks {
                let resolved = MarkdownParser.resolveLinkTarget(link.target, from: path, knownPaths: known)
                    ?? resolveTitle(link.target, from: path)

                let targetID: String
                if let resolved {
                    targetID = resolved
                    nodeIDs.insert(resolved)
                } else {
                    targetID = "unresolved:\(link.target)"
                    unresolved.insert(link.target)
                    nodeIDs.insert(targetID)
                }

                let edgeID = "\(path)->\(targetID)"
                if var existing = edgeMap[edgeID] {
                    existing.weight += 1
                    edgeMap[edgeID] = existing
                } else {
                    edgeMap[edgeID] = GraphEdge(id: edgeID, source: path, target: targetID, weight: 1)
                }

                if let resolved {
                    let ctx = contextSnippet(in: note.content, around: link)
                    let bl = Backlink(
                        sourcePath: path,
                        sourceTitle: note.title,
                        context: ctx,
                        isLinked: true
                    )
                    backlinks[resolved, default: []].append(bl)
                }
            }
        }

        // Degree
        var degree: [String: Int] = [:]
        for edge in edgeMap.values {
            degree[edge.source, default: 0] += 1
            degree[edge.target, default: 0] += 1
        }

        var graphNodes: [GraphNode] = []
        for id in nodeIDs {
            if id.hasPrefix("unresolved:") {
                let label = String(id.dropFirst("unresolved:".count))
                graphNodes.append(GraphNode(
                    id: id,
                    label: label,
                    kind: .unresolved,
                    path: nil,
                    tags: [],
                    folder: "",
                    degree: degree[id] ?? 0,
                    summary: "Unresolved wikilink target",
                    x: Double.random(in: -200...200),
                    y: Double.random(in: -200...200)
                ))
            } else if let note = notes[id] {
                let summary = note.frontmatter["description"]
                    ?? note.frontmatter["summary"]
                    ?? MarkdownParser.noteSummary(from: note.content)
                graphNodes.append(GraphNode(
                    id: id,
                    label: note.title,
                    kind: .note,
                    path: id,
                    tags: note.tags,
                    folder: note.folderPath,
                    degree: degree[id] ?? 0,
                    summary: summary,
                    x: Double.random(in: -400...400),
                    y: Double.random(in: -400...400)
                ))
            }
        }

        // Optional tag nodes (can be filtered in UI)
        for (tag, paths) in tags {
            let tid = "tag:#\(tag)"
            graphNodes.append(GraphNode(
                id: tid,
                label: "#\(tag)",
                kind: .tag,
                path: nil,
                tags: [tag],
                folder: "",
                degree: paths.count,
                summary: "\(paths.count) note\(paths.count == 1 ? "" : "s") tagged",
                x: Double.random(in: -300...300),
                y: Double.random(in: -300...300)
            ))
            for p in paths {
                let eid = "\(p)->\(tid)"
                edgeMap[eid] = GraphEdge(id: eid, source: p, target: tid, weight: 0.5)
            }
        }

        self.backlinks = backlinks
        self.unresolved = unresolved
        self.tags = tags
        let edges = Array(edgeMap.values)
        self.graph = GraphSnapshot(nodes: graphNodes, edges: edges)

        // Only notify graph view when topology actually changed (not every FSEvents noop).
        let topo = Self.topologyKey(nodes: graphNodes, edges: edges)
        if topo != lastTopologyKey {
            lastTopologyKey = topo
            self.lastBuilt = Date()
        }
    }

    private static func topologyKey(nodes: [GraphNode], edges: [GraphEdge]) -> String {
        let n = nodes.map(\.id).sorted().joined(separator: "\u{1e}")
        let e = edges.map(\.id).sorted().joined(separator: "\u{1e}")
        return n + "\u{1f}" + e
    }

    /// Resolve a wikilink target via title multimap (never crashes on duplicate basenames).
    func resolveTitle(_ target: String, from sourcePath: String) -> String? {
        let key = target.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return nil }
        let candidates = titleIndex[key]
            ?? titleIndex[(key as NSString).lastPathComponent]
            ?? []
        if candidates.isEmpty { return nil }
        if candidates.count == 1 { return candidates[0] }

        // Prefer same folder as source, then shortest path, then lexicographic (stable).
        let sourceDir = (sourcePath as NSString).deletingLastPathComponent
        if let sameFolder = candidates.first(where: {
            ($0 as NSString).deletingLastPathComponent == sourceDir
        }) {
            return sameFolder
        }
        return candidates.sorted {
            if $0.count != $1.count { return $0.count < $1.count }
            return $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }.first
    }

    private static func buildTitleIndex(notes: [String: NoteDocument]) -> [String: [String]] {
        var index: [String: [String]] = [:]
        func add(_ key: String, path: String) {
            let k = key.lowercased()
            guard !k.isEmpty else { return }
            var list = index[k] ?? []
            if !list.contains(path) {
                list.append(path)
                index[k] = list
            }
        }
        for (path, note) in notes {
            let fullNoExt = (path as NSString).deletingPathExtension
            let baseNoExt = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            add(fullNoExt, path: path)
            add(baseNoExt, path: path)
            add(note.title, path: path)
            // Also index nested path segments used in wikilinks like Projects/Ideas
            if fullNoExt.contains("/") {
                add(fullNoExt, path: path)
            }
        }
        return index
    }

    func backlinks(for path: String) -> [Backlink] {
        backlinks[path] ?? []
    }

    func unlinkedMentions(for path: String) -> [Backlink] {
        guard let note = notes[path] else { return [] }
        let title = note.title
        guard title.count >= 2 else { return [] }

        var results: [Backlink] = []
        let linkedSources = Set((backlinks[path] ?? []).map(\.sourcePath))

        for (otherPath, other) in notes where otherPath != path {
            if linkedSources.contains(otherPath) { continue }
            // Skip if already has a wikilink to this note
            let alreadyLinked = other.outgoingLinks.contains {
                MarkdownParser.resolveLinkTarget($0.target, from: otherPath, knownPaths: Set(notes.keys)) == path
            }
            if alreadyLinked { continue }

            if other.content.range(of: title, options: .caseInsensitive) != nil {
                if let range = other.content.range(of: title, options: .caseInsensitive) {
                    let ctx = snippet(other.content, around: range)
                    results.append(Backlink(
                        sourcePath: otherPath,
                        sourceTitle: other.title,
                        context: ctx,
                        isLinked: false
                    ))
                }
            }
        }
        return results.sorted { $0.sourceTitle.localizedCaseInsensitiveCompare($1.sourceTitle) == .orderedAscending }
    }

    func localGraph(center: String, depth: Int, includeTags: Bool, includeUnresolved: Bool, includeOrphans: Bool) -> GraphSnapshot {
        let all = graph
        var keep = Set<String>([center])
        var frontier: Set<String> = [center]

        // adjacency
        var adj: [String: Set<String>] = [:]
        for e in all.edges {
            adj[e.source, default: []].insert(e.target)
            adj[e.target, default: []].insert(e.source)
        }

        for _ in 0..<max(depth, 0) {
            var next = Set<String>()
            for n in frontier {
                for m in adj[n] ?? [] {
                    if !keep.contains(m) {
                        next.insert(m)
                    }
                }
            }
            keep.formUnion(next)
            frontier = next
            if frontier.isEmpty { break }
        }

        var nodes = all.nodes.filter { keep.contains($0.id) }
        if !includeTags {
            nodes.removeAll { $0.kind == .tag }
        }
        if !includeUnresolved {
            nodes.removeAll { $0.kind == .unresolved }
        }
        let nodeIDs = Set(nodes.map(\.id))
        let edges = all.edges.filter { nodeIDs.contains($0.source) && nodeIDs.contains($0.target) }

        if includeOrphans {
            // local graph rarely needs orphans outside neighborhood
        }

        return GraphSnapshot(nodes: nodes, edges: edges)
    }

    func globalGraph(
        query: String,
        folders: Set<String>,
        tagsFilter: Set<String>,
        showTags: Bool,
        showAttachments: Bool,
        showOrphans: Bool,
        showUnresolved: Bool
    ) -> GraphSnapshot {
        var nodes = graph.nodes
        var edges = graph.edges

        if !showTags {
            nodes.removeAll { $0.kind == .tag }
        }
        if !showAttachments {
            nodes.removeAll { $0.kind == .attachment }
        }
        if !showUnresolved {
            nodes.removeAll { $0.kind == .unresolved }
        }

        if !folders.isEmpty {
            nodes.removeAll { node in
                guard node.kind == .note else { return false }
                return !folders.contains(where: { node.folder == $0 || node.folder.hasPrefix($0 + "/") || $0.isEmpty })
            }
        }

        if !tagsFilter.isEmpty {
            nodes.removeAll { node in
                guard node.kind == .note else { return node.kind != .tag }
                return node.tags.first(where: { tagsFilter.contains($0) }) == nil
            }
        }

        if !query.isEmpty {
            let q = query.lowercased()
            nodes.removeAll { !$0.label.lowercased().contains(q) && !($0.path?.lowercased().contains(q) ?? false) }
        }

        let ids = Set(nodes.map(\.id))
        edges = edges.filter { ids.contains($0.source) && ids.contains($0.target) }

        if !showOrphans {
            let connected = Set(edges.flatMap { [$0.source, $0.target] })
            nodes.removeAll { !connected.contains($0.id) && $0.kind == .note }
        }

        return GraphSnapshot(nodes: nodes, edges: edges)
    }

    private func contextSnippet(in content: String, around link: WikiLink) -> String {
        // Prefer body-only text so YAML frontmatter never leaks into the sidebar
        // (e.g. "a, welcome] --- # Welcome…").
        let (_, body) = MarkdownParser.parseFrontmatter(content)
        let ns = body as NSString
        guard ns.length > 0 else { return "" }

        // Wider window so the right-sidebar context rarely feels mid-sentence cut.
        let radius = 120
        let start: Int
        let end: Int
        if let loc = link.location, let len = link.length {
            // Link offsets are against the full file; map into body.
            let bodyStart = max(0, (content as NSString).length - ns.length)
            let bodyLoc = max(0, loc - bodyStart)
            start = max(0, bodyLoc - radius)
            end = min(ns.length, bodyLoc + max(len, 1) + radius)
        } else if let found = body.range(of: "[[\(link.target)", options: .caseInsensitive)
                    ?? body.range(of: link.target, options: .caseInsensitive) {
            let nsRange = NSRange(found, in: body)
            start = max(0, nsRange.location - radius)
            end = min(ns.length, nsRange.location + nsRange.length + radius)
        } else {
            start = 0
            end = min(ns.length, radius * 2)
        }

        return Self.cleanSnippet(ns.substring(with: NSRange(location: start, length: end - start)),
                                 fromStart: start > 0,
                                 toEnd: end < ns.length)
    }

    private func snippet(_ content: String, around range: Range<String.Index>) -> String {
        let (_, body) = MarkdownParser.parseFrontmatter(content)
        let needle = String(content[range])
        // Always search in body (indices from `content` are invalid on a stripped body).
        guard let searchRange = body.range(of: needle, options: .caseInsensitive)
                ?? body.range(of: needle)
        else {
            return Self.cleanSnippet(String(body.prefix(240)), fromStart: false, toEnd: body.count > 240)
        }
        let start = body.index(searchRange.lowerBound, offsetBy: -120, limitedBy: body.startIndex) ?? body.startIndex
        let end = body.index(searchRange.upperBound, offsetBy: 120, limitedBy: body.endIndex) ?? body.endIndex
        return Self.cleanSnippet(String(body[start..<end]),
                                 fromStart: start > body.startIndex,
                                 toEnd: end < body.endIndex)
    }

    /// Collapse whitespace and break at word edges so we never show mid-word cuts like "Markdown Guid".
    private static func cleanSnippet(_ raw: String, fromStart: Bool, toEnd: Bool) -> String {
        var s = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        while s.contains("  ") {
            s = s.replacingOccurrences(of: "  ", with: " ")
        }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)

        // Prefer whitespace; fall back to punctuation so we never end on "Guid" or "|".
        if fromStart {
            s = trimLeadingPartialToken(s)
        }
        if toEnd {
            s = trimTrailingPartialToken(s)
        }

        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        // Drop leading table/list chrome left after a mid-line start.
        while let first = s.first, "|•-*".contains(first) {
            s = String(s.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        if fromStart { s = "…" + s }
        if toEnd { s = s + "…" }
        return s
    }

    private static func trimLeadingPartialToken(_ s: String) -> String {
        if let space = s.firstIndex(of: " "), space < s.endIndex {
            let after = s.index(after: space)
            if after < s.endIndex { return String(s[after...]) }
        }
        // No space: if we started mid-token, drop until a soft break.
        if let idx = s.firstIndex(where: { ")]}>,.;:|".contains($0) }) {
            let after = s.index(after: idx)
            if after < s.endIndex { return String(s[after...]) }
        }
        return s
    }

    private static func trimTrailingPartialToken(_ s: String) -> String {
        if let space = s.lastIndex(of: " "), space > s.startIndex {
            return String(s[..<space])
        }
        // No space: walk back to a soft break so we never leave "Markdow".
        if let idx = s.lastIndex(where: { "([{/<|,.;:".contains($0) }), idx > s.startIndex {
            return String(s[..<idx])
        }
        return s
    }
}
