# Nexus

**Native macOS knowledge base** — local-first Markdown vaults, Obsidian-style linking, and a world-class graph visualizer.

Built with **SwiftUI + AppKit**, not Electron or Tauri. Fully offline. No accounts. No telemetry. **MIT licensed**.

![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-black)
![Swift](https://img.shields.io/badge/Swift-5.10%2B-orange)
![License](https://img.shields.io/badge/license-MIT-blue)

---

## Why native Swift?

Earlier web-shell approaches (Tauri/Electron) only give you a native *window*. Nexus is a real Mac app:

- Unified toolbar, sidebar, menus, and key equivalents
- `NSTextView` editor + system fonts
- FSEvents file watching
- AppKit-drawn graph with force layout
- Security-scoped vault bookmarks

---

## Features

### Vaults (local-first)
- Open any folder as a vault
- Pure `.md` files + attachments (images, PDFs, …)
- Folder structure preserved
- Live FSEvents watching — external editor changes reindex automatically

### Notes
- Source / live preview / split editor
- `[[Wikilinks]]`, `[[target|alias]]`, `![[embeds]]`
- Tags (`#tag`), YAML frontmatter, headings outline
- Task lists, code spans, **GFM tables**, **Obsidian callouts**, blockquotes
- Offline **KaTeX** math (`$…$`, `$$…$$`)
- Daily notes (⌘D), templates via command palette
- Autosave

### Graph view (centerpiece)
- **Global** and **Local** graph (depth 1–5)
- Force-directed physics (repulsion, springs, center force, damping)
- Node size by degree
- Zoom, pan, drag nodes
- Hover → highlight neighbors, fade others
- Click → open note; right-click context menu
- Filters: query, orphans, tags, unresolved, attachments
- Color by folder / tag / degree
- Labels: always / hover / never
- Tunable physics + presets + PNG export
- **Metal** GPU path for nodes/edges (CoreGraphics fallback + labels)

### Other
- Instant search with `path:`, `tag:`, `file:` operators
- Backlinks + unlinked mentions
- Freeform canvas (cards, groups, arrows)
- Command palette (⌘P) + quick switcher (⌘O)
- Light / dark / system appearance
- Plugin API hooks (Swift) for commands & post-processors
- **Workspace persistence** (`.nexus/workspace.json` per vault)

---

## Requirements

- macOS 14 Sonoma or later
- Xcode 16+ (Swift 5.10+)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

---

## Setup

```bash
cd Nexus
xcodegen generate
open Nexus.xcodeproj
```

In Xcode: select the **Nexus** scheme → **My Mac** → Run (⌘R).

Or from the CLI:

```bash
xcodegen generate
xcodebuild -scheme Nexus -configuration Debug build
```

### First launch

1. **Open Vault…** or **Create Sample Vault**
2. Explore notes, press **⌘⌥G** for the graph
3. **⌘P** for the command palette

---

## Architecture

```
Nexus/
├── NexusApp.swift              # App entry, menus, window chrome
├── Models/                     # Notes, graph, canvas types
├── Services/
│   ├── VaultService.swift      # Folder vault + FSEvents watcher
│   ├── LinkIndex.swift         # Wikilinks, backlinks, graph snapshot
│   ├── SearchService.swift     # Full-text + operators
│   ├── AppState.swift          # UI state, tabs, graph settings
│   └── PluginAPI.swift         # Swift plugin host
├── GraphEngine/
│   └── ForceSimulator.swift    # Force-directed layout (grid approx at scale)
├── Views/
│   ├── RootView.swift          # NavigationSplitView shell
│   ├── Editor/                 # NSTextView + WKWebView preview
│   ├── Graph/                  # Interactive graph canvas
│   ├── Canvas/                 # Freeform canvas
│   ├── Sidebar/                # Files, search, tags, outline, backlinks
│   ├── CommandPalette/
│   └── Settings/
└── Utilities/MarkdownParser.swift
```

### How the graph stays in sync

1. `VaultService` scans the vault into `[path: NoteDocument]` and builds the file tree.
2. An `FSEventStream` watches the vault root; debounced rescans pick up external edits.
3. `AppState` observes `vault.$notes` and calls `LinkIndex.rebuild(from:)`.
4. `LinkIndex` extracts `[[wikilinks]]` / tags, resolves targets (basename / path), and publishes a `GraphSnapshot` (nodes + edges), plus backlinks.
5. `GraphView` filters that snapshot (global/local, orphans, tags…) and feeds `ForceSimulator`.
6. A 60 fps timer integrates physics; `GraphNSView` draws edges/nodes with AppKit/CoreGraphics.

The graph engine is isolated under `GraphEngine/` so you can swap in Metal later without touching vault I/O.

---

## Plugin API

```swift
final class MyPlugin: NexusPlugin {
    let id = "com.example.myplugin"
    let name = "My Plugin"
    let version = "1.0.0"

    @MainActor
    func activate(api: PluginContext) async {
        api.registerCommand(id: "hello", title: "Hello from plugin") {
            // use api.openNote, api.getVaultNotes(), etc.
        }
        api.registerMarkdownPostProcessor { markdown in
            // transform markdown before preview
            return markdown
        }
    }

    func deactivate() async {}
}

// At launch:
await pluginHost.register(MyPlugin())
```

See `Services/PluginAPI.swift` and `SampleWordCountPlugin`.

---

## Performance notes (graph)

| Vault size | Expected graph behavior |
|------------|-------------------------|
| &lt; 500 nodes | Full O(n²) repulsion, silky 60 fps |
| 500–2k | Still interactive; layout settles in ~1–3 s |
| 2k–8k | Spatial-hash repulsion (cell grid); pan/zoom stay smooth; prefer filters |
| 8k–15k | Use local graph, hide orphans/tags, lower animation strength |

Tips for large vaults:
- Prefer **Local graph** while writing
- Disable tag nodes and unresolved links in Global view
- Lower **Repulsion** / **Animation** if CPU spikes
- Future: Metal instanced rendering + Barnes–Hut octree (engine is modular)

Benchmark methodology (manual):
1. Generate N notes with random `[[links]]`
2. Open Global Graph, wait for α to cool
3. Observe FPS while panning (Instruments → Core Animation)

---

## Keyboard shortcuts

| Shortcut | Action |
|----------|--------|
| ⌘N | New note |
| ⌘⇧O | Open vault |
| ⌘O | Quick switcher |
| ⌘P | Command palette |
| ⌘D | Daily note |
| ⌘⇧F | Search vault |
| ⌘⌥G | Graph view |
| ⌘⌥⇧G | Local graph |
| ⌘⌥E | Editor |
| ⌘⌥C | Canvas |
| ⌘⌥1 / 2 | Toggle sidebars |

---

## Roadmap (honest)

This is a strong **native foundation** with real vault/graph/editor parity for daily use. Not every Obsidian plugin or edge-case Markdown extension is ported yet. Natural next steps:

- [x] Metal graph renderer (initial spike; instancing / 15k stress next)
- [x] KaTeX + GFM tables + callouts in preview
- [x] Workspace layout persistence
- [ ] Hotkey customizer UI
- [ ] Metal edge thickness + large-vault stress / instancing
- [ ] `.nexusplugin` bundle loading from vault
- [ ] iCloud Drive vault-friendly conflict handling

---

## License

MIT — see [LICENSE](./LICENSE).

Nexus is not affiliated with Obsidian.md.
