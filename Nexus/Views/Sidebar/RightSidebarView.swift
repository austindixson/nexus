import SwiftUI

struct RightSidebarView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $app.rightSidebarTab) {
                ForEach(RightSidebarTab.allCases) { tab in
                    Image(systemName: tab.systemImage).help(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(8)

            Divider()

            switch app.rightSidebarTab {
            case .backlinks:
                BacklinksPane()
            case .outgoing:
                OutgoingLinksPane()
            case .properties:
                PropertiesPane()
            }
        }
        .background(.ultraThinMaterial)
    }
}

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

/// Simple wrapping tag chips without a full layout engine.
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
