import Foundation
import PDFKit
import AppKit

/// Import external sources as Markdown notes under `Sources/` (files stay vault-owned).
enum SourceImporter {
    enum ImportError: LocalizedError {
        case unreadable
        case empty
        case network(String)

        var errorDescription: String? {
            switch self {
            case .unreadable: return "Could not read the selected file."
            case .empty: return "No text could be extracted."
            case .network(let m): return m
            }
        }
    }

    struct Result {
        var path: String
        var title: String
    }

    // MARK: - PDF

    @MainActor
    static func importPDF(url: URL, into vault: VaultService) throws -> Result {
        guard let doc = PDFDocument(url: url) else { throw ImportError.unreadable }
        var pages: [String] = []
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i), let text = page.string else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                pages.append("## Page \(i + 1)\n\n\(trimmed)")
            }
        }
        let body = pages.joined(separator: "\n\n")
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ImportError.empty
        }
        let title = url.deletingPathExtension().lastPathComponent
        return try writeSourceNote(
            title: title,
            sourceType: "pdf",
            sourceURL: url.path,
            body: body,
            into: vault
        )
    }

    // MARK: - Plain text / markdown file

    @MainActor
    static func importTextFile(url: URL, into vault: VaultService) throws -> Result {
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw ImportError.unreadable
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ImportError.empty
        }
        let title = url.deletingPathExtension().lastPathComponent
        let isMD = ["md", "markdown"].contains(url.pathExtension.lowercased())
        return try writeSourceNote(
            title: title,
            sourceType: isMD ? "markdown" : "text",
            sourceURL: url.path,
            body: text,
            into: vault
        )
    }

    // MARK: - Pasted text

    @MainActor
    static func importPastedText(title: String, text: String, into vault: VaultService) throws -> Result {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { throw ImportError.empty }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Pasted note \(dayStamp())"
            : title
        return try writeSourceNote(
            title: name,
            sourceType: "paste",
            sourceURL: nil,
            body: t,
            into: vault
        )
    }

    // MARK: - Web URL / YouTube

    @MainActor
    static func importWebURL(_ urlString: String, into vault: VaultService) async throws -> Result {
        var raw = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.contains("://") { raw = "https://" + raw }
        guard let url = URL(string: raw) else { throw ImportError.network("Invalid URL.") }

        if let videoID = youtubeVideoID(from: url) {
            return try await importYouTube(videoID: videoID, sourceURL: url.absoluteString, into: vault)
        }

        var request = URLRequest(url: url)
        request.setValue("Nexus/0.1 (local knowledge base)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ImportError.network(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw ImportError.network("HTTP \(http.statusCode)")
        }

        let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        let (title, markdown) = htmlToMarkdown(html, fallbackTitle: url.host ?? "Web page")
        guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ImportError.empty
        }
        return try writeSourceNote(
            title: title,
            sourceType: "web",
            sourceURL: url.absoluteString,
            body: markdown,
            into: vault
        )
    }

    /// Extract transcript + title from a YouTube video (best-effort, no API key).
    @MainActor
    static func importYouTube(videoID: String, sourceURL: String, into vault: VaultService) async throws -> Result {
        let watchURL = URL(string: "https://www.youtube.com/watch?v=\(videoID)")!
        var request = URLRequest(url: watchURL)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw ImportError.network("YouTube HTTP \(http.statusCode)")
        }
        let html = String(data: data, encoding: .utf8) ?? ""

        var title = "YouTube \(videoID)"
        if let range = html.range(of: #"<title>(.*?)</title>"#, options: [.regularExpression, .caseInsensitive]) {
            title = String(html[range])
                .replacingOccurrences(of: #"</?title>"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: " - YouTube", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Prefer captionTracks in ytInitialPlayerResponse
        var transcript = ""
        if let trackURL = captionTrackURL(from: html) {
            transcript = (try? await fetchCaptionTrack(url: trackURL)) ?? ""
        }
        if transcript.isEmpty {
            // Fallback: timedtext list
            if let listURL = URL(string: "https://www.youtube.com/api/timedtext?type=list&v=\(videoID)"),
               let listData = try? await URLSession.shared.data(from: listURL).0,
               let listXML = String(data: listData, encoding: .utf8),
               let lang = listXML.range(of: #"lang_code="([^"]+)""#, options: .regularExpression).map({ String(listXML[$0]) }) {
                let code = lang.replacingOccurrences(of: #"lang_code=""#, with: "").replacingOccurrences(of: "\"", with: "")
                if let capURL = URL(string: "https://www.youtube.com/api/timedtext?v=\(videoID)&lang=\(code)"),
                   let cap = try? await fetchCaptionTrack(url: capURL) {
                    transcript = cap
                }
            }
        }

        var body = ""
        if !transcript.isEmpty {
            body = "## Transcript\n\n" + transcript
        } else {
            body = """
            ## Note

            Could not fetch captions for this video (disabled or region-locked).
            Title and link are preserved — paste notes below.

            Watch: \(sourceURL)
            """
        }

        return try writeSourceNote(
            title: title,
            sourceType: "youtube",
            sourceURL: sourceURL,
            body: body,
            into: vault
        )
    }

    static func youtubeVideoID(from url: URL) -> String? {
        let host = url.host?.lowercased() ?? ""
        if host.contains("youtu.be") {
            let id = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return id.isEmpty ? nil : String(id.prefix(11))
        }
        if host.contains("youtube.com") {
            if let v = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "v" })?.value,
               !v.isEmpty {
                return v
            }
            // /embed/ID or /shorts/ID
            let parts = url.path.split(separator: "/")
            if let idx = parts.firstIndex(where: { $0 == "embed" || $0 == "shorts" || $0 == "live" }),
               parts.index(after: idx) < parts.endIndex {
                return String(parts[parts.index(after: idx)].prefix(11))
            }
        }
        return nil
    }

    private static func captionTrackURL(from html: String) -> URL? {
        // "captionTracks":[{"baseUrl":"https://...
        guard let range = html.range(of: #"captionTracks":\s*\[\{"#, options: .regularExpression) else {
            return nil
        }
        let from = html[range.lowerBound...]
        guard let base = from.range(of: #"baseUrl"\s*:\s*"([^"]+)""#, options: .regularExpression) else {
            return nil
        }
        var urlStr = String(from[base])
        if let m = urlStr.range(of: #"https[^"]+"#, options: .regularExpression) {
            urlStr = String(urlStr[m])
        }
        urlStr = urlStr
            .replacingOccurrences(of: "\\u0026", with: "&")
            .replacingOccurrences(of: "\\/", with: "/")
        return URL(string: urlStr)
    }

    private static func fetchCaptionTrack(url: URL) async throws -> String {
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: req)
        let raw = String(data: data, encoding: .utf8) ?? ""
        // JSON3 format or XML <text>
        if raw.contains("\"events\"") || raw.contains("\"segs\"") {
            return parseJSON3Captions(raw)
        }
        return parseXMLCaptions(raw)
    }

    private static func parseXMLCaptions(_ xml: String) -> String {
        var lines: [String] = []
        let pattern = #"<text[^>]*>([\s\S]*?)</text>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return "" }
        let ns = xml as NSString
        for m in regex.matches(in: xml, options: [], range: NSRange(location: 0, length: ns.length)) {
            guard m.numberOfRanges >= 2 else { continue }
            var t = ns.substring(with: m.range(at: 1))
            t = t.replacingOccurrences(of: #"&amp;"#, with: "&")
            t = t.replacingOccurrences(of: #"&lt;"#, with: "<")
            t = t.replacingOccurrences(of: #"&gt;"#, with: ">")
            t = t.replacingOccurrences(of: #"&quot;"#, with: "\"")
            t = t.replacingOccurrences(of: #"&#39;"#, with: "'")
            t = t.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            t = t.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { lines.append(t) }
        }
        // Dedupe consecutive
        var out: [String] = []
        for line in lines {
            if out.last != line { out.append(line) }
        }
        let joined = out.joined(separator: " ")
        return joined.count > 100_000 ? String(joined.prefix(100_000)) + "\n\n…(truncated)" : joined
    }

    private static func parseJSON3Captions(_ json: String) -> String {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let events = obj["events"] as? [[String: Any]]
        else { return "" }
        var parts: [String] = []
        for ev in events {
            guard let segs = ev["segs"] as? [[String: Any]] else { continue }
            for seg in segs {
                if let utf8 = seg["utf8"] as? String {
                    let t = utf8.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty, t != "\n" { parts.append(t) }
                }
            }
        }
        let joined = parts.joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return joined.count > 100_000 ? String(joined.prefix(100_000)) + "\n\n…(truncated)" : joined
    }

    // MARK: - Write note

    @MainActor
    private static func writeSourceNote(
        title: String,
        sourceType: String,
        sourceURL: String?,
        body: String,
        into vault: VaultService
    ) throws -> Result {
        ensureSourcesFolder(vault)
        let safe = sanitizeFilename(title)
        let day = dayStamp()
        var front = """
        ---
        title: \(title)
        source_type: \(sourceType)
        imported: \(day)
        tags: [source, \(sourceType)]
        """
        if let sourceURL {
            front += "\nsource_url: \(sourceURL)"
        }
        front += "\n---\n\n"
        let content = front + "# \(title)\n\n" + body.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        guard let path = vault.createNote(named: safe, inFolder: "Sources", content: content) else {
            throw ImportError.unreadable
        }
        return Result(path: path, title: title)
    }

    @MainActor
    private static func ensureSourcesFolder(_ vault: VaultService) {
        _ = vault.createFolder(named: "Sources")
    }

    private static func sanitizeFilename(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = name.components(separatedBy: invalid).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Imported \(dayStamp())" : String(cleaned.prefix(80))
    }

    private static func dayStamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    /// Minimal HTML → Markdown (title + text blocks). Good enough for article capture.
    private static func htmlToMarkdown(_ html: String, fallbackTitle: String) -> (String, String) {
        var title = fallbackTitle
        if let range = html.range(of: #"<title[^>]*>(.*?)</title>"#, options: [.regularExpression, .caseInsensitive]) {
            let raw = String(html[range])
            title = raw
                .replacingOccurrences(of: #"</?title[^>]*>"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if title.isEmpty { title = fallbackTitle }
        }

        var text = html
        // Drop scripts/styles
        text = text.replacingOccurrences(of: #"<script[\s\S]*?</script>"#, with: " ", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: #"<style[\s\S]*?</style>"#, with: " ", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: #"<nav[\s\S]*?</nav>"#, with: " ", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: #"<footer[\s\S]*?</footer>"#, with: " ", options: [.regularExpression, .caseInsensitive])

        // Headings
        for level in 1...6 {
            let pattern = "<h\(level)[^>]*>(.*?)</h\(level)>"
            text = text.replacingOccurrences(
                of: pattern,
                with: "\n\n" + String(repeating: "#", count: level) + " $1\n\n",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        text = text.replacingOccurrences(of: #"<br\s*/?>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: #"</p>"#, with: "\n\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: #"</div>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: #"<li[^>]*>"#, with: "\n- ", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)

        // Decode a few entities
        let entities = [
            "&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">",
            "&quot;": "\"", "&#39;": "'", "&apos;": "'",
        ]
        for (k, v) in entities {
            text = text.replacingOccurrences(of: k, with: v)
        }

        // Collapse whitespace
        while text.contains("\n\n\n") {
            text = text.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Cap huge pages
        if text.count > 80_000 {
            text = String(text.prefix(80_000)) + "\n\n…(truncated)"
        }
        return (title, text)
    }
}
