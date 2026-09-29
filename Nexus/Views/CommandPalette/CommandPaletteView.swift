import SwiftUI

struct CommandItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    let systemImage: String
    let action: () -> Void
}

struct CommandPaletteView: View {
    @EnvironmentObject private var app: AppState
    @State private var query = ""
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture { app.showCommandPalette = false }

            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "command")
                        .foregroundStyle(.secondary)
                    TextField("Run a command…", text: $query)
                        .textFieldStyle(.plain)
                        .font(.title3)
                        .focused($focused)
                        .onSubmit { runFirst() }
                }
                .padding(16)

                Divider()

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(filtered) { item in
                            Button {
                                item.action()
                                app.showCommandPalette = false
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: item.systemImage)
                                        .frame(width: 20)
                                        .foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.title)
                                        if let subtitle = item.subtitle {
                                            Text(subtitle)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .background(Color.primary.opacity(0.0001))
                        }
                    }
                }
                .frame(maxHeight: 360)
            }
            .frame(width: 560)
            .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.4), radius: 30, y: 12)
        }
        .onAppear { focused = true }
        .onExitCommand { app.showCommandPalette = false }
    }

    private var commands: [CommandItem] {
        [
            CommandItem(id: "new-note", title: "New note", subtitle: "⌘N", systemImage: "square.and.pencil") {
                app.createNote()
            },
            CommandItem(id: "daily", title: "Open daily note", subtitle: "⌘D", systemImage: "calendar") {
                app.openDailyNote()
            },
            CommandItem(id: "open-vault", title: "Open vault…", subtitle: "⌘⇧O", systemImage: "folder") {
                app.openVaultPanel()
            },
            CommandItem(id: "graph", title: "Open graph view", subtitle: "⌘⌥G", systemImage: "point.3.connected.trianglepath.dotted") {
                app.mainMode = .graph
                app.graphMode = .global
            },
            CommandItem(id: "local-graph", title: "Open local graph", subtitle: nil, systemImage: "circle.grid.cross") {
                app.openLocalGraph()
            },
            CommandItem(id: "canvas", title: "Open canvas", subtitle: nil, systemImage: "rectangle.3.group") {
                app.mainMode = .canvas
            },
            CommandItem(id: "new-canvas", title: "New canvas", subtitle: nil, systemImage: "plus.rectangle.on.rectangle") {
                app.newCanvas()
            },
            CommandItem(id: "search", title: "Search in vault", subtitle: "⌘⇧F", systemImage: "magnifyingglass") {
                app.focusSearch()
            },
            CommandItem(id: "toggle-left", title: "Toggle left sidebar", subtitle: nil, systemImage: "sidebar.left") {
                app.toggleLeftSidebar()
            },
            CommandItem(id: "toggle-right", title: "Toggle right sidebar", subtitle: nil, systemImage: "sidebar.right") {
                app.toggleRightSidebar()
            },
            CommandItem(id: "source", title: "Editor: source mode", subtitle: nil, systemImage: "chevron.left.forwardslash.chevron.right") {
                app.mainMode = .editor
                app.editorMode = .source
            },
            CommandItem(id: "preview", title: "Editor: live preview", subtitle: nil, systemImage: "eye") {
                app.mainMode = .editor
                app.editorMode = .livePreview
            },
            CommandItem(id: "split", title: "Editor: split view", subtitle: nil, systemImage: "rectangle.split.2x1") {
                app.mainMode = .editor
                app.editorMode = .split
            },
            CommandItem(id: "template-meeting", title: "Insert template: Meeting", subtitle: nil, systemImage: "doc.badge.plus") {
                app.insertTemplate("""

                ## Meeting — \(Date.now.formatted(date: .abbreviated, time: .shortened))

                ### Attendees
                -

                ### Notes
                -

                ### Actions
                - [ ]
                """)
            },
            CommandItem(id: "reindex", title: "Rebuild vault index", subtitle: nil, systemImage: "arrow.triangle.2.circlepath") {
                app.vault.fullRescan()
            },
            CommandItem(id: "ask", title: "Ask Nexus…", subtitle: "AI / offline search", systemImage: "sparkles") {
                app.focusAskNexus()
            },
            CommandItem(id: "import", title: "Import source…", subtitle: "PDF, web, text → Sources/", systemImage: "square.and.arrow.down") {
                app.showImportSheet = true
            },
            CommandItem(id: "studio-summary", title: "Studio: summary note", subtitle: nil, systemImage: "doc.richtext") {
                app.rightSidebarTab = .ask
                app.showRightSidebar = true
            },
            CommandItem(id: "reload-plugins", title: "Reload plugins", subtitle: ".nexus/plugins", systemImage: "puzzlepiece.extension") {
                Task { await app.reloadPlugins() }
            },
        ] + app.pluginHost.allCommands.map { cmd in
            CommandItem(id: "plugin.\(cmd.id)", title: cmd.title, subtitle: "Plugin", systemImage: "puzzlepiece") {
                cmd.action()
            }
        }
    }

    private var filtered: [CommandItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { return commands }
        return commands.filter {
            $0.title.localizedCaseInsensitiveContains(q)
                || ($0.subtitle?.localizedCaseInsensitiveContains(q) ?? false)
        }
    }

    private func runFirst() {
        guard let first = filtered.first else { return }
        first.action()
        app.showCommandPalette = false
    }
}

struct QuickSwitcherView: View {
    @EnvironmentObject private var app: AppState
    @State private var query = ""
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture { app.showQuickSwitcher = false }

            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "doc.text.magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Switch to note…", text: $query)
                        .textFieldStyle(.plain)
                        .font(.title3)
                        .focused($focused)
                        .onSubmit { openFirst() }
                }
                .padding(16)
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(hits, id: \.path) { hit in
                            Button {
                                app.openNote(path: hit.path)
                                app.showQuickSwitcher = false
                            } label: {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(hit.title).font(.body.weight(.medium))
                                        Text(hit.path).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 360)
            }
            .frame(width: 560)
            .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.4), radius: 30, y: 12)
        }
        .onAppear { focused = true }
        .onExitCommand { app.showQuickSwitcher = false }
    }

    private var hits: [SearchHit] {
        if query.isEmpty {
            return app.vault.notes.values
                .sorted { $0.modified > $1.modified }
                .prefix(30)
                .map { SearchHit(id: $0.id, path: $0.id, title: $0.title, snippet: $0.folderPath, score: 1, line: nil) }
        }
        return SearchService.search(query: query, notes: app.vault.notes, limit: 40, index: app.vault.indexStore)
    }

    private func openFirst() {
        guard let first = hits.first else { return }
        app.openNote(path: first.path)
        app.showQuickSwitcher = false
    }
}
