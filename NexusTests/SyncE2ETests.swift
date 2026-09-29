import XCTest
@testable import Nexus

/// Git-based cloud sync tests.
///
/// The vault-filesystem half uses real temp vaults and the process's real git
/// binary; the git *remote* is a local bare repo under the sandbox. Network
/// credentials are never contacted by these tests.
@MainActor
final class SyncE2ETests: XCTestCase {
    private var vault: URL!
    private var remote: URL!

    private var syncService: GitSyncService!

    override func setUpWithError() throws {
        vault = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nexus-sync-vault-\(UUID().uuidString.prefix(8))", isDirectory: true)
        remote = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nexus-sync-remote-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        try "seed".write(to: vault.appendingPathComponent("Welcome.md"), atomically: true, encoding: .utf8)
        // A dedicated instance per test: the engine is a long-lived singleton,
        // and a cycle from the previous test must never touch this test's vault.
        syncService = GitSyncService.forTesting()
    }

    override func tearDown() async throws {
        // Let this test's own cycles finish before tearing the instance down.
        await syncService.waitForSettledForTesting(timeout: 30)
        syncService.detach()
        syncService.resetPersistedSettingsForTesting()
        syncService = nil
        GitSyncService.shared.detach()
        GitSyncService.shared.resetPersistedSettingsForTesting()
        try? FileManager.default.removeItem(at: vault)
        try? FileManager.default.removeItem(at: remote)
    }

    // MARK: - GitRemote parsing / validation

    func testGitRemoteAcceptsValidTargets() {
        XCTAssertNotNil(GitRemote.parse("https://github.com/user/repo.git"))
        XCTAssertNotNil(GitRemote.parse("ssh://git@github.com/user/repo.git"))
        XCTAssertNotNil(GitRemote.parse("git@github.com:user/repo.git"))
        XCTAssertNotNil(GitRemote.parse("/Users/ghost32/vault-remotes/e2e-sync.git"))
        XCTAssertNotNil(GitRemote.parse("git+ssh://git@host/path/repo.git"))
    }

    func testGitRemoteRejectsFileAndUnknownSchemes() {
        // file:// only resolves to a *local path* when the host is empty/localhost.
        if let parsed = GitRemote.parse("file:///tmp/vault.git") {
            if case .localPath(let p) = parsed {
                XCTAssertEqual(p, "/tmp/vault.git")
            } else {
                XCTFail("file:// must normalize to localPath or nil")
            }
        }
        XCTAssertNil(GitRemote.parse("file://evil.example.com/repo.git"))
        XCTAssertNil(GitRemote.parse("ext::sh -c 'id'"))
        XCTAssertNil(GitRemote.parse("ftp://host/repo"))
        XCTAssertNil(GitRemote.parse(""))
        XCTAssertNil(GitRemote.parse("   "))
        XCTAssertNil(GitRemote.parse("relative/path/repo.git"))
    }

    func testGitRemoteRejectsCredentialsInNetworkURLs() {
        // Credentials in remote URLs would land in cleartext inside .git/config.
        XCTAssertNil(GitRemote.parse("https://user:pass@github.com/user/repo.git"))
        XCTAssertNil(GitRemote.parse("ssh://user:pass@github.com/user/repo.git"))
        // Plain ssh user (git@host) is fine.
        XCTAssertNotNil(GitRemote.parse("ssh://git@github.com/user/repo.git"))
    }

    func testGitRemoteRejectsTraversalAndControlChars() {
        XCTAssertNil(GitRemote.parse("/Users/ghost64\n--upload-pack=evil"))
        XCTAssertNil(GitRemote.parse("https://example.com/a\u{0000}b"))
        XCTAssertNil(GitRemote.parse("/Users/ghost64/\u{0007}.git"))
    }

    func testGitRemoteLocalPathNormalizes() {
        XCTAssertEqual(GitRemote.parse("/tmp/vault.git"), .localPath("/tmp/vault.git"))
        XCTAssertNil(GitRemote.parse("~/vault.git"))
    }

