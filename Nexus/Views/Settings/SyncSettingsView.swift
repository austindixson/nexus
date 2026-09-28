import SwiftUI

/// Settings → Sync tab: full configuration for git-based cloud sync.
struct SyncSettingsView: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject private var sync = GitSyncService.shared

    @State private var remoteDraft = ""
    @State private var branchDraft = "main"
    @State private var nameDraft = ""
    @State private var emailDraft = ""
    @State private var secretDraft = ""
    @State private var debounceDraft = 120
    @State private var intervalDraft = 300
    @State private var keySavedMessage: String?
    @State private var enableError: String?

    var body: some View {
        Form {
            Section("Status") {
                LabeledContent("Phase", value: sync.statusSummary)
                if let last = sync.status.lastSyncAt {
                    LabeledContent("Last sync", value: GitSyncService.relative(last))
                }
                if !sync.settings.enabled {
                    Text("Off. Nexus never touches the network for sync until you enable it for this vault.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Remote") {
                TextField("Remote URL", text: $remoteDraft, prompt: Text("https://…, git@host:repo.git, or /path/to/vault.git"))
                    .font(.callout.monospaced())
                    .disableAutocorrection(true)
                if let parsed = GitRemote.parse(remoteDraft) {
                    Label(parsed.displayLabel + (parsed.isNetworkRemote ? " (network)" : " (local)"), systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else if !remoteDraft.isEmpty {
                    Label("Invalid remote. Use https://, ssh://, git@host:path, or an absolute path to a bare repo. file:// and other schemes are rejected.", systemImage: "xmark.circle")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                TextField("Branch", text: $branchDraft)
                HStack {
                    TextField("Git user name", text: $nameDraft)
                    TextField("Git email", text: $emailDraft)
                }
                Text("Identity is written to this vault's local git config only — global config is untouched.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Section("Timing") {
                Stepper("Autocommit after \(debounceDraft)s of quiet", value: $debounceDraft, in: SyncSettings.debounceRange, step: 30)
                Stepper("Sync every \(intervalDraft / 60) min", value: $intervalDraft, in: SyncSettings.intervalRange, step: 60)
            }

            Section {
                HStack {
                    SecureField("Token / SSH passphrase (stored in Keychain)", text: $secretDraft)
                    Button("Save key") {
                        guard !sync.settings.keychainAccount.isEmpty else {
                            keySavedMessage = "No keychain account set."
                            return
                        }
                        sync.storeSecret(secretDraft, for: sync.settings.keychainAccount)
                        secretDraft = ""
                        keySavedMessage = "Key stored in Keychain (com.ghost64.nexus.sync)."
                    }
                    Button("Delete key") {
                        sync.deleteSecret(for: sync.settings.keychainAccount)
                        keySavedMessage = "Key removed from Keychain."
                    }
                }
                TextField("Keychain account label", text: $accountDraft)
                if let msg = keySavedMessage {
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Credentials")
            } footer: {
                Text("HTTPS remotes can use a token here; ssh:// remotes use ssh-agent by default. Keys never live inside the vault or UserDefaults.")
                    .font(.caption2)
            }

            if !sync.status.conflictPaths.isEmpty {
                Section("Conflicts") {
                    ForEach(sync.status.conflictPaths, id: \.self) { path in
                        HStack {
                            Text(path)
                                .font(.caption.monospaced())
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button("Keep local") {
                                Task { try? await sync.resolveConflict(path: path, side: .ours) }
                            }
                            Button("Keep remote") {
                                Task { try? await sync.resolveConflict(path: path, side: .theirs) }
                            }
                        }
                    }
                }
            }

            Section {
                if sync.settings.enabled {
                    HStack {
                        Button("Sync now") {
                            Task { await sync.syncNow() }
                        }
                        .disabled(sync.status.isBusy)
                        Button("Turn off sync", role: .destructive) {
                            sync.disableSync()
                        }
                    }
                } else {
                    Button("Enable sync for this vault") {
                        applyDraft()
                    }
                    .disabled(remoteDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let err = enableError ?? sync.status.lastError, sync.status.phase == .error {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            } footer: {
                Text("Enabling makes the vault a git repository and pushes the first snapshot. Local state (.nexus/) is git-ignored and never leaves this machine.")
                    .font(.caption2)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: loadDraft)
        .onChange(of: sync.settingsRevision) { _, _ in loadDraft() }
    }

    @State private var accountDraft = "default"

    private func loadDraft() {
        let s = sync.settings
        remoteDraft = s.remote
        branchDraft = s.branch
        nameDraft = s.authorName
        emailDraft = s.authorEmail
        debounceDraft = s.debounceSeconds
        intervalDraft = s.intervalSeconds
        accountDraft = s.keychainAccount
        keySavedMessage = nil
        enableError = nil
    }

    private func applyDraft() {
        enableError = nil
        guard GitRemote.parse(remoteDraft) != nil else {
            enableError = "Remote is not a valid git URL or absolute path."
            return
        }
        var s = sync.settings
        s.branch = branchDraft.isEmpty ? "main" : branchDraft
        s.authorName = nameDraft
        s.authorEmail = emailDraft
        s.debounceSeconds = debounceDraft
        s.intervalSeconds = intervalDraft
        s.keychainAccount = accountDraft
        sync.saveSettings(s)
        sync.enableSync(remoteRaw: remoteDraft)
    }
}
