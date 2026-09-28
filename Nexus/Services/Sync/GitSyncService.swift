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
    private let defaultsKey = "nexus.sync.v1"
    private let keychainService = "com.ghost64.nexus.sync"

    private var cycleTask: Task<Void, Never>?
    private var commitTask: Task<Void, Never>?
    /// Vault mutation events awaiting the next debounced autocommit.
    private var pendingChanges = false
    private var cancellables = Set<AnyCancellable>()
    /// Re-entrancy guard for the whole cycle (init/enable/merge).
    private var cycleLock = false
    /// Set while *we* write to the vault so the FSEvents watcher does not
    /// interpret a pull as a user edit storm (we still want it to reindex).
    private var applyingRemote = false

    private init() {
        loadSettings()
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
        cycleTask?.cancel()
        cycleTask = nil
        commitTask?.cancel()
        commitTask = nil
        cancellables.removeAll()
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
        settings = normalized
        persistSettings()
        settingsRevision += 1
        status.conflictPaths = conflictCopyPaths()
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
        Task { [weak self] in
            guard let self else { return }
            do {
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
                newSettings.keychainAccount = account.isEmpty ? newSettings.keychainAccount : account
                self.saveSettings(newSettings)
                self.status.lastError = nil
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
        cycleTask?.cancel()
        cycleTask = nil
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
            _ = try? await self.commitLocalChanges(message: "nexus: sync \(Self.stamp())")
        }
    }

    /// Weak reference wired by AppState so we can observe vault mutations.
    weak var vaultServiceForObservation: VaultService?

    // MARK: - Core cycle

    func initializeAndSync() async {
        guard !cycleLock, let vaultRoot else { return }
        cycleLock = true
        defer { cycleLock = false }
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
                try writeSafetyGitignore(at: vaultRoot)
            }
            await ensureLocalIdentity(at: vaultRoot)
            try await ensureRemoteConfigured(at: vaultRoot)
            // If the remote already has commits (shared repo from another machine),
            // pull them before the first commit to avoid unrelated-histories pain.
            let hasRemoteCommits = await remoteHasCommits()
            if hasRemoteCommits {
                status.lastAction = "Pulling initial history…"
                try await pull(rebase: true)
            }
            status.lastAction = "Committing current vault…"
            try await commitLocalChanges(message: "nexus: enable sync \(Self.stamp())")
            status.lastAction = "Pushing…"
            try await push()
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
        }
    }

    /// Run one full sync cycle (autocommit → pull --rebase → push). Safe to call manually.
    func syncNow() async {
        guard settings.enabled, !status.isBusy, let vaultRoot else { return }
        guard !cycleLock else { return }
        cycleLock = true
        defer { cycleLock = false }
        do {
            await ensureLocalIdentity(at: vaultRoot)
            try await ensureRemoteConfigured(at: vaultRoot)
            status.phase = .scanning
            let dirty = try await commitLocalChanges(message: "nexus: sync \(Self.stamp())")
            status.phase = .pulling
            status.lastAction = dirty ? "Pushing local changes…" : "Pulling…"
            try await pull(rebase: true)
            status.phase = .pushing
            try await push()
            status.phase = .idle
            status.lastSyncAt = Date()
            status.lastAction = "Synced \(Self.stamp())"
            status.lastError = nil
            pendingChanges = false
            refreshCounts(at: vaultRoot)
            status.conflictPaths = conflictCopyPaths()
        } catch {
            status.phase = .error
            status.lastError = error.localizedDescription
        }
    }

    private func startCycleTimer() {
        cycleTask?.cancel()
        let interval = UInt64(settings.intervalSeconds) * 1_000_000_000
        cycleTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                guard !Task.isCancelled else { break }
                await self?.syncNow()
            }
        }
    }

    // MARK: - Git plumbing (all via /usr/bin/git argument arrays — never a shell)

    nonisolated private static let gitPath = "/usr/bin/git"

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
                    guard !Task.isCancelled, let process, process.isRunning else { return }
                    process.terminationHandler = nil
                    process.interrupt()
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
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

                process.terminationHandler = { proc in
                    outData.finish()
                    errData.finish()
                    timeoutTask.cancel()
                    let result = GitResult(
                        exitCode: proc.terminationStatus,
                        stdout: outData.snapshot(),
                        stderr: errData.snapshot()
                    )
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
        guard let vaultRoot else { throw GitError.noVault }
        var args: [String] = []
        // Local-path remotes are explicit user choice (shared volume / another Mac).
        // file:// protocol stays disabled unless the configured remote parses as
        // a safe local path; safe.directory covers externally-owned repos.
        var fileAllow = "false"
        if case .localPath(let path)? = GitRemote.parse(settings.remote) {
            fileAllow = "always"
            args += ["-c", "safe.directory=\(path)", "-c", "safe.directory=\(vaultRoot.path)"]
        }
        args += ["-c", "protocol.file.allow=\(fileAllow)"] + arguments
        let remote = GitRemote.parse(settings.remote)
        return try await withAskpassInstalled(using: remote) {
            try await self.runGit(args, at: vaultRoot, timeout: Self.gitTimeout(for: arguments))
        }
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

    private func safeBranch() -> String {
        let b = settings.branch.trimmingCharacters(in: .whitespacesAndNewlines)
        return b.isEmpty ? "main" : b
    }

    private func safeBranchForArg() -> String {
        // Branch names: letters, digits, dot, dash, underscore, slash.
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        let scalars = settings.branch.unicodeScalars.map { scalar -> String in
            allowed.contains(scalar) || scalar == "/" ? String(scalar) : ""
        }
        let cleaned = String(scalars.joined()).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return cleaned.isEmpty ? "main" : cleaned
    }

    private func ensureLocalIdentity(at vaultRoot: URL) async {
        let name = settings.authorName.trimmingCharacters(in: .whitespacesAndNewlines)
        let email = settings.authorEmail.trimmingCharacters(in: .whitespacesAndNewlines)
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
    @discardableResult
    func commitLocalChanges(message: String) async throws -> Bool {
        guard settings.enabled, let vaultRoot else { throw GitError.noVault }
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
        let commit = try await git(["commit", "-m", message])
        if !commit.ok {
            // "nothing to commit" races are fine; anything else is a real failure.
            if commit.stdout.contains("nothing to commit") || commit.stderr.contains("nothing to commit") {
                return false
            }
            // Author identity may be missing — set a neutral fallback locally.
            if commit.stderr.localizedCaseInsensitiveContains("Please tell me who you are")
                || commit.stderr.localizedCaseInsensitiveContains("author identity") {
                _ = try? await git(["config", "user.name", "Nexus"])
                _ = try? await git(["config", "user.email", "nexus@localhost"])
                let retry = try await git(["commit", "-m", message])
                if !retry.ok {
                    throw GitError.commandFailed("commit", retry.stderr)
                }
                refreshCounts(at: vaultRoot)
                return true
            }
            throw GitError.commandFailed("commit", commit.stderr)
        }
        refreshCounts(at: vaultRoot)
        return true
    }

    func pull(rebase: Bool) async throws {
        guard settings.enabled else { return }
        let branch = safeBranchForArg()
        var args = ["pull"]
        if rebase { args.append("--rebase") }
        args.append(contentsOf: ["origin", branch])
        let result = try await git(args)
        if result.ok { return }

        let combined = (result.stdout + result.stderr).lowercased()
        // The remote branch may not exist yet (first-ever push) — nothing to pull.
        if combined.contains("couldn't find remote ref") || combined.contains("no such ref") {
            return
        }
        // Conflicted rebase: abort so we never leave the repo mid-rebase, and
        // surface the conflict to the user instead of guessing a side.
        if combined.contains("conflict") || combined.contains("merge conflict") || hasUnmergedPaths() {
            _ = try? await git(["rebase", "--abort"])
            _ = try? await git(["merge", "--abort"])
            status.conflictPaths = conflictCopyPaths()
            throw GitError.conflict(
                "Pull produced conflicts. Rebase aborted; your local commits are intact. Resolve in Settings → Sync."
            )
        }
        throw GitError.commandFailed("pull", result.stderr)
    }

    /// `git status --porcelain` lines with unmerged codes (DD/AU/UU/AA/DU/UA…).
    private func hasUnmergedPaths() -> Bool {
        guard let res = try? gitSyncStatusPorcelain(), res.ok else { return false }
        for line in res.stdout.split(separator: "\n") {
            guard line.count >= 2 else { continue }
            let xy = String(line.prefix(2))
            if xy.contains("U") || xy == "AA" || xy == "DD" { return true }
        }
        return false
    }

    /// Non-async status probe kept separate so callers stay simple.
    private func gitSyncStatusPorcelain() throws -> GitResult {
        // Called from pull() already on MainActor; run synchronously via runGitSync.
        try GitSyncService.runGitBlocking(["status", "--porcelain"], at: vaultRoot!, timeout: 15)
    }

    func push() async throws {
        guard settings.enabled else { return }
        let branch = safeBranchForArg()
        let result = try await git(["push", "-u", "origin", branch])
        if result.ok { return }

        let combined = (result.stdout + result.stderr).lowercased()
        // Non-fast-forward: try one rebase-then-retry. Never force-push.
        if combined.contains("non-fast-forward") || combined.contains("fetch first") || combined.contains("rejected") {
            let rebase = try await git(["pull", "--rebase", "origin", branch])
            if rebase.ok {
                let retry = try await git(["push", "-u", "origin", branch])
                if retry.ok { return }
                throw GitError.commandFailed("push", retry.stderr)
            }
            _ = try? await git(["rebase", "--abort"])
            status.conflictPaths = conflictCopyPaths()
            if (rebase.stdout + rebase.stderr).lowercased().contains("conflict") {
                throw GitError.conflict(
                    "Push was rejected and rebase conflicts. Rebase aborted; your local commits are intact."
                )
            }
            throw GitError.commandFailed("push", rebase.stderr)
        }
        throw GitError.commandFailed("push", result.stderr)
    }

    // MARK: - Counts / conflicts

    func refreshCounts(at vaultRoot: URL) {
        Task {
            guard let branch = try? await currentBranch() else { return }
            let ahead = try? await git(["rev-list", "--count", "origin/\(branch)..HEAD"])
            let behind = try? await git(["rev-list", "--count", "HEAD..origin/\(branch)"])
            let statusRes = try? await git(["status", "--porcelain"])
            await MainActor.run {
                if let ahead, ahead.ok { self.status.aheadCount = Int(ahead.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0 }
                if let behind, behind.ok { self.status.behindCount = Int(behind.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0 }
                if let statusRes, statusRes.ok {
                    self.status.dirtyCount = statusRes.stdout.split(separator: "\n").filter { !$0.isEmpty }.count
                }
            }
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
        refreshCounts(at: vaultRoot)
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
            }
        }
    }
}
