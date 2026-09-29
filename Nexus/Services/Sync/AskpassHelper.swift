import Foundation

/// Hands a Keychain-stored secret to git for a single command without ever
/// placing it in the environment, on disk in the vault, or in `.git/config`.
///
/// How it works:
/// 1. The secret is written to a 0600 file in the system temp directory.
/// 2. A 0700 `askpass` shell script in the same temp directory echoes that file.
/// 3. `runGit` exports `GIT_ASKPASS`/`SSH_ASKPASS` pointing at the script.
/// 4. Both files are deleted the moment the git command exits.
///
/// HTTPS: git asks for a username then a password; the password is delivered
/// from the file (the username arrives with the prompt and is discarded).
/// SSH: private-key passphrases are answered the same way when the user has
/// added a key without ssh-agent (BatchMode still prevents any interactive hang).
///
/// The helper is installed per git invocation via
/// `GitSyncService.withAskpass(arguments:_:)` and is only ever active for
/// network remotes — local-path remotes never receive the secret.
struct AskpassHelper {
    let helperPath: String
    let secretPath: String
    /// ssh gets `-o StrictHostKeyChecking=yes` when the user has not opted into
    /// a LAN/local remote (network remotes should verify host keys).
    let strictHostKey: Bool

    /// The currently-active helper context for git invocations on this task.
    /// `withAskpass` installs it around a single command and restores the
    /// previous value afterwards; it is never a process-wide ambient secret.
    nonisolated(unsafe) static var current: AskpassHelper?

    private static let scriptBody = """
    #!/bin/sh
    # Nexus askpass helper — prints the stored credential for git. Deleted on exit.
    cat "$NEXUS_ASKPASS_SECRET_FILE" 2>/dev/null || true
    """

    init?(secret: String) {
        guard !secret.isEmpty else { return nil }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("com.ghost64.nexus.sync", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            return nil
        }

        let nonce = UUID().uuidString
        let secretURL = dir.appendingPathComponent("secret-\(nonce)")
        let helperURL = dir.appendingPathComponent("askpass-\(nonce).sh")

        // Secret file: 0600, atomic.
        do {
            try secret.write(to: secretURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: secretURL.path)
        } catch {
            return nil
        }

        // Helper script: 0700, never contains the secret itself.
        do {
            try Self.scriptBody.write(to: helperURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helperURL.path)
        } catch {
            try? FileManager.default.removeItem(at: secretURL)
            return nil
        }

        helperPath = helperURL.path
        secretPath = secretURL.path
        strictHostKey = true
    }

    /// Extra environment for `runGit` while this helper is installed.
    var environmentExtras: [String: String] {
        var extras: [String: String] = [
            "GIT_ASKPASS": helperPath,
            "SSH_ASKPASS": helperPath,
            "NEXUS_ASKPASS_SECRET_FILE": secretPath,
            "DISPLAY": ":0", // makes ssh consult SSH_ASKPASS instead of the tty
            "SSH_ASKPASS_DELAY": "1000000",
        ]
        if strictHostKey {
            extras["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes -o StrictHostKeyChecking=yes"
        }
        return extras
    }

    /// Delete the temp files. `withAskpass` calls this in its `defer`.
    func cleanup() {
        try? FileManager.default.removeItem(atPath: helperPath)
        try? FileManager.default.removeItem(atPath: secretPath)
    }
}

extension GitSyncService {
    /// Install an askpass helper around a git command when the remote is a
    /// network URL and a Keychain secret exists. Restores the previous helper
    /// afterwards and scrubs temp files.
    func withAskpassInstalled<R>(
        using remote: GitRemote?,
        _ body: () async throws -> R
    ) async rethrows -> R {
        guard let remote, remote.isNetworkRemote,
              !settings.keychainAccount.isEmpty,
              let secret = loadSecret(for: settings.keychainAccount)
        else {
            return try await body()
        }
        guard let helper = AskpassHelper(secret: secret) else {
            return try await body()
        }
        let previous = AskpassHelper.current
        AskpassHelper.current = helper
        defer {
            AskpassHelper.current = previous
            helper.cleanup()
        }
        return try await body()
    }
}
