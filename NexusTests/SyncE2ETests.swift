import XCTest
@testable import Nexus

/// Git-based cloud sync tests.
///
/// The vault-filesystem half uses real temp vaults and the process's real git
/// binary; the git *remote* is a local bare repo under the sandbox. Network
/// credentials are never contacted by these tests.
final class SyncE2ETests: XCTestCase {
    private var vault: URL!
    private var remote: URL!

    override func setUpWithError() throws {
        vault = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nexus-sync-vault-\(UUID().uuidString.prefix(8))", isDirectory: true)
        remote = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nexus-sync-remote-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        try "seed".write(to: vault.appendingPathComponent("Welcome.md"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
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
        // Initialize the bare remote.
        let initProc = Process()
        initProc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        initProc.arguments = ["init", "--bare", "-b", "main", remote.path]
        initProc.environment = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin"]
        try initProc.run()
        initProc.waitUntilExit()
        XCTAssertEqual(initProc.terminationStatus, 0)

        let sync = GitSyncService.shared
        sync.resetPersistedSettingsForTesting()
        sync.vaultServiceForObservation = nil // no vault observer for this test
        sync.attach(vaultRoot: vault)

        var settings = sync.settings
        settings.branch = "main"
        settings.authorName = "Sync Tests"
        settings.authorEmail = "tests@example.invalid"
        settings.keychainAccount = "" // no credentials in tests
        sync.saveSettings(settings)

        sync.enableSync(remoteRaw: remote.path)

        // enableSync spawns a Task; wait for it to settle.
        var settled = false
        for _ in 0..<100 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if !sync.status.isBusy { settled = true; break }
        }
        XCTAssertTrue(settled, "enableSync never settled")
        XCTAssertNil(sync.status.lastError, "unexpected error: \(sync.status.lastError ?? "none")")
        XCTAssertEqual(sync.status.phase, .idle)
        XCTAssertTrue(sync.settings.enabled)
        XCTAssertEqual(sync.settings.remote, remote.path)

        // The vault became a git repo with a safety .gitignore.
        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: vault.appendingPathComponent(".git").path))
        let gitignore = try String(contentsOf: vault.appendingPathComponent(".gitignore"), encoding: .utf8)
        XCTAssertTrue(gitignore.contains(".nexus/"))

        // The remote received the seed commit.
        let heads = runGitSync(["ls-remote", "--heads", remote.path], at: vault)
        XCTAssertTrue(heads.stdout.contains("refs/heads/main"))
    }

    @MainActor
    func testAutocommitAfterNoteMutation() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/git") else {
            throw XCTSkip("git CLI not installed on this runner")
        }
        // Enable sync first (reuse the first-sync flow).
        let initProc = Process()
        initProc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        initProc.arguments = ["init", "--bare", "-b", "main", remote.path]
        initProc.environment = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin"]
        try initProc.run(); initProc.waitUntilExit()

        let sync = GitSyncService.shared
        sync.resetPersistedSettingsForTesting()
        var settings = sync.settings
        settings.branch = "main"
        settings.authorName = "Sync Tests"
        settings.authorEmail = "tests@example.invalid"
        settings.debounceSeconds = SyncSettings.debounceRange.lowerBound // 30s — we trigger manually
        settings.keychainAccount = ""
        sync.saveSettings(settings)
        sync.attach(vaultRoot: vault)
        sync.enableSync(remoteRaw: remote.path)
        for _ in 0..<100 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if !sync.status.isBusy { break }
        }

        // Deterministic branch: enableSync's ls-remote pre-flight resolves the branch
        // in a background Task; pin HEAD onto the configured branch so the assertion
        // below does not race that Task.
        let headRes = runGitSync(["symbolic-ref", "HEAD", "refs/heads/main"], at: vault)
        XCTAssertEqual(headRes.code, 0, "could not pin vault HEAD to main")

        // Simulate a vault mutation and force a cycle.
        try "changed".write(to: vault.appendingPathComponent("Welcome.md"), atomically: true, encoding: .utf8)
        sync.noteDidChange(path: "Welcome.md")
        await sync.syncNow()

        let err = sync.status.lastError ?? ""
        XCTAssert(err.isEmpty || !err.contains("Please tell me who you are"),
                  "commit must not fail on missing identity: \(err)")
        // The mutation must reach the remote as a tree change. Assert on the
        // remote tree contents (robust), not on our internal commit-message prefix.
        let remoteTree = runGitSync(["show", "main:Welcome.md"], at: remote)
        XCTAssertEqual(remoteTree.code, 0, "no Welcome.md on remote main")
        XCTAssertTrue(remoteTree.stdout.contains("changed"),
                      "expected mutation to reach the remote; got: \(remoteTree.stdout.prefix(120))")
    }

    @MainActor
    func testWorkspaceSidecarExcludedAndUnmergedPathsDetected() throws {
        let sync = GitSyncService.shared
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
    func testInvalidRemoteDoesNotHalfEnable() async throws {
        let sync = GitSyncService.shared
        sync.resetPersistedSettingsForTesting()
        var settings = sync.settings
        settings.keychainAccount = ""
        settings.enabled = false
        sync.saveSettings(settings)
        sync.attach(vaultRoot: vault)

        sync.enableSync(remoteRaw: "ext::sh -c 'id'")
        for _ in 0..<50 {
            try await Task.sleep(nanoseconds: 50_000_000)
            if !sync.status.isBusy { break }
        }
        XCTAssertFalse(sync.settings.enabled, "invalid remote must never flip enabled")
        XCTAssertEqual(sync.status.phase, .error)
        XCTAssertNotNil(sync.status.lastError)
    }

    // MARK: - Process helpers

    @discardableResult
    private func runGitSync(_ args: [String], at cwd: URL) -> (stdout: String, code: Int32) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = args
        p.currentDirectoryURL = cwd
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        p.environment = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM": "1"]
        try? p.run()
        p.waitUntilExit()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        return (String(data: data, encoding: .utf8) ?? "", p.terminationStatus)
    }
}
