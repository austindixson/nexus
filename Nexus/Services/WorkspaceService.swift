import Foundation
import AppKit

/// Persists UI layout / open tabs / graph filters across launches.
/// App-wide defaults in UserDefaults; per-vault snapshot in `<vault>/.nexus/workspace.json`.
enum WorkspaceService {
    private static let defaultsKey = "nexus.workspace.v1"

    struct Snapshot: Codable, Equatable {
        var mainMode: String
        var editorMode: String
        var showLeftSidebar: Bool
        var showRightSidebar: Bool
        var leftSidebarTab: String
        var rightSidebarTab: String
        var selectedPath: String?
        var openTabs: [String]
        var graphMode: String
        var graphLocalDepth: Int
        var graphShowTags: Bool
        var graphShowOrphans: Bool
        var graphShowUnresolved: Bool
        var graphShowAttachments: Bool
        var graphQuery: String
        var graphColorBy: String
        var graphLabels: String
        var useMetalGraph: Bool
        var appearance: String
        var windowFrame: String?

        @MainActor
        static func capture(from app: AppState) -> Snapshot {
            Snapshot(
                mainMode: app.mainMode.rawValue,
                editorMode: app.editorMode.rawValue,
                showLeftSidebar: app.showLeftSidebar,
                showRightSidebar: app.showRightSidebar,
                leftSidebarTab: app.leftSidebarTab.rawValue,
                rightSidebarTab: app.rightSidebarTab.rawValue,
                selectedPath: app.selectedPath,
                openTabs: app.openTabs,
                graphMode: app.graphMode.rawValue,
                graphLocalDepth: app.graphLocalDepth,
                graphShowTags: app.graphShowTags,
                graphShowOrphans: app.graphShowOrphans,
                graphShowUnresolved: app.graphShowUnresolved,
                graphShowAttachments: app.graphShowAttachments,
                graphQuery: app.graphQuery,
                graphColorBy: app.graphColorBy.rawValue,
                graphLabels: app.graphLabels.rawValue,
                useMetalGraph: app.useMetalGraph,
                appearance: app.appearance.rawValue,
                windowFrame: NSApp.keyWindow.map { NSStringFromRect($0.frame) }
            )
        }

        @MainActor
        func apply(to app: AppState, restoreSelection: Bool) {
            if let m = MainMode(rawValue: mainMode) { app.mainMode = m }
            if let m = EditorMode(rawValue: editorMode) { app.editorMode = m }
            app.showLeftSidebar = showLeftSidebar
            app.showRightSidebar = showRightSidebar
            if let t = LeftSidebarTab(rawValue: leftSidebarTab) { app.leftSidebarTab = t }
            if let t = RightSidebarTab(rawValue: rightSidebarTab) { app.rightSidebarTab = t }
            if let m = GraphViewMode(rawValue: graphMode) { app.graphMode = m }
            app.graphLocalDepth = min(max(graphLocalDepth, 1), 5)
            app.graphShowTags = graphShowTags
            app.graphShowOrphans = graphShowOrphans
            app.graphShowUnresolved = graphShowUnresolved
            app.graphShowAttachments = graphShowAttachments
            app.graphQuery = graphQuery
            if let c = GraphColorMode(rawValue: graphColorBy) { app.graphColorBy = c }
            if let l = GraphLabelMode(rawValue: graphLabels) { app.graphLabels = l }
            app.useMetalGraph = useMetalGraph
            if let a = AppAppearance(rawValue: appearance) { app.appearance = a }

            if restoreSelection {
                let existingTabs = openTabs.filter { app.vault.notes[$0] != nil || $0.hasSuffix(".canvas") }
                app.openTabs = existingTabs
                if let path = selectedPath, existingTabs.contains(path) || app.vault.notes[path] != nil {
                    if path.hasSuffix(".canvas") {
                        app.openCanvas(path: path)
                    } else {
                        app.openNote(path: path)
                    }
                } else if let first = existingTabs.first {
                    app.openNote(path: first)
                }
            }

            if let windowFrame, let frame = Optional(NSRectFromString(windowFrame)),
               frame.width > 200, frame.height > 200,
               let window = NSApp.windows.first(where: { $0.isVisible || $0.isMainWindow }) ?? NSApp.windows.first {
                window.setFrame(frame, display: true)
            }
        }
    }

    static func saveAppDefaults(_ snapshot: Snapshot) {
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    static func loadAppDefaults() -> Snapshot? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    static func saveVaultWorkspace(_ snapshot: Snapshot, vaultRoot: URL?) {
        guard let vaultRoot else {
            saveAppDefaults(snapshot)
            return
        }
        let dir = vaultRoot.appendingPathComponent(".nexus", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("workspace.json")
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: url, options: .atomic)
        }
        saveAppDefaults(snapshot)
    }

    static func loadVaultWorkspace(vaultRoot: URL?) -> Snapshot? {
        if let vaultRoot {
            let url = vaultRoot.appendingPathComponent(".nexus/workspace.json")
            if let data = try? Data(contentsOf: url),
               let snap = try? JSONDecoder().decode(Snapshot.self, from: data) {
                return snap
            }
        }
        return loadAppDefaults()
    }
}