    // MARK: - Conflict-file detection

    func testConflictFileNameDetection() {
        // Only genuine git/iCloud conflict variants — never "Note 2.md" style renames.
        XCTAssertTrue(GitSyncService.isConflictFileName("Welcome (conflict ghost32 2026-09-28).md"))
        XCTAssertTrue(GitSyncService.isConflictFileName("Note (conflicted copy 2026-09-28).md"))
        XCTAssertFalse(GitSyncService.isConflictFileName("Welcome 2.md"))
        XCTAssertFalse(GitSyncService.isConflictFileName("My Note.md"))
        XCTAssertFalse(GitSyncService.isConflictFileName("Notes 2026.md"))
    }

    func testPickRemoteBranchPrefersPreferredThenFirst() {
        let ls = "abc123\trefs/heads/main\ndef456\trefs/heads/dev\n"
        XCTAssertEqual(GitSyncService.pickRemoteBranch(from: ls, preferred: "dev"), "dev")
        XCTAssertEqual(GitSyncService.pickRemoteBranch(from: ls, preferred: "trunk"), "main")
        XCTAssertNil(GitSyncService.pickRemoteBranch(from: "", preferred: "main"))
    }

    func testNormalizeVaultRelative() {
        XCTAssertEqual(GitSyncService.normalizeVaultRelative("./a/b.md"), "a/b.md")
        XCTAssertEqual(GitSyncService.normalizeVaultRelative("/a/b.md"), "a/b.md")
        XCTAssertEqual(GitSyncService.normalizeVaultRelative("a/../b.md"), "a/b.md")
        XCTAssertEqual(GitSyncService.normalizeVaultRelative(""), "")
    }

    // MARK: - Sync service integration (temp vault + real git, local bare remote)

