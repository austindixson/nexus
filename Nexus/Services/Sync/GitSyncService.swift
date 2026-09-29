import Foundation
import Combine

// MARK: - Models

/// Git-based cloud sync for vaults. Opt-in per vault: with sync disabled Nexus
/// never runs git and never touches the network.
///
/// Design (docs/SYNC.md): the vault folder is turned into a git repository;
/// a debounce-driven autocommit plus a fetch/rebase/push cycle moves changes
/// between machines. Conflict copies are written as `Name (conflict host ts).md`
/// and surfaced in the UI instead of silently picking a side.

nonisolated enum SyncPhase: String, Equatable, Sendable {
    case off
    case idle
    case scanning
    case committing
    case pushing
    case pulling
    case syncing
    case error
}

nonisolated struct SyncSettings: Codable, Equatable, Sendable {
    var enabled: Bool = false
    /// Raw remote as entered (validated through `GitRemote.parse`).
    var remote: String = ""
    var branch: String = "main"
    /// Seconds of quiet before an autocommit fires.
    var debounceSeconds: Int = 120
    /// Seconds between sync cycles when enabled.
    var intervalSeconds: Int = 300
    /// Keychain account holding the HTTPS token / SSH passphrase (empty = ssh-agent / keyless).
    var keychainAccount: String = ""
    /// Explicit git identity written to the vault's *local* git config only.
    var authorName: String = ""
    var authorEmail: String = ""

    static let debounceRange = 30...3600
    static let intervalRange = 60...86400
}

nonisolated struct SyncStatus: Equatable, Sendable {
    var phase: SyncPhase = .off
    var lastSyncAt: Date?
    var lastAction: String = ""
    var lastError: String?
    var aheadCount: Int = 0
    var behindCount: Int = 0
    var dirtyCount: Int = 0
    var conflictPaths: [String] = []

    var isBusy: Bool {
        switch phase {
        case .scanning, .committing, .pushing, .pulling, .syncing: return true
        case .off, .idle, .error: return false
        }
    }
}

/// Result of one git invocation.
nonisolated struct GitResult: Sendable {
    let exitCode: Int32
    let stdout: String
    let stderr: String
    var ok: Bool { exitCode == 0 }
}

/// Drains a Pipe on a background thread so large git output cannot deadlock
/// the caller (reading to EOF on the main actor after termination would block).
final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var done = false

    func startReading(from pipe: Pipe) {
        let handle = pipe.fileHandleForReading
        DispatchQueue.global(qos: .utility).async { [weak self] in
            while true {
                let chunk: Data
                do {
                    chunk = try handle.read(upToCount: 65536) ?? Data()
                } catch {
                    break // pipe closed (e.g. killed process)
                }
                if chunk.isEmpty { break }
                self?.append(chunk)
            }
            try? handle.close()
            self?.finish()
        }
    }

    private func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    func finish() {
        lock.lock()
        done = true
        lock.unlock()
    }

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return done
    }

    func snapshot() -> String {
        lock.lock()
        let copy = data
        lock.unlock()
        return String(decoding: copy, as: UTF8.self)
    }
}

/// Hands a continuation to at most one resumer (process exit vs timeout watchdog).
final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<GitResult, Error>?
    private var resumed = false

    func set(_ continuation: CheckedContinuation<GitResult, Error>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func resume(_ make: () -> GitResult) {
        lock.lock()
        guard !resumed, let cont = continuation else { lock.unlock(); return }
        resumed = true
        lock.unlock()
        cont.resume(returning: make())
    }

    func resumeThrowing(_ error: Error) {
        lock.lock()
        guard !resumed, let cont = continuation else { lock.unlock(); return }
        resumed = true
        lock.unlock()
        cont.resume(throwing: error)
    }
}

// MARK: - Service

@MainActor
final class GitSyncService: ObservableObject {
    static let shared = GitSyncService()

    @Published private(set) var settings = SyncSettings()
    @Published private(set) var status = SyncStatus()
    /// Bumped whenever we want the UI to re-validate.
    @Published private(set) var settingsRevision = 0

    private(set) var vaultRoot: URL?

    private let fm = FileManager.default

    private let keychainService = "com.ghost64.nexus.sync"

    private var cycleTask: Task<Void, Never>?
    private var commitTask: Task<Void, Never>?
    /// Vault mutation events awaiting the next debounced autocommit.
    private var pendingChanges = false
    /// Raw stderr from the most recent failed git command (headless diagnostics).
    var lastGitErrorRaw: String?
    private var cancellables = Set<AnyCancellable>()
    /// Re-entrancy guard for the whole cycle (init/enable/merge).
    private var cycleLock = false
    /// Set while *we* write to the vault so the FSEvents watcher does not
    /// interpret a pull as a user edit storm (we still want it to reindex).
    private var applyingRemote = false
    /// Enable-cycle task, keyed by vault path so a close→open handoff in tests
    /// (or a rapid UI toggle) can cancel only the task that targets the old vault.
    private var enableTask: Task<Void, Never>?
    private var enableTaskVaultPath: String?
    /// Safety window so a crash inside a pull can never leave the watcher
    /// permanently suppressed (the `defer` in pull cancels this normally).
    private var remoteApplyGuard: Task<Void, Never>?
    /// Paths of vaults with a cycle currently running. Cleared in the cycle
    /// `defer`; `waitForCycleClose` polls this set so tests can await completion
    /// even after `detach()` cleared `vaultRoot`.
    private var runningCyclePaths: Set<String> = []

    private init() {
        loadSettings()
    }

    /// Fresh, isolated instance for tests. The shared singleton accumulates
    /// cycles and timers across test cases, which is exactly the cross-talk
    /// this suite needs to rule out.
    static func forTesting() -> GitSyncService {
        let service = GitSyncService()
        service.defaultsKey = "nexus.sync.testing.\(UUID().uuidString)"
        return service
    }

    /// Per-instance UserDefaults key so a test instance never reads or writes
    /// the real app's persisted sync settings.
    private var defaultsKey: String = "nexus.sync.v1"

    /// Await the background enableSync task (tests only).
    func waitForEnableTaskForTesting() async {
        await enableTask?.value
        if let path = vaultRoot?.path {
            await waitForCycleClose(at: path)
        }
    }

