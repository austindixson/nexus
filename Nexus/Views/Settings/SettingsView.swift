import SwiftUI
import AppKit

enum SettingsPane: String, CaseIterable, Identifiable {
    case general
    case editor
    case graph
    case ai
    case sync
    case hotkeys
    case plugins
    case about

    var id: String { rawValue }

    static let preferredTabKey = "nexus.settings.preferredTab"

    static func prefer(_ pane: SettingsPane) {
        UserDefaults.standard.set(pane.rawValue, forKey: preferredTabKey)
    }
}

struct SettingsView: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject private var ai = AIConfiguration.shared

    @AppStorage(SettingsPane.preferredTabKey) private var preferredTabRaw = SettingsPane.general.rawValue

    @State private var xaiKeyDraft = ""
    @State private var openAIKeyDraft = ""
    @State private var anthropicKeyDraft = ""
    @State private var deepSeekKeyDraft = ""
    @State private var remoteKeyDraft = ""
    @State private var keySavedMessage: String?
    @State private var connectionMessage: String?
    @State private var connectionOK: Bool?
    @State private var connectionTesting = false

    private var selectedTab: Binding<SettingsPane> {
        Binding(
            get: { SettingsPane(rawValue: preferredTabRaw) ?? .general },
            set: { preferredTabRaw = $0.rawValue }
        )
    }

    var body: some View {
        TabView(selection: selectedTab) {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsPane.general)

            editorTab
                .tabItem { Label("Editor", systemImage: "doc.richtext") }
                .tag(SettingsPane.editor)

            graphTab
                .tabItem { Label("Graph", systemImage: "point.3.connected.trianglepath.dotted") }
                .tag(SettingsPane.graph)

            aiTab
                .tabItem { Label("AI", systemImage: "sparkles") }
                .tag(SettingsPane.ai)

            syncTab
                .tabItem { Label("Sync", systemImage: "arrow.triangle.2.circlepath") }
                .tag(SettingsPane.sync)

            HotkeysSettingsView()
                .tabItem { Label("Hotkeys", systemImage: "keyboard") }
                .tag(SettingsPane.hotkeys)

            pluginsTab
                .tabItem { Label("Plugins", systemImage: "puzzlepiece.extension") }
                .tag(SettingsPane.plugins)

            aboutTab
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(SettingsPane.about)
        }
        .frame(width: 580, height: 560)
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
                .pickerStyle(.menu)
                .onChange(of: ai.providerKind) { _, kind in
                    ai.applyDefaultModelIfNeeded(for: kind)
                    connectionMessage = nil
                    connectionOK = nil
                }
                TextField("Model ID", text: $ai.modelID)
                Text("Vault works fully offline with AI disabled. Keys stay in Keychain — never in vault files. There is no Nexus account.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                providerNeedsKeyHint
            }

            Section("Local credentials") {
                Toggle("Use Claude Code / Codex CLI and project .env when no Keychain key", isOn: $ai.useLocalCredentials)
                TextField("Project .env path", text: $ai.clmEnvPath)
                Text(ai.claudeCodeStatusText)
                    .font(.caption2)
                    .foregroundStyle(ai.hasClaudeCodeCLI ? .green : .secondary)
                Text(ai.codexStatusText)
                    .font(.caption2)
                    .foregroundStyle(ai.hasCodexCLI ? .green : .secondary)
                Text(ai.clmEnvStatusText)
                    .font(.caption2)
                    .foregroundStyle(ai.hasCLMEnv ? .green : .secondary)
                Text("Reads ~/.claude, ~/.codex, and DEEPSEEK_API_KEY (etc.) from the .env path — does not copy secrets into Nexus. Cursor login is not supported.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Refresh detection") {
                    ai.refreshKeyFlags()
                }
            }

            if ai.providerKind == .openai {
                Section("OpenAI") {
                    SecureField("OPENAI_API_KEY", text: $openAIKeyDraft)
                    keyButtons(
                        save: {
                            ai.setOpenAIKey(openAIKeyDraft)
                            openAIKeyDraft = ""
                            keySavedMessage = ai.hasOpenAIKey ? "Key saved to Keychain." : "Key cleared."
                        },
                        clear: {
                            ai.setOpenAIKey(nil)
                            keySavedMessage = "Key cleared."
                        },
                        hasKey: ai.hasOpenAIKey
                    )
                    Text("https://api.openai.com/v1 · or Codex CLI ChatGPT login when local credentials are enabled.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    if ai.useLocalCredentials && ai.hasCodexCLI && ai.openAIAPIKey() == nil {
                        Text("Codex ChatGPT login: use a Codex model (e.g. \(AIConfiguration.codexDefaultModel)). Platform models like gpt-4o-mini are rejected.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }

            if ai.providerKind == .xai {
                Section("SpaceXAI (xAI)") {
                    SecureField("XAI_API_KEY", text: $xaiKeyDraft)
                    keyButtons(
                        save: {
                            ai.setXAIKey(xaiKeyDraft)
                            xaiKeyDraft = ""
                            keySavedMessage = ai.hasXAIKey ? "Key saved to Keychain." : "Key cleared."
                        },
                        clear: {
                            ai.setXAIKey(nil)
                            keySavedMessage = "Key cleared."
                        },
                        hasKey: ai.hasXAIKey
                    )
                    Text("Default model: grok-4.5 · https://api.x.ai/v1")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            if ai.providerKind == .anthropic {
                Section("Anthropic (Claude)") {
                    SecureField("ANTHROPIC_API_KEY", text: $anthropicKeyDraft)
                    keyButtons(
                        save: {
                            ai.setAnthropicKey(anthropicKeyDraft)
                            anthropicKeyDraft = ""
                            keySavedMessage = ai.hasAnthropicKey ? "Key saved to Keychain." : "Key cleared."
                        },
                        clear: {
                            ai.setAnthropicKey(nil)
                            keySavedMessage = "Key cleared."
                        },
                        hasKey: ai.hasAnthropicKey
                    )
                    Text("Console API key, or Claude Code CLI OAuth when local credentials are enabled.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            if ai.providerKind == .deepseek {
                Section("DeepSeek") {
                    SecureField("DEEPSEEK_API_KEY", text: $deepSeekKeyDraft)
                    keyButtons(
                        save: {
                            ai.setDeepSeekKey(deepSeekKeyDraft)
                            deepSeekKeyDraft = ""
                            keySavedMessage = ai.hasDeepSeekKey ? "Key saved to Keychain." : "Key cleared."
                        },
                        clear: {
                            ai.setDeepSeekKey(nil)
                            keySavedMessage = "Key cleared."
                        },
                        hasKey: ai.hasDeepSeekKey
                    )
                    Text("https://api.deepseek.com · default model deepseek-chat. Can also read DEEPSEEK_API_KEY from the project .env path (e.g. Desktop/CLM/.env).")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            if ai.providerKind == .ollama {
                Section("Ollama") {
                    TextField("Base URL", text: $ai.ollamaBaseURL)
                    Text("Localhost or a Tailscale MagicDNS / Funnel URL (e.g. http://100.x.x.x:11434 or https://ollama.tailnet.ts.net). No API key required.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if ai.providerKind == .remoteOpenAI {
                Section("Remote OpenAI-compatible") {
                    TextField("Base URL", text: $ai.remoteOpenAIBaseURL)
                    SecureField("API key", text: $remoteKeyDraft)
                    keyButtons(
                        save: {
                            ai.setRemoteOpenAIKey(remoteKeyDraft)
                            remoteKeyDraft = ""
                            keySavedMessage = ai.hasRemoteOpenAIKey ? "Key saved to Keychain." : "Key cleared."
                        },
                        clear: {
                            ai.setRemoteOpenAIKey(nil)
                            keySavedMessage = "Key cleared."
                        },
                        hasKey: ai.hasRemoteOpenAIKey
                    )
                    Text("OpenRouter, LiteLLM, self-hosted gateways, or Tailscale-exposed OpenAI-compatible servers. Base URL must include the /v1 path when required by the host.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if ai.providerKind != .disabled {
                Section("Connection") {
                    HStack {
                        Button {
                            connectionTesting = true
                            connectionMessage = nil
                            connectionOK = nil
                            Task {
                                let result = await ai.testConnection()
                                connectionTesting = false
                                switch result {
                                case .ok(let msg):
                                    connectionOK = true
                                    connectionMessage = msg
                                case .failure(let msg):
                                    connectionOK = false
                                    connectionMessage = msg
                                }
                            }
                        } label: {
                            if connectionTesting {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("Test connection")
                            }
                        }
                        .disabled(connectionTesting)
                        if let connectionMessage {
                            Text(connectionMessage)
                                .font(.caption)
                                .foregroundStyle(connectionOK == true ? Color.green : (connectionOK == false ? Color.orange : .secondary))
                                .lineLimit(3)
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

    @ViewBuilder
    private var providerNeedsKeyHint: some View {
        switch ai.providerKind {
        case .openai where !ai.isEnabled:
            Text("Add an API key, or enable local Codex CLI / CLM .env credentials.")
                .font(.caption)
                .foregroundStyle(.orange)
        case .xai where !ai.hasXAIKey:
            Text("Add an API key below to enable SpaceXAI.")
                .font(.caption)
                .foregroundStyle(.orange)
        case .anthropic where !ai.isEnabled:
            Text("Add an API key, or enable Claude Code CLI / CLM .env credentials.")
                .font(.caption)
                .foregroundStyle(.orange)
        case .deepseek where !ai.isEnabled:
            Text("Add a DeepSeek API key, or enable reading DEEPSEEK_API_KEY from the project .env.")
                .font(.caption)
                .foregroundStyle(.orange)
        case .remoteOpenAI where !ai.hasRemoteOpenAIKey:
            Text("Add an API key below to enable this remote endpoint.")
                .font(.caption)
                .foregroundStyle(.orange)
        default:
            EmptyView()
        }
    }

    private func keyButtons(save: @escaping () -> Void, clear: @escaping () -> Void, hasKey: Bool) -> some View {
        HStack {
            Button("Save key", action: save)
            Button("Clear key", action: clear)
            if hasKey {
                Text("Key present")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }
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
