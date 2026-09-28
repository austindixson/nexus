# Nexus Cloud Sync (git-based, opt-in)

Nexus stays **local-first**. Sync is an opt-in per-vault feature: until you turn it on,
Nexus never touches the network. When enabled, the vault itself becomes a git repository
and sync is a commit/push/pull cycle over any git remote.

## How it works

1. **Enable** — Settings → Sync (or the Sync pane in the sidebar). Nexus runs
   `git init` inside the vault and writes a safety `.gitignore` (`.nexus/`, `.DS_Store`,
   `.obsidian/`, `.trash/`, `.git` can never sync itself).
2. **Remote** — any git URL: a local path to a bare repo, `ssh://host/path/to/vault.git`,
   or `https://github.com/you/vault.git`. Nexus shows the credential (user / key) it will use.
3. **Autocommit** — file changes in the vault are committed after a debounce
   (default 60–300 s). Every commit is authored by Nexus with a timestamped message.
4. **Sync cycle** — `git fetch` + `git pull --rebase`; a clean tree re-merges, an
   unresolvable clash is aborted safely (nothing is lost; you are asked to resolve).
   After the cycle, the FSEvents watcher reindexes changed files.
5. **Conflict copies** — if a merge has to keep both sides, Nexus writes
   `Note (conflict <host> <timestamp>).md`, flags it in the Sync pane, and lists it
   under Settings → Sync so you can pick a side in the UI.

## Safety rules

- Disabled by default; turning sync off leaves the git repo untouched.
- Nexus never runs `git push --force` and never resets a dirty worktree.
- If the remote rejects (non-fast-forward), Nexus rebases and retries once, then surfaces the error.
- Remote URL, branch, and debounce are stored in `<vault>/.nexus/sync.json`.
  The auth *key* is stored in the macOS Keychain (`com.ghost64.nexus.sync`), never in the vault.
- A git identity (`user.name` / `user.email`) is required; Nexus writes it to the vault's
  local git config only.

## Sharing the repo across machines

The vault repo is a normal git repo, so any topology works:

- **Bare repo on a server / another Mac**: create it once with
  `git init --bare ~/vault-remote.git`, then add it as the remote on each machine.
  Example over SSH: `ssh+git://ghost32.local/Users/ghost32/vault-remote.git`.
- **GitHub / GitLab**: create an empty repo and paste its URL into Settings → Sync.
- **LAN path**: any reachable filesystem path (including a mounted share).

## What syncs

Everything inside the vault folder that git tracks, minus the safety ignore list.
That means `.md`, canvases, attachments, and `Studio/` / `Sources/` output —
while `.nexus/` (workspace, index, sync settings) stays local.
