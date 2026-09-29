import Foundation
import Combine
import AppKit

/// Local-first vault: pure folders of Markdown + attachments, with FSEvents live reload.
/// Incremental note updates + SQLite FTS sidecar (`.nexus/index.sqlite`).
@MainActor
final class VaultService: ObservableObject {
    @Published private(set) var rootURL: URL?
    @Published private(set) var tree: [VaultNode] = []
    @Published private(set) var notes: [String: NoteDocument] = [:] // path -> doc
    @Published private(set) var isIndexing = false
    @Published private(set) var noteCount = 0
    @Published private(set) var lastError: String?

    /// Per-vault SQLite index (FTS + graph positions). Nil when no vault open.
    private(set) var indexStore: VaultIndexStore?

    private var watcher: DirectoryWatcher?
    private var bookmarkData: Data?
    private let fm = FileManager.default
    private var reloadTask: Task<Void, Never>?
    /// Suppress FSEvents-driven full rescans while we write from this process.
    private var suppressWatcherUntil: Date = .distantPast

    nonisolated static let supportedNoteExtensions: Set<String> = ["md", "markdown"]
    nonisolated static let attachmentExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "svg", "pdf",
        "mp3", "wav", "mp4", "mov", "zip"
    ]

    var isOpen: Bool { rootURL != nil }

    var knownPaths: Set<String> { Set(notes.keys) }

    // MARK: - Open / close

    /// Called after any vault content mutation (create/save/rename/delete or
    /// FSEvents rescan). GitSyncService uses this to schedule debounced autocommits.
    var onNoteMutated: ((String) -> Void)?

    /// Called after Nexus persists workspace state into `<vault>/.nexus/workspace.json`
    /// (last vault path, tabs, layout). GitSyncService uses this to keep that
    /// machine-local file out of every sync commit.
    var onWorkspaceSaved: ((String) -> Void)?

    /// Path of the per-vault workspace sidecar (relative to vault root).
    nonisolated static func workspaceSidecarPath(for vaultRoot: URL) -> String {
        ".nexus/workspace.json"
    }

    func openVault(at url: URL) {
        closeVault()
        let standardized = url.standardizedFileURL
        guard fm.fileExists(atPath: standardized.path) else {
            lastError = "Folder does not exist."
            return
        }

        do {
            bookmarkData = try standardized.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(bookmarkData, forKey: "nexus.vaultBookmark")
            UserDefaults.standard.set(standardized.path, forKey: "nexus.vaultPath")
        } catch {
            UserDefaults.standard.set(standardized.path, forKey: "nexus.vaultPath")
        }

        _ = standardized.startAccessingSecurityScopedResource()
        rootURL = standardized

        let store = VaultIndexStore()
        do {
            try store.open(vaultRoot: standardized)
            indexStore = store
        } catch {
            lastError = "Index open failed: \(error.localizedDescription)"
            indexStore = nil
        }

        WorkspaceService.onVaultWorkspaceSaved = { [weak self] path in
            self?.onWorkspaceSaved?(path)
        }

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
        indexStore?.close()
        indexStore = nil
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
        let previous = notes
        // Prefer in-memory mtimes; fall back to SQLite for cold start.
        var cachedMtimes = Dictionary(uniqueKeysWithValues: previous.map { ($0.key, $0.value.modified) })
        if cachedMtimes.isEmpty {
            cachedMtimes = indexStore?.modifiedTimes() ?? [:]
        }

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let result = await self.scanVault(root: root, cachedMtimes: cachedMtimes, previousNotes: previous)
            await MainActor.run {
                var merged = result.notes
                for path in result.unchangedPaths {
                    if merged[path] == nil, let old = previous[path] {
                        merged[path] = old
                    }
                }
                self.tree = result.tree
                self.notes = merged
                self.noteCount = merged.count
                self.isIndexing = false
                self.syncIndex(with: merged)
            }
        }
    }

    /// Incremental rescan: only reparse notes whose mtime changed.
    /// Marker passed to onNoteMutated for "the tree changed" events (vs a specific path).
    static let rescanChangeToken = "__rescan__"

    func incrementalRescan() {
        guard let root = rootURL else { return }
        isIndexing = true
        let previous = notes
        let cachedMtimes = Dictionary(uniqueKeysWithValues: previous.map { ($0.key, $0.value.modified) })

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let result = await self.scanVault(root: root, cachedMtimes: cachedMtimes, previousNotes: previous)
            await MainActor.run {
                var merged = previous
                // Remove deleted
                let stillPresent = Set(result.notes.keys).union(result.unchangedPaths)
                for path in merged.keys where !stillPresent.contains(path) {
                    merged.removeValue(forKey: path)
                    self.indexStore?.removeNote(path: path)
                }
                // Apply changed
                for (path, doc) in result.notes {
                    merged[path] = doc
                }
                self.tree = result.tree
                self.notes = merged
                self.noteCount = merged.count
                self.isIndexing = false
                self.syncIndex(with: merged)
                // Notify only when the scan changed something, so a git pull (which
                // lands as external file changes) schedules a re-commit of merged
                // state while pure watcher churn stays silent.
                if merged != previous {
                    self.onNoteMutated?(VaultService.rescanChangeToken)
                }
            }
        }
    }

    nonisolated private func scanVault(
        root: URL,
        cachedMtimes: [String: Date],
        previousNotes: [String: NoteDocument]
    ) async -> (tree: [VaultNode], notes: [String: NoteDocument], unchangedPaths: Set<String>) {
        let fm = FileManager.default
        var notes: [String: NoteDocument] = [:]
        var unchanged = Set<String>()
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
                if CloudVaultSupport.shouldSkipFile(name: name) { continue }
                if name == ".nexus" || name == ".obsidian" { continue }
                // Conflict copies still appear in tree but tagged via name (user can merge).

                let rel = relative(of: child)
                let isDir = values?.isDirectory == true
                let modified = values?.contentModificationDate

                if isDir {
                    let children = walk(child)
                    nodes.append(VaultNode(id: rel, name: name, kind: .folder, children: children, modified: modified))
                } else {
                    let ext = child.pathExtension.lowercased()
                    if Self.supportedNoteExtensions.contains(ext) {
                        let mtime = modified ?? .distantPast
                        if let cached = cachedMtimes[rel],
                           abs(cached.timeIntervalSince1970 - mtime.timeIntervalSince1970) < 0.501,
                           previousNotes[rel] != nil || cachedMtimes[rel] != nil {
                            // Skip reparse — caller merges previous content
                            unchanged.insert(rel)
                            // Still need a placeholder if previousNotes empty (full scan first open with index mtimes)
                            if let prev = previousNotes[rel] {
                                notes[rel] = prev
                                unchanged.insert(rel)
                            } else if let doc = loadNote(at: child, relativePath: rel) {
                                // Have mtime in SQLite but not memory — load once
                                notes[rel] = doc
                            }
                            nodes.append(VaultNode(id: rel, name: name, kind: .note, children: [], modified: modified))
                        } else if let doc = loadNote(at: child, relativePath: rel) {
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
        return (tree, notes, unchanged)
    }

    nonisolated private func loadNote(at url: URL, relativePath: String) -> NoteDocument? {
        CloudVaultSupport.ensureDownloaded(at: url)
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

    private func syncIndex(with notes: [String: NoteDocument]) {
        guard let indexStore else { return }
        for (path, note) in notes {
            indexStore.upsertNote(
                path: path,
                title: note.title,
                folder: note.folderPath,
                tags: note.tags,
                modified: note.modified,
                content: note.content
            )
        }
        indexStore.removeNotes(notIn: Set(notes.keys))
    }

    private func upsertIndex(for path: String, doc: NoteDocument) {
        indexStore?.upsertNote(
            path: path,
            title: doc.title,
            folder: doc.folderPath,
            tags: doc.tags,
            modified: doc.modified,
            content: doc.content
        )
    }

    private func markSelfWrite() {
        suppressWatcherUntil = Date().addingTimeInterval(0.6)
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
            if !folder.isEmpty {
                try fm.createDirectory(
                    at: root.appendingPathComponent(folder),
                    withIntermediateDirectories: true
                )
            }
            markSelfWrite()
            try CloudVaultSupport.atomicWrite(body, to: url)
            if let doc = loadNote(at: url, relativePath: rel) {
                notes[rel] = doc
                noteCount = notes.count
                upsertIndex(for: rel, doc: doc)
                patchTreeInsertNote(path: rel, name: fileName, modified: doc.modified)
            }
            onNoteMutated?(rel)
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
            markSelfWrite()
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            patchTreeInsertFolder(path: rel, name: name)
            return rel
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    func saveNote(path: String, content: String) {
        guard let url = absoluteURL(for: path) else { return }
        do {
            markSelfWrite()
            try CloudVaultSupport.atomicWrite(content, to: url)
            if let doc = loadNote(at: url, relativePath: path) {
                notes[path] = doc
                upsertIndex(for: path, doc: doc)
                onNoteMutated?(path)
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func deleteNode(path: String) {
        guard let url = absoluteURL(for: path) else { return }
        do {
            markSelfWrite()
            try fm.trashItem(at: url, resultingItemURL: nil)
            // Remove note and any nested paths
            let prefix = path.hasSuffix("/") ? path : path + "/"
            let toRemove = notes.keys.filter { $0 == path || $0.hasPrefix(prefix) }
            for p in toRemove {
                notes.removeValue(forKey: p)
                indexStore?.removeNote(path: p)
            }
            noteCount = notes.count
            removeFromTree(path: path)
            onNoteMutated?(path)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func renameNode(path: String, newName: String) {
        guard let url = absoluteURL(for: path) else { return }
        let parent = url.deletingLastPathComponent()
        let dest = parent.appendingPathComponent(newName)
        do {
            markSelfWrite()
            try fm.moveItem(at: url, to: dest)
            // For simplicity, incremental rescan after rename (path graph changes)
            incrementalRescan()
            onNoteMutated?(path)
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
            markSelfWrite()
            let data = try JSONEncoder().encode(document)
            try data.write(to: url, options: .atomic)
            onNoteMutated?(path)
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

    // MARK: - Tree patches

    private func patchTreeInsertNote(path: String, name: String, modified: Date?) {
        let parentPath = (path as NSString).deletingLastPathComponent
        let node = VaultNode(id: path, name: name, kind: .note, children: [], modified: modified)
        if parentPath.isEmpty || parentPath == "." {
            if !tree.contains(where: { $0.id == path }) {
                tree.append(node)
                tree.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            }
            return
        }
        tree = insertChild(node, parentPath: parentPath, into: tree)
    }

    private func patchTreeInsertFolder(path: String, name: String) {
        let parentPath = (path as NSString).deletingLastPathComponent
        let node = VaultNode(id: path, name: name, kind: .folder, children: [], modified: Date())
        if parentPath.isEmpty || parentPath == "." {
            if !tree.contains(where: { $0.id == path }) {
                tree.append(node)
                tree.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            }
            return
        }
        tree = insertChild(node, parentPath: parentPath, into: tree)
    }

    private func insertChild(_ node: VaultNode, parentPath: String, into nodes: [VaultNode]) -> [VaultNode] {
        nodes.map { n in
            var copy = n
            if copy.id == parentPath && copy.isFolder {
                if !copy.children.contains(where: { $0.id == node.id }) {
                    copy.children.append(node)
                    copy.children.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                }
            } else if copy.isFolder {
                copy.children = insertChild(node, parentPath: parentPath, into: copy.children)
            }
            return copy
        }
    }

    private func removeFromTree(path: String) {
        func filterNodes(_ nodes: [VaultNode]) -> [VaultNode] {
            nodes.compactMap { n in
                if n.id == path { return nil }
                var copy = n
                if copy.isFolder {
                    copy.children = filterNodes(copy.children)
                }
                return copy
            }
        }
        tree = filterNodes(tree)
    }

    // MARK: - Watcher

    private func startWatching() {
        guard let root = rootURL else { return }
        watcher?.stop()
        watcher = DirectoryWatcher(url: root) { [weak self] changedPaths in
            Task { @MainActor in
                self?.scheduleReload(changedPaths: changedPaths)
            }
        }
        watcher?.start()
    }

    private func scheduleReload(changedPaths: [String] = []) {
        if Date() < suppressWatcherUntil { return }
        // Ignore internal sidecar churn (.nexus/index.sqlite, workspace.json).
        // Those used to FSEvent → rescan → link rebuild → graph load → physics explosion.
        if !changedPaths.isEmpty {
            let relevant = changedPaths.contains { path in
                let p = path.lowercased()
                if p.contains("/.nexus/") || p.hasSuffix("/.nexus") { return false }
                if p.contains("/.obsidian/") || p.hasSuffix("/.obsidian") { return false }
                if p.hasSuffix(".nexus-tmp") || p.contains(".nexus-tmp-") { return false }
                return true
            }
            if !relevant { return }
        }
        reloadTask?.cancel()
        let delay = CloudVaultSupport.rescanDebounceNanoseconds(for: rootURL)
        reloadTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            if Date() < suppressWatcherUntil { return }
            incrementalRescan()
        }
    }

    /// Suppress FSEvents briefly (e.g. while writing graph positions into `.nexus/`).
    func suppressExternalReload(for seconds: TimeInterval = 1.0) {
        suppressWatcherUntil = Date().addingTimeInterval(seconds)
    }

    /// True when vault lives under iCloud Drive / ubiquitous container.
    var isICloudVault: Bool {
        guard let rootURL else { return false }
        return CloudVaultSupport.isLikelyICloudVault(rootURL)
    }

    /// Notes that look like conflict copies (for UI surfacing).
    var conflictCopyPaths: [String] {
        notes.keys.filter { CloudVaultSupport.isConflictCopy(name: ($0 as NSString).lastPathComponent) }.sorted()
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
    /// Changed absolute paths (may be empty if the event payload couldn't be read).
    private let callback: ([String]) -> Void

    init(url: URL, callback: @escaping ([String]) -> Void) {
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
            { _, info, numEvents, eventPaths, _, _ in
                guard let info else { return }
                let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
                // With UseCFTypes, eventPaths is a CFArray of CFString paths.
                var changed: [String] = []
                let cfPaths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
                let count = min(Int(numEvents), CFArrayGetCount(cfPaths))
                for i in 0..<count {
                    guard let raw = CFArrayGetValueAtIndex(cfPaths, i) else { continue }
                    let s = Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
                    changed.append(s)
                }
                watcher.callback(changed)
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