    @MainActor
    func testEnableAndFirstSyncCommitAgainstLocalBareRemote() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/git") else {
            throw XCTSkip("git CLI not installed on this runner")
        }
        // The remote is a bare repo created up front (production reality); a
        // plain empty directory is not a valid git remote and must be rejected
        // by enableSync's preconditions instead.
        let r = try makeBareRemote()

        let sync = syncService!
        sync.resetPersistedSettingsForTesting()
        sync.vaultServiceForObservation = nil // no vault observer for this test
        sync.attach(vaultRoot: vault)

        var settings = sync.settings
        settings.branch = "main"
        settings.authorName = "Sync Tests"
        settings.authorEmail = "tests@example.invalid"
        settings.keychainAccount = "" // no credentials in tests
        sync.saveSettings(settings)

        sync.enableSync(remoteRaw: r.path)
        await sync.waitForEnableTaskForTesting()

        XCTAssertFalse(sync.status.isBusy, "enableSync never settled")
        XCTAssertNil(sync.status.lastError, "unexpected error: \(sync.status.lastError ?? "none")")
        XCTAssertEqual(sync.status.phase, .idle)
        XCTAssertTrue(sync.settings.enabled)
        XCTAssertEqual(sync.settings.remote, r.path)

        // The vault became a git repo with a safety .gitignore.
        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: vault.appendingPathComponent(".git").path))
        let gitignore = try String(contentsOf: vault.appendingPathComponent(".gitignore"), encoding: .utf8)
        XCTAssertTrue(gitignore.contains(".nexus/"))

        // The remote received the seed commit.
        let heads = runGitSync(["ls-remote", "--heads", r.path], at: vault)
        XCTAssertTrue(heads.stdout.contains("refs/heads/main"))

        // A plain directory is not a git remote: enableSync must refuse it and
        // must never git-init the user's folder.
        let notARemote = FileManager.default.temporaryDirectory
            .appendingPathComponent("nexus-sync-notarepo-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: notARemote, withIntermediateDirectories: true)
        sync.resetPersistedSettingsForTesting()
        sync.attach(vaultRoot: vault)
        sync.enableSync(remoteRaw: notARemote.path)
        await sync.waitForEnableTaskForTesting()
        XCTAssertNotNil(sync.status.lastError, "a plain directory must be rejected as a remote")
        XCTAssertFalse(sync.settings.enabled)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: notARemote.appendingPathComponent("objects").path),
            "Nexus must never git-init the remote path itself")
        try? FileManager.default.removeItem(at: notARemote)
    }

    @MainActor
    func testAutocommitAfterNoteMutation() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/git") else {
            throw XCTSkip("git CLI not installed on this runner")
        }
        let r = try makeBareRemote()

        let sync = syncService!
        sync.resetPersistedSettingsForTesting()
        var settings = sync.settings
        settings.branch = "main"
        settings.authorName = "Sync Tests"
        settings.authorEmail = "tests@example.invalid"
        settings.debounceSeconds = SyncSettings.debounceRange.lowerBound // we trigger manually
        settings.keychainAccount = ""
        sync.saveSettings(settings)
        sync.attach(vaultRoot: vault)
        sync.enableSync(remoteRaw: r.path)
        await sync.waitForEnableTaskForTesting()
        await sync.waitForSettledForTesting()

        // Simulate a vault mutation and force a cycle.
        try "changed".write(to: vault.appendingPathComponent("Welcome.md"), atomically: true, encoding: .utf8)
        sync.noteDidChange(path: "Welcome.md")
        await sync.syncNow()
        await sync.waitForSettledForTesting()
        // The mutation must reach the remote; poll instead of sleeping so slow
        // CI never sees a false failure (the push lands after syncNow returns).
        let remoteTree: GitOut = {
            var last = runGitSync(["show", "main:Welcome.md"], at: r)
            let deadline = Date().addingTimeInterval(30)
            while last.code != 0 && Date() < deadline {
                Thread.sleep(forTimeInterval: 1)
                last = runGitSync(["show", "main:Welcome.md"], at: r)
            }
            return last
        }()

        let err = sync.status.lastError ?? ""
        XCTAssert(err.isEmpty || !err.contains("Please tell me who you are"),
                  "commit must not fail on missing identity: \(err)")
        // The mutation must reach the remote as a tree change. Assert on the
        // remote tree contents (robust), not on our internal commit-message prefix.
        XCTAssertEqual(remoteTree.code, 0, "no Welcome.md on remote main: \(remoteTree.stderr.prefix(160))")
        XCTAssertTrue(remoteTree.stdout.contains("changed"),
                      "expected mutation to reach the remote; got: \(remoteTree.stdout.prefix(120))")
    }

    @MainActor
    func testWorkspaceSidecarExcludedAndUnmergedPathsDetected() throws {
        let sync = syncService!
        sync.resetPersistedSettingsForTesting()
        sync.attach(vaultRoot: vault)
        // Write a conflict copy; conflictCopyPaths must find it but never treat
        // ordinary numbered renames as conflicts.
        try "x".write(to: vault.appendingPathComponent("Welcome (conflict ghost32 2026-09-28).md"), atomically: true, encoding: .utf8)
        try "y".write(to: vault.appendingPathComponent("Welcome 2.md"), atomically: true, encoding: .utf8)
        let conflicts = sync.conflictCopyPaths()
        XCTAssertEqual(conflicts, ["Welcome (conflict ghost32 2026-09-28).md"])
    }

    @MainActor
    func testSidecarsStayUntrackedAfterEnableAndMutation() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/git") else {
            throw XCTSkip("git CLI not installed on this runner")
        }
        // A vault that is ALREADY a git repo (sync enabled onto a pre-existing
        // repo): the machine-local sidecars must never become tracked.
        let initProc = Process()
        initProc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        initProc.arguments = ["init", "-b", "main", vault.path]
        initProc.environment = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin"]
        try initProc.run(); initProc.waitUntilExit()
        try "seed".write(to: vault.appendingPathComponent("Seed.md"), atomically: true, encoding: .utf8)
        _ = runGitSync(["add", "-A"], at: vault)
        _ = runGitSync(["-c", "user.name=T", "-c", "user.email=t@e.invalid", "commit", "-m", "seed"], at: vault)

        let remote = try makeBareRemote()

        let sync = syncService!
        sync.resetPersistedSettingsForTesting()
        var settings = sync.settings
        settings.branch = "main"
        settings.authorName = "Sync Tests"
        settings.authorEmail = "tests@example.invalid"
        settings.keychainAccount = ""
        sync.saveSettings(settings)
        sync.attach(vaultRoot: vault)
        sync.enableSync(remoteRaw: remote.path)
        await sync.waitForEnableTaskForTesting()

        await sync.waitForSettledForTesting()

        // Sidecars must never be tracked. After enable, .gitignore exists and
        // `git add -A` (what every cycle runs) must leave the sidecars out.
        let ignored = runGitSync(["check-ignore", "-q", ".nexus/sync.json"], at: vault)
        XCTAssertEqual(ignored.code, 0, ".gitignore must cover .nexus/")
        try FileManager.default.createDirectory(
            at: vault.appendingPathComponent(".nexus"), withIntermediateDirectories: true)
        try "{\"enabled\":true}".write(
            to: vault.appendingPathComponent(".nexus/sync.json"), atomically: true, encoding: .utf8)
        _ = runGitSync(["add", "-A"], at: vault)
        let staged = runGitSync(["diff", "--cached", "--name-only"], at: vault)
        XCTAssertFalse(staged.stdout.contains(".nexus/"),
                       "add -A staged sidecars: \(staged.stdout)")
        let tracked = runGitSync(["ls-files"], at: vault)
        XCTAssertFalse(tracked.stdout.contains(".nexus/"),
                       "sidecar tracked by git: \(tracked.stdout)")
    }

    func testPullBlockedKeepsPendingAndLocalCommit() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/git") else {
            throw XCTSkip("git CLI not installed on this runner")
        }
        let remote = try makeBareRemote()

        let sync = syncService!
        sync.resetPersistedSettingsForTesting()
        var settings = sync.settings
        settings.branch = "main"
        settings.authorName = "Sync Tests"
        settings.authorEmail = "tests@example.invalid"
        settings.keychainAccount = ""
        sync.saveSettings(settings)
        sync.attach(vaultRoot: vault)
        sync.enableSync(remoteRaw: remote.path)
        await sync.waitForEnableTaskForTesting()
        await sync.waitForSettledForTesting()
        XCTAssertEqual(sync.status.phase, .idle,
                       "enable must settle before mutation test: \(sync.status.lastError ?? "nil")")

        // A user edits a file behind Nexus' back *during* the enable window.
        // Nexus must commit it, and if a later pull would be blocked, the local
        // commit must survive and the remote must still receive history.
        try "# user edit\n".write(to: vault.appendingPathComponent("User.md"), atomically: true, encoding: .utf8)
        sync.noteDidChange(path: "User.md")
        await sync.syncNow()
        await sync.waitForSettledForTesting()

        let log = runGitSync(["log", "--oneline", "--all"], at: vault)
        XCTAssertTrue(log.stdout.contains("nexus: sync"), "user edit must be committed: \(log.stdout)")
        let remoteLog = runGitSync(["log", "--oneline", "--all"], at: remote)
        XCTAssertTrue(remoteLog.stdout.contains("nexus: sync"),
                      "history must reach the remote: \(remoteLog.stdout)")
        // The committed user file must be present in the pushed tree.
        let tree = runGitSync(["show", "main:User.md"], at: remote)
        XCTAssertEqual(tree.code, 0, "User.md missing from remote tree: \(tree.stderr.prefix(200))")
    }

    @MainActor
    func testInvalidRemoteDoesNotHalfEnable() async throws {
        let sync = syncService!
        sync.resetPersistedSettingsForTesting()
        var settings = sync.settings
        settings.keychainAccount = ""
        settings.enabled = false
        sync.saveSettings(settings)
        sync.attach(vaultRoot: vault)

        sync.enableSync(remoteRaw: "ext::sh -c 'id'")
        await sync.waitForEnableTaskForTesting()

        await sync.waitForSettledForTesting()
        XCTAssertFalse(sync.settings.enabled, "invalid remote must never flip enabled")
        XCTAssertEqual(sync.status.phase, .error)
        XCTAssertNotNil(sync.status.lastError)
    }

    /// Create a unique bare repo (git CLI) and return its path.
    private func makeBareRemote() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nexus-sync-remote-\(UUID().uuidString)")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["init", "--bare", "-b", "main", dir.path]
        p.environment = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin"]
        try p.run(); p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, "bare init failed")
        return dir
    }

    func testEnableAgainstRemoteWithExistingHistory() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/git") else { throw XCTSkip("no git") }
        let r = try makeBareRemote()
        // Seed the remote with an unrelated history, as another machine would.
        let seed = FileManager.default.temporaryDirectory
            .appendingPathComponent("nexus-seed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: seed, withIntermediateDirectories: true)
        try "remote".write(to: seed.appendingPathComponent("Remote.md"), atomically: true, encoding: .utf8)
        for args in [["init", "-b", "main"], ["config", "user.email", "s@e.invalid"], ["config", "user.name", "Seed"], ["add", "-A"], ["commit", "-m", "remote seed"], ["push", r.path, "main"]] {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/git"); p.arguments = args
            p.currentDirectoryURL = seed
            p.environment = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM": "1"]
            let pipe = Pipe(); p.standardError = pipe
            try p.run(); p.waitUntilExit()
            if p.terminationStatus != 0 {
                let d = pipe.fileHandleForReading.readDataToEndOfFile()
                XCTFail("seed step \(args) failed: \(String(data: d, encoding: .utf8) ?? "?")")
                return
            }
        }
        try? FileManager.default.removeItem(at: seed)

        let sync = syncService!
        sync.resetPersistedSettingsForTesting()
        sync.vaultServiceForObservation = nil
        sync.attach(vaultRoot: vault)
        var settings = sync.settings
        settings.branch = "main"
        settings.authorName = "Sync Tests"
        settings.authorEmail = "tests@example.invalid"
        settings.keychainAccount = ""
        sync.saveSettings(settings)

        sync.enableSync(remoteRaw: r.path)
        await sync.waitForEnableTaskForTesting()
        await sync.waitForSettledForTesting()

        XCTAssertNil(sync.status.lastError, "unexpected error: \(sync.status.lastError ?? "")")
        XCTAssertEqual(sync.status.phase, .idle)
        XCTAssertTrue(sync.settings.enabled)
        // Remote history must land in the vault, and local seed must reach remote.
        let remoteFile = runGitSync(["show", "main:Remote.md"], at: vault)
        XCTAssertEqual(remoteFile.code, 0, "Remote.md missing after integrate: \(remoteFile.stderr.prefix(200))")
        let localOnRemote = runGitSync(["show", "main:Welcome.md"], at: r)
        XCTAssertEqual(localOnRemote.code, 0, "Welcome.md missing from remote: \(localOnRemote.stderr.prefix(200))")
    }

    // MARK: - Process helpers

    private struct GitOut { let stdout: String; let stderr: String; let code: Int32 }
    private func runGitSync(_ args: [String], at cwd: URL) -> GitOut {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = args
        p.currentDirectoryURL = cwd
        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.environment = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM": "1"]
        try? p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return GitOut(stdout: String(data: data, encoding: .utf8) ?? "",
                      stderr: String(data: errData, encoding: .utf8) ?? "",
                      code: p.terminationStatus)
    }


}