    /// Wait until a cycle against `path` finishes or fails. Safe after detach():
    /// pass the path captured before detaching. A no-op when no cycle is in
    /// flight, so repeated calls always terminate.
    func waitForCycleClose(at path: String) async {
        // Poll instead of parking a continuation: the continuation could be
        // resumed by a detached cycle while the vault is gone, and this must
        // also work from a plain (non-async) main thread.
        while runningCyclePaths.contains(path) {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// Await until the sync engine leaves the busy phases (tests only).
    /// `.idle`, `.off`, and `.error` are all settled terminal states.
    func waitForSettledForTesting(timeout: TimeInterval = 30) async {
        let deadline = Date().addingTimeInterval(timeout)
        while status.isBusy && Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// Wipe persisted sync settings (tests + "reset sync" affordances).
    func resetPersistedSettingsForTesting() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        // Drop any per-vault sidecar so tests (and re-enables) start clean.
        if let vaultRoot {
            try? fm.removeItem(at: vaultRoot.appendingPathComponent(".nexus", isDirectory: true))
        }
        settings = SyncSettings()
        status = SyncStatus()
        settingsRevision += 1
    }

    // MARK: - Lifecycle

    /// Called when a vault opens (or closes). Loads per-vault settings and starts/stops timers.
    func attach(vaultRoot: URL?) {
        detach()
        self.vaultRoot = vaultRoot
        guard let vaultRoot else {
            status.phase = .off
            return
        }
        loadSettings()
        if settings.enabled && isGitRepo(at: vaultRoot) {
            status.phase = .idle
            startCycleTimer()
            observeVaultChanges()
        } else {
            status.phase = .off
        }
    }

    func detach() {
        // A cycle in flight is keyed by its own vault path and runs to
        // completion (its git commands are never cancelled); the timers die.
        stopCycleTimer()
        commitTask?.cancel()
        commitTask = nil
        pendingChanges = false
        // Only clear vault callbacks when detaching from the same vault that set them
        // (a close→open handoff must not strip the new vault's observer).
        if let vault = observedVault, vault.rootURL == vaultRoot || vaultRoot == nil {
            vault.onNoteMutated = nil
            vault.onWorkspaceSaved = nil
        }
        observedVault = nil
        workspaceAssumeUnchanged.removeAll()
        vaultRoot = nil
    }

    // MARK: - Settings persistence (UserDefaults + .nexus/sync.json)

    func saveSettings(_ newSettings: SyncSettings) {
        var normalized = newSettings
        let branch = normalized.branch.trimmingCharacters(in: .whitespacesAndNewlines)
        normalized.branch = branch.isEmpty ? "main" : branch
        normalized.debounceSeconds = min(max(normalized.debounceSeconds, SyncSettings.debounceRange.lowerBound), SyncSettings.debounceRange.upperBound)
        normalized.intervalSeconds = min(max(normalized.intervalSeconds, SyncSettings.intervalRange.lowerBound), SyncSettings.intervalRange.upperBound)
        let wasEnabled = settings.enabled
        settings = normalized
        persistSettings()
        settingsRevision += 1
        status.conflictPaths = conflictCopyPaths()
        // `enabled` is the single source of truth for the sync machinery: the
        // periodic timer follows it in both directions. (Tests set `enabled`
        // through saveSettings to take the engine fully manual; the UI always
        // goes through enableSync/disableSync.)
        if normalized.enabled && !wasEnabled && vaultRoot != nil && isGitRepo(at: vaultRoot!) {
            startCycleTimer()
            observeVaultChanges()
        } else if !normalized.enabled {
            stopCycleTimer()
        }
    }

    private func persistSettings() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
        guard let vaultRoot else { return }
        let dir = vaultRoot.appendingPathComponent(".nexus", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("sync.json")
        if let data = try? JSONEncoder().encode(settings) {
            // .nexus/ is git-ignored by enable(), so this never syncs itself.
            try? data.write(to: url, options: .atomic)
        }
    }

    private func loadSettings() {
        var loaded: SyncSettings?
        if let url = vaultRoot?.appendingPathComponent(".nexus/sync.json"),
           let data = try? Data(contentsOf: url) {
            loaded = try? JSONDecoder().decode(SyncSettings.self, from: data)
        }
        if loaded == nil, let data = UserDefaults.standard.data(forKey: defaultsKey) {
            loaded = try? JSONDecoder().decode(SyncSettings.self, from: data)
        }
        settings = loaded ?? SyncSettings()
        // Clamp restored values.
        settings.debounceSeconds = min(max(settings.debounceSeconds, SyncSettings.debounceRange.lowerBound), SyncSettings.debounceRange.upperBound)
        settings.intervalSeconds = min(max(settings.intervalSeconds, SyncSettings.intervalRange.lowerBound), SyncSettings.intervalRange.upperBound)
        status.conflictPaths = conflictCopyPaths()
    }

    // MARK: - Keychain (separate service from AI keys)

    func storeSecret(_ secret: String, for account: String) {
        let data = Data(secret.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    func loadSecret(for account: String) -> String? {
        guard !account.isEmpty else { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let result = SecItemCopyMatching(query as CFDictionary, &item)
        guard result == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func deleteSecret(for account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Whether a Keychain secret exists for the configured account (UI hint only).
    var hasStoredSecret: Bool {
        guard !settings.keychainAccount.isEmpty else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: settings.keychainAccount,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess
    }

    // MARK: - Validation

    func validateRemote(_ raw: String) -> GitRemote? {
        GitRemote.parse(raw)
    }

    /// Validate, pre-flight (ls-remote), and only then enable sync for this vault.
    func enableSync(remoteRaw: String) {
        guard let vaultRoot else {
            status.lastError = "Open a vault first."
            return
        }
        guard let remote = GitRemote.parse(remoteRaw) else {
            status.lastError = "Invalid remote. Use https://, ssh://, git@host:path, or an absolute path to a bare repo."
            status.phase = .error
            return
        }
        guard isSafeVaultRoot(vaultRoot) else {
            status.lastError = "Vault path is not safe for git sync."
            status.phase = .error
            return
        }
        // Reject keychain labels that could not round-trip.
        let account = settings.keychainAccount.trimmingCharacters(in: .whitespacesAndNewlines)
        if account.contains("\u{0000}") || account.contains("\n") {
            status.lastError = "Keychain account label contains invalid characters."
            status.phase = .error
            return
        }
        // Local-path remotes must exist and look like a repo; refuse to git-init a random dir.
        if case .localPath(let path) = remote {
            let url = URL(fileURLWithPath: path)
            guard fm.fileExists(atPath: url.path) else {
                status.lastError = "Remote path does not exist: \(path)"
                status.phase = .error
                return
            }
            let bareMarker = fm.fileExists(atPath: url.appendingPathComponent("HEAD").path)
                || fm.fileExists(atPath: url.appendingPathComponent("objects").path)
            let worktreeMarker = fm.fileExists(atPath: url.appendingPathComponent(".git").path)
            guard bareMarker || worktreeMarker else {
                status.lastError = "Remote path is not a git repository: \(path)"
                status.phase = .error
                return
            }
        }

        var branch = settings.branch.trimmingCharacters(in: .whitespacesAndNewlines)
        if branch.isEmpty { branch = "main" }

        status.lastError = nil
        status.phase = .syncing
        status.lastAction = "Checking remote…"

        let trimmedRaw = remoteRaw.trimmingCharacters(in: .whitespacesAndNewlines)

        func preflightAndEnable() async throws -> String {
            // Bring the vault to "repo exists, origin = this remote, HEAD on the
            // configured branch" using synchronous local git calls (no network).
            // Doing this before any commit is what prevents the first commit
            // landing on `master` (push would fail: "src refspec main does not
            // match any") when the pre-flight probe is still in flight.
            ensureVaultReadyForBranch(at: vaultRoot, branch: branch)
            // Pre-flight before flipping `enabled`: a bad remote must never leave
            // the vault half-enabled with a broken git state.
            let probe = try await self.runGit(
                ["ls-remote", "--heads", self.remoteURLString(remote)],
                at: vaultRoot,
                timeout: 30
            )
            let combined = (probe.stdout + probe.stderr).lowercased()
            if probe.exitCode != 0 {
                if combined.contains("authentication") || combined.contains("permission")
                    || combined.contains("403") || combined.contains("invalid credentials") {
                    throw GitError.authFailed
                }
                if combined.contains("could not read from remote") || combined.contains("connection")
                    || combined.contains("timed out") || combined.contains("resolve host")
                    || combined.contains("unable to access") {
                    throw GitError.unreachable
                }
                throw GitError.commandFailed("ls-remote", probe.stderr)
            }
            // Shared repo created on another Mac: adopt an existing branch when
            // the configured one is absent.
            let resolvedBranch = Self.pickRemoteBranch(from: probe.stdout, preferred: branch) ?? branch
            var newSettings = self.settings
            newSettings.enabled = true
            newSettings.remote = trimmedRaw
            newSettings.branch = resolvedBranch
            newSettings.keychainAccount = account.isEmpty ? self.settings.keychainAccount : account
            self.saveSettings(newSettings)
            self.status.lastError = nil
            return resolvedBranch
        }

        // The task is *never* cancelled once started (detach only stops timers):
        // an aborted initialize used to leave the vault unborn. Completion is
        // tracked instead, so a re-enable can wait for the previous attempt.
        enableTask = Task { [weak self] in
            guard let self else { return }
            let vaultPath = vaultRoot.path
            self.enableTaskVaultPath = vaultPath
            defer { if self.enableTaskVaultPath == vaultPath { self.enableTaskVaultPath = nil } }
            do {
                _ = try await preflightAndEnable()
                await self.initializeAndSync()
            } catch {
                self.status.phase = .error
                self.status.lastError = error.localizedDescription
            }
        }
    }


    /// Pick which remote branch to track: preferred if present, else the first head.
    nonisolated static func pickRemoteBranch(from lsOutput: String, preferred: String) -> String? {
        var refs: [String] = []
        for line in lsOutput.split(separator: "\n") {
            // "<sha>\trefs/heads/<name>"
            guard let tab = line.firstIndex(of: "\t") else { continue }
            let ref = String(line[line.index(after: tab)...])
            guard ref.hasPrefix("refs/heads/") else { continue }
            refs.append(String(ref.dropFirst("refs/heads/".count)))
        }
        if refs.contains(preferred) { return preferred }
        return refs.first
    }

    func disableSync() {
        stopCycleTimer()
        commitTask?.cancel()
        commitTask = nil
        cancellables.removeAll()
        pendingChanges = false
        var newSettings = settings
        newSettings.enabled = false
        saveSettings(newSettings)
        status.phase = .off
        // We never delete the git repo — the user may want history or to re-enable.
    }

    // MARK: - Vault change observation

    private func observeVaultChanges() {
        guard let vault = vaultServiceForObservation else { return }
        guard observedVault !== vault else { return }
        observedVault = vault
        vault.onNoteMutated = { [weak self] path in
            Task { @MainActor [weak self] in
                self?.noteDidChange(path: path)
            }
        }
        // The workspace sidecar (.nexus/workspace.json) is machine-local: record it
        // in an assume-unchanged set so autocommits never churn on it.
        vault.onWorkspaceSaved = { [weak self] path in
            Task { @MainActor [weak self] in
                await self?.noteWorkspaceSaved(path: path)
            }
        }
    }

    private weak var observedVault: VaultService?

    /// VaultService reports every content mutation here. We ignore the machine-local
    /// workspace sidecar so layout autosave does not schedule pointless commits.
    func noteDidChange(path: String) {
        guard settings.enabled, vaultRoot != nil, !applyingRemote else { return }
        if path == ".nexus/workspace.json" || path.hasPrefix(".nexus/") { return }
        pendingChanges = true
        scheduleAutocommit()
    }

    /// Keep `.nexus/workspace.json` out of sync commits via git's
    /// assume-unchanged bit (the file exists in the repo; we just never restage it).
    private func noteWorkspaceSaved(path: String) async {
        guard settings.enabled, vaultRoot != nil else { return }
        let tracked = try? await git(["ls-files", "--error-unmatch", path])
        guard tracked?.ok == true else {
            // Untracked and .nexus/ is in the safety .gitignore — nothing to do.
            return
        }
        if workspaceAssumeUnchanged.contains(path) { return }
        let result = try? await git(["update-index", "--assume-unchanged", path])
        if result?.ok == true {
            workspaceAssumeUnchanged.insert(path)
        }
    }

    private var workspaceAssumeUnchanged: Set<String> = []

    private func scheduleAutocommit() {
        commitTask?.cancel()
        let delay = UInt64(settings.debounceSeconds) * 1_000_000_000
        commitTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard let self, !Task.isCancelled, self.pendingChanges else { return }
            do {
                _ = try await self.commitLocalChanges(message: "nexus: sync \(Self.stamp())")
                self.pendingChanges = false
            } catch {
                // Never swallow: an uncommitted vault means changes that never reach
                // the remote. Surface it; the interval cycle retries anyway.
                self.status.phase = .error
                self.status.lastError = error.localizedDescription
            }
        }
    }

    /// Snapshot of everything the git layer needs, captured once at cycle entry.
    /// The engine is a MainActor singleton, but a test (or a fast vault
    /// close→open) can `detach()` mid-cycle, clearing `vaultRoot`/`settings`
    /// while this cycle still has awaits in flight; every git command would
    /// then run against the *next* vault. The context makes a cycle immune.
    private struct CycleContext {
        let vaultRoot: URL
        let settings: SyncSettings
        var remote: GitRemote? { GitRemote.parse(settings.remote) }
        var branch: String {
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
            let cleaned = String(settings.branch.unicodeScalars.map { scalar -> String in
                allowed.contains(scalar) || scalar == "/" ? String(scalar) : ""
            }.joined()).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return cleaned.isEmpty ? "main" : cleaned
        }
    }
    /// Context of the cycle currently in flight, read by the git helpers.
    private var cycleContext: CycleContext?
    /// Weak reference wired by AppState so we can observe vault mutations.
    weak var vaultServiceForObservation: VaultService?

    // MARK: - Core cycle

    func initializeAndSync() async {
        guard let vaultRoot, !cycleLock else { return }
        cycleLock = true
        runningCyclePaths.insert(vaultRoot.path)
        cycleContext = CycleContext(vaultRoot: vaultRoot, settings: settings)
        defer { cycleLock = false; runningCyclePaths.remove(vaultRoot.path); cycleContext = nil }
        do {
            status.phase = .syncing
            status.lastAction = "Initializing repository…"
            if !isGitRepo(at: vaultRoot) {
                let initResult = try await runGit(["init", "--initial-branch=\(safeBranch())"], at: vaultRoot)
                if !initResult.ok {
                    // Older git without --initial-branch.
                    _ = try await runGit(["init"], at: vaultRoot)
                    _ = try await runGit(["symbolic-ref", "HEAD", "refs/heads/\(safeBranch())"], at: vaultRoot)
                }
            }
            await ensureLocalIdentity(at: vaultRoot)
            // The identity must exist *before* the first commit or git refuses with
            // "Please tell me who you are". Settings are the authoritative source.
            if settings.authorName.isEmpty || settings.authorEmail.isEmpty {
                var seeded = settings
                if seeded.authorName.isEmpty {
                    seeded.authorName = ProcessInfo.processInfo.userName.isEmpty ? "Nexus" : ProcessInfo.processInfo.userName
                }
                if seeded.authorEmail.isEmpty {
                    let host = ProcessInfo.processInfo.hostName
                    let user = ProcessInfo.processInfo.userName
                    seeded.authorEmail = "\(user)@\(host.isEmpty ? "localhost" : host)"
                }
                saveSettings(seeded)
                await ensureLocalIdentity(at: vaultRoot)
            }
            try await ensureRemoteConfigured(at: vaultRoot)
            // Pre-commit integration: only when the remote already has history
            // and our HEAD is unborn. Unrelated histories cannot be rebased
            // later, so the remote tip is adopted outright (a clean checkout);
            // the safety gitignore + first commit then sit on top of it.
            let remoteHeads = try? await git(["ls-remote", "--heads", "origin"])
            let remoteHasHistory = remoteHeads?.ok == true
                && !remoteHeads!.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if remoteHasHistory {
                let remoteBranch = Self.pickRemoteBranch(from: remoteHeads!.stdout, preferred: safeBranch()) ?? safeBranch()
                if remoteBranch != safeBranch() {
                    var adopted = settings
                    adopted.branch = remoteBranch
                    saveSettings(adopted)
                }
                let headOk = (try? await git(["rev-parse", "--verify", "HEAD"]))?.ok ?? false
                if !headOk {
                    status.lastAction = "Adopting remote history…"
                    _ = try await git(["fetch", "origin", "refs/heads/\(remoteBranch):refs/remotes/origin/\(remoteBranch)"])
                    _ = try await git(["checkout", "-q", "-B", remoteBranch, "origin/\(remoteBranch)"])
                }
            }
            // The safety ignore runs *before* the first commit so .nexus/
            // sidecars are never tracked (tracked sidecars make every later
            // `pull --rebase` refuse to run). Sidecar *untracking* runs after
            // the first commit: before it the repo is unborn or freshly
            // checked out, and a `git rm --cached` there would create the very
            // "unstaged changes" that block the pull below.
            try writeSafetyGitignore(at: vaultRoot)
            status.lastAction = "Committing current vault…"
            // This cycle runs *before* the user-visible enable flag flips, so the
            // enable-time git operations must not require it: skipping the commit
            // silently used to leave the vault unborn, and the push then failed
            // with "src refspec main does not match any".
            _ = try await commitLocalChanges(message: "nexus: enable sync \(Self.stamp())", requireEnabled: false)
            // Drop any sidecars an older build tracked, then commit that cleanup:
            // an untracked-but-dirty index would make the pull below refuse with
            // "cannot pull with rebase: You have unstaged changes".
            await untrackLocalSidecars(at: vaultRoot)
            _ = try await commitLocalChanges(message: "nexus: untrack local sidecars", requireEnabled: false)
            // The very first commit of a pre-existing repo switches HEAD to the
            // configured branch; a cycle started during that switch used to see
            // "src refspec main does not match any".
            try await ensureHeadOnConfiguredBranch(at: vaultRoot)
            if remoteHasHistory {
                // Own history + remote history: rebase ours onto theirs now that
                // the worktree is clean, so the push below is a fast-forward.
                status.lastAction = "Integrating remote history…"
                do {
                    try await pull(rebase: true, requireEnabled: false)
                } catch let error as GitError {
                    if case .conflict = error { throw error }
                    if case .pullBlocked = error { throw error }
                    SyncTrace.log("enable pull skipped (push continues): \(error.localizedDescription)")
                }
            }
            status.lastAction = "Pushing…"
            try await push(requireEnabled: false)
            status.phase = .idle
            status.lastSyncAt = Date()
            status.lastAction = "Sync enabled"
            status.lastError = nil
            status.conflictPaths = conflictCopyPaths()
            startCycleTimer()
            observeVaultChanges()
        } catch {
            status.phase = .error
            status.lastError = error.localizedDescription
            // Keep a copy for post-mortem inspection when the test harness deletes
            // the vault in tearDown.
            let dest = URL(fileURLWithPath: "/tmp/nexus-init-fail-vault")
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.copyItem(at: vaultRoot, to: dest)
            SyncTrace.log("init FAILED vault copied to \(dest.path): \(error.localizedDescription)")
        }
    }

    /// One-shot cycle against an explicitly supplied remote (headless smoke runs).
    /// Applies the override to settings first, then delegates to `syncNow()`, so
    /// `.nexus/sync.json`, git config, and the vault repo all end up consistent.
    func syncOnce(remoteOverride: String) async {
        var next = settings
        next.remote = remoteOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        next.enabled = true
        if next.branch.isEmpty { next.branch = "main" }
        saveSettings(next)
        await syncNow()
    }

    /// Run one full sync cycle (autocommit → pull --rebase → push). Safe to call manually.
    func syncNow() async {
        // The enabled check happens when the cycle is *scheduled*; by the time it
        // runs the vault may have detached (tests close vaults between cycles),
        // and a cycle already in flight must still reach the remote.
        guard let vaultRoot, !cycleLock else { return }
        cycleLock = true
        runningCyclePaths.insert(vaultRoot.path)
        if cycleContext == nil { cycleContext = CycleContext(vaultRoot: vaultRoot, settings: settings) }
        defer { cycleLock = false; runningCyclePaths.remove(vaultRoot.path); cycleContext = nil }
        do {
            await ensureLocalIdentity(at: vaultRoot)
            try await ensureRemoteConfigured(at: vaultRoot)
            // ensureRemoteConfigured pins an unborn HEAD to the configured branch;
            // ensureHeadOnConfiguredBranch additionally handles a HEAD sitting on
            // some other (already-committed) branch.
            try await ensureHeadOnConfiguredBranch(at: vaultRoot)
            // Commit first: `git pull --rebase` refuses to run over an unclean
            // worktree, so local edits must be committed before we integrate remote
            // commits.
            // A user edit may have landed while this cycle was queued; commit it
            // now so the pull below never runs over an unclean worktree. The flag
            // stays set until a cycle actually pushes — nothing is ever silently dropped.
            let dirty = try await commitLocalChanges(message: "nexus: sync \(Self.stamp())")
            if !dirty, pendingChanges {
                // A scheduled commit found nothing to stage: the edit either
                // raced the cycle or was reverted. Record it instead of leaving
                // the engine silently not-ready.
                status.lastAction = "Nothing new to commit"
            }
            status.phase = .pulling
            status.lastAction = dirty ? "Pushing local changes…" : "Pulling…"
            do {
                try await pull(rebase: true)
            } catch let error as GitError {
                // A conflict or a blocked rebase genuinely must stop the cycle
                // (pushing now would strand a half-rebase). Anything else — a
                // branch that does not exist on the remote yet, a transient
                // network blip — only means there was nothing to integrate, so
                // the committed work still goes out below.
                if case .conflict = error { throw error }
                if case .pullBlocked = error { throw error }
                SyncTrace.log("pull skipped (push continues): \(error.localizedDescription)")
            }
            status.phase = .pushing
            do {
                try await push()
            } catch {
                // A committed vault must not report "synced" while the remote is behind —
                // aheadCount tells the UI the truth and the interval cycle retries.
                await refreshCounts(at: vaultRoot)
                throw error
            }
            status.phase = .idle
            status.lastSyncAt = Date()
            status.lastError = nil
            // The cycle reached the remote: nothing is pending anymore.
            pendingChanges = false
            await refreshCounts(at: vaultRoot)
            status.conflictPaths = conflictCopyPaths()
            status.lastAction = "Synced \(Self.stamp())"
        } catch {
            status.phase = .error
            status.lastError = error.localizedDescription
            // Keep pendingChanges when a pull was blocked: the local commit exists
            // and must reach the remote on the next cycle.
            await refreshCounts(at: vaultRoot)
        }
    }

    private func startCycleTimer() {
        stopCycleTimer()
        let interval = UInt64(settings.intervalSeconds) * 1_000_000_000
        cycleTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                guard !Task.isCancelled else { break }
                await self?.syncNow()
            }
        }
    }

    private func stopCycleTimer() {
        cycleTask?.cancel()
        cycleTask = nil
    }

    // MARK: - Git plumbing (all via /usr/bin/git argument arrays — never a shell)

    nonisolated private static let gitPath = "/usr/bin/git"

    /// Bumped whenever sync diagnostics change, so smoke reports prove which
    /// build produced them.
    nonisolated static let diagnosticsTag = "2026-09-28-4"

    nonisolated static func gitPathPresent() -> Bool {
        FileManager.default.isExecutableFile(atPath: "/usr/bin/git")
    }

    /// Synchronous git runner for the rare call sites that must not suspend
    /// (conflict detection inside a cycle). Off-main only; never use in async code.
    nonisolated private static func runGitBlocking(_ arguments: [String], at cwd: URL, timeout: TimeInterval) throws -> GitResult {
        for arg in arguments {
            if arg.unicodeScalars.contains(where: { $0 == "\0" || $0 == "\n" || $0 == "\r" }) {
                throw GitError.invalidArgument
            }
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = cwd
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.environment = [
            "HOME": NSHomeDirectory(),
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_CONFIG_NOSYSTEM": "1",
        ]
        let outData = OutputCollector()
        let errData = OutputCollector()
        outData.startReading(from: outPipe)
        errData.startReading(from: errPipe)
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            usleep(20_000)
        }
        if process.isRunning {
            process.terminationHandler = nil
            process.interrupt()
            usleep(200_000)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        outData.finish()
        errData.finish()
        return GitResult(exitCode: process.terminationStatus, stdout: outData.snapshot(), stderr: errData.snapshot())
    }

    @discardableResult
    func runGit(_ arguments: [String], at cwd: URL, timeout: TimeInterval? = nil) async throws -> GitResult {
        // Defense-in-depth: reject any argument carrying control chars or NULs.
        for arg in arguments {
            if arg.unicodeScalars.contains(where: { $0 == "\0" || $0 == "\n" || $0 == "\r" }) {
                throw GitError.invalidArgument
            }
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<GitResult, Error>) in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: Self.gitPath)
                process.arguments = arguments
                process.currentDirectoryURL = cwd
                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe

                // Minimal env: never leak the app's environment into git.
                // GIT_SSH_COMMAND is intentionally not inherited (no user shell overrides);
                // HOME is required for ssh key discovery, PATH for /usr/bin/git helpers.
                var env: [String: String] = [
                    "HOME": NSHomeDirectory(),
                    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                    "GIT_TERMINAL_PROMPT": "0", // never block on an interactive credential prompt
                    "GIT_CONFIG_NOSYSTEM": "1", // ignore /etc/gitconfig surprises
                ]
                if let home = ProcessInfo.processInfo.environment["HOME"] { env["HOME"] = home }
                if let sshAuth = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"] { env["SSH_AUTH_SOCK"] = sshAuth }
                if let lang = ProcessInfo.processInfo.environment["LANG"] { env["LANG"] = lang }
                // Credential plumbing (see AskpassHelper): a Keychain secret is
                // handed to git through a temp-file askpass helper that lives only for
                // this process; SSH gets BatchMode so it can never block on a prompt.
                // The secret itself is never placed in the environment or in .git/config.
                if let helper = AskpassHelper.current {
                    env.merge(helper.environmentExtras) { _, new in new }
                }
                process.environment = env
                SyncTrace.logFull("spawn \(arguments.joined(separator: " ")) cwd=\(cwd.path)")

                // Read pipes to EOF on background threads — reading on the main actor
                // after termination deadlocks when git writes more than the pipe buffer.
                let outData = OutputCollector()
                let errData = OutputCollector()
                outData.startReading(from: outPipe)
                errData.startReading(from: errPipe)

                // Resume exactly once, whether the process exits or the watchdog fires.
                let box = ResultBox()
                box.set(continuation)

                // Per-command timeout: network plumbing fails fast, local stays generous.
                let timeout = timeout ?? Self.gitTimeout(for: arguments.filter {
                    !$0.hasPrefix("-c") && !$0.hasPrefix("protocol.") && !$0.hasPrefix("safe.")
                })
                let timeoutTask = Task { [weak process] in
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    // Even when the cycle cancelled this task, a git process still
                    // running past its timeout must never leave the continuation
                    // suspended: clean up and resume regardless (ResultBox only
                    // resumes once, so a late fire is harmless).
                    guard let process, process.isRunning else { return }
                    if !Task.isCancelled {
                        process.terminationHandler = nil
                        process.interrupt()
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                    }
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    outData.finish()
                    errData.finish()
                    let partial = errData.snapshot()
                    box.resume {
                        GitResult(
                            exitCode: -1,
                            stdout: outData.snapshot(),
                            stderr: (partial.isEmpty ? "" : partial + "\n") + "git timed out after \(Int(timeout))s"
                        )
                    }
                }

                // Absolute backstop on the whole command: the soft watchdog can
                // in principle be swallowed (a cancelled task that dies before
                // resuming), and a never-resuming continuation would strand the
                // cycle in "Syncing…" forever. This one always fires.
                let ceiling = timeout + 60
                let ceilingTask = Task { [weak process] in
                    try? await Task.sleep(nanoseconds: UInt64(ceiling * 1_000_000_000))
                    guard let process else { return }
                    if process.isRunning {
                        SyncTrace.log("git hard-ceiling kill after \(Int(ceiling))s: "
                            + arguments.joined(separator: " "))
                        process.terminationHandler = nil
                        kill(process.processIdentifier, SIGKILL)
                    }
                    box.resume {
                        GitResult(exitCode: -1, stdout: outData.snapshot(),
                                  stderr: "git did not finish within \(Int(ceiling))s and was stopped.")
                    }
                }
                process.terminationHandler = { proc in
                    ceilingTask.cancel()
                    outData.finish()
                    errData.finish()
                    timeoutTask.cancel()
                    var result = GitResult(
                        exitCode: proc.terminationStatus,
                        stdout: outData.snapshot(),
                        stderr: errData.snapshot()
                    )
                    // Signal death (e.g. SIGKILL from the system) produces no output;
                    // annotate so the sync UI is not silent.
                    if result.exitCode != 0, result.stdout.isEmpty, result.stderr.isEmpty,
                       proc.terminationReason == .uncaughtSignal {
                        result = GitResult(
                            exitCode: result.exitCode,
                            stdout: "",
                            stderr: "git was killed by a signal (exit \(result.exitCode))."
                        )
                    }
                    box.resume { result }
                }
                do {
                    try process.run()
                } catch {
                    timeoutTask.cancel()
                    box.resumeThrowing(GitError.launchFailed(error.localizedDescription))
                }
            }
        } onCancel: {
            // Cancellation never kills git mid-command (partial states are worse
            // than waiting for the timeout watchdog).
        }
    }

    private func git(_ arguments: [String]) async throws -> GitResult {
        // Prefer the snapshot the running cycle captured at entry; fall back to
        // the live singleton state for the one-shot entry points that do not
        // (yet) capture. Either way, a `detach()` mid-cycle cannot redirect the
        // git commands at the next vault.
        let ctx = cycleContext
        guard let vaultRoot = ctx?.vaultRoot ?? self.vaultRoot else { throw GitError.noVault }
        var args: [String] = []
        // Local-path remotes are explicit user choice (shared volume / another Mac).
        // file:// protocol stays disabled unless the configured remote parses as
        // a safe local path; safe.directory covers externally-owned repos.
        var fileAllow = "false"
        if case .localPath(let path)? = ctx?.remote ?? GitRemote.parse(settings.remote) {
            fileAllow = "always"
            args += ["-c", "safe.directory=\(path)", "-c", "safe.directory=\(vaultRoot.path)"]
        }
        args += ["-c", "protocol.file.allow=\(fileAllow)"] + arguments
        let remote = ctx?.remote ?? GitRemote.parse(settings.remote)
        let res = try await withAskpassInstalled(using: remote) {
            try await self.runGit(args, at: vaultRoot, timeout: Self.gitTimeout(for: arguments))
        }
        if !res.ok {
            SyncTrace.log("git exit=\(res.exitCode) \(arguments.joined(separator: " ")) "
                + "err=\(res.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return res
    }

    /// Per-command timeouts (seconds). Network ops get generous budgets; local
    /// plumbing must fail fast so a hung git never wedges the sync loop.
    nonisolated static func gitTimeout(for arguments: [String]) -> TimeInterval {
        let first = arguments.first(where: { !$0.hasPrefix("-") && !$0.hasPrefix("protocol.") && !$0.hasPrefix("safe.") })
            ?? arguments.first ?? ""
        switch first {
        case "ls-remote": return 30
        case "push": return 300
        case "pull", "fetch": return 300
        case "commit", "add", "status", "rev-parse", "rev-list", "config", "ls-files",
             "update-index", "remote", "init", "symbolic-ref", "diff", "checkout", "rebase", "merge":
            return 120
        default: return 120
        }
    }

    func isGitRepo(at url: URL) -> Bool {
        let direct = fm.fileExists(atPath: url.appendingPathComponent(".git").path)
            || fm.fileExists(atPath: url.appendingPathComponent("HEAD").path)
        return direct
    }

    /// Synchronously bring the vault to "git repo, origin configured to the
    /// settings remote, HEAD on `branch`". Local git calls only — never network.
    /// Running this before the first commit is what keeps a first commit from
    /// landing on `master` (push would then fail with "src refspec main does
    /// not match any").
    private func ensureVaultReadyForBranch(at vaultRoot: URL, branch: String) {
        if !isGitRepo(at: vaultRoot) {
            let initResult = try? GitSyncService.runGitBlocking(
                ["init", "--initial-branch=\(branch)"], at: vaultRoot, timeout: 30)
            if initResult?.ok != true {
                _ = try? GitSyncService.runGitBlocking(["init"], at: vaultRoot, timeout: 30)
                _ = try? GitSyncService.runGitBlocking(
                    ["symbolic-ref", "HEAD", "refs/heads/\(branch)"], at: vaultRoot, timeout: 30)
            }
        }
        if let remote = GitRemote.parse(settings.remote) {
            let url = remoteURLString(remote)
            let current = try? GitSyncService.runGitBlocking(
                ["remote", "get-url", "origin"], at: vaultRoot, timeout: 15)
            if current?.ok == true {
                if current!.stdout.trimmingCharacters(in: .whitespacesAndNewlines) != url {
                    _ = try? GitSyncService.runGitBlocking(
                        ["remote", "set-url", "origin", url], at: vaultRoot, timeout: 15)
                }
            } else {
                _ = try? GitSyncService.runGitBlocking(
                    ["remote", "add", "origin", url], at: vaultRoot, timeout: 15)
            }
        }
        // Unborn HEAD: rename the branch pointer onto the configured branch so
        // the very first commit lands there. Otherwise leave HEAD to
        // ensureHeadOnConfiguredBranch (it also handles detached states).
        let headExists = try? GitSyncService.runGitBlocking(
            ["rev-parse", "--verify", "HEAD"], at: vaultRoot, timeout: 15)
        if headExists?.ok != true {
            _ = try? GitSyncService.runGitBlocking(
                ["symbolic-ref", "HEAD", "refs/heads/\(branch)"], at: vaultRoot, timeout: 15)
        }
    }

    private func ensureHeadOnConfiguredBranch(at vaultRoot: URL) async throws {
        let branch = safeBranchForArg()
        let current = try await git(["symbolic-ref", "--short", "-q", "HEAD"])
        if current.ok, current.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == branch { return }
        // Unborn HEAD (no commits yet): just rename the branch pointer.
        let headExists = try await git(["rev-parse", "--verify", "HEAD"])
        if !headExists.ok {
            _ = try await git(["symbolic-ref", "HEAD", "refs/heads/\(branch)"])
            return
        }
        if branch == "HEAD" { return } // detached at an odd ref — leave the tree alone
        let exists = try await git(["show-ref", "--verify", "--quiet", "refs/heads/\(branch)"])
        if exists.ok {
            _ = try await git(["checkout", "-q", branch])
        } else {
            _ = try await git(["checkout", "-q", "-b", branch])
        }
    }

    private func safeBranch() -> String {
        if let ctx = cycleContext { return ctx.branch }
        let b = settings.branch.trimmingCharacters(in: .whitespacesAndNewlines)
        return b.isEmpty ? "main" : b
    }

    /// Drop the machine-local `.nexus/` sidecars from the index if an earlier
    /// build tracked them. Their presence makes `pull --rebase` refuse to run,
    /// and they must never reach the remote. Runs before any commit.
    private func untrackLocalSidecars(at vaultRoot: URL) async {
        let listed = try? await git(["ls-files", "--", ".nexus"])
        guard let listed, listed.ok else { return }
        let paths = listed.stdout
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.isEmpty }
        guard !paths.isEmpty else { return }
        _ = try? await git(["rm", "-r", "--cached", "--", ".nexus"])
        // Leave a working-tree copy behind if the user's files are still there.
        try? writeSafetyGitignore(at: vaultRoot)
    }

    private func safeBranchForArg() -> String {
        if let ctx = cycleContext { return ctx.branch }
        // Branch names: letters, digits, dot, dash, underscore, slash.
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        let scalars = settings.branch.unicodeScalars.map { scalar -> String in
            allowed.contains(scalar) || scalar == "/" ? String(scalar) : ""
        }
        let cleaned = String(scalars.joined()).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return cleaned.isEmpty ? "main" : cleaned
    }

    private func ensureLocalIdentity(at vaultRoot: URL) async {
        let source = cycleContext?.settings ?? settings
        let name = source.authorName.trimmingCharacters(in: .whitespacesAndNewlines)
        let email = source.authorEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !email.isEmpty else { return }
        _ = try? await git(["config", "user.name", name])
        _ = try? await git(["config", "user.email", email])
    }

    private func ensureRemoteConfigured(at vaultRoot: URL) async throws {
        guard let remote = GitRemote.parse(settings.remote) else {
            throw GitError.invalidRemote
        }
        let current = try await git(["remote", "get-url", "origin"])
        if current.ok, current.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == remoteURLString(remote) {
            return
        }
        if current.ok {
            _ = try await git(["remote", "set-url", "origin", remoteURLString(remote)])
        } else {
            _ = try await git(["remote", "add", "origin", remoteURLString(remote)])
        }
        // origin now exists — an unborn HEAD must point at the configured branch
        // before any commit is possible (otherwise the first commit lands on
        // `master` and the push of `main` fails with "src refspec ...").
        let headExists = try await git(["rev-parse", "--verify", "HEAD"])
        if !headExists.ok {
            _ = try await git(["symbolic-ref", "HEAD", "refs/heads/\(safeBranch())"])
        }
    }

    private func remoteURLString(_ remote: GitRemote) -> String {
        switch remote {
        case .https(let s), .http(let s), .ssh(let s): return s
        case .localPath(let p): return p
        }
    }

    private func remoteHasCommits() async -> Bool {
        let result = try? await git(["ls-remote", "--heads", "origin"])
        return result?.ok == true && !(result?.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    // MARK: - Commit / pull / push

    /// Stage everything and commit if the worktree is dirty. Returns whether a commit was made.
    /// A missing git identity is seeded from ProcessInfo (never a `nexus@localhost`
    /// placeholder) so commits carry a real author.
    @discardableResult
    func commitLocalChanges(message: String, requireEnabled: Bool = true) async throws -> Bool {
        guard let vaultRoot, (!requireEnabled || settings.enabled) else { throw GitError.noVault }
        // Ignore rules and sidecar cleanup run before the dirty check so a
        // machine-local sidecar never shows up as a user change.
        try? writeSafetyGitignore(at: vaultRoot)
        await untrackLocalSidecars(at: vaultRoot)
        let before = try await git(["status", "--porcelain"])
        guard before.ok else {
            throw GitError.commandFailed("status", before.stderr)
        }
        let changedLines = before.stdout
            .split(separator: "\n")
            .filter { !$0.isEmpty }
        status.dirtyCount = changedLines.count
        guard !changedLines.isEmpty else { return false }

        _ = try await git(["add", "-A"])
        // git's commit editor ignores GIT_TERMINAL_PROMPT, so an unset identity
        // could block the cycle forever waiting on /dev/tty; pass a fallback
        // identity explicitly instead.
        let info = ProcessInfo.processInfo
        let source = cycleContext?.settings ?? settings
        let name = source.authorName.trimmingCharacters(in: .whitespacesAndNewlines)
        let email = source.authorEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackName = name.isEmpty ? (info.userName.isEmpty ? "Nexus" : info.userName) : name
        let fallbackEmail = email.isEmpty
            ? "\(fallbackName)@\(info.hostName.isEmpty ? "localhost" : info.hostName)"
            : email
        let commit = try await git([
            "-c", "user.name=\(fallbackName)", "-c", "user.email=\(fallbackEmail)",
            "commit", "-m", message,
        ])
        if !commit.ok {
            // "nothing to commit" races are fine; anything else is a real failure.
            if commit.stdout.contains("nothing to commit") || commit.stderr.contains("nothing to commit") {
                return false
            }
            // Author identity may be missing — set a neutral fallback locally.
            if commit.stderr.localizedCaseInsensitiveContains("Please tell me who you are")
                || commit.stderr.localizedCaseInsensitiveContains("author identity") {
                let info = ProcessInfo.processInfo
                let name = info.userName.isEmpty ? "Nexus" : info.userName
                let host = info.hostName.isEmpty ? "localhost" : info.hostName
                var seeded = settings
                seeded.authorName = name
                seeded.authorEmail = "\(name)@\(host)"
                saveSettings(seeded)
                await ensureLocalIdentity(at: vaultRoot)
                let retry = try await git(["commit", "-m", message])
                if !retry.ok {
                    throw GitError.commandFailed("commit", retry.stderr)
                }
                await refreshCounts(at: vaultRoot)
                return true
            }
            throw GitError.commandFailed("commit", commit.stderr)
        }
        await refreshCounts(at: vaultRoot)
        return true
    }

    func pull(rebase: Bool, requireEnabled: Bool = true) async throws {
        guard !requireEnabled || settings.enabled else { return }
        let branch = safeBranchForArg()
        var args = ["pull"]
        if rebase { args.append("--rebase") }
        // Explicit refspec into the *remote-tracking* ref: the short "origin main"
        // form fails outright (exit 128) on remotes without a configured fetch
        // refspec, and a ":refs/heads/main" target updates the local branch
        // during fetch, which git rejects as non-fast-forward while rebasing.
        args.append(contentsOf: ["origin", "refs/heads/\(branch):refs/remotes/origin/\(branch)"])

        // Suppress the vault watcher while git rewrites the worktree, and clear
        // any mutation it observed mid-checkout: a remote-side edit that we are
        // pulling is not a local pending change.
        applyingRemote = true
        remoteApplyGuard?.cancel()
        remoteApplyGuard = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 60_000_000_000) // safety window
            guard let self, !Task.isCancelled else { return }
            self.applyingRemote = false
        }
        defer {
            remoteApplyGuard?.cancel()
            remoteApplyGuard = nil
            applyingRemote = false
            // NOTE: pendingChanges must NOT be cleared here. An edit that landed
            // between the commit step and this pull is still a local pending
            // change; clearing it here made the mutation never reach the remote.
        }
        let result = try await git(args)
        if result.ok { return }

        let combined = (result.stdout + result.stderr).lowercased()
        // The remote branch may not exist yet (first-ever push, or a push
        // still in flight) — there is simply nothing to pull yet.
        if combined.contains("couldn't find remote ref") || combined.contains("no such ref") {
            return
        }
        // Killed git (SIGPIPE/SIGKILL) leaves no output at all. The refspec form
        // unpacks on the receiving side instead of streaming a pack over the
        // "push" transport, so it survives the signal that kills the plain form.
        if result.exitCode == 141 || combined.contains("sigpipe") || combined.contains("signal 13") {
            var retryArgs = ["pull", "origin", "refs/heads/\(branch):refs/remotes/origin/\(branch)"]
            if rebase { retryArgs = ["pull", "--rebase", "origin", "refs/heads/\(branch):refs/remotes/origin/\(branch)"] }
            let retry = try await git(retryArgs)
            if retry.ok { return }
            let retryCombined = (retry.stdout + retry.stderr).lowercased()
            if retryCombined.isEmpty {
                let detail = SyncTrace.tail(24).joined(separator: "\n")
                lastGitErrorRaw = "pull: empty output\n" + detail
                throw GitError.commandFailed("pull",
                    "git pull exited with no output (possibly killed). Recent git activity:\n\(detail.suffix(600))")
            }
            let retryErr = classifyPullFailure(GitResult(exitCode: retry.exitCode,
                stdout: retry.stdout, stderr: retry.stderr), rebaseWasAttempted: rebase)
            throw retryErr
        }
        if combined.isEmpty {
            let detail = SyncTrace.tail(24).joined(separator: "\n")
            lastGitErrorRaw = "pull: empty output\n" + detail
            throw GitError.commandFailed("pull",
                "git pull exited with no output (possibly killed). Recent git activity:\n\(detail.suffix(600))")
        }
        throw classifyPullFailure(result, rebaseWasAttempted: rebase)
    }

    /// Turn a failed `pull` result into the right GitError. `rebaseWasAttempted`
    /// gates the blocked/conflict heuristics: "unstaged changes" wording also
    /// appears in plain fetch/status failures where no rebase ever ran, and
    /// those must not masquerade as a blocked rebase. Never returns an empty
    /// "git pull: " message.
    private func classifyPullFailure(_ result: GitResult, rebaseWasAttempted: Bool) -> GitError {
        let raw = (result.stderr + " " + result.stdout)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let combined = (result.stdout + result.stderr).lowercased()
        if rebaseWasAttempted {
            // Rebase refused to start over an unclean worktree (or a conflicted
            // rebase is already in progress). Never stash and never lose work.
            if combined.contains("cannot pull with rebase")
                || combined.contains("you have unstaged changes")
                || combined.contains("you have uncommitted changes")
                || combined.contains("unstaged changes")
                || (combined.contains("cannot lock ref") && combined.contains("rebase")) {
                lastGitErrorRaw = "pull: " + raw
                return GitError.pullBlocked(
                    "The vault has uncommitted changes outside Nexus' control, so the\nrebase was skipped. Your vault is untouched — commit or revert the\nchanges in the vault folder (or turn sync off and edit manually)."
                )
            }
            // Conflicted rebase: abort so we never leave the repo mid-rebase, and
            // surface the conflict to the user instead of guessing a side.
            if combined.contains("conflict") || combined.contains("merge conflict") || hasUnmergedPathsBlocking() {
                _ = try? Self.runGitBlocking(["rebase", "--abort"], at: vaultRoot!, timeout: 15)
                _ = try? Self.runGitBlocking(["merge", "--abort"], at: vaultRoot!, timeout: 15)
                status.conflictPaths = conflictCopyPaths()
                return GitError.conflict(
                    "Pull produced conflicts. Rebase aborted; your local commits are intact. Resolve in Settings → Sync."
                )
            }
        }
        // Include stdout: git writes most diagnostics ("Cannot rebase", "You have
        // unstaged changes") to stdout; stderr alone is often empty.
        lastGitErrorRaw = "pull: " + raw
        return GitError.commandFailed("pull", result.stderr.isEmpty ? result.stdout : result.stderr)
    }

    /// `git status --porcelain` lines with unmerged codes (DD/AU/UU/AA/DU/UA…).
    /// Blocking variant for use inside synchronous classification; on failure it
    /// conservatively reports unmerged paths.
    nonisolated private static func hasUnmergedPathsBlocking(at vaultRoot: URL) -> Bool {
        guard let res = try? GitSyncService.runGitBlocking(["status", "--porcelain"], at: vaultRoot, timeout: 15),
              res.ok else { return true }
        for line in res.stdout.split(separator: "\n") {
            guard line.count >= 2 else { continue }
            let xy = String(line.prefix(2))
            if xy.contains("U") || xy == "AA" || xy == "DD" { return true }
        }
        return false
    }

    private func hasUnmergedPathsBlocking() -> Bool {
        Self.hasUnmergedPathsBlocking(at: vaultRoot!)
    }

    func push(requireEnabled: Bool = true) async throws {
        guard !requireEnabled || settings.enabled else { return }
        let branch = safeBranchForArg()
        try await ensureHeadOnConfiguredBranch(at: vaultRoot!)
        SyncTrace.log("push pre: vault=\(vaultRoot?.path ?? "nil") branch=\(branch) "
            + "remote=\(cycleContext?.settings.remote ?? settings.remote) "
            + "head=\((try? await git(["rev-parse", "--short", "HEAD"]))?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? "?")")
        let preHead = (try? await git(["rev-parse", "HEAD"]))?
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let result = try await git(["push", "-u", "origin", branch])
        if result.ok { return }
        SyncTrace.log("push post: exit=\(result.exitCode) "
            + "remote=\(cycleContext?.settings.remote ?? settings.remote) "
            + "out=\(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)) "
            + "err=\(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))")

        var combined = (result.stdout + result.stderr).lowercased()
        // git kills the pack-sending side over the "push" transport with SIGPIPE
        // (exit 141) and prints nothing at all — the "died of signal 13" line only
        // reaches us via the parent's status line, which the "push" form does not
        // emit. Re-run once with an explicit refspec: the "git push <url> <src>"
        // form unpacks on the receiving side and survives.
        if result.exitCode == 141 || combined.contains("sigpipe") || combined.contains("signal 13") {
            let retry = try await git(["push", "origin", "refs/heads/\(branch):refs/heads/\(branch)"])
            if retry.ok { return }
            combined = (retry.stdout + retry.stderr).lowercased()
            if retry.exitCode == 141 || combined.contains("sigpipe") || combined.contains("signal 13") {
                lastGitErrorRaw = "push (sigpipe): " + (retry.stderr + " " + retry.stdout)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw GitError.commandFailed("push", retry.stderr.isEmpty ? retry.stdout : retry.stderr)
            }
        }
        // A killed or timed-out git produces no output at all; surface the
        // post-mortem trace instead of the empty "git push failed." string.
        if combined.isEmpty {
            let detail = SyncTrace.tail(24).joined(separator: "\n")
            lastGitErrorRaw = "push: empty output\n" + detail
            throw GitError.commandFailed("push",
                "git push exited with no output (possibly killed). Recent git activity:\n\(detail.suffix(600))")
        }
        // Non-fast-forward: the remote moved ahead of us. Reconcile with the
        // proven pull path (explicit refspec into the remote-tracking ref +
        // rebase; the bare "pull --rebase origin main" form fails outright on
        // remotes without a fetch refspec, e.g. plain file remotes), then retry
        // once. Never force-push.
        if combined.contains("non-fast-forward") || combined.contains("fetch first") || combined.contains("rejected") {
            do {
                try await pull(rebase: true, requireEnabled: false)
            } catch GitError.pullBlocked {
                throw GitError.pullBlocked(
                    "Push was rejected because the remote moved ahead, but the vault has\nuncommitted changes outside Nexus' control, so the rebase was skipped.\nYour vault is untouched — sync again once the vault is clean."
                )
            }
            var retry = try await git(["push", "-u", "origin", branch])
            var retryCombined = (retry.stdout + retry.stderr).lowercased()
            if retry.exitCode == 141 || retryCombined.contains("sigpipe") || retryCombined.contains("signal 13") {
                retry = try await git(["push", "origin", "refs/heads/\(branch):refs/heads/\(branch)"])
                retryCombined = (retry.stdout + retry.stderr).lowercased()
            }
            if retry.ok { return }
            if !retryCombined.contains("rejected") && !retryCombined.contains("non-fast-forward") {
                lastGitErrorRaw = "push (retry): " + (retry.stderr + " " + retry.stdout)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw GitError.commandFailed("push", retry.stderr.isEmpty ? retry.stdout : retry.stderr)
            }
            // Still rejected. If the rebase actually consumed the remote commits
            // (HEAD moved and now contains origin/<branch>), the remote itself is
            // refusing the update — surface that instead of a raw git error.
            let headRes = try? await git(["rev-parse", "HEAD"])
            let postHead = headRes?.stdout
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let ancestorRes = try? await git(["merge-base", "--is-ancestor", "origin/\(branch)", "HEAD"])
            let absorbed = !postHead.isEmpty && postHead != preHead && ancestorRes?.ok == true
            if absorbed {
                lastGitErrorRaw = "push: rebase succeeded but the remote still rejected the push: "
                    + (retry.stderr + " " + retry.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
                throw GitError.pullBlocked(
                    "Your changes were merged with the remote, but the remote still refused the push.\nThe remote may be read-only or protected — check its URL and permissions in Settings → Sync."
                )
            }
            _ = try? await git(["rebase", "--abort"])
            status.conflictPaths = conflictCopyPaths()
            if combined.contains("conflict") {
                throw GitError.conflict(
                    "Push was rejected and rebase conflicts. Rebase aborted; your local commits are intact."
                )
            }
            lastGitErrorRaw = "push: " + (result.stderr + " " + result.stdout)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw GitError.commandFailed("push", result.stderr.isEmpty ? result.stdout : result.stderr)
        }
        lastGitErrorRaw = "push: " + (result.stderr + " " + result.stdout)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        throw GitError.commandFailed("push", result.stderr.isEmpty ? result.stdout : result.stderr)
    }

    // MARK: - Counts / conflicts

    /// Ahead/behind/dirty counts. Fetches first so `origin/<branch>` is current —
    /// otherwise counts stay stale right after a successful push/pull.
    func refreshCounts(at vaultRoot: URL) async {
        guard let branch = try? await currentBranch() else { return }
        // Cheap update of remote refs (best effort; ignore failures).
        _ = try? await git(["fetch", "--quiet", "origin", branch])
        let ahead = try? await git(["rev-list", "--count", "origin/\(branch)..HEAD"])
        let behind = try? await git(["rev-list", "--count", "HEAD..origin/\(branch)"])
        let statusRes = try? await git(["status", "--porcelain"])
        if let ahead, ahead.ok { self.status.aheadCount = Int(ahead.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0 }
        if let behind, behind.ok { self.status.behindCount = Int(behind.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0 }
        if let statusRes, statusRes.ok {
            self.status.dirtyCount = statusRes.stdout.split(separator: "\n").filter { !$0.isEmpty }.count
        }
    }

    private func currentBranch() async throws -> String {
        let result = try await git(["rev-parse", "--abbrev-ref", "HEAD"])
        guard result.ok else { return safeBranchForArg() }
        let name = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty || name == "HEAD" ? safeBranchForArg() : name
    }

    /// Notes that look like git/merge conflict copies left in the vault.
    func conflictCopyPaths() -> [String] {
        guard let vaultRoot else { return [] }
        let keys: [URLResourceKey] = [.isRegularFileKey]
        var results: [String] = []
        func walk(_ dir: URL, prefix: String) {
            guard let kids = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: keys, options: [.skipsPackageDescendants]
            ) else { return }
            for child in kids {
                let name = child.lastPathComponent
                if name == ".git" || name == ".nexus" || name.hasPrefix(".") { continue }
                let values = try? child.resourceValues(forKeys: Set(keys))
                if values?.isDirectory == true {
                    walk(child, prefix: prefix.isEmpty ? name : prefix + "/" + name)
                } else if Self.isConflictFileName(name) {
                    results.append(prefix.isEmpty ? name : prefix + "/" + name)
                }
            }
        }
        walk(vaultRoot, prefix: "")
        return results.sorted()
    }

    /// Strict conflict-copy detection: only real git/iCloud conflict names.
    nonisolated static func isConflictFileName(_ name: String) -> Bool {
        let lower = name.lowercased()
        if lower.contains("conflicted copy") { return true }
        if lower.hasSuffix(" (conflict).md") || lower.contains("(conflict") { return true }
        if lower.hasSuffix(" copy.md") || lower.hasSuffix(" copy 2.md") { return true }
        return false
    }

    // MARK: - Safety helpers

    private func isSafeVaultRoot(_ url: URL) -> Bool {
        let path = url.path
        guard path.hasPrefix("/"), path.count > 1 else { return false }
        let forbidden = ["/", "/Users", "/System", "/Library", "/Applications", "/usr", "/etc", "/var", "/private"]
        if forbidden.contains(path) { return false }
        if url.lastPathComponent == ".nexus" || url.lastPathComponent.hasPrefix(".") { return false }
        return true
    }

    private func writeSafetyGitignore(at vaultRoot: URL) throws {
        let url = vaultRoot.appendingPathComponent(".gitignore")
        let content = """
        # Nexus vault safety ignore (added when cloud sync was enabled)
        .nexus/
        .DS_Store
        .obsidian/
        .trash/
        *.icloud
        .Spotlight-V100
        .Trashes
        """
        if let existing = try? String(contentsOf: url, encoding: .utf8) {
            // Append only if our marker is absent; never overwrite a user's file.
            if !existing.contains("Nexus vault safety ignore") {
                try? (existing + "\n" + content + "\n").write(to: url, atomically: true, encoding: .utf8)
            }
        } else {
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Merge / conflict resolution (explicit user choice only)

    enum ConflictSide: String {
        case ours = "local"
        case theirs = "remote"
    }

    /// Resolve a conflicted file by choosing a side.
    /// - Note: `path` is vault-relative; resolution uses `git checkout --ours/--theirs`
    ///   with `--` so the path is never interpreted as a revision spec.
    func resolveConflict(path: String, side: ConflictSide) async throws {
        guard let vaultRoot else { throw GitError.noVault }
        let normalized = GitSyncService.normalizeVaultRelative(path)
        guard !normalized.isEmpty else { throw GitError.invalidArgument }

        // During a conflicted merge/rebase, `--ours`/`--theirs` exist. Outside of one
        // they do not — fall back to leaving the file alone.
        let sideFlag = side == .ours ? "--ours" : "--theirs"
        let checkout = try await git(["checkout", sideFlag, "--", normalized])
        if !checkout.ok {
            // Nothing mid-merge: treat as "already resolved" if the file is not unmerged.
            let unmerged = try await git(["diff", "--name-only", "--diff-filter=U"])
            if unmerged.ok, unmerged.stdout.split(separator: "\n").contains(Substring(normalized)) {
                throw GitError.commandFailed("checkout", checkout.stderr)
            }
        }
        _ = try await git(["add", "--", normalized])

        // Conflict *copies* (git/iCloud variants with both sides on disk): if the user
        // chose the canonical side, drop the copy so it stops shadowing the real note.
        if Self.isConflictFileName((normalized as NSString).lastPathComponent) {
            let conflictURL = vaultRoot.appendingPathComponent(normalized)
            try? fm.removeItem(at: conflictURL)
            _ = try? await git(["add", "-A"])
        }

        let commit = try await git(["commit", "-m", "nexus: resolve conflict (\(side.rawValue)) \(Self.stamp())"])
        if !commit.ok, !commit.stdout.contains("nothing to commit"), !commit.stderr.contains("nothing to commit") {
            // Mid-rebase the correct move is `rebase --continue`; if that fails, abort safely.
            let continued = try await git(["-c", "core.editor=true", "rebase", "--continue"])
            if !continued.ok {
                let combined = (continued.stdout + continued.stderr).lowercased()
                if combined.contains("no rebase in progress") || combined.contains("nothing to commit") {
                    // already clean
                } else {
                    _ = try? await git(["rebase", "--abort"])
                    throw GitError.conflict("Could not continue the rebase; aborted safely so nothing is lost.")
                }
            }
        }
        await refreshCounts(at: vaultRoot)
        status.conflictPaths = conflictCopyPaths()
    }

    /// Normalize a user-supplied relative path to a safe vault-relative form.
    nonisolated static func normalizeVaultRelative(_ path: String) -> String {
        var p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if p.hasPrefix("./") { p.removeFirst(2) }
        while p.hasPrefix("/") { p.removeFirst() }
        let parts = p.split(separator: "/", omittingEmptySubsequences: true)
        let safe = parts.filter { $0 != "." && $0 != ".." }
        return safe.joined(separator: "/")
    }

    // MARK: - Status text

    var statusSummary: String {
        switch status.phase {
        case .off: return "Sync off"
        case .idle:
            if let last = status.lastSyncAt {
                return "Synced \(Self.relative(last))"
            }
            return "Idle"
        case .scanning: return "Scanning…"
        case .committing: return "Committing…"
        case .pushing: return "Pushing…"
        case .pulling: return "Pulling…"
        case .syncing: return status.lastAction
        case .error: return "Error: \(status.lastError ?? "unknown")"
        }
    }

    nonisolated static func stamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: Date())
    }

    nonisolated static func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "en_US")
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }

    // MARK: - Errors

    enum GitError: LocalizedError {
        case noVault
        case invalidRemote
        case invalidArgument
        case launchFailed(String)
        case commandFailed(String, String)
        case conflict(String)
        case authFailed
        case unreachable
        case pullBlocked(String)

        var errorDescription: String? {
            switch self {
            case .noVault: return "No vault is open."
            case .invalidRemote: return "Remote is not a valid git URL or absolute path."
            case .invalidArgument: return "git argument rejected (control characters)."
            case .launchFailed(let s): return "Could not launch git: \(s)"
            case .commandFailed(let cmd, let err):
                let trimmed = err.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? "git \(cmd) failed." : "git \(cmd): \(trimmed)"
            case .conflict(let s): return s
            case .authFailed:
                return "Authentication failed. Check the token in Settings → Sync (or ssh-agent for ssh:// remotes)."
            case .unreachable:
                return "Remote is unreachable. Check the network, the remote URL, or whether the server is running."
            case .pullBlocked(let s): return s
            }
        }
    }
}
