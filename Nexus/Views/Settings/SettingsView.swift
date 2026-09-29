import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject private var ai = AIConfiguration.shared

    @State private var xaiKeyDraft = ""
    @State private var openAIKeyDraft = ""
    @State private var keySavedMessage: String?

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }

            editorTab
                .tabItem { Label("Editor", systemImage: "doc.richtext") }

            graphTab
                .tabItem { Label("Graph", systemImage: "point.3.connected.trianglepath.dotted") }

            aiTab
                .tabItem { Label("AI", systemImage: "sparkles") }

            syncTab
                .tabItem { Label("Sync", systemImage: "arrow.triangle.2.circlepath") }

            HotkeysSettingsView()
                .tabItem { Label("Hotkeys", systemImage: "keyboard") }

            pluginsTab
                .tabItem { Label("Plugins", systemImage: "puzzlepiece.extension") }

            aboutTab
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 580, height: 500)
    }

    private var generalTab: some View {
        Form {
            Picker("Appearance", selection: $app.appearance) {
                ForEach(AppAppearance.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            Toggle("Show left sidebar", isOn: $app.showLeftSidebar)
            Toggle("Show right sidebar", isOn: $app.showRightSidebar)
            Section("Workspace") {
                Text("Layout, open tabs, and graph filters are saved to `.nexus/workspace.json` in the vault and restored on launch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Save workspace now") {
                    app.saveWorkspaceNow()
                }
            }
            Section("Index") {
                Text("Note metadata, FTS search, and graph positions live in `.nexus/index.sqlite` (local, per vault).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Rebuild vault index") {
                    app.vault.fullRescan()
                }
            }
        }
        .padding()
    }

    private var editorTab: some View {
        Form {
            Picker("Default editor mode", selection: $app.editorMode) {
                Text("Source").tag(EditorMode.source)
                Text("Live preview").tag(EditorMode.livePreview)
                Text("Split").tag(EditorMode.split)
            }
            Text("Files are plain Markdown on disk. External edits appear via FSEvents (incremental).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    private var graphTab: some View {
        Form {
            Picker("Default graph mode", selection: $app.graphMode) {
                Text("Global").tag(GraphViewMode.global)
                Text("Local").tag(GraphViewMode.local)
            }
            Stepper("Local depth: \(app.graphLocalDepth)", value: $app.graphLocalDepth, in: 1...5)
            Picker("Color by", selection: $app.graphColorBy) {
                ForEach(GraphColorMode.allCases) { Text($0.title).tag($0) }
            }
            Picker("Labels", selection: $app.graphLabels) {
                ForEach(GraphLabelMode.allCases) { Text($0.title).tag($0) }
            }
            Toggle("Metal graph renderer", isOn: $app.useMetalGraph)
            Text("Uses GPU for nodes/edges; CoreGraphics remains the fallback and still draws labels. Layout positions persist in the vault index.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    private var aiTab: some View {
        Form {
            Section("Provider") {
                Picker("Provider", selection: $ai.providerKind) {
                    ForEach(AIConfiguration.ProviderKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                TextField("Model ID", text: $ai.modelID)
                Text("Vault works fully offline with AI disabled. Keys are stored in Keychain only — never in vault files.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if ai.providerKind == .xai {
                Section("SpaceXAI (xAI)") {
                    SecureField("XAI_API_KEY", text: $xaiKeyDraft)
                    HStack {
                        Button("Save key") {
                            ai.setXAIKey(xaiKeyDraft)
                            xaiKeyDraft = ""
                            keySavedMessage = ai.hasXAIKey ? "Key saved to Keychain." : "Key cleared."
                        }
                        Button("Clear key") {
                            ai.setXAIKey(nil)
                            keySavedMessage = "Key cleared."
                        }
                        if ai.hasXAIKey {
                            Text("Key present")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                    }
                    Text("Default model: grok-4.5 · https://api.x.ai/v1")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            if ai.providerKind == .ollama {
                Section("Ollama") {
                    TextField("Base URL", text: $ai.ollamaBaseURL)
                    Text("Run models locally (e.g. ollama run llama3.2). No API key required.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if ai.providerKind == .openAICompatible {
                Section("OpenAI-compatible") {
                    TextField("Base URL", text: $ai.openAIBaseURL)
                    SecureField("API key", text: $openAIKeyDraft)
                    HStack {
                        Button("Save key") {
                            ai.setOpenAIKey(openAIKeyDraft)
                            openAIKeyDraft = ""
                            keySavedMessage = ai.hasOpenAIKey ? "Key saved." : "Key cleared."
                        }
                        Button("Clear key") {
                            ai.setOpenAIKey(nil)
                            keySavedMessage = "Key cleared."
                        }
                    }
                }
            }

            Section("Retrieval") {
                Picker("Default scope", selection: $ai.scopeMode) {
                    ForEach(AIConfiguration.ScopeMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                Toggle("Allow general knowledge when vault is thin", isOn: $ai.allowGeneralKnowledge)
                Text("Ask Nexus always retrieves from FTS first and cites note paths. Offline mode returns ranked passages without a model.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let keySavedMessage {
                Text(keySavedMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
    }

    private var pluginsTab: some View {
        Form {
            Section("Loaded") {
                if app.pluginHost.plugins.isEmpty {
                    Text("No plugins loaded.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(app.pluginHost.plugins.values.sorted(by: { $0.name < $1.name })), id: \.id) { plugin in
                        LabeledContent(plugin.name, value: "v\(plugin.version)")
                    }
                }
                Button("Reload plugins") {
                    Task { await app.reloadPlugins() }
                }
            }
            Section("Install") {
                Text("Place a folder named `YourPlugin.nexusplugin` (with `manifest.json`) in `.nexus/plugins/` inside the vault.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Declarative actions only: alert, insert, open, daily + regex post-processors + templates. No network code.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let root = app.vault.rootURL {
                    let dir = root.appendingPathComponent(".nexus/plugins")
                    Button("Reveal plugins folder") {
                        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(dir)
                    }
                }
            }
            if !app.pluginHost.loadedBundlePaths.isEmpty {
                Section("Bundles") {
                    ForEach(app.pluginHost.loadedBundlePaths, id: \.self) { path in
                        Text(path)
                            .font(.system(.caption2, design: .monospaced))
                            .lineLimit(2)
                    }
                }
            }
        }
        .padding()
    }

    private var syncTab: some View {
        SyncSettingsView()
    }

    private var aboutTab: some View {
        Form {
            LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0")
            LabeledContent("Stack", value: "SwiftUI · AppKit · FSEvents · SQLite FTS5 · Metal")
            Text("Nexus is local-first. No telemetry. No accounts. MIT licensed. AI is optional and off by default.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let path = app.vault.rootURL?.path {
                LabeledContent("Vault", value: path)
            }
            LabeledContent("Notes indexed", value: "\(app.vault.noteCount)")
            if app.vault.isICloudVault {
                Label("iCloud vault — longer FSEvents debounce + atomic saves", systemImage: "icloud")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            let conflicts = app.vault.conflictCopyPaths
            if !conflicts.isEmpty {
                Section("Possible conflict copies (\(conflicts.count))") {
                    ForEach(conflicts.prefix(12), id: \.self) { path in
                        Button(path) { app.openNote(path: path) }
                            .font(.caption)
                    }
                }
            }
        }
        .padding()
    }
}
