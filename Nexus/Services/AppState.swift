import Foundation
import SwiftUI
import AppKit
import Combine

@MainActor
final class AppState: ObservableObject {
    let vault = VaultService()
    let linkIndex = LinkIndex()

    // Navigation / layout
    @Published var mainMode: MainMode = .editor
    @Published var editorMode: EditorMode = .split
    @Published var selectedPath: String?
    @Published var openTabs: [String] = []
    @Published var leftSidebarTab: LeftSidebarTab = .files
    @Published var rightSidebarTab: RightSidebarTab = .backlinks
    @Published var showLeftSidebar = true
    @Published var showRightSidebar = true
    @Published var showCommandPalette = false
    @Published var showQuickSwitcher = false
    @Published var searchQuery = ""
    @Published var focusSearchToken = UUID()

    // Editor buffer
    @Published var draftContent: String = ""
    @Published var isDirty = false
    private var saveTask: Task<Void, Never>?

    // Graph
    @Published var graphMode: GraphViewMode = .global
    @Published var graphLocalDepth = 1
    @Published var graphShowTags = false
    @Published var graphShowOrphans = true
    @Published var graphShowUnresolved = true
    @Published var graphShowAttachments = false
    @Published var graphQuery = ""
    @Published var graphColorBy: GraphColorMode = .folder
    @Published var graphLabels: GraphLabelMode = .hover
    @Published var graphPhysics = GraphPhysicsSettings()
    @Published var graphResetCamera = UUID()
    @Published var graphReheat = UUID()
    @Published var graphPresets: [GraphPreset] = GraphPreset.defaults
    /// Prefer Metal for graph nodes/edges when available (CPU layout unchanged).
    @Published var useMetalGraph = true

    // Canvas
    @Published var activeCanvasPath: String?
    @Published var canvasDocument = CanvasDocument(nodes: [], edges: [], groups: [])

    // Theme
    @Published var appearance: AppAppearance = .dark {
        didSet {
            applyAppearance()
            UserDefaults.standard.set(appearance.rawValue, forKey: "nexus.appearance")
        }
    }

    private var cancellables = Set<AnyCancellable>()
    private var workspaceSaveTask: Task<Void, Never>?
    private var isRestoringWorkspace = false

    init() {
        if let raw = UserDefaults.standard.string(forKey: "nexus.appearance"),
           let a = AppAppearance(rawValue: raw) {
            appearance = a
        }
        applyAppearance()

        vault.$notes
            .debounce(for: .milliseconds(100), scheduler: RunLoop.main)
            .sink { [weak self] notes in
                self?.linkIndex.rebuild(from: notes)
            }
            .store(in: &cancellables)

        vault.$rootURL
            .dropFirst()
            .sink { [weak self] _ in
                self?.restoreWorkspaceForCurrentVault()
            }
            .store(in: &cancellables)

        // Lightweight autosave: objectWillChange fires on any @Published mutation.
        objectWillChange
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.scheduleWorkspaceSave()
            }
            .store(in: &cancellables)

