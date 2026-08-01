import SwiftUI

struct RootView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        ZStack {
            if app.vault.isOpen {
                mainWorkspace
            } else {
                WelcomeView()
            }

            if app.showCommandPalette {
                CommandPaletteView()
                    .transition(.opacity)
                    .zIndex(100)
            }

            if app.showQuickSwitcher {
                QuickSwitcherView()
                    .transition(.opacity)
                    .zIndex(100)
            }
        }
        .background(WindowAccessor())
        .animation(.easeOut(duration: 0.15), value: app.showCommandPalette)
        .animation(.easeOut(duration: 0.15), value: app.showQuickSwitcher)
    }

    private var mainWorkspace: some View {
        NavigationSplitView {
            if app.showLeftSidebar {
                LeftSidebarView()
                    .navigationSplitViewColumnWidth(min: 200, ideal: 260, max: 420)
            }
        } detail: {
            HSplitView {
                centerPane
                    .frame(minWidth: 420)

                if app.showRightSidebar {
                    RightSidebarView()
                        .frame(minWidth: 220, idealWidth: 280, maxWidth: 400)
                }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Picker("Mode", selection: $app.mainMode) {
                    ForEach(MainMode.allCases) { mode in
                        Label(mode.title, systemImage: icon(for: mode)).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 280)
            }

            ToolbarItemGroup(placement: .primaryAction) {
                if app.mainMode == .editor {
                    Picker("Editor", selection: $app.editorMode) {
                        Text("Source").tag(EditorMode.source)
                        Text("Preview").tag(EditorMode.livePreview)
                        Text("Split").tag(EditorMode.split)
                    }
                    .frame(width: 200)
                }

                Button {
                    app.showCommandPalette = true
                } label: {
                    Label("Command Palette", systemImage: "command")
                }
                .help("Command Palette (⌘P)")

                if app.vault.isIndexing {
                    ProgressView()
                        .controlSize(.small)
                }

                Text("\(app.vault.noteCount) notes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if app.mainMode == .editor && !app.openTabs.isEmpty {
                TabStripView()
            }
        }
    }

    @ViewBuilder
    private var centerPane: some View {
        switch app.mainMode {
        case .editor:
            EditorWorkspaceView()
        case .graph:
            GraphView()
        case .canvas:
            CanvasView()
        }
    }

    private func icon(for mode: MainMode) -> String {
        switch mode {
        case .editor: return "doc.richtext"
        case .graph: return "point.3.connected.trianglepath.dotted"
        case .canvas: return "rectangle.3.group"
        }
    }
}

// Soft titlebar material
struct WindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .visible
            window.isMovableByWindowBackground = false
            window.backgroundColor = NSColor.windowBackgroundColor
            window.toolbarStyle = .unified
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            window.titlebarAppearsTransparent = true
            window.toolbarStyle = .unified
        }
    }
}

struct WelcomeView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            VStack(spacing: 12) {
                Image(systemName: "circle.hexagongrid.fill")
                    .font(.system(size: 64, weight: .light))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.accentColor, Color.purple.opacity(0.8)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Text("Nexus")
                    .font(.system(size: 42, weight: .semibold, design: .rounded))
                Text("A native macOS knowledge base.\nLocal-first Markdown vaults. World-class graph.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }

            VStack(spacing: 12) {
                Button {
                    app.openVaultPanel()
                } label: {
                    Label("Open Vault…", systemImage: "folder")
                        .frame(minWidth: 200)
                }
                .controlSize(.large)
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .buttonStyle(.borderedProminent)

                Button {
                    createDemoVault()
                } label: {
                    Label("Create Sample Vault", systemImage: "sparkles")
                        .frame(minWidth: 200)
                }
                .controlSize(.large)
            }

            Text("Fully offline · No accounts · MIT License")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RadialGradient(
                colors: [Color.accentColor.opacity(0.12), Color.clear],
                center: .center,
                startRadius: 40,
                endRadius: 420
            )
        )
    }

    private func createDemoVault() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose Location"
        panel.message = "Pick a parent folder for the sample vault"
        panel.begin { response in
            guard response == .OK, let parent = panel.url else { return }
            let vaultURL = parent.appendingPathComponent("Nexus Sample Vault")
            let fm = FileManager.default
            try? fm.createDirectory(at: vaultURL, withIntermediateDirectories: true)
            let files: [String: String] = [
                "Welcome.md": """
                ---
                tags: [meta, welcome]
                ---
                # Welcome to Nexus

                Nexus is a **native macOS** knowledge base for local Markdown vaults.

                - Create notes with `[[Wikilinks]]`
                - Explore the **Graph View** (⌘⌥G)
                - Use the command palette (⌘P)

                ## Start here
                - [[Graph View]]
                - [[Daily Notes]]
                - [[Markdown Guide]]

                #inbox
                """,
                "Graph View.md": """
                # Graph View

                The graph is the centerpiece of Nexus:

                - Global and local graphs
                - Force-directed physics
                - Filters, presets, PNG export

                See also [[Welcome]] and [[Markdown Guide]].
                """,
                "Daily Notes.md": """
                # Daily Notes

                Press **⌘D** to open today's daily note.

                Related: [[Welcome]]
                """,
                "Markdown Guide.md": """
                # Markdown Guide

                ## Wikilinks
                Link with [[Welcome]] or [[Welcome|an alias]].

                ## Embeds
                ![[Welcome]]

                ## Callouts
                > [!tip] Live preview
                > Tables and callouts render in split / preview modes.

                > [!warning]
                > Unresolved wikilinks stay visible in the graph as grey nodes.

                ## Tables
                | Feature | Status |
                | --- | :---: |
                | Wikilinks | yes |
                | Callouts | yes |
                | Graph | yes |

                ## Math
                Inline $E = mc^2$ and display:

                $$
                \\int_0^1 x^2 \\, dx = \\frac{1}{3}
                $$

                ## Tasks
                - [x] Install Nexus
                - [ ] Build your graph

                1. Open a vault
                2. Write a note
                3. Open the graph (⌘⌥G)

                Tags: #guide #markdown

                Links: [[Graph View]] [[Daily Notes]]
                """,
                "Projects/Ideas.md": """
                # Ideas

                - Native Metal graph renderer
                - Plugin marketplace (local only)

                Back to [[Welcome]]
                #projects
                """,
            ]
            for (path, body) in files {
                let url = vaultURL.appendingPathComponent(path)
                try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? body.write(to: url, atomically: true, encoding: .utf8)
            }
            Task { @MainActor in
                app.vault.openVault(at: vaultURL)
                app.openNote(path: "Welcome.md")
            }
        }
    }
}

// Need AppKit for NSOpenPanel in WelcomeView
import AppKit
