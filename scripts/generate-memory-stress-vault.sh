#!/usr/bin/env bash
# Generate a large Karpathy-style memory vault for manual Nexus graph stress.
set -euo pipefail
N="${1:-800}"
DEST="${2:-$HOME/Documents/Nexus-Memory-Stress}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

rm -rf "$DEST"
mkdir -p "$DEST"/{raw/{inbox,receipts,sessions,proposals},wiki/{user,projects,decisions,concepts,entities,agents}}

python3 - "$DEST" "$N" <<'PY'
import os, sys
root, n = sys.argv[1], int(sys.argv[2])
n = max(n, 50)

def w(rel, body):
    path = os.path.join(root, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(body)

w("AGENTS.md", """---
description: Stress-test maintainer contract for Nexus memory vault
---
# AGENTS.md

Always set `description` on pages. Compile surgically.
""")

w("log.md", """---
description: Stress vault operation log
---
# log

## [2026-07-31 12:00] ingest | Stress generate
""")

w("wiki/hot.md", f"""---
type: hot
description: Always-on brief for {n}-note stress vault
---
# Hot

- Stress vault: ~{n} notes
- Open graph ⌘⌥G and hover nodes for descriptions
- Hubs: [[wiki/index]] [[wiki/overview]]
""")

w("wiki/index.md", f"""---
description: Catalog of stress memory pages ({n} target)
---
# Index

- [[wiki/hot]] — hot brief
- [[wiki/overview]] — overview
- Entities under wiki/entities/
""")

w("wiki/overview.md", f"""---
type: concept
description: Overview of the {n}-note Nexus memory stress vault
tags: [meta, stress]
---
# Overview

Karpathy-style vault generated for graph + index stress.
Hub links: [[wiki/hot]] · [[wiki/index]]
""")

projects = min(25, max(8, n // 30))
concepts = min(40, max(10, n // 20))
sessions = min(50, max(10, n // 15))
entities = max(n - projects - concepts - sessions - 10, n // 2)

for i in range(projects):
    links = " ".join(f"[[wiki/entities/entity-{(i*3+k)%entities}]]" for k in range(4))
    w(f"wiki/projects/project-{i}.md", f"""---
type: project
description: Stress project {i} — multi-entity hub
tags: [project, stress]
updated: 2026-07-31
---
# Project {i}

## Compiled truth
Synthetic project for memory graph stress.

## Links
{links} [[wiki/overview]] [[wiki/hot]]
""")

for i in range(concepts):
    peers = " ".join(f"[[wiki/concepts/concept-{(i+k)%concepts}]]" for k in (0,1,5))
    w(f"wiki/concepts/concept-{i}.md", f"""---
type: concept
description: Concept {i} in the stress ontology
tags: [concept, stress]
---
# Concept {i}

{peers} [[wiki/projects/project-{i%projects}]]
""")

for i in range(entities):
    n1, n2, n3 = (i+1)%entities, (i+17)%entities, (i*3)%entities
    proj = i % projects
    conc = i % concepts
    w(f"wiki/entities/entity-{i}.md", f"""---
type: entity
description: Entity {i} — multi-hop node for graph stress
tags: [entity, stress, batch-{i//50}]
updated: 2026-07-31
---
# Entity {i}

## Compiled truth
Synthetic entity for memory wiki stress testing at scale.

## Links
[[wiki/entities/entity-{n1}]] [[wiki/entities/entity-{n2}]] [[wiki/entities/entity-{n3}]]
[[wiki/projects/project-{proj}]] [[wiki/concepts/concept-{conc}]] [[wiki/index]]
""")

for i in range(sessions):
    ent = i % entities
    w(f"raw/sessions/2026-07-31-session-{i}.md", f"""---
type: session
description: Session digest {i} on entity-{ent}
date: 2026-07-31
---
# Session {i}

## Focus
Worked on [[wiki/entities/entity-{ent}]] and [[wiki/projects/project-{i%projects}]].
""")

count = sum(1 for dp, _, fs in os.walk(root) for f in fs if f.endswith(".md"))
print(f"Wrote {count} markdown files → {root}")
print(f"entities={entities} projects={projects} concepts={concepts} sessions={sessions}")
PY

echo "Vault ready: $DEST"
find "$DEST" -name '*.md' | wc -l
