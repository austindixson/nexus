import Foundation
import Combine
import AppKit

/// Local-first vault: pure folders of Markdown + attachments, with FSEvents live reload.
@MainActor
final class VaultService: ObservableObject {
    @Published private(set) var rootURL: URL?
    @Published private(set) var tree: [VaultNode] = []
    @Published private(set) var notes: [String: NoteDocument] = [:] // path -> doc
    @Published private(set) var isIndexing = false
    @Published private(set) var noteCount = 0
    @Published private(set) var lastError: String?

    private var watcher: DirectoryWatcher?
    private var bookmarkData: Data?
    private let fm = FileManager.default
    private var reloadTask: Task<Void, Never>?

    nonisolated static let supportedNoteExtensions: Set<String> = ["md", "markdown"]
    nonisolated static let attachmentExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "svg", "pdf",
        "mp3", "wav", "mp4", "mov", "zip"
    ]

    var isOpen: Bool { rootURL != nil }

    var knownPaths: Set<String> { Set(notes.keys) }

    // MARK: - Open / close

    func openVault(at url: URL) {
        closeVault()
        let standardized = url.standardizedFileURL
        guard fm.fileExists(atPath: standardized.path) else {
            lastError = "Folder does not exist."
            return
        }

        // Security-scoped bookmark for relaunch
        do {
            bookmarkData = try standardized.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(bookmarkData, forKey: "nexus.vaultBookmark")
            UserDefaults.standard.set(standardized.path, forKey: "nexus.vaultPath")
        } catch {
            // Still proceed for non-sandboxed runs
            UserDefaults.standard.set(standardized.path, forKey: "nexus.vaultPath")
        }

        _ = standardized.startAccessingSecurityScopedResource()
        rootURL = standardized
        fullRescan()
        startWatching()
    }

    func restoreLastVault() {
        if let data = UserDefaults.standard.data(forKey: "nexus.vaultBookmark") {
            var isStale = false
            do {
                let url = try URL(
                    resolvingBookmarkData: data,
                    options: [.withSecurityScope],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
                openVault(at: url)
                return
            } catch {
                // fall through
            }
        }
        if let path = UserDefaults.standard.string(forKey: "nexus.vaultPath") {
            openVault(at: URL(fileURLWithPath: path))
        }
    }

    func closeVault() {
        watcher?.stop()
        watcher = nil
        if let rootURL {
            rootURL.stopAccessingSecurityScopedResource()
        }
        rootURL = nil
        tree = []
        notes = [:]
        noteCount = 0
    }

    // MARK: - Scanning

    func fullRescan() {
        guard let root = rootURL else { return }
        isIndexing = true
        lastError = nil

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let result = await self.scanVault(root: root)
            await MainActor.run {
                self.tree = result.tree
                self.notes = result.notes
                self.noteCount = result.notes.count
                self.isIndexing = false
            }
        }
    }

    nonisolated private func scanVault(root: URL) async -> (tree: [VaultNode], notes: [String: NoteDocument]) {
        let fm = FileManager.default
        var notes: [String: NoteDocument] = [:]
        let rootPath = root.standardizedFileURL.path

        func relative(of url: URL) -> String {
            let p = url.standardizedFileURL.path
            if p.hasPrefix(rootPath) {
                let rel = String(p.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                return rel
            }
            return url.lastPathComponent
        }

        func walk(_ dir: URL) -> [VaultNode] {
            var nodes: [VaultNode] = []
            let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey, .isHiddenKey]
            guard let kids = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: keys,
                options: [.skipsPackageDescendants]
            ) else { return [] }

            let sorted = kids.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

            for child in sorted {
                let values = try? child.resourceValues(forKeys: Set(keys))
                if values?.isHidden == true { continue }
                let name = child.lastPathComponent
                if name.hasPrefix(".") { continue }
                if name == ".nexus" || name == ".obsidian" { continue } // allow reading later; hide from tree root clutter optionally

                let rel = relative(of: child)
                let isDir = values?.isDirectory == true
                let modified = values?.contentModificationDate

                if isDir {
                    let children = walk(child)
                    nodes.append(VaultNode(id: rel, name: name, kind: .folder, children: children, modified: modified))
                } else {
                    let ext = child.pathExtension.lowercased()
                    if Self.supportedNoteExtensions.contains(ext) {
                        if let doc = loadNote(at: child, relativePath: rel) {
                            notes[rel] = doc
                            nodes.append(VaultNode(id: rel, name: name, kind: .note, children: [], modified: modified))
                        }
                    } else if ext == "canvas" {
                        nodes.append(VaultNode(id: rel, name: name, kind: .canvas, children: [], modified: modified))
                    } else if Self.attachmentExtensions.contains(ext) {
                        nodes.append(VaultNode(id: rel, name: name, kind: .attachment, children: [], modified: modified))
                    }
                }
            }
            return nodes
        }

        let tree = walk(root)
        return (tree, notes)
    }

    nonisolated private func loadNote(at url: URL, relativePath: String) -> NoteDocument? {
        guard let data = try? Data(contentsOf: url),
              let content = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        else { return nil }

        let (meta, _) = MarkdownParser.parseFrontmatter(content)
        let tags = MarkdownParser.extractTags(from: content, frontmatter: meta)
        let links = MarkdownParser.extractWikiLinks(from: content)
        let headings = MarkdownParser.extractHeadings(from: content)
        let title = meta["title"] ?? (relativePath as NSString).deletingPathExtension
            .components(separatedBy: "/").last ?? relativePath
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()

        return NoteDocument(
            id: relativePath,
            title: title,
            content: content,
            absoluteURL: url,
            modified: modified,
            frontmatter: meta,
            tags: tags,
            outgoingLinks: links,
            headings: headings
        )
    }

    // MARK: - CRUD

    func absoluteURL(for relativePath: String) -> URL? {
        guard let root = rootURL else { return nil }
        return root.appendingPathComponent(relativePath)
    }

    @discardableResult
    func createNote(named name: String? = nil, inFolder folder: String = "", content: String? = nil) -> String? {
        guard let root = rootURL else { return nil }
        let base = name ?? "Untitled \(formattedStamp())"
        var fileName = base.hasSuffix(".md") ? base : base + ".md"
        var rel = folder.isEmpty ? fileName : (folder as NSString).appendingPathComponent(fileName)
        var url = root.appendingPathComponent(rel)
        var i = 1
        while fm.fileExists(atPath: url.path) {
            let stem = (base as NSString).deletingPathExtension
            fileName = "\(stem) \(i).md"
            rel = folder.isEmpty ? fileName : (folder as NSString).appendingPathComponent(fileName)
            url = root.appendingPathComponent(rel)
            i += 1
        }

        let title = (fileName as NSString).deletingPathExtension
        let day: String = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd"
            return f.string(from: Date())
        }()
        let body = content ?? """
        ---
        title: \(title)
        description: 
        updated: \(day)
        tags: []
        ---

        # \(title)

        """
        do {
            try body.write(to: url, atomically: true, encoding: .utf8)
            if let doc = loadNote(at: url, relativePath: rel) {
                notes[rel] = doc
            }
            fullRescan()
            return rel
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    func createFolder(named name: String, inFolder folder: String = "") -> String? {
        guard let root = rootURL else { return nil }
        let rel = folder.isEmpty ? name : (folder as NSString).appendingPathComponent(name)
        let url = root.appendingPathComponent(rel)
        do {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            fullRescan()
            return rel
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    func saveNote(path: String, content: String) {
        guard let url = absoluteURL(for: path) else { return }
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            if let doc = loadNote(at: url, relativePath: path) {
                notes[path] = doc
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func deleteNode(path: String) {
        guard let url = absoluteURL(for: path) else { return }
        do {
            try fm.trashItem(at: url, resultingItemURL: nil)
            notes.removeValue(forKey: path)
            fullRescan()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func renameNode(path: String, newName: String) {
        guard let url = absoluteURL(for: path) else { return }
        let parent = url.deletingLastPathComponent()
        let dest = parent.appendingPathComponent(newName)
        do {
            try fm.moveItem(at: url, to: dest)
            fullRescan()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func readFile(path: String) -> String? {
        guard let url = absoluteURL(for: path) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    func writeCanvas(path: String, document: CanvasDocument) {
        guard let url = absoluteURL(for: path) else { return }
        do {
            let data = try JSONEncoder().encode(document)
            try data.write(to: url, options: .atomic)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func loadCanvas(path: String) -> CanvasDocument {
        guard let url = absoluteURL(for: path),
              let data = try? Data(contentsOf: url),
              let doc = try? JSONDecoder().decode(CanvasDocument.self, from: data)
        else {
            return CanvasDocument(nodes: [], edges: [], groups: [])
        }
        return doc
    }

    // MARK: - Watcher

    private func startWatching() {
        guard let root = rootURL else { return }
        watcher?.stop()
        watcher = DirectoryWatcher(url: root) { [weak self] in
            Task { @MainActor in
                self?.scheduleReload()
            }
        }
        watcher?.start()
    }

    private func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            fullRescan()
        }
    }

    private func formattedStamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HHmmss"
        return f.string(from: Date())
    }
}

// MARK: - FSEvents wrapper

final class DirectoryWatcher {
    private var stream: FSEventStreamRef?
    private let url: URL
    private let callback: () -> Void

    init(url: URL, callback: @escaping () -> Void) {
        self.url = url
        self.callback = callback
    }

    func start() {
        let path = url.path as CFString
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let paths = [path] as CFArray
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes
            | kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagNoDefer
        )

        stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, _, _, _, _ in
                guard let info else { return }
                let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
                watcher.callback()
            },
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.2,
            flags
        )

        if let stream {
            FSEventStreamScheduleWithRunLoop(stream, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            FSEventStreamStart(stream)
        }
    }

    func stop() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }

    deinit { stop() }
}
