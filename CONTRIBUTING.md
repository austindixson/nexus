# Contributing to Nexus

Thanks for helping improve a native, local-first knowledge base.

## Ground rules

1. **Native Swift only** — do not reintroduce Electron, Tauri, or a web shell.
2. Prefer small PRs scoped to one area (parser, graph, shell, tests).
3. Match existing patterns: SwiftUI shell, AppKit where it fits (`NSTextView`, graph host), main-actor UI state.
4. Keep vault data as plain Markdown on disk — no proprietary note DB.

## Dev setup

```bash
brew install xcodegen
xcodegen generate
open Nexus.xcodeproj
```

## Before you open a PR

```bash
xcodegen generate
xcodebuild -scheme Nexus -destination 'platform=macOS' build
xcodebuild -scheme Nexus -destination 'platform=macOS' test
```

## Good first areas

- Markdown preview fidelity
- Graph filters / performance
- Keyboard / accessibility polish
- Tests around `MarkdownParser` and `LinkIndex`

## License

By contributing, you agree your changes are licensed under the MIT License.
