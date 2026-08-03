# Nexus branding

## Logo concept

**Nexus** = a luminous hub where knowledge links meet.

- **Central hub node** — the active idea / vault center of gravity  
- **Connected constellation** — notes, tags, and backlinks as a living graph  
- **Cyan → violet spectrum** — clarity (search/editor) meeting structure (graph)  
- **Dark charcoal-indigo field** — calm, native, Mac-dark aesthetic  

No wordmark is baked into the app icon (Apple HIG). The word **Nexus** appears in marketing materials (README hero) and the app’s menu bar title.

## Source masters

| File | Use |
|------|-----|
| `branding/icon-master-1024.png` | Full-bleed 1024² master for AppIcon generation |
| `docs/assets/logo.png` | Rounded presentation mark for README / marketing |
| `docs/assets/icon.png` | Full-bleed mark |
| `docs/assets/banner.png` | Wide abstract graph banner |
| `docs/assets/hero.svg` | GitHub hero with exact typography |
| `docs/assets/*-map.svg` / `architecture.svg` / `data-flow.svg` | Visual explainers (hand-authored SVG) |

## Regenerating AppIcon sizes

From the repo root (`Nexus/`):

```bash
MASTER=branding/icon-master-1024.png
ICONSET=Nexus/Resources/Assets.xcassets/AppIcon.appiconset

for px in 16 32 64 128 256 512 1024; do
  sips -z $px $px "$MASTER" --out "$ICONSET/icon-$px.png"
done
```

`Contents.json` maps each macOS slot to the matching `icon-{pixels}.png` (shared where 1x/2x sizes overlap).

Then rebuild:

```bash
xcodegen generate
xcodebuild -scheme Nexus -configuration Release -destination 'platform=macOS' build
```

