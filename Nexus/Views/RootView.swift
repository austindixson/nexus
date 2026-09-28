import SwiftUI
import AppKit

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
        .sheet(isPresented: $app.showImportSheet) {
            ImportSheetView()
                .environmentObject(app)
        }
    }

    /// Full-width chrome bar + split content. Avoids liquid-glass toolbar pills that never span the window.
    private var mainWorkspace: some View {
        VStack(spacing: 0) {
            NexusChromeBar()

            NavigationSplitView {
                if app.showLeftSidebar {
                    LeftSidebarView()
                        .navigationSplitViewColumnWidth(min: 200, ideal: 260, max: 420)
                }
            } detail: {
                HSplitView {
                    VStack(spacing: 0) {
                        if app.mainMode == .editor && !app.openTabs.isEmpty {
                            TabStripView()
                        }
                        centerPane
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .frame(minWidth: 420)

                    if app.showRightSidebar {
                        RightSidebarView()
                            .frame(minWidth: 240, idealWidth: 300, maxWidth: 420)
                            .frame(maxHeight: .infinity)
                    }
                }
            }
        }
        .background(WindowSubtitleSync(subtitle: windowSubtitle))
    }

    private var windowSubtitle: String {
        if app.vault.isIndexing {
            return "Indexing…"
        }
        let n = app.vault.noteCount
        if let name = app.vault.rootURL?.lastPathComponent {
            return "\(name) · \(n) note\(n == 1 ? "" : "s")"
        }
        return "\(n) note\(n == 1 ? "" : "s")"
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
}

// MARK: - Full-width app chrome (edge to edge)

struct NexusChromeBar: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        HStack(spacing: 12) {
            // Sidebar toggles
            HStack(spacing: 2) {
                chromeIconButton(
                    "sidebar.left",
                    isOn: app.showLeftSidebar,
                    help: "Toggle left sidebar"
                ) {
                    app.toggleLeftSidebar()
                }
                chromeIconButton(
                    "sidebar.right",
                    isOn: app.showRightSidebar,
                    help: "Toggle right sidebar"
                ) {
                    app.toggleRightSidebar()
                }
            }

            // Workspace mode — always readable width
            Picker("Mode", selection: $app.mainMode) {
                ForEach(MainMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 248)
            .labelsHidden()
            .help("Workspace mode")

            Spacer(minLength: 8)

            if app.mainMode == .editor {
                Picker("Editor", selection: $app.editorMode) {
                    Text("Source").tag(EditorMode.source)
                    Text("Preview").tag(EditorMode.livePreview)
                    Text("Split").tag(EditorMode.split)
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
                .labelsHidden()
                .help("Editor layout")
            }

            if app.vault.isIndexing {
                ProgressView()
                    .controlSize(.small)
            }

            Button {
                app.showCommandPalette = true
            } label: {
                Label("Search", systemImage: "magnifyingglass")
                    .labelStyle(.iconOnly)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Command palette (⌘P)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background {
            Rectangle()
                .fill(Color(nsColor: .windowBackgroundColor))
        }
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private func chromeIconButton(
        _ systemImage: String,
        isOn: Bool,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isOn ? Color.primary : Color.secondary)
                .frame(width: 28, height: 28)
                .background {
                    if isOn {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.primary.opacity(0.08))
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}

// Opaque titlebar; controls live in NexusChromeBar so the strip is truly full-width.
struct WindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { configure(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { configure(nsView.window) }
    }

    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        window.titlebarAppearsTransparent = false
        window.titleVisibility = .visible
        window.isMovableByWindowBackground = false
        window.backgroundColor = NSColor.windowBackgroundColor
        window.toolbarStyle = .unified
        window.styleMask.remove(.fullSizeContentView)
        // Empty system toolbar — chrome is our full-width bar.
        window.toolbar = nil
    }
}

struct WindowSubtitleSync: NSViewRepresentable {
    var subtitle: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.isHidden = true
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            if window.subtitle != subtitle {
                window.subtitle = subtitle
            }
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
