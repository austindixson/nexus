import Foundation

/// Lightweight Obsidian-flavored Markdown extractor (links, tags, headings, frontmatter).
/// Live preview uses a structured block renderer (tables, callouts, GFM basics).
enum MarkdownParser {

    // [[target]] or [[target|alias]] or ![[embed]]
    private static let wikiLinkRegex: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"(!)?\[\[([^\]|#]+)(?:#[^\]|]+)?(?:\|([^\]]+))?\]\]"#,
            options: []
        )
    }()

    private static let tagRegex: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"(?<![\w/])#([\w\-/]+)"#,
            options: []
        )
    }()

    private static let frontmatterRegex: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\A---\r?\n([\s\S]*?)\r?\n---\r?\n?"#,
            options: []
        )
    }()

    // [!type] optional title — after leading `>` is stripped from quote lines
    private static let calloutStartRegex: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"^\[!([A-Za-z0-9_-]+)\]([+-])?\s*(.*)$"#,
            options: []
        )
    }()

    /// Prefer frontmatter `description` / `summary`, else first non-empty body sentence.
    static func noteSummary(from content: String, maxLen: Int = 160) -> String? {
        let parsed = parseFrontmatter(content)
        for key in ["description", "summary", "desc", "abstract"] {
            if let v = parsed.meta[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty {
                return clipSummary(v, maxLen: maxLen)
            }
        }
        // First meaningful body line (skip headings that only repeat the title)
        for line in parsed.body.split(separator: "\n", omittingEmptySubsequences: false) {
            var t = String(line).trimmingCharacters(in: .whitespaces)
            if t.isEmpty { continue }
            if t.hasPrefix("#") {
                t = t.replacingOccurrences(of: #"^#+\s*"#, with: "", options: .regularExpression)
                // Skip pure title lines; keep if long enough to be useful
                if t.count < 24 { continue }
            }
            if t.hasPrefix("---") || t.hasPrefix("```") { continue }
            if t.hasPrefix("## ") { continue }
            return clipSummary(t, maxLen: maxLen)
        }
        return nil
    }

    private static func clipSummary(_ s: String, maxLen: Int) -> String {
        let one = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        if one.count <= maxLen { return one }
        return String(one.prefix(maxLen - 1)) + "…"
    }

    static func parseFrontmatter(_ content: String) -> (meta: [String: String], body: String) {
        let ns = content as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard let match = frontmatterRegex.firstMatch(in: content, options: [], range: full),
              match.numberOfRanges >= 2,
              let blockRange = Range(match.range(at: 1), in: content),
              let wholeRange = Range(match.range, in: content)
        else {
            return ([:], content)
        }

        let block = String(content[blockRange])
        var meta: [String: String] = [:]
        for line in block.split(separator: "\n", omittingEmptySubsequences: false) {
            let raw = String(line)
            guard let colon = raw.firstIndex(of: ":") else { continue }
            let key = raw[..<colon].trimmingCharacters(in: .whitespaces)
            var value = raw[raw.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            if !key.isEmpty {
                meta[key] = value
            }
        }
        let body = String(content[wholeRange.upperBound...])
        return (meta, body)
    }

    static func extractWikiLinks(from content: String) -> [WikiLink] {
        let ns = content as NSString
        let full = NSRange(location: 0, length: ns.length)
        let matches = wikiLinkRegex.matches(in: content, options: [], range: full)
        return matches.compactMap { match -> WikiLink? in
            guard match.numberOfRanges >= 3,
                  let targetRange = Range(match.range(at: 2), in: content)
            else { return nil }
            let isEmbed = match.range(at: 1).location != NSNotFound
            let target = String(content[targetRange]).trimmingCharacters(in: .whitespaces)
            var alias: String?
            if match.numberOfRanges >= 4, match.range(at: 3).location != NSNotFound,
               let aliasRange = Range(match.range(at: 3), in: content) {
                alias = String(content[aliasRange])
            }
            var link = WikiLink(target: target, alias: alias, isEmbed: isEmbed)
            link.location = match.range.location
            link.length = match.range.length
            return link
        }
    }

    static func extractTags(from content: String, frontmatter: [String: String]) -> [String] {
        var tags = Set<String>()
        if let fmTags = frontmatter["tags"] {
            for part in fmTags.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "[" || $0 == "]" }) {
                let t = part.trimmingCharacters(in: CharacterSet(charactersIn: "#\""))
                if !t.isEmpty { tags.insert(t) }
            }
        }
        let ns = content as NSString
        let full = NSRange(location: 0, length: ns.length)
        for match in tagRegex.matches(in: content, options: [], range: full) {
            guard let r = Range(match.range(at: 1), in: content) else { continue }
            tags.insert(String(content[r]))
        }
        return tags.sorted()
    }

    static func extractHeadings(from content: String) -> [Heading] {
        let lines = content.components(separatedBy: .newlines)
        var result: [Heading] = []
        for (idx, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("#") else { continue }
            var level = 0
            for ch in trimmed {
                if ch == "#" { level += 1 } else { break }
            }
            guard level >= 1, level <= 6 else { continue }
            let text = trimmed.dropFirst(level).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            result.append(Heading(level: level, text: text, line: idx + 1))
        }
        return result
    }

    static func resolveLinkTarget(_ target: String, from notePath: String, knownPaths: Set<String>) -> String? {
        let clean = target
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")

        if knownPaths.contains(clean) { return clean }
        if knownPaths.contains(clean + ".md") { return clean + ".md" }

        let base = (clean as NSString).lastPathComponent
        let baseNoExt = (base as NSString).deletingPathExtension
        let candidates = knownPaths.filter {
            let name = ($0 as NSString).lastPathComponent
            let nameNoExt = (name as NSString).deletingPathExtension
            return nameNoExt.caseInsensitiveCompare(baseNoExt) == .orderedSame
                || name.caseInsensitiveCompare(base) == .orderedSame
                || $0.caseInsensitiveCompare(clean) == .orderedSame
                || $0.caseInsensitiveCompare(clean + ".md") == .orderedSame
        }
        if candidates.count == 1 { return candidates.first }
        if let exact = candidates.first(where: { $0.hasSuffix("/" + base) || $0 == base || $0 == base + ".md" }) {
            return exact
        }
        return candidates.sorted().first
    }

    // MARK: - Live preview

    /// Convert Obsidian-flavored Markdown body to HTML for the native WKWebView preview.
    static func renderPreviewHTML(_ content: String, title: String) -> String {
        let (meta, body) = parseFrontmatter(content)
        let bodyHTML = renderBodyHTML(body)

        let fmHTML: String
        if meta.isEmpty {
            fmHTML = ""
        } else {
            let rows = meta.keys.sorted().map { key in
                "<tr><th>\(escape(key))</th><td>\(escape(meta[key] ?? ""))</td></tr>"
            }.joined()
            fmHTML = "<table class=\"frontmatter\">\(rows)</table>"
        }

        // Offline KaTeX (bundled under Resources/katex, loaded via baseURL).
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8"/>
        <link rel="stylesheet" href="katex.min.css"/>
        <style>
          :root {
            color-scheme: dark light;
            --bg: transparent;
            --text: #e6e6e6;
            --muted: #9a9a9a;
            --link: #7aa2ff;
            --code-bg: rgba(127,127,127,0.12);
            --tag: #c3a6ff;
            --embed: rgba(122,162,255,0.12);
            --border: rgba(127,127,127,0.28);
            --table-stripe: rgba(127,127,127,0.08);
            --callout-bg: rgba(127,127,127,0.08);
          }
          @media (prefers-color-scheme: light) {
            :root {
              --text: #1c1c1e;
              --muted: #6c6c70;
              --link: #2f6fed;
              --tag: #7b4fd6;
              --code-bg: rgba(0,0,0,0.05);
              --border: rgba(0,0,0,0.12);
              --table-stripe: rgba(0,0,0,0.03);
              --callout-bg: rgba(0,0,0,0.04);
            }
          }
          html, body {
            margin: 0; padding: 0;
            background: var(--bg);
            color: var(--text);
            font: 15px/1.65 -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif;
            -webkit-font-smoothing: antialiased;
          }
          body { padding: 28px 36px 80px; max-width: 820px; }
          h1,h2,h3,h4,h5,h6 { line-height: 1.25; margin: 1.4em 0 0.5em; font-weight: 600; }
          h1 { font-size: 1.85em; letter-spacing: -0.02em; }
          h2 { font-size: 1.4em; }
          h3 { font-size: 1.15em; }
          p { margin: 0.75em 0; }
          a.wikilink { color: var(--link); text-decoration: none; border-bottom: 1px solid color-mix(in srgb, var(--link) 40%, transparent); }
          a.wikilink:hover { border-bottom-color: var(--link); }
          a.ext { color: var(--link); }
          code { font-family: "SF Mono", Menlo, monospace; font-size: 0.9em; background: var(--code-bg); padding: 0.1em 0.35em; border-radius: 4px; }
          pre { background: var(--code-bg); padding: 12px 14px; border-radius: 8px; overflow-x: auto; border: 1px solid var(--border); }
          pre code { background: none; padding: 0; }
          .tag { color: var(--tag); font-weight: 500; }
          .embed { background: var(--embed); border: 1px solid var(--border); border-radius: 8px; padding: 12px 14px; margin: 12px 0; color: var(--muted); }
          .task { margin: 0.25em 0; list-style: none; margin-left: 0; }
          .task.done { color: var(--muted); text-decoration: line-through; }
          ul, ol { padding-left: 1.4em; margin: 0.6em 0; }
          li { margin: 0.2em 0; }
          hr { border: none; border-top: 1px solid var(--border); margin: 1.5em 0; }
          blockquote {
            margin: 0.8em 0; padding: 0.15em 0 0.15em 1em;
            border-left: 3px solid var(--link); color: var(--muted);
          }
          table.md-table {
            width: 100%; border-collapse: collapse; margin: 1em 0;
            font-size: 0.95em; overflow: hidden; border: 1px solid var(--border);
            border-radius: 8px;
          }
          table.md-table th, table.md-table td {
            border: 1px solid var(--border); padding: 8px 12px; text-align: left;
          }
          table.md-table th { background: var(--table-stripe); font-weight: 600; }
          table.md-table tr:nth-child(even) td { background: var(--table-stripe); }
          table.md-table.align-center td, table.md-table.align-center th { text-align: center; }
          table.md-table td.align-right, table.md-table th.align-right { text-align: right; }
          table.md-table td.align-center, table.md-table th.align-center { text-align: center; }
          table.frontmatter { width: 100%; border-collapse: collapse; margin-bottom: 1.5em; font-size: 0.9em; color: var(--muted); }
          table.frontmatter th { text-align: left; padding: 4px 10px 4px 0; font-weight: 500; width: 120px; }
          table.frontmatter td { padding: 4px 0; }
          .callout {
            margin: 1em 0; border-radius: 8px; border: 1px solid var(--border);
            background: var(--callout-bg); overflow: hidden;
          }
          .callout-title {
            display: flex; align-items: center; gap: 8px;
            font-weight: 600; padding: 10px 14px 6px; font-size: 0.95em;
          }
          .callout-body { padding: 0 14px 12px; }
          .callout-body > :first-child { margin-top: 0.25em; }
          .callout-body > :last-child { margin-bottom: 0; }
          .callout-icon { font-size: 1.05em; }
          .callout[data-type="note"], .callout[data-type="info"] { border-left: 4px solid #7aa2ff; }
          .callout[data-type="tip"], .callout[data-type="hint"] { border-left: 4px solid #3dd68c; }
          .callout[data-type="warning"], .callout[data-type="caution"] { border-left: 4px solid #f5a524; }
          .callout[data-type="danger"], .callout[data-type="error"], .callout[data-type="bug"] { border-left: 4px solid #f31260; }
          .callout[data-type="success"], .callout[data-type="check"], .callout[data-type="done"] { border-left: 4px solid #17c964; }
          .callout[data-type="question"], .callout[data-type="help"], .callout[data-type="faq"] { border-left: 4px solid #a78bfa; }
          .callout[data-type="example"], .callout[data-type="quote"] { border-left: 4px solid #9a9a9a; }
          .callout[data-type="todo"], .callout[data-type="abstract"], .callout[data-type="summary"], .callout[data-type="tldr"] { border-left: 4px solid #66d9ef; }
          .math-display { margin: 1em 0; overflow-x: auto; text-align: center; }
          .math-inline { }
          .katex-error { color: #f31260; }
        </style>
        </head>
        <body>
        \(fmHTML)
        \(bodyHTML)
        <script src="katex.min.js"></script>
        <script>
          (function() {
            if (typeof katex === 'undefined') return;
            function renderAll(sel, display) {
              document.querySelectorAll(sel).forEach(function(el) {
                var src = el.getAttribute('data-tex') || el.textContent;
                try {
                  katex.render(src, el, { throwOnError: false, displayMode: display, output: 'html' });
                } catch (e) {
                  el.classList.add('katex-error');
                }
              });
            }
            renderAll('span.math-inline', false);
            renderAll('div.math-display', true);
          })();
        </script>
        </body>
        </html>
        """
    }

    /// Render markdown body only (no document chrome). Exposed for tests.
    static func renderBodyHTML(_ body: String) -> String {
        // Protect display math first so `$` / fences inside math are not mangled.
        let (withDisplay, displaySlots) = extractDisplayMath(body)
        let lines = withDisplay.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")

        var html: [String] = []
        var i = 0
        var paragraph: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            let joined = paragraph.joined(separator: " ")
            html.append("<p>\(renderInline(joined))</p>")
            paragraph.removeAll(keepingCapacity: true)
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code block
            if trimmed.hasPrefix("```") {
                flushParagraph()
                let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                i += 1
                var codeLines: [String] = []
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    codeLines.append(lines[i])
                    i += 1
                }
                if i < lines.count { i += 1 } // closing ```
                let code = escape(codeLines.joined(separator: "\n"))
                let langAttr = lang.isEmpty ? "" : " class=\"language-\(escape(lang))\""
                html.append("<pre><code\(langAttr)>\(code)</code></pre>")
                continue
            }

            // Empty line
            if trimmed.isEmpty {
                flushParagraph()
                i += 1
                continue
            }

            // Horizontal rule
            if isHorizontalRule(trimmed) {
                flushParagraph()
                html.append("<hr/>")
                i += 1
                continue
            }

            // Callout / blockquote
            if trimmed.hasPrefix(">") {
                flushParagraph()
                let (blockHTML, consumed) = consumeBlockquoteOrCallout(lines, start: i)
                html.append(blockHTML)
                i += consumed
                continue
            }

            // GFM table (header + separator)
            if looksLikeTableRow(trimmed),
               i + 1 < lines.count,
               isTableSeparator(lines[i + 1].trimmingCharacters(in: .whitespaces)) {
                flushParagraph()
                let (tableHTML, consumed) = consumeTable(lines, start: i)
                html.append(tableHTML)
                i += consumed
                continue
            }

            // Heading
            if let heading = parseHeading(trimmed) {
                flushParagraph()
                html.append("<h\(heading.level)>\(renderInline(heading.text))</h\(heading.level)>")
                i += 1
                continue
            }

            // Unordered list / task list
            if let listMatch = parseUnorderedListItem(trimmed) {
                flushParagraph()
                let (listHTML, consumed) = consumeUnorderedList(lines, start: i)
                html.append(listHTML)
                _ = listMatch
                i += consumed
                continue
            }

            // Ordered list
            if parseOrderedListItem(trimmed) != nil {
                flushParagraph()
                let (listHTML, consumed) = consumeOrderedList(lines, start: i)
                html.append(listHTML)
                i += consumed
                continue
            }

            // Paragraph accumulation
            paragraph.append(trimmed)
            i += 1
        }
        flushParagraph()
        var joined = html.joined(separator: "\n")
        for (idx, tex) in displaySlots.enumerated() {
            let token = "%%DISPLAYMATH\(idx)%%"
            let block = "<div class=\"math-display\" data-tex=\"\(escapeAttr(tex))\">\(escape(tex))</div>"
            joined = joined.replacingOccurrences(of: token, with: block)
            // Token may have been wrapped in <p>
            joined = joined.replacingOccurrences(of: "<p>\(token)</p>", with: block)
        }
        return joined
    }

    /// Extract `$$...$$` and `\[...\]` display math into placeholders.
    static func extractDisplayMath(_ input: String) -> (String, [String]) {
        var slots: [String] = []
        var result = input
        while let range = result.range(of: "$$") {
            guard let end = result.range(of: "$$", range: range.upperBound..<result.endIndex) else { break }
            let tex = String(result[range.upperBound..<end.lowerBound])
            let token = "%%DISPLAYMATH\(slots.count)%%"
            slots.append(tex)
            result.replaceSubrange(range.lowerBound..<end.upperBound, with: token)
        }
        if let re = try? NSRegularExpression(pattern: #"\\\[([\s\S]+?)\\\]"#, options: []) {
            let matches = re.matches(in: result, options: [], range: NSRange(location: 0, length: (result as NSString).length))
            for match in matches.reversed() {
                guard let full = Range(match.range, in: result),
                      let inner = Range(match.range(at: 1), in: result) else { continue }
                let tex = String(result[inner])
                let token = "%%DISPLAYMATH\(slots.count)%%"
                slots.append(tex)
                result.replaceSubrange(full, with: token)
            }
        }
        return (result, slots)
    }

    // MARK: - Block helpers

    private static func isHorizontalRule(_ line: String) -> Bool {
        let s = line.replacingOccurrences(of: " ", with: "")
        return s.count >= 3 && (s.allSatisfy { $0 == "-" } || s.allSatisfy { $0 == "*" } || s.allSatisfy { $0 == "_" })
    }

    private static func parseHeading(_ line: String) -> (level: Int, text: String)? {
        guard line.hasPrefix("#") else { return nil }
        var level = 0
        for ch in line {
            if ch == "#" { level += 1 } else { break }
        }
        guard level >= 1, level <= 6 else { return nil }
        let rest = line.dropFirst(level)
        guard rest.first == " " || rest.isEmpty else { return nil }
        let text = rest.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return (level, text)
    }

    private static func parseUnorderedListItem(_ line: String) -> (task: Bool?, text: String)? {
        // - item / * item / + item / - [ ] task / - [x] task
        guard let re = try? NSRegularExpression(pattern: #"^([-*+])\s+(?:\[([ xX])\]\s+)?(.+)$"#) else { return nil }
        let ns = line as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard let m = re.firstMatch(in: line, options: [], range: full),
              let textRange = Range(m.range(at: 3), in: line)
        else { return nil }
        let text = String(line[textRange])
        if m.range(at: 2).location != NSNotFound, let boxRange = Range(m.range(at: 2), in: line) {
            let box = String(line[boxRange]).lowercased()
            return (box == "x", text)
        }
        return (nil, text)
    }

    private static func parseOrderedListItem(_ line: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: #"^\d+[.)]\s+(.+)$"#) else { return nil }
        let ns = line as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard let m = re.firstMatch(in: line, options: [], range: full),
              let r = Range(m.range(at: 1), in: line)
        else { return nil }
        return String(line[r])
    }

    private static func consumeUnorderedList(_ lines: [String], start: Int) -> (String, Int) {
        var i = start
        var items: [String] = []
        while i < lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            guard let item = parseUnorderedListItem(trimmed) else { break }
            if let done = item.task {
                let cls = done ? "task done" : "task"
                let mark = done ? "☑" : "☐"
                items.append("<li class=\"\(cls)\">\(mark) \(renderInline(item.text))</li>")
            } else {
                items.append("<li>\(renderInline(item.text))</li>")
            }
            i += 1
        }
        return ("<ul>\(items.joined())</ul>", i - start)
    }

    private static func consumeOrderedList(_ lines: [String], start: Int) -> (String, Int) {
        var i = start
        var items: [String] = []
        while i < lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            guard let text = parseOrderedListItem(trimmed) else { break }
            items.append("<li>\(renderInline(text))</li>")
            i += 1
        }
        return ("<ol>\(items.joined())</ol>", i - start)
    }

    private static func consumeBlockquoteOrCallout(_ lines: [String], start: Int) -> (String, Int) {
        var i = start
        var rawLines: [String] = []
        while i < lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(">") {
                var content = String(trimmed.dropFirst())
                if content.hasPrefix(" ") { content = String(content.dropFirst()) }
                rawLines.append(content)
                i += 1
            } else if trimmed.isEmpty, i + 1 < lines.count,
                      lines[i + 1].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                // blank line inside quote
                rawLines.append("")
                i += 1
            } else {
                break
            }
        }

        guard let first = rawLines.first else {
            return ("", i - start)
        }

        let ns = first as NSString
        let full = NSRange(location: 0, length: ns.length)
        if let match = calloutStartRegex.firstMatch(in: first, options: [], range: full),
           let typeRange = Range(match.range(at: 1), in: first) {
            let type = String(first[typeRange]).lowercased()
            var title = ""
            if match.range(at: 3).location != NSNotFound, let titleRange = Range(match.range(at: 3), in: first) {
                title = String(first[titleRange]).trimmingCharacters(in: .whitespaces)
            }
            if title.isEmpty {
                title = type.capitalized
            }
            let bodyLines = Array(rawLines.dropFirst())
            let bodyMarkdown = bodyLines.joined(separator: "\n")
            let bodyHTML: String
            if bodyMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                bodyHTML = ""
            } else {
                bodyHTML = renderBodyHTML(bodyMarkdown)
            }
            let icon = calloutIcon(for: type)
            let html = """
            <div class="callout" data-type="\(escape(type))">
              <div class="callout-title"><span class="callout-icon">\(icon)</span><span>\(renderInline(title))</span></div>
              <div class="callout-body">\(bodyHTML)</div>
            </div>
            """
            return (html, i - start)
        }

        // Plain blockquote — join non-empty lines as paragraphs
        let inner = rawLines.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { "<p>\(renderInline($0))</p>" }
            .joined()
        return ("<blockquote>\(inner)</blockquote>", i - start)
    }

    private static func calloutIcon(for type: String) -> String {
        switch type {
        case "note", "info": return "ℹ️"
        case "tip", "hint": return "💡"
        case "warning", "caution": return "⚠️"
        case "danger", "error", "bug": return "⚠️"
        case "success", "check", "done": return "✅"
        case "question", "help", "faq": return "❓"
        case "example": return "📋"
        case "quote": return "💬"
        case "todo": return "☑️"
        case "abstract", "summary", "tldr": return "📝"
        default: return "📌"
        }
    }

    // MARK: - Tables

    private static func looksLikeTableRow(_ line: String) -> Bool {
        line.contains("|")
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        // | --- | :---: | ---: |
        guard line.contains("|") || line.contains("-") else { return false }
        let cells = splitTableRow(line)
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            let s = cell.trimmingCharacters(in: .whitespaces)
            guard !s.isEmpty else { return false }
            return s.unicodeScalars.allSatisfy { ch in
                ch == "-" || ch == ":" || ch == " "
            } && s.contains("-")
        }
    }

    private static func splitTableRow(_ line: String) -> [String] {
        var s = line.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("|") { s = String(s.dropFirst()) }
        if s.hasSuffix("|") { s = String(s.dropLast()) }
        return s.split(separator: "|", omittingEmptySubsequences: false).map {
            String($0).trimmingCharacters(in: .whitespaces)
        }
    }

    private enum TableAlign {
        case left, center, right
    }

    private static func parseAlignments(_ separator: String) -> [TableAlign] {
        splitTableRow(separator).map { cell in
            let s = cell.trimmingCharacters(in: .whitespaces)
            let left = s.hasPrefix(":")
            let right = s.hasSuffix(":")
            if left && right { return .center }
            if right { return .right }
            return .left
        }
    }

    private static func consumeTable(_ lines: [String], start: Int) -> (String, Int) {
        let headerCells = splitTableRow(lines[start].trimmingCharacters(in: .whitespaces))
        let aligns = parseAlignments(lines[start + 1].trimmingCharacters(in: .whitespaces))
        var i = start + 2
        var bodyRows: [[String]] = []
        while i < lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || !looksLikeTableRow(trimmed) { break }
            if isTableSeparator(trimmed) { break }
            bodyRows.append(splitTableRow(trimmed))
            i += 1
        }

        func alignClass(_ idx: Int) -> String {
            let a = idx < aligns.count ? aligns[idx] : .left
            switch a {
            case .left: return ""
            case .center: return " class=\"align-center\""
            case .right: return " class=\"align-right\""
            }
        }

        var thead = "<thead><tr>"
        for (idx, cell) in headerCells.enumerated() {
            thead += "<th\(alignClass(idx))>\(renderInline(cell))</th>"
        }
        thead += "</tr></thead>"

        var tbody = "<tbody>"
        for row in bodyRows {
            tbody += "<tr>"
            for idx in 0..<headerCells.count {
                let cell = idx < row.count ? row[idx] : ""
                tbody += "<td\(alignClass(idx))>\(renderInline(cell))</td>"
            }
            tbody += "</tr>"
        }
        tbody += "</tbody>"

        return ("<table class=\"md-table\">\(thead)\(tbody)</table>", i - start)
    }

    // MARK: - Inline

    static func renderInline(_ text: String) -> String {
        var s = text

        // Protect code spans
        var codeSpans: [String] = []
        if let re = try? NSRegularExpression(pattern: #"`([^`]+)`"#) {
            let ns = s as NSString
            let matches = re.matches(in: s, options: [], range: NSRange(location: 0, length: ns.length))
            for match in matches.reversed() {
                guard let r = Range(match.range(at: 1), in: s) else { continue }
                let code = String(s[r])
                let token = "%%CODE\(codeSpans.count)%%"
                codeSpans.append("<code>\(escape(code))</code>")
                if let full = Range(match.range, in: s) {
                    s.replaceSubrange(full, with: token)
                }
            }
        }

        // Protect inline math $...$ and \(...\)
        var mathSpans: [String] = []
        if let re = try? NSRegularExpression(pattern: #"\\\((.+?)\\\)"#) {
            let matches = re.matches(in: s, options: [], range: NSRange(location: 0, length: (s as NSString).length))
            for match in matches.reversed() {
                guard let full = Range(match.range, in: s), let inner = Range(match.range(at: 1), in: s) else { continue }
                let token = "%%MATH\(mathSpans.count)%%"
                mathSpans.append(String(s[inner]))
                s.replaceSubrange(full, with: token)
            }
        }
        // $...$ single-line, not $$ 
        if let re = try? NSRegularExpression(pattern: #"(?<!\$)\$(?!\$)([^$\n]+?)\$(?!\$)"#) {
            let matches = re.matches(in: s, options: [], range: NSRange(location: 0, length: (s as NSString).length))
            for match in matches.reversed() {
                guard let full = Range(match.range, in: s), let inner = Range(match.range(at: 1), in: s) else { continue }
                let token = "%%MATH\(mathSpans.count)%%"
                mathSpans.append(String(s[inner]))
                s.replaceSubrange(full, with: token)
            }
        }

        // Escape remaining HTML-sensitive chars outside code
        s = escape(s)

        // Images ![alt](url)
        s = replacePattern(s, pattern: #"!\[([^\]]*)\]\(([^)]+)\)"#) { m in
            let alt = m[0]
            let url = m[1]
            return "<img src=\"\(url)\" alt=\"\(alt)\" style=\"max-width:100%;border-radius:6px\"/>"
        }

        // Links [text](url)
        s = replacePattern(s, pattern: #"\[([^\]]+)\]\(([^)]+)\)"#) { m in
            "<a class=\"ext\" href=\"\(m[1])\">\(m[0])</a>"
        }

        // Embeds ![[note]]
        s = replacePattern(s, pattern: #"!\[\[([^\]|]+)(?:\|[^\]]+)?\]\]"#) { m in
            "<div class=\"embed\">Embed: \(m[0])</div>"
        }

        // Wikilinks [[target|alias]] or [[target]]
        s = replacePattern(s, pattern: #"\[\[([^\]|#]+)(?:#[^\]|]+)?(?:\|([^\]]+))?\]\]"#) { m in
            let target = m[0]
            let alias = m.count > 1 && !m[1].isEmpty ? m[1] : target
            let href = "nexus://note/\(target.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? target)"
            return "<a class=\"wikilink\" href=\"\(href)\">\(alias)</a>"
        }

        // Bold **text**
        s = replacePattern(s, pattern: #"\*\*([^*]+)\*\*"#) { m in
            "<strong>\(m[0])</strong>"
        }
        // Italic *text* or _text_
        s = replacePattern(s, pattern: #"(?<!\*)\*([^*]+)\*(?!\*)"#) { m in
            "<em>\(m[0])</em>"
        }
        s = replacePattern(s, pattern: #"(?<!\w)_([^_]+)_(?!\w)"#) { m in
            "<em>\(m[0])</em>"
        }
        // Strikethrough ~~text~~
        s = replacePattern(s, pattern: #"~~([^~]+)~~"#) { m in
            "<del>\(m[0])</del>"
        }
        // Highlight ==text==
        s = replacePattern(s, pattern: #"==([^=]+)=="#) { m in
            "<mark>\(m[0])</mark>"
        }

        // Tags
        s = replacePattern(s, pattern: #"(?<![\w/])#([\w\-/]+)"#) { m in
            "<span class=\"tag\">#\(m[0])</span>"
        }

        // Restore math spans (escaped content in data-tex)
        for (idx, tex) in mathSpans.enumerated() {
            let html = "<span class=\"math-inline\" data-tex=\"\(escapeAttr(tex))\">\(escape(tex))</span>"
            s = s.replacingOccurrences(of: "%%MATH\(idx)%%", with: html)
        }

        // Restore code spans
        for (idx, code) in codeSpans.enumerated() {
            s = s.replacingOccurrences(of: "%%CODE\(idx)%%", with: code)
        }

        return s
    }

    private static func escapeAttr(_ s: String) -> String {
        escape(s)
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private static func replacePattern(_ input: String, pattern: String, handler: ([String]) -> String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return input }
        let ns = input as NSString
        let matches = re.matches(in: input, options: [], range: NSRange(location: 0, length: ns.length))
        var result = input
        for match in matches.reversed() {
            var groups: [String] = []
            for g in 1..<match.numberOfRanges {
                if match.range(at: g).location != NSNotFound, let r = Range(match.range(at: g), in: result) {
                    groups.append(String(result[r]))
                } else {
                    groups.append("")
                }
            }
            let replacement = handler(groups)
            if let full = Range(match.range, in: result) {
                result.replaceSubrange(full, with: replacement)
            }
        }
        return result
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
