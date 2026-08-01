import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        TabView {
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
            }
            .padding()
            .tabItem { Label("General", systemImage: "gearshape") }

            Form {
                Picker("Default editor mode", selection: $app.editorMode) {
                    Text("Source").tag(EditorMode.source)
                    Text("Live preview").tag(EditorMode.livePreview)
                    Text("Split").tag(EditorMode.split)
                }
                Text("Files are plain Markdown on disk. External edits appear via FSEvents.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .tabItem { Label("Editor", systemImage: "doc.richtext") }

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
                Text("Uses GPU for nodes/edges; CoreGraphics remains the fallback and still draws labels.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .tabItem { Label("Graph", systemImage: "point.3.connected.trianglepath.dotted") }

            Form {
                LabeledContent("Version", value: "0.1.0")
                LabeledContent("Stack", value: "SwiftUI · AppKit · FSEvents")
                Text("Nexus is fully offline. No telemetry. No accounts. MIT licensed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let path = app.vault.rootURL?.path {
                    LabeledContent("Vault", value: path)
                }
            }
            .padding()
            .tabItem { Label("About", systemImage: "info.circle") }
        }
    }
}
