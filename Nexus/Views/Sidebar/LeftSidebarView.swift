import SwiftUI
import AppKit

struct LeftSidebarView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        VStack(spacing: 0) {
            SidebarIconBar(
                items: LeftSidebarTab.allCases.map {
                    SidebarIconBarItem(id: $0.rawValue, title: $0.title, systemImage: $0.systemImage)
                },
                selection: Binding(
                    get: { app.leftSidebarTab.rawValue },
                    set: { if let t = LeftSidebarTab(rawValue: $0) { app.leftSidebarTab = t } }
                )
            )
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 8)

            Divider()

            Group {
                switch app.leftSidebarTab {
                case .files:
                    FileExplorerView()
                case .search:
                    VaultSearchView()
                case .tags:
                    TagsView()
                case .outline:
                    OutlineView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - File explorer

struct FileExplorerView: View {
    @EnvironmentObject private var app: AppState
    @State private var expanded: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(app.vault.rootURL?.lastPathComponent ?? "Vault")
                    .font(.headline)
                    .lineLimit(1)
                if app.vault.isICloudVault {
                    Image(systemName: "icloud.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("iCloud Drive vault")
                }
                Spacer()
                Button {
                    app.createNote()
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .buttonStyle(.borderless)
                .help("New note")

                Button {
                    app.createFolder()
                } label: {
                    Image(systemName: "folder.badge.plus")
                }
                .buttonStyle(.borderless)
                .help("New folder")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if !app.vault.conflictCopyPaths.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("\(app.vault.conflictCopyPaths.count) possible conflict copies")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
                .help("iCloud/simultaneous-edit copies like “Note 2.md”. Open Settings → About for the list.")
            }

            List(selection: Binding(
                get: { app.selectedPath },
                set: { path in
                    guard let path else { return }
                    if path.hasSuffix(".canvas") {
                        app.openCanvas(path: path)
                    } else if path.hasSuffix(".md") || path.hasSuffix(".markdown") {
                        app.openNote(path: path)
                    } else {
                        app.selectedPath = path
                    }
                }
            )) {
                ForEach(app.vault.tree) { node in
                    NodeRow(node: node, expanded: $expanded)
                }
            }
            .listStyle(.sidebar)
        }
    }
}

struct NodeRow: View {
    let node: VaultNode
    @Binding var expanded: Set<String>
    @EnvironmentObject private var app: AppState

    var body: some View {
        if node.isFolder {
            DisclosureGroup(isExpanded: Binding(
                get: { expanded.contains(node.id) },
                set: { open in
                    if open { expanded.insert(node.id) } else { expanded.remove(node.id) }
                }
            )) {
                ForEach(node.children) { child in
                    NodeRow(node: child, expanded: $expanded)
                }
            } label: {
                Label(node.name, systemImage: "folder.fill")
                    .tag(node.id)
            }
        } else {
            Label {
                Text(node.title)
            } icon: {
                Image(systemName: icon)
                    .foregroundStyle(iconColor)
            }
            .tag(node.id)
            .contextMenu {
                if node.isNote {
                    Button("Open") { app.openNote(path: node.id) }
                    Button("Open Local Graph") {
                        app.selectedPath = node.id
                        app.openLocalGraph()
                    }
                }
                Button("Reveal in Finder") {
                    if let url = app.vault.absoluteURL(for: node.id) {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
                Divider()
                Button("Move to Trash", role: .destructive) {
                    app.vault.deleteNode(path: node.id)
                    if app.selectedPath == node.id {
                        app.selectedPath = nil
                    }
                }
            }
        }
    }

    private var icon: String {
        switch node.kind {
        case .note: return "doc.text"
        case .canvas: return "rectangle.3.group"
        case .attachment: return "paperclip"
        case .folder: return "folder"
        }
    }

    private var iconColor: Color {
        switch node.kind {
        case .note: return .secondary
        case .canvas: return .orange
        case .attachment: return .teal
        case .folder: return .accentColor
        }
    }
}

// MARK: - Search

struct VaultSearchView: View {
    @EnvironmentObject private var app: AppState
    @State private var query = ""
    @State private var hits: [SearchHit] = []
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search vault… path: tag: file:", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(10)
                .focused($focused)
                .onChange(of: query) { _, new in
                    hits = SearchService.search(query: new, notes: app.vault.notes, index: app.vault.indexStore)
                }
                .onChange(of: app.focusSearchToken) { _, _ in
                    focused = true
                }

            List(hits) { hit in
                Button {
                    app.openNote(path: hit.path)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(hit.title)
                            .font(.body.weight(.medium))
                            .foregroundStyle(.primary)
                        Text(hit.path)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if !hit.snippet.isEmpty {
                            Text(hit.snippet)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.sidebar)
        }
        .onAppear {
            if app.leftSidebarTab == .search {
                focused = true
            }
        }
    }
}

// MARK: - Tags

struct TagsView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        let tags = app.linkIndex.tags.keys.sorted()
        List {
            ForEach(tags, id: \.self) { tag in
                DisclosureGroup {
                    let paths = Array(app.linkIndex.tags[tag] ?? []).sorted()
                    ForEach(paths, id: \.self) { path in
                        Button(app.vault.notes[path]?.title ?? path) {
                            app.openNote(path: path)
                        }
                        .buttonStyle(.plain)
                    }
                } label: {
                    Label("#\(tag)", systemImage: "tag.fill")
                    Spacer()
                    Text("\(app.linkIndex.tags[tag]?.count ?? 0)")
                        .foregroundStyle(.secondary)
                        .font(.caption.monospacedDigit())
                }
            }
        }
        .listStyle(.sidebar)
    }
}

// MARK: - Outline

struct OutlineView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        let headings = app.currentNote?.headings
            ?? MarkdownParser.extractHeadings(from: app.draftContent)

        List {
            if headings.isEmpty {
                Text("No headings in this note")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(headings) { heading in
                    Text(heading.text)
                        .font(.system(size: CGFloat(15 - heading.level), weight: heading.level <= 2 ? .semibold : .regular))
                        .padding(.leading, CGFloat(heading.level - 1) * 12)
                }
            }
        }
        .listStyle(.sidebar)
    }
}