        vault.restoreLastVault()
        // Restore workspace after vault notes index has a moment to load
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.restoreWorkspaceForCurrentVault()
        }
    }

    func scheduleWorkspaceSave() {
        guard !isRestoringWorkspace else { return }
        workspaceSaveTask?.cancel()
        workspaceSaveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            saveWorkspaceNow()
        }
    }

    func saveWorkspaceNow() {
        guard !isRestoringWorkspace else { return }
        let snap = WorkspaceService.Snapshot.capture(from: self)
        WorkspaceService.saveVaultWorkspace(snap, vaultRoot: vault.rootURL)
    }

    func restoreWorkspaceForCurrentVault() {
        guard let snap = WorkspaceService.loadVaultWorkspace(vaultRoot: vault.rootURL) else { return }
        isRestoringWorkspace = true
        snap.apply(to: self, restoreSelection: vault.isOpen)
        isRestoringWorkspace = false
    }

    // MARK: - Vault UI actions

    func openVaultPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Open Vault"
        panel.message = "Choose a folder of Markdown notes"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                self?.saveWorkspaceNow()
                self?.vault.openVault(at: url)
                self?.selectedPath = nil
                self?.openTabs = []
                self?.draftContent = ""
                // Per-vault workspace restored via rootURL publisher + delayed restore
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    self?.restoreWorkspaceForCurrentVault()
                }
            }
        }
    }

    func createNote() {
        let folder = selectedFolderHint()
        if let path = vault.createNote(inFolder: folder) {
            openNote(path: path)
        }
    }

    func createFolder() {
        let alert = NSAlert()
        alert.messageText = "New Folder"
        alert.informativeText = "Name for the new folder:"
        let field = NSTextField(string: "New Folder")
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return }
            _ = vault.createFolder(named: name, inFolder: selectedFolderHint())
        }
    }

    func openDailyNote() {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        let name = f.string(from: Date())
        // Prefer Daily/ folder if present
        let folder = vault.tree.contains(where: { $0.name == "Daily" && $0.isFolder }) ? "Daily" : ""
        if let existing = vault.notes.keys.first(where: {
            ($0 as NSString).lastPathComponent == "\(name).md"
        }) {
            openNote(path: existing)
            return
        }
        let template = """
        # \(name)

        ## Tasks
        - [ ]

        ## Notes

        """
        if let path = vault.createNote(named: name, inFolder: folder, content: template) {
            openNote(path: path)
        }
    }

    func openNote(path: String) {
        flushSave()
        selectedPath = path
        mainMode = .editor
        if !openTabs.contains(path) {
            openTabs.append(path)
        }
        draftContent = vault.notes[path]?.content ?? vault.readFile(path: path) ?? ""
        isDirty = false
    }

    func closeTab(_ path: String) {
        if path == selectedPath { flushSave() }
        openTabs.removeAll { $0 == path }
        if selectedPath == path {
            selectedPath = openTabs.last
            if let selectedPath {
                draftContent = vault.notes[selectedPath]?.content ?? ""
            } else {
                draftContent = ""
            }
            isDirty = false
        }
    }

    func updateDraft(_ text: String) {
        draftContent = text
        isDirty = true
        scheduleSave()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            flushSave()
        }
    }

    func flushSave() {
        guard isDirty, let path = selectedPath else { return }
        vault.saveNote(path: path, content: draftContent)
        isDirty = false
    }

    func toggleLeftSidebar() { showLeftSidebar.toggle() }
    func toggleRightSidebar() { showRightSidebar.toggle() }
    func focusSearch() {
        leftSidebarTab = .search
        showLeftSidebar = true
        focusSearchToken = UUID()
    }

    func openLocalGraph() {
        graphMode = .local
        mainMode = .graph
    }

    func openGraphForSelection() {
        graphMode = selectedPath == nil ? .global : .local
        mainMode = .graph
    }

    // MARK: - Templates

    func insertTemplate(_ body: String) {
        draftContent += (draftContent.hasSuffix("\n") || draftContent.isEmpty ? "" : "\n") + body
        isDirty = true
        scheduleSave()
    }

    // MARK: - Canvas

    func openCanvas(path: String) {
        activeCanvasPath = path
        canvasDocument = vault.loadCanvas(path: path)
        mainMode = .canvas
    }

    func newCanvas() {
        guard let path = vault.createNote(named: "Untitled Canvas", content: "") else { return }
        // Replace .md with .canvas — simple approach: write canvas file
        let canvasPath = (path as NSString).deletingPathExtension + ".canvas"
        if let root = vault.rootURL {
            let url = root.appendingPathComponent(canvasPath)
            let empty = CanvasDocument(
                nodes: [
                    CanvasCard(id: UUID().uuidString, x: 0, y: 0, width: 260, height: 140, type: "text", text: "New card", file: nil, color: nil)
                ],
                edges: [],
                groups: []
            )
            if let data = try? JSONEncoder().encode(empty) {
                try? data.write(to: url)
            }
            // remove the accidental md if created
            if let md = vault.absoluteURL(for: path) {
                try? FileManager.default.removeItem(at: md)
            }
            vault.fullRescan()
            openCanvas(path: canvasPath)
        }
    }

    func saveCanvas() {
        guard let path = activeCanvasPath else { return }
        vault.writeCanvas(path: path, document: canvasDocument)
    }

    // MARK: - Helpers

    private func selectedFolderHint() -> String {
        guard let selectedPath else { return "" }
        if selectedPath.hasSuffix(".md") || selectedPath.hasSuffix(".canvas") {
            return (selectedPath as NSString).deletingLastPathComponent
        }
        return selectedPath
    }

    private func applyAppearance() {
        switch appearance {
        case .system:
            NSApp.appearance = nil
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    var currentNote: NoteDocument? {
        guard let selectedPath else { return nil }
        return vault.notes[selectedPath]
    }

    var currentBacklinks: [Backlink] {
        guard let selectedPath else { return [] }
        return linkIndex.backlinks(for: selectedPath)
    }

    var currentUnlinked: [Backlink] {
        guard let selectedPath else { return [] }
        return linkIndex.unlinkedMentions(for: selectedPath)
    }
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

enum GraphColorMode: String, CaseIterable, Identifiable {
    case folder, tag, degree
    var id: String { rawValue }
    var title: String {
        switch self {
        case .folder: return "Folder"
        case .tag: return "Tag"
        case .degree: return "Connections"
        }
    }
}

enum GraphLabelMode: String, CaseIterable, Identifiable {
    case always, hover, never
    var id: String { rawValue }
    var title: String {
        switch self {
        case .always: return "Always"
        case .hover: return "On hover"
        case .never: return "Never"
        }
    }
}

struct GraphPhysicsSettings: Hashable {
    /// Many-body repulsion magnitude (Obsidian-like spread). Higher = more open layout.
    var repulsion: Double = 2800
    /// COM recenter strength 0…1 (d3 forceCenter). Structure-preserving — not a radial crush.
    var centerForce: Double = 1.0
    /// Ideal edge length in world units — longer = roomier connected cluster.
    var springLength: Double = 130
    /// Link stiffness (keep modest so repulsion can maintain spacing).
    var springStrength: Double = 0.022
    /// Velocity keep-factor after each tick (d3 velocityDecay ≈ 1 - damping). 0.6–0.85 is typical.
    var damping: Double = 0.72
    /// Global multiplier on charge / springs / collision.
    var animationStrength: Double = 1.0
    var linkThickness: Double = 1.0
}

struct GraphPreset: Identifiable, Hashable, Codable {
    var id: String
    var name: String
    var showTags: Bool
    var showOrphans: Bool
    var showUnresolved: Bool
    var query: String

    static let defaults: [GraphPreset] = [
        GraphPreset(id: "all", name: "All notes", showTags: false, showOrphans: true, showUnresolved: true, query: ""),
        GraphPreset(id: "connected", name: "No orphans", showTags: false, showOrphans: false, showUnresolved: false, query: ""),
        GraphPreset(id: "tags", name: "With tags", showTags: true, showOrphans: false, showUnresolved: false, query: ""),
    ]
}
