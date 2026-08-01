# Nexus — Galladriel follow-up checkpoint

**Date:** 2026-07-30  
**Owner (session):** agent / user  
**Active path:** native SwiftUI + AppKit only (`Nexus/`)

---

## 1) Done-state vs next-state

### Already complete

| Area | Status |
|------|--------|
| Native macOS app shell (menus, toolbar, sidebars) | Done |
| Local vault open/create, FSEvents rescan | Done |
| Markdown source editor + live preview + split | Done |
| Preview: GFM tables + Obsidian callouts + lists/HR | Done |
| Offline KaTeX math (`$…$`, `$$…$$`) | Done |
| Metal graph renderer + CoreGraphics fallback | Done |
| Workspace layout persistence (`.nexus/workspace.json`) | Done |
| Unit tests (parser/search/preview) green | Done (10/10) |
| Wikilinks / tags / frontmatter / backlinks / unlinked | Done |
| Search operators (`path:`, `tag:`, `file:`) | Done |
| Graph: global/local, force layout, filters, presets, PNG | Done |
| Canvas (basic cards/groups/arrows) | Done |
| Command palette + quick switcher + daily notes | Done |
| Plugin API scaffold + sample plugin | Done |
| README / MIT license / XcodeGen project | Done |
| Clean build | **Green** (see §2) |
| Smoke launch | **OK** (see §2) |

### Remains (prioritized)

| Priority | Item | Risk | Owner |
|----------|------|------|-------|
| P1 | Metal: edge thickness, instancing, 15k stress | Med | agent |
| P2 | Hotkey customizer UI | Low | agent |
| P2 | Plugin bundle loading from vault | Med | agent |

---

## 2) Native build / launch check (exact result)

Commands:

```bash
cd "/Users/ghost64/Desktop/not obsidian/Nexus"
xcodegen generate
xcodebuild -scheme Nexus -configuration Debug -destination 'platform=macOS' clean build
open "$DERIVED/Build/Products/Debug/Nexus.app"
```

| Check | Result |
|-------|--------|
| `xcodegen generate` | OK — wrote `Nexus.xcodeproj` |
| `clean build` | **`BUILD SUCCEEDED`** |
| App bundle | `…/DerivedData/Nexus-…/Build/Products/Debug/Nexus.app` |
| Launch (`open` + `pgrep -x Nexus`) | **`LAUNCH_OK: Nexus process running`** |
| Quit | **`LAUNCH_OK: Nexus quit cleanly`** |

No compile errors on the native path after this follow-up.

---

## 3) Legacy Tauri / web scaffold

| Finding | Action |
|---------|--------|
| No `package.json`, `src-tauri`, `Cargo.toml`, or `.rs` under workspace | None present |
| Workspace contains only `Nexus/` (native) | Single active tree |
| macOS volume is case-insensitive: historical `nexus` (Tauri) and `Nexus` (Swift) collide as one folder | Tauri scaffold was superseded; native tree is what remains |
| README already states native-only (mentions Tauri only as “not this”) | Documented |

**Deprecation record:** Tauri/Vite/React is **not** an active launch path. Do not re-scaffold Tauri in this workspace. Native Xcode scheme `Nexus` is the only supported run path.

Optional future cleanup (N/A if folder already gone): delete any reintroduced `src-tauri` / `package.json` immediately.

---

## 4) Graph audit + smallest safe interaction slice

### Audit (no TODO/FIXME markers in tree)

- `GraphEngine/ForceSimulator.swift` — layout only; no open TODOs
- `Views/Graph/GraphView.swift` — interactive host + UI

### Regressions found

1. **Click-to-open broken:** `mouseDown` always set `draggingNode`, so `mouseUp` never treated a node press as a click.
2. **Hover unreliable:** no `NSTrackingArea`; `mouseMoved` often never delivered.
3. **Color/label controls:** changing Color-by / Labels did not refresh appearance without a full graph rebuild.

### Implemented (minimal, this session)

- Drag threshold (4pt): click opens note; drag moves node; background pan unchanged
- `NSTrackingArea` + `mouseExited` for hover highlight / fade
- `refreshAppearance()` + `onChange` for `graphColorBy` / `graphLabels`

Verified: rebuild **BUILD SUCCEEDED**; launch smoke still OK.

---

## 5) Clear next action

