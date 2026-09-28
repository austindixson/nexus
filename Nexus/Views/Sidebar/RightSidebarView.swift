import SwiftUI
import AppKit

struct RightSidebarView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        VStack(spacing: 0) {
            SidebarIconBar(
                items: RightSidebarTab.allCases.map {
                    SidebarIconBarItem(id: $0.rawValue, title: $0.title, systemImage: $0.systemImage)
                },
                selection: Binding(
                    get: { app.rightSidebarTab.rawValue },
                    set: { if let t = RightSidebarTab(rawValue: $0) { app.rightSidebarTab = t } }
                )
            )
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 8)

            Divider()

            Group {
                switch app.rightSidebarTab {
                case .backlinks:
                    BacklinksPane()
                case .outgoing:
                    OutgoingLinksPane()
                case .properties:
                    PropertiesPane()
                case .ask:
                    AskNexusPanel()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Shared icon tab bar

struct SidebarIconBarItem: Identifiable, Hashable {
    let id: String
    let title: String
    let systemImage: String
}

/// Compact icon tabs — explicit sizes so they never collapse to an empty strip.
struct SidebarIconBar: View {
    let items: [SidebarIconBarItem]
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 4) {
            ForEach(items) { item in
                let selected = selection == item.id
                Button {
                    selection = item.id
                } label: {
                    Image(systemName: item.systemImage)
                        .font(.system(size: 14, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                        .frame(width: 40, height: 30)
                        .background {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(selected ? Color.accentColor.opacity(0.15) : Color.clear)
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .help(item.title)
                .accessibilityLabel(item.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .padding(4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 38)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.18))
        }
    }
}

// MARK: - Panes

struct BacklinksPane: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        List {
            Section("Linked mentions") {
                let linked = app.currentBacklinks
                if linked.isEmpty {
                    Text("No backlinks")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(linked) { bl in
                        Button {
                            app.openNote(path: bl.sourcePath)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(bl.sourceTitle).font(.body.weight(.medium))
                                Text(bl.context)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(8)
                                    .truncationMode(.tail)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .multilineTextAlignment(.leading)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Section("Unlinked mentions") {
                let unlinked = app.currentUnlinked
                if unlinked.isEmpty {
                    Text("No unlinked mentions")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(unlinked) { bl in
                        Button {
                            app.openNote(path: bl.sourcePath)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(bl.sourceTitle).font(.body.weight(.medium))
                                Text(bl.context)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(8)
                                    .truncationMode(.tail)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .multilineTextAlignment(.leading)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }
}

struct OutgoingLinksPane: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        let links = app.currentNote?.outgoingLinks ?? MarkdownParser.extractWikiLinks(from: app.draftContent)
        List {
            if links.isEmpty {
                Text("No outgoing links")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(links.enumerated()), id: \.offset) { _, link in
                    Button {
                        let known = app.vault.knownPaths
                        if let resolved = MarkdownParser.resolveLinkTarget(link.target, from: app.selectedPath ?? "", knownPaths: known) {
                            app.openNote(path: resolved)
                        }
                    } label: {
                        HStack {
                            Image(systemName: link.isEmbed ? "arrow.down.doc" : "link")
                            Text(link.alias ?? link.target)
                            Spacer()
                            if MarkdownParser.resolveLinkTarget(link.target, from: app.selectedPath ?? "", knownPaths: app.vault.knownPaths) == nil {
                                Text("unresolved")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .listStyle(.sidebar)
    }
}

struct PropertiesPane: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        let note = app.currentNote
        let fm = note?.frontmatter ?? MarkdownParser.parseFrontmatter(app.draftContent).meta
        let tags = note?.tags ?? MarkdownParser.extractTags(from: app.draftContent, frontmatter: fm)

        List {
            Section("File") {
                LabeledContent("Path", value: app.selectedPath ?? "—")
                if let modified = note?.modified {
                    LabeledContent("Modified", value: modified.formatted(date: .abbreviated, time: .shortened))
                }
            }
            Section("Frontmatter") {
                if fm.isEmpty {
                    Text("No frontmatter").foregroundStyle(.secondary)
                } else {
                    ForEach(fm.keys.sorted(), id: \.self) { key in
                        LabeledContent(key, value: fm[key] ?? "")
                    }
                }
            }
            Section("Tags") {
                if tags.isEmpty {
                    Text("No tags").foregroundStyle(.secondary)
                } else {
                    FlowTags(tags: tags)
                }
            }
        }
        .listStyle(.sidebar)
    }
}

struct FlowTags: View {
    let tags: [String]

    var body: some View {
        FlexibleTags(tags: tags)
    }
}

struct FlexibleTags: View {
    let tags: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(tags, id: \.self) { tag in
                Text("#\(tag)")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.purple.opacity(0.18), in: Capsule())
            }
        }
    }
}
