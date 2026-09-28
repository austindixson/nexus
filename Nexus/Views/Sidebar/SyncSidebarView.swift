import SwiftUI

/// Sidebar surface for git-based cloud sync: status, controls, conflicts.
/// Rendered in the left sidebar's "Sync" tab.
struct SyncSidebarView: View {
    @EnvironmentObject private var app: AppState

    private var sync: GitSyncService { app.sync }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                Divider()
                if sync.settings.enabled {
                    enabledContent
                } else {
                    disabledContent
                }
                if !sync.status.conflictPaths.isEmpty {
                    Divider()
                    conflictSection
                }
                Spacer(minLength: 12)
            }
            .padding(12)
        }
    }

    // MARK: - Header / status

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: phaseIcon)
                .font(.title3)
                .foregroundStyle(phaseColor)
                .symbolEffect(.variableColor.iterative, options: .repeating, isActive: sync.status.isBusy)
            VStack(alignment: .leading, spacing: 2) {
                Text("Cloud Sync")
                    .font(.headline)
                Text(sync.statusSummary)
                    .font(.caption)
                    .foregroundStyle(sync.status.phase == .error ? Color.red : .secondary)
                    .lineLimit(2)
            }
            Spacer()
            if sync.settings.enabled && !sync.status.isBusy {
                Button {
                    Task { await sync.syncNow() }
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                .help("Sync now")
                .disabled(sync.status.isBusy)
            }
        }
    }

    private var phaseIcon: String {
        switch sync.status.phase {
        case .off: return "arrow.triangle.2.circlepath.slash"
        case .idle: return "checkmark.icloud"
        case .scanning, .syncing: return "arrow.triangle.2.circlepath"
        case .committing: return "square.and.arrow.down.on.square"
        case .pushing: return "arrow.up.circle"
        case .pulling: return "arrow.down.circle"
        case .error: return "exclamationmark.icloud"
        }
    }

    private var phaseColor: Color {
        switch sync.status.phase {
        case .error: return .red
        case .off: return .secondary
        default: return .accentColor
        }
    }

    // MARK: - Disabled state

    private var disabledContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sync the vault through a git remote. Opt-in: Nexus never touches the network until you turn this on.")
                .font(.callout)
                .foregroundStyle(.secondary)
            SyncEnableForm(sync: sync)
        }
    }

    // MARK: - Enabled state

    private var enabledContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent("Remote") {
                Text(GitRemote.parse(sync.settings.remote)?.displayLabel ?? "—")
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(sync.settings.remote)
            }
            LabeledContent("Branch", value: sync.settings.branch)
            HStack(spacing: 12) {
                Metric(title: "Ahead", value: sync.status.aheadCount, tint: sync.status.aheadCount > 0 ? .accentColor : .secondary)
                Metric(title: "Behind", value: sync.status.behindCount, tint: sync.status.behindCount > 0 ? .orange : .secondary)
                Metric(title: "Changes", value: sync.status.dirtyCount, tint: sync.status.dirtyCount > 0 ? .accentColor : .secondary)
            }
            if let err = sync.status.lastError {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                    .textSelection(.enabled)
            }
            if sync.status.lastSyncAt == nil {
                Text("Not synced yet — first sync runs when you enable, then on the interval.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Sync now") { Task { await sync.syncNow() } }
                    .disabled(sync.status.isBusy)
                Button("Open in Finder") {
                    if let root = app.vault.rootURL {
                        let url = root.appendingPathComponent(".git")
                        if FileManager.default.fileExists(atPath: url.path) {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        } else {
                            NSWorkspace.shared.activateFileViewerSelecting([root])
                        }
                    }
                }
                Spacer()
                Button("Turn off", role: .destructive) {
                    sync.disableSync()
                }
            }
            .font(.callout)
            SettingsLink {
                Text("Sync settings…")
                    .font(.callout)
            }
            .buttonStyle(.link)
        }
    }

    // MARK: - Conflicts

    private var conflictSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Conflicts (\(sync.status.conflictPaths.count))", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            Text("Both versions were kept as conflict copies. Pick which side wins; the copy is then removed.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(sync.status.conflictPaths, id: \.self) { path in
                HStack(spacing: 8) {
                    Image(systemName: "doc.badge.ellipsis")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 1) {
                        Text((path as NSString).lastPathComponent)
                            .font(.callout.monospaced())
                            .lineLimit(1)
                        Text((path as NSString).deletingLastPathComponent)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Button("Keep local") {
                        Task { try? await sync.resolveConflict(path: path, side: .ours) }
                    }
                    Button("Keep remote") {
                        Task { try? await sync.resolveConflict(path: path, side: .theirs) }
                    }
                }
                .padding(8)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }
}

private struct Metric: View {
    let title: String
    let value: Int
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("\(value)")
                .font(.title3.monospacedDigit())
                .foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Inline enable form used when sync is off.
private struct SyncEnableForm: View {
    @ObservedObject var sync: GitSyncService
    @State private var remote = ""
    @State private var branch = "main"
    @State private var name = ""
    @State private var email = ""
    @State private var showingDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Remote URL (https://…, git@host:repo.git, or /path/to/vault.git)", text: $remote)
                .textFieldStyle(.roundedBorder)
                .font(.callout.monospaced())
                .onSubmit { enable() }
            if showingDetails {
                TextField("Branch", text: $branch)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout)
                HStack {
                    TextField("Git user name", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .font(.callout)
                    TextField("Git email", text: $email)
                        .textFieldStyle(.roundedBorder)
                        .font(.callout)
                }
            }
            if let err = sync.status.lastError, sync.status.phase == .error {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            HStack {
                Button("Enable sync") { enable() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(remote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sync.status.isBusy)
                Toggle("Details", isOn: $showingDetails)
                    .toggleStyle(.button)
                    .controlSize(.small)
                    .font(.caption)
            }
            Text("The vault becomes a git repo. Local state (.nexus/) is never pushed.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func enable() {
        var settings = sync.settings
        settings.branch = branch
        settings.authorName = name
        settings.authorEmail = email
        sync.saveSettings(settings)
        sync.enableSync(remoteRaw: remote)
    }
}