**Recommended next step (P1, user-facing):**  
Improve Markdown live preview fidelity (GFM tables + callouts) *or* start Metal graph renderer spike — pick one; do not parallelize both.

| Option | Why | Risk | Owner |
|--------|-----|------|-------|
| **A. Preview fidelity** | Daily note UX; small surface | Low (preview-only) | agent |
| **B. Metal graph spike** | Long-term centerpiece scale | Med (isolated in GraphEngine) | agent |
| **C. Unit tests host fix** | CI confidence | Low | agent |

**Default if unspecified:** **A** (preview tables/callouts) — lowest risk, visible progress.

**Do not:** reintroduce Tauri; expand plugin marketplace; large editor rewrite.

---

## Checkpoint log

| Time | Event |
|------|-------|
| Galladriel start | Captured done vs next; audited tree |
| Build | clean build → SUCCEEDED |
| Launch | process up + clean quit |
| Tauri | confirmed absent / superseded |
| Graph slice | click/hover/color-by fixes landed + rebuild green |
| Next actions | Preview tables/callouts + unit tests **TEST SUCCEEDED** (9/9) |
| All remaining | Metal graph + workspace + KaTeX — **BUILD SUCCEEDED**, **TEST SUCCEEDED** (10/10), **LAUNCH_OK** |
| 2026-07-31 e2e | Full run: **BUILD SUCCEEDED**, **TEST SUCCEEDED** (11/11 incl. EndToEndTests), vault restore + `.nexus/workspace.json`, KaTeX in bundle, **LAUNCH_OK** / **QUIT_OK** |

---

## Follow-up execution (preview + tests)

### Shipped

1. **Live preview fidelity** (`Utilities/MarkdownParser.swift`)
   - Structured block renderer (not only regex soup)
   - **GFM tables** (header, alignment row, body)
   - **Obsidian callouts** (`> [!tip]`, `> [!warning]`, …) with typed styling
   - Plain blockquotes, ordered lists, task lists, HR, fenced code
   - Inline: bold/italic/strike/highlight, wikilinks, tags, md links/images
2. **Sample vault** Markdown Guide includes callouts + table demos
3. **Unit tests**
   - `ENABLE_TESTABILITY` on app target; host loader fixed
   - New `PreviewRendererTests` (table, callout, blockquote, lists)
   - Result: **`TEST SUCCEEDED` — 9 tests, 0 failures**

### Batch complete (Metal + workspace + KaTeX)

| Item | Detail |
|------|--------|
| Metal | `GraphEngine/MetalGraphRenderer.swift` — GPU nodes/edges; CG labels + full CG fallback; toggle in Graph controls/Settings |
| Workspace | `WorkspaceService` → `<vault>/.nexus/workspace.json` + UserDefaults; mode, sidebars, tabs, graph filters, Metal flag, window frame |
| KaTeX | Bundled offline `katex.min.js/css` + fonts; `$…$` / `$$…$$` / `\( \)` / `\[ \]`; flattened resource paths |

### Next action (updated)

| Default | Hotkey customizer UI |
| Alt | Metal edge thickness / large-vault stress + instancing |
| Avoid | Tauri reintroduction |

**Owner:** agent on next ask

---

## Super Notch — runtime / UX checkpoint (2026-07-31)

Cross-project work done in this workspace session (Super Notch on Desktop; island automation live).

### Shipped notes (push into session)

| Item | Detail |
|------|--------|
| **Hands Runtime** | Travel, notes, and git-status skills routed as structured host skills (command intent) with Receipt + WorldDelta — not free-form chat |
| **Get status** | Expanded detection (`get status`, bare `status`, etc.) so STT phrasing still hits `skill.repo.status` |
| **Travel booking** | Required minimum = origin + destination + departure; missing RT return defaults to depart+4d; Kayak filled deep-link primary |
| **Minimized glow** | Collapsed notch shows listen/think/speak under-glow (bleed + panel height + status reframe) |
| **Expand on PTT** | `expandOnPushToTalk` defaults **on**; re-opens minimized island when re-arming / holding Right ⌘ |

### Trace / settings

- Orchestrator: `route=skill skill=… hands=…`
- Settings → Talk → **Expand island when talking** (default yes)

### Next (optional)

- appagent AxHand fallback for Notes when Automation blocked  
- CliHand eic contract pack beyond git status  
- Further flight URL polish if Kayak/Google still blank  

**Owner:** Super Notch track on next ask
