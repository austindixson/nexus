import Foundation
import AppKit

/// Headless one-shot sync run for e2e verification and CI:
///
///   Nexus --sync-smoke <vault-path>
///
/// Opens the vault, loads its `.nexus/sync.json`, runs `syncNow()` once with an
/// explicit Keychain account override, prints a JSON report, exits 0/1.
/// Never writes anything to the vault beyond what a normal sync cycle writes.
enum SyncSmoke {
    /// `CommandLine.arguments` after `--sync-smoke <vault-path>`.
    static var extraArguments: [String] = []

    static func run(vaultPath: String) {
        var accountOverride: String?
        var remoteOverride: String?
        var i = 0
        let extras = extraArguments
        while i < extras.count {
            switch extras[i] {
            case "--keychain-account" where i + 1 < extras.count:
                accountOverride = extras[i + 1]; i += 2
            case "--remote" where i + 1 < extras.count:
                remoteOverride = extras[i + 1]; i += 2
            default:
                i += 1
            }
        }

        let url = URL(fileURLWithPath: (vaultPath as NSString).expandingTildeInPath)
        FileHandle.standardError.write("nexus sync-smoke: opening vault \(url.path)\n".data(using: .utf8)!)

        let sync = GitSyncService.shared
        Task { @MainActor in
            // Seed the settings the vault's .nexus/sync.json may not carry yet.
            var seeded = sync.settings
            seeded.enabled = true
            if let remoteOverride, GitRemote.parse(remoteOverride) != nil {
                seeded.remote = remoteOverride
            }
            if let accountOverride {
                seeded.keychainAccount = accountOverride
            }
            sync.saveSettings(seeded)
            sync.attach(vaultRoot: url)
            // Give the vault's FSEvents bootstrap a moment to settle, then run one cycle.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await sync.syncNow()
            var report: [String: String] = [
                "vault": url.path,
                "phase": sync.status.phase.rawValue,
                "action": sync.status.lastAction,
            ]
            if let err = sync.status.lastError { report["error"] = err }
            report["ahead"] = String(sync.status.aheadCount)
            report["behind"] = String(sync.status.behindCount)
            report["dirty"] = String(sync.status.dirtyCount)
            report["conflicts"] = String(sync.status.conflictPaths.count)
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                FileHandle.standardError.write(((String(data: data, encoding: .utf8) ?? "{}") + "\n").data(using: .utf8)!)
            }
            // Give pipes a beat to flush, then exit the process.
            try? await Task.sleep(nanoseconds: 200_000_000)
            let ok = sync.status.phase != .error
            exit(ok ? 0 : 1)
        }
    }
}
